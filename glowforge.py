#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""glowforge - zamienia zainstalowany font macOS na wersje swiecaca w HDR.

Idea: font wektorowy nie niesie koloru, wiec nie da sie w nim zapisac HDR.
Ale font MOZE zawierac tabele `sbix` (Apple: bitmapowe glify), a kazdy glif
w sbix to osobny plik PNG. PNG potrafi nieesc profil koloru (`iCCP`) albo
sygnalizacje HDR (`cICP`, PNG 3rd Edition). Wystarczy wiec:

    1. wybrac zainstalowany font,
    2. zrasteryzowac jego glify do bitmap,
    3. zapisac je jako PNG z `iCCP` albo `cICP`,
    4. wstrzyknac to jako nowa tabele `sbix` do KOPII fontu.

Tabela `sbix` ma pierszenstwo nad obrysami, wiec tekst skladany tym fontem
renderuje sie jako bitmapy - i te bitmapy swieca.

Stopien swiecenia reguluje sie opcja --boost: ile razy jasniej od bialej
plamy SDR ma swiecic glif. Bez --boost wchodzimy w pelny zakres PQ, czyli
dokladnie w to, co robi logo z ogloszenia (10000 cd/m2).

Uzycie:
    glowforge list [--query Q]
    glowforge inspect FONT
    glowforge convert FONT [opcje]
    glowforge verify FONT

Zestawy znakow: ascii | latin | pl | all
Tryby koloru : srgb (kontrola) | iccp (domyslnie) | cicp | both
"""
from __future__ import annotations

import argparse
import math
import os
import re
import struct
import subprocess
import sys
import zlib

# --------------------------------------------------------------------------
# stale
# --------------------------------------------------------------------------
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = HERE
DEFAULT_PROFILE = os.path.join(ROOT, "profiles", "pq-bt2020.icc")
OUTDIR = os.path.join(ROOT, "out")

FONT_DIRS = [
    os.path.join(os.path.expanduser("~"), "Library", "Fonts"),
    "/Library/Fonts",
    "/System/Library/Fonts",
    "/System/Library/Fonts/Supplemental",
]

FONT_EXT = {".ttf", ".ttc", ".otf", ".otc", ".dfont", ".suit"}

# tabele niosace kolor (czyli takie, ktore moga nieesc HDR)
COLOUR_TABLES = ("sbix", "CBDT", "CBLC", "COLR", "CPAL", "SVG ", "EBDT", "EBLC", "bdat", "bloc")

# SDR biel w HDR: BT.2408 przyjmuje 203 cd/m2 (macOS wychodzi ~194, blisko)
SDR_WHITE_NITS = 203.0
PQ_MAX_NITS = 10000.0

# cICP: 09 = pierwotne BT.2020, 10 = transfer PQ, 00 = macierz jednostkowa, 01 = pelny zakres
CICP_PQ_BT2020 = bytes([0x09, 0x10, 0x00, 0x01])

CHARSETS = {
    "ascii": list(range(0x20, 0x7F)),
    "latin": list(range(0x20, 0x7F)) + list(range(0xA0, 0x180)),
    "pl": list(range(0x20, 0x7F)) + [ord(c) for c in "ąćęłńóśźżĄĆĘŁŃÓŚŹŻ„”–—…"],
    "all": None,  # wszystko, co jest w cmap
}


def pq_code(nits, bits=8):
    """Kod PQ (SMPTE ST.2084) dla danej luminancji - inverse EOTF."""
    y = min(1.0, max(0.0, nits / PQ_MAX_NITS))
    m1, m2 = 2610.0 / 16384.0, 2523.0 / 4096.0 * 128.0
    c1, c2, c3 = 3424.0 / 4096.0, 2413.0 / 4096.0 * 32.0, 2392.0 / 4096.0 * 32.0
    ym = y ** m1
    yp = ((c1 + c2 * ym) / (1.0 + c3 * ym)) ** m2
    return int(round(yp * ((1 << bits) - 1)))


def pq_nits(code, bits=8):
    """Luminancja dla kodu PQ - EOTF."""
    yp = code / float((1 << bits) - 1)
    m1, m2 = 2610.0 / 16384.0, 2523.0 / 4096.0 * 128.0
    c1, c2, c3 = 3424.0 / 4096.0, 2413.0 / 4096.0 * 32.0, 2392.0 / 4096.0 * 32.0
    p = yp ** (1.0 / m2)
    num, den = max(p - c1, 0.0), c2 - c3 * p
    if den <= 0:
        return 0.0
    return PQ_MAX_NITS * (num / den) ** (1.0 / m1)


# --------------------------------------------------------------------------
# PNG
# --------------------------------------------------------------------------
def png_chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def png_rgba(w, h, rows, extras=b""):
    """8-bit RGBA (colortype 6). Profil RGB jest tu zgodny ze specyfikacja -
    RGBA jest typem koloru opartym na RGB. (Pulapka, w ktora wpadlismy przy
    logo: profil RGB wpakowany w obraz GRAYSCALE - czytniki to odrzucaja.)"""
    raw = bytearray()
    for y in range(h):
        raw.append(0)          # filtr 0 (None)
        raw += rows[y]
    return (b"\x89PNG\r\n\x1a\n"
            + png_chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + extras
            + png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + png_chunk(b"IEND", b""))


def colour_chunks(mode, profile, pq_bytes):
    """Zwraca (chunki, opis) dla wybranego sposobu opisania koloru.

    Kolejnosc pierszenstwa wg PNG 3rd Edition:
        cICP  >  iCCP  >  sRGB  >  cHRM+gAMA
    """
    if mode == "srgb":
        return png_chunk(b"sRGB", b"\x00"), "sRGB (kontrola, SDR)"
    if mode == "iccp":
        data = b"ICC Profile\x00\x00" + zlib.compress(profile, 9)
        return png_chunk(b"iCCP", data), "iCCP = %d B profilu PQ" % len(profile)
    if mode == "cicp":
        return png_chunk(b"cICP", CICP_PQ_BT2020), "cICP = 09 10 00 01 (PQ/BT.2020)"
    if mode == "both":
        data = b"ICC Profile\x00\x00" + zlib.compress(profile, 9)
        return (png_chunk(b"iCCP", data) + png_chunk(b"cICP", CICP_PQ_BT2020),
                "iCCP + cICP (cICP wygrywa)")
    raise ValueError("nieznany tryb: %s" % mode)


def png_list_chunks(data):
    """Lista chunkow w PNG (do weryfikacji)."""
    out, p = [], 8
    while p + 8 <= len(data):
        ln = struct.unpack(">I", data[p:p + 4])[0]
        out.append((data[p + 4:p + 8].decode("latin-1"), ln))
        p += 12 + ln
    return out


# --------------------------------------------------------------------------
# czytanie sfnt bez fontTools (szybkie - do indeksu i inspekcji)
# --------------------------------------------------------------------------
def sfnt_faces(path):
    """Lista offsetow tablic-directory w pliku. Jeden wpis = jeden font."""
    with open(path, "rb") as fh:
        head = fh.read(16)
        if len(head) < 12:
            return None, None
        if head[:4] == b"ttcf":
            ver, n = struct.unpack(">II", head[4:12])
            fh.seek(12)
            offs = struct.unpack(">%dI" % n, fh.read(4 * n))
            return "ttc", list(offs)
        if head[:4] in (b"\x00\x01\x00\x00", b"OTTO", b"true", b"ttcf"):
            return {b"\x00\x01\x00\x00": "ttf", b"OTTO": "otf",
                    b"true": "ttf(legacy)"}[head[:4]], [0]
        if head[:4] == b"typ1":
            return "typ1", [0]
    return None, None


def sfnt_tables(path, off=0):
    """{tag: (offset, dlugosc)} dla danego katalogu tabel."""
    with open(path, "rb") as fh:
        fh.seek(off)
        hdr = fh.read(12)
        if len(hdr) < 12:
            return {}
        n = struct.unpack(">H", hdr[4:6])[0]
        recs = fh.read(16 * n)
    out = {}
    for i in range(n):
        tag, _cs, o, ln = struct.unpack(">4sIII", recs[16 * i:16 * (i + 1)])
        out[tag.decode("latin-1")] = (o, ln)
    return out


def sfnt_blob(path, loc):
    with open(path, "rb") as fh:
        fh.seek(loc[0])
        return fh.read(loc[1])


def parse_name_table(blob):
    """{nameID: tekst} z tabeli 'name' (format 0/1)."""
    if len(blob) < 6:
        return {}
    fmt, count, str_off = struct.unpack(">HHH", blob[:6])
    out = {}
    for i in range(count):
        rec = blob[6 + 12 * i:6 + 12 * (i + 1)]
        if len(rec) < 12:
            break
        pid, eid, lid, nid, ln, off = struct.unpack(">HHHHHH", rec)
        raw = blob[str_off + off:str_off + off + ln]
        try:
            if pid == 3:
                txt = raw.decode("utf-16-be", "replace")
            elif pid == 1:
                txt = raw.decode("mac_roman", "replace")
            elif pid == 0:
                txt = raw.decode("utf-16-be", "replace")
            else:
                continue
        except Exception:
            continue
        if nid not in out or (pid == 3 and not out[nid]):
            out[nid] = txt.strip("\x00").strip()
    return out


def describe_font(path, face=0):
    kind, offs = sfnt_faces(path)
    if not kind:
        return None
    tabs = sfnt_tables(path, offs[face])
    info = {
        "path": path, "container": kind, "faces": len(offs), "face": face,
        "glyphs": None, "family": None, "subfamily": None, "ps": None,
        "tables": sorted(tabs), "colour": [t for t in COLOUR_TABLES if t in tabs],
        "upem": None,
    }
    if "name" in tabs:
        nm = parse_name_table(sfnt_blob(path, tabs["name"]))
        info["family"] = nm.get(1) or nm.get(16)
        info["subfamily"] = nm.get(2)
        info["ps"] = nm.get(6)
    if "maxp" in tabs:
        b = sfnt_blob(path, tabs["maxp"])
        if len(b) >= 6:
            info["glyphs"] = struct.unpack(">H", b[4:6])[0]
    if "head" in tabs:
        b = sfnt_blob(path, tabs["head"])
        if len(b) >= 20:
            info["upem"] = struct.unpack(">H", b[18:20])[0]
    return info


def scan_fonts(dirs=None):
    seen, out = set(), []
    for d in (dirs or FONT_DIRS):
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            ext = os.path.splitext(name)[1].lower()
            if ext not in FONT_EXT:
                continue
            p = os.path.join(d, name)
            if not os.path.isfile(p) or p in seen:
                continue
            seen.add(p)
            try:
                if os.path.getsize(p) < 64:
                    continue
                info = describe_font(p)
            except Exception:
                continue
            if info:
                out.append(info)
    return out


# --------------------------------------------------------------------------
# wybor fontu
# --------------------------------------------------------------------------
def resolve(query, fonts=None):
    """Znajduje font po sciezce, nazwie rodziny, nazwie PostScript lub pliku."""
    if os.path.exists(query):
        info = describe_font(os.path.abspath(query))
        if info:
            return info
        raise SystemExit("nie umiem odczytac fontu: %s" % query)

    fonts = fonts or scan_fonts()
    q = query.lower()
    exact, part = [], []
    for f in fonts:
        hay = [f["family"] or "", f["ps"] or "", os.path.basename(f["path"])]
        if any((h or "").lower() == q for h in hay):
            exact.append(f)
        elif any(q in (h or "").lower() for h in hay):
            part.append(f)
    hits = exact or part
    if not hits:
        raise SystemExit("nie znalazlem fontu: %r  (uzyj: glowforge list)" % query)
    if len(hits) > 1 and not exact:
        print("pasuje %d fontow:" % len(hits))
        for f in hits[:25]:
            print("   %-28s %-12s %s" % (f["family"], f["subfamily"] or "", f["path"]))
        raise SystemExit("podaj dokladniejsza nazwe albo pelna sciezke")
    return hits[0]


# --------------------------------------------------------------------------
# rasteryzacja glifow
# --------------------------------------------------------------------------
def rasterise(fontpath, face, ch, ppem):
    """Zwraca (szer, wys, bajty_alfa, off_x, off_y) albo None.

    off_x / off_y to polozenie LEWEJ i DOLNEJ krawedzi obrazu wzgledem
    punktu wstawienia (origin) na linii bazowej, w pikselach, w gore = +.

    Taka jest definicja z OpenType:
        originOffsetX - "position of the LEFT edge of the bitmap graphic in
                         relation to the glyph design space origin"
        originOffsetY - "position of the BOTTOM edge of the bitmap graphic in
                         relation to the glyph design space origin"

    Uwaga: wpisanie tu gornej krawedzi (czesty blad) powoduje, ze obraz
    laduje o cala swoja wysokosc za wysoko. Renderery przycinaja dodatkowo
    bitmape do prostokatu obrysu glifu, wiec z przesunietego obrazu zostaje
    jednopikselowa kreska - i wyglada to jak zupelnie inny blad.
    """
    from PIL import Image, ImageDraw, ImageFont

    f = ImageFont.truetype(fontpath, ppem, index=face)
    ascent, _descent = f.getmetrics()

    bb = f.getbbox(ch)
    if not bb:
        return None
    l0, t0, r0, b0 = (math.floor(v) for v in bb)
    l0 -= 1
    t0 -= 1
    r0 += 1
    b0 += 1
    if r0 <= l0 or b0 <= t0:
        return None

    im = Image.new("L", (r0 - l0, b0 - t0), 0)
    ImageDraw.Draw(im).text((-l0, -t0), ch, font=f, fill=255, anchor="la")

    tight = im.getbbox()
    if not tight:
        return None            # glif bez tuszu (spacja)
    if tight != (0, 0, im.width, im.height):
        im = im.crop(tight)
        l0 += tight[0]
        t0 += tight[1]

    # linia bazowa jest w tym ukladzie na wysokosci 'ascent'
    bottom = t0 + im.height
    return im.width, im.height, im.tobytes(), l0, ascent - bottom


def bitmap_png(w, h, alpha, rgb, extras):
    a = alpha
    rows = []
    for y in range(h):
        row = bytearray()
        base = y * w
        for x in range(w):
            row += bytes((rgb[0], rgb[1], rgb[2], a[base + x]))
        rows.append(bytes(row))
    return png_rgba(w, h, rows, extras)


# --------------------------------------------------------------------------
# konwersja
# --------------------------------------------------------------------------
def collect_chars(font, charset, chars, rng):
    cmap = font.getBestCmap()
    got = set()
    if chars:
        pool = [ord(c) for c in chars]
    elif rng:
        pool = []
        for part in rng.split(","):
            part = part.strip()
            if "-" in part:
                a, b = part.split("-", 1)
                pool += list(range(int(a, 0), int(b, 0) + 1))
            elif part:
                pool.append(int(part, 0))
    elif charset == "all":
        pool = sorted(cmap)
    else:
        pool = CHARSETS[charset]
    for cp in pool:
        if cp in cmap:
            got.add(cp)
    return sorted(got), cmap


def family_name(base_family, override, mode, boost):
    """Rodzina musi byc UNIKALNA dla kazdego wariantu.

    Bez tego font HDR i kontrola SDR maja ta sama nazwe rodziny i ten sam
    PostScript name, wiec system traktuje je jako jeden font - drugi sie nie
    zaimportuje ("already installed").
    """
    if override:
        fam = override
    else:
        base = re.sub(r"\s+(Regular|Bold|Italic|Light|Medium|Thin|Black)$", "",
                      (base_family or "Font")).strip()
        fam = base + " Glow"
        if mode == "srgb":
            fam += " SDR"
        elif boost > 0:
            fam += " %gx" % boost
    return fam, re.sub(r"[^A-Za-z0-9]", "", fam)


def find_installed(ps_name):
    """Szuka juz zainstalowanego fontu o tym PostScript name."""
    for d in (os.path.join(os.path.expanduser("~"), "Library", "Fonts"),
              "/Library/Fonts"):
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if os.path.splitext(name)[1].lower() not in FONT_EXT:
                continue
            p = os.path.join(d, name)
            try:
                info = describe_font(p)
            except Exception:
                continue
            if info and info["ps"] == ps_name:
                return p
    return None


def rename(font, family):
    """Zmienia nazwy, zeby wersja swiecaca nie kolidowala z oryginalem."""
    name = font["name"]
    ps = re.sub(r"[^A-Za-z0-9]", "", family)
    for rec in list(name.names):
        if rec.nameID in (1, 16):
            name.setName(family, rec.nameID, rec.platformID, rec.platEncID, rec.langID)
        elif rec.nameID == 4:
            name.setName(family, rec.nameID, rec.platformID, rec.platEncID, rec.langID)
        elif rec.nameID == 6:
            name.setName(ps, rec.nameID, rec.platformID, rec.platEncID, rec.langID)
        elif rec.nameID == 3:
            name.setName("GLOWFORGE;" + ps, rec.nameID, rec.platformID,
                         rec.platEncID, rec.langID)


def convert(args):
    from fontTools.ttLib import TTFont, newTable
    from fontTools.ttLib.tables.sbixGlyph import Glyph
    from fontTools.ttLib.tables.sbixStrike import Strike

    info = resolve(args.font)
    face = args.face
    if face >= info["faces"]:
        raise SystemExit("font ma %d czcionek, nie ma numeru %d" % (info["faces"], face))

    profile = b""
    if args.mode in ("iccp", "both"):
        if not os.path.exists(args.profile):
            raise SystemExit("brak profilu: %s" % args.profile)
        profile = open(args.profile, "rb").read()

    ppems = [int(x) for x in args.ppem.split(",") if x.strip()]
    rgb = tuple(int(args.color[i:i + 2], 16) for i in (0, 2, 4))

    # --- poziom swiecenia -------------------------------------------------
    if args.boost > 0:
        nits = min(PQ_MAX_NITS, args.boost * SDR_WHITE_NITS)
    else:
        nits = PQ_MAX_NITS
    code = pq_code(nits)
    level = (code, code, code)

    print("font         : %s %s" % (info["family"], info["subfamily"] or ""))
    print("plik         : %s%s" % (info["path"],
          "" if info["faces"] == 1 else "  (czcionka %d z %d)" % (face, info["faces"])))
    print("glifow       : %d   upem: %s" % (info["glyphs"], info["upem"]))
    print("tabele koloru: %s" % (", ".join(info["colour"]) or "brak"))
    print("tryb         : %s" % args.mode)
    if args.mode != "srgb":
        print("poziom       : kod PQ %d  =  %s cd/m2  =  %.1fx bieli SDR"
              % (code, ("%.0f" % nits) if nits < PQ_MAX_NITS else "10000",
                 nits / SDR_WHITE_NITS))
    print()

    font = TTFont(info["path"], fontNumber=face, recalcBBoxes=False,
                  recalcTimestamp=False)
    chars, cmap = collect_chars(font, args.charset, args.chars, args.range)
    if not chars:
        raise SystemExit("zaden znak z wybranego zestawu nie jest w tym foncie")
    print("znakow       : %d  (%s)" % (len(chars), args.charset))

    # Poziom swiecenia siedzi w PIKSELLACH, nie w profilu: ten sam profil PQ
    # opisuje zakres 0..10000 cd/m2, a o tym jak jasno swieci decyduje to,
    # jaka wartosc kodu wpiszemy w piksel. 255 = 10000 cd/m2 (jak logo),
    # mniejszy kod = proporcjonalnie ciemniej. Skalujemy caly kolor, zeby
    # ewentualny barwny tusz zachowal odcien.
    if args.mode != "srgb" and code < 255:
        rgb = tuple(min(255, int(round(v * code / 255.0))) for v in rgb)
    extras, desc = colour_chunks(args.mode, profile, level)
    print("kolor        : %s   RGB tuszu=%s" % (desc, rgb))
    print()

    if "sbix" in font:
        print("uwaga: font mial juz tabele sbix - zostanie zastapiona")

    sbix = newTable("sbix")
    sbix.version = 1
    sbix.flags = 1              # bit0 = 1 (wymog); bit1 = 0 -> tylko bitmapy

    total_px = 0
    for ppem in ppems:
        strike = Strike(ppem=ppem, resolution=72)
        made = 0
        for cp in chars:
            gname = cmap[cp]
            try:
                r = rasterise(info["path"], face, chr(cp), ppem)
            except Exception:
                continue
            if not r:
                continue
            w, h, alpha, ox, oy = r
            png = bitmap_png(w, h, alpha, rgb, extras)
            strike.glyphs[gname] = Glyph(
                glyphName=gname, graphicType="png",
                originOffsetX=ox, originOffsetY=oy, imageData=png)
            made += 1
            total_px += w * h
        sbix.strikes[ppem] = strike
        print("  strike %3d ppem : %4d glifow" % (ppem, made))

    if not any(s.glyphs for s in sbix.strikes.values()):
        raise SystemExit("nie udalo sie zrasteryzowac ani jednego glifu")

    if "sbix" in font:
        del font["sbix"]
    font["sbix"] = sbix

    family, ps_name = family_name(info["family"], args.name, args.mode, args.boost)
    rename(font, family)

    out = args.output or os.path.join(OUTDIR, ps_name + ".ttf")
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    font.save(out)

    size = os.path.getsize(out)
    n_img = sum(len(s.glyphs) for s in sbix.strikes.values())
    print()
    print("nazwa rodziny: %s" % family)
    print("PostScript   : %s" % ps_name)
    print("zapisane     : %s" % out)
    print("rozmiar      : %.1f MB   (%d glifo-obrazow, %.1f Mpx)"
          % (size / 1048576.0, n_img, total_px / 1e6))

    clash = find_installed(ps_name)
    if clash and not args.install:
        print()
        print("UWAGA: font o tej nazwie jest juz zainstalowany w systemie:")
        print("       %s" % clash)
        print("       Import sie nie uda (system powie \"already installed\").")
        print("       Nadaj inna nazwe:  --name \"%s 2\"" % family)

    if args.install:
        dst = os.path.join(os.path.expanduser("~"), "Library", "Fonts",
                           os.path.basename(out))
        with open(out, "rb") as a, open(dst, "wb") as b:
            b.write(a.read())
        print("zainstalowany: %s" % dst)
        # Sama kopia do ~/Library/Fonts NIE wystarcza — system nie zauwaza pliku
        # wrzuconego tam przez program. Rejestrujemy go trwale, jesli mamy
        # do dyspozycji pomocnik (scripts/rejestracja_trwala).
        helper = os.path.join(ROOT, "scripts", "rejestracja_trwala")
        if os.path.exists(helper):
            try:
                r = subprocess.run([helper, "reg", dst], capture_output=True, timeout=20)
                if r.returncode == 0:
                    print("              (zarejestrowany trwale — system widzi go od razu)")
                else:
                    print("              (rejestracja trwala sie nie udala;")
                    print("               uruchom: %s reg %s)" % (helper, dst))
            except Exception as e:
                print("              (nie udalo sie zarejestrowac trwale: %s)" % e)
        else:
            print("              (brak %s — zarejestruj recznie)" % helper)
        print("              (nowe aplikacje zobacza go od razu; w dzialajacych")
        print("               moze trzeba odswiezyc liste fontow)")
    return out


# --------------------------------------------------------------------------
# weryfikacja
# --------------------------------------------------------------------------
def verify(path):
    """Czyta gotowy plik i sprawdza, co naprawde jest w srodku."""
    info = describe_font(path)
    if not info:
        raise SystemExit("nie umiem odczytac: %s" % path)
    print("plik      : %s" % path)
    print("format    : %s, czcionek %d, glifow %d, upem %s"
          % (info["container"], info["faces"], info["glyphs"], info["upem"]))
    print("rodzina   : %s" % info["family"])
    print("tabele    : %s" % ", ".join(info["tables"]))
    print("kolor     : %s" % (", ".join(info["colour"]) or "brak"))
    if "sbix" not in info["tables"]:
        print("\nBRAK tabeli sbix - ten font nie bedzie swiecil.")
        return 1

    from fontTools.ttLib import TTFont
    f = TTFont(path)
    sbix = f["sbix"]
    print("\nsbix      : wersja %d, flagi %d (bit0=%d, bit1=rysuj-obrysy=%d)"
          % (sbix.version, sbix.flags, sbix.flags & 1, (sbix.flags >> 1) & 1))
    if not (sbix.flags & 1):
        print("  BLAD: bit 0 musi byc ustawiony")
    if (sbix.flags >> 1) & 1:
        print("  uwaga: bit 1 ustawiony -> pod bitmapami rysowane beda obrysy")

    bad = 0
    for ppem in sorted(sbix.strikes):
        st = sbix.strikes[ppem]
        types = {}
        for g in st.glyphs.values():
            types[g.graphicType] = types.get(g.graphicType, 0) + 1
        empty = types.pop(None, 0)
        print("  strike %3d ppem : %4d wpisow  bitmapy: %s  bez bitmapy: %d"
              % (ppem, len(st.glyphs),
                 ", ".join("%s x%d" % (k, v) for k, v in sorted(types.items())) or "brak",
                 empty))
        print("                   (glify bez bitmapy renderuja sie z obrysow)")

    # szczegolowy raport dla jednego glifu z bitmapa
    st = sbix.strikes[sorted(sbix.strikes)[0]]
    with_png = sorted(n for n, g in st.glyphs.items() if g.imageData)
    if not with_png:
        print("\nzadna bitmapa nie ma danych")
        return 1
    gname = with_png[0]
    g = st.glyphs[gname]
    print("\nprzyklad  : glif %r, %d B, originOffset=(%d, %d)"
          % (gname, len(g.imageData), g.originOffsetX, g.originOffsetY))
    ch = png_list_chunks(g.imageData)
    print("  chunki  : %s" % ", ".join("%s(%d)" % (t, n) for t, n in ch))
    ihdr = g.imageData[16:29]
    w, h, bd, ct = struct.unpack(">IIBB", ihdr[:10])
    print("  obrazek : %dx%d, %d bit, colortype %d (%s)"
          % (w, h, bd, ct, {0: "gray", 2: "RGB", 4: "gray+alpha", 6: "RGBA"}.get(ct, "?")))

    tags = [t for t, _ in ch]
    colour = [t for t in tags if t in ("iCCP", "cICP", "sRGB", "cHRM", "gAMA")]
    print("  kolor   : %s" % (", ".join(colour) or "BRAK - to bedzie SDR"))
    if "iCCP" in tags and ct in (0, 4):
        print("  BLAD: profil RGB w obrazie w skali szarosci - czytniki to odrzuca")
        bad += 1
    if "cICP" in tags:
        p = g.imageData.find(b"cICP")
        c = g.imageData[p + 4:p + 8]
        print("  cICP    : primaries=%d transfer=%d matrix=%d range=%d"
              % (c[0], c[1], c[2], c[3]))
        if c[1] != 16:
            print("  uwaga: transfer != 16 (PQ) - to nie jest HDR wg ST.2084")
    for t, n in ch:
        if t == "sRGB":
            print("  sRGB    : obecny - jest NIZSZY priorytet niz iCCP/cICP, ale")
            print("            w czytniku bez obslugi iCCP zdegraduje obraz do SDR")

    verdict = "OK" if (colour and bad == 0) else "PROBLEM"
    print("\nwerdykt   : %s" % verdict)
    return 0 if verdict == "OK" else 1


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def cmd_list(args):
    fonts = scan_fonts()
    q = (args.query or "").lower()
    n = 0
    for f in fonts:
        blob = "%s %s %s %s" % (f["family"], f["path"], f["container"], f["face"])
        if q and q not in blob.lower():
            continue
        if args.colour and not f["colour"]:
            continue
        n += 1
        if args.tsv:
            # tryb maszynowy: rodzina, odmiana, PostScript, plik, tabele koloru
            print("%s\t%s\t%s\t%s\t%s" % (f["family"] or "", f["subfamily"] or "",
                                           f["ps"] or "", f["path"],
                                           ",".join(f["colour"])))
            continue
        mark = ("  [kolor: %s]" % ",".join(f["colour"])) if f["colour"] else ""
        faces = "" if f["faces"] == 1 else "  (%d czcionek)" % f["faces"]
        print("%-30s %-10s %-4s %5s  %s%s%s"
              % ((f["family"] or "?")[:30], (f["subfamily"] or "")[:10],
                 f["container"], f["glyphs"], f["path"], faces, mark))
    if not args.tsv:
        print("\n%d fontow%s" % (n, " (filtr)" if q or args.colour else ""))
    return 0


def cmd_inspect(args):
    info = resolve(args.font)
    print("plik      : %s" % info["path"])
    print("kontener  : %s, czcionek w pliku: %d" % (info["container"], info["faces"]))
    print("rodzina   : %s / %s" % (info["family"], info["subfamily"]))
    print("postcript : %s" % info["ps"])
    print("glifow    : %s   upem: %s" % (info["glyphs"], info["upem"]))
    print("tabele    : %s" % ", ".join(info["tables"]))
    have = info["colour"]
    print("tabele koloru: %s" % (", ".join(have) if have else "brak (font czysto obrysowy)"))
    if "sbix" in have:
        print("            -> ma sbix: da sie podmienic kolor bez rasteryzacji")
    else:
        print("            -> brak sbix: glowforge dorobi go z obrysow")
    print("SDR?      : %s" % ("tak - obrysy nie niosa koloru" if not have else "zalezy od tabeli"))
    return 0


def cmd_convert(args):
    convert(args)
    return 0


def cmd_verify(args):
    return verify(args.font)


PREVIEW_HTML = """<!DOCTYPE html>
<html lang="pl"><head><meta charset="utf-8">
<title>glowforge - podglad</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; padding:32px 40px; background:#000; color:#fff;
         font-family:-apple-system,system-ui,sans-serif; }
  h1 { font-size:15px; font-weight:600; letter-spacing:.08em; text-transform:uppercase;
       color:#666; margin:0 0 4px; }
  p.note { color:#666; font-size:13px; margin:0 0 36px; max-width:70ch; line-height:1.6; }
  section { margin-bottom:44px; border-top:1px solid #1c1c1c; padding-top:20px; }
  h2 { font-size:13px; font-weight:600; color:#8ab4f8; margin:0 0 2px;
       font-family:ui-monospace,Menlo,monospace; }
  .meta { font-size:11px; color:#555; font-family:ui-monospace,Menlo,monospace;
          margin-bottom:16px; }
  .row { white-space:nowrap; overflow:hidden; }
  .s16 { font-size:16px } .s24 { font-size:24px } .s40 { font-size:40px }
  .s72 { font-size:72px } .s120 { font-size:120px; line-height:1.1 }
  .lbl { font-family:ui-monospace,Menlo,monospace; font-size:10px; color:#444;
         margin-top:22px; letter-spacing:.1em; }
  .big { font-size:96px; line-height:1.2; }
  .cmpwrap { margin-bottom:18px; }
  .cmpname { display:block; font-family:ui-monospace,Menlo,monospace; font-size:11px;
             color:#777; letter-spacing:.04em; }
  .cmp { font-size:64px; line-height:1.25; white-space:nowrap; overflow:hidden; }
  .oryg { color:#e8a33d; font-weight:700; }
__FACES__
</style></head><body>
<h1>glowforge - podglad fontow</h1>
<p class="note">Pierwszy wiersz to <b>oryginalny font systemowy</b> - punkt
odniesienia. Kolejne to jego skonwertowane kopie, od najciemniejszej do
najjasniejszej. Jesli ekran obsluguje HDR (XDR / EDR), te z trybem
<code>cICP</code> / <code>iCCP</code> powinny swiecic mocniej niz oryginal
i mocniej niz kontrola <code>srgb</code>. Rozmiary pod spodem pokazuja wybor
stopnia pisma - miedzy stopniami font spada na obrysy.</p>
__SECTIONS__
</body></html>
"""


def cmd_preview(args):
    """Generuje strone HTML z podgladem wygenerowanych fontow.

    Zeby przegladarka wczytala @font-face, strona musi byc podana przez HTTP
    (file:// blokuje fonty cross-origin). Serwer: glowforge serve
    """
    import html as _html
    import shutil

    entries = []
    if args.original:
        src = resolve(args.original)
        dst = os.path.join(OUTDIR, "_oryginal-" + os.path.basename(src["path"]))
        shutil.copyfile(src["path"], dst)
        entries.append((dst, "ORYGINAL - plik systemowy, obrysy wektorowe"))
        print("dolaczam oryginal: %s" % src["path"])
    for p in args.fonts:
        entries.append((p, ""))

    rows = [16, 24, 40, 72, 120]
    faces, sections, compare = [], [], []
    for i, (path, note) in enumerate(entries):
        if not os.path.exists(path):
            print("pomijam (nie ma pliku): %s" % path)
            continue
        info = describe_font(path)
        if not info:
            print("pomijam (nie font): %s" % path)
            continue
        fam = "gf%d" % i
        try:
            stamp = int(os.path.getmtime(path))
        except OSError:
            stamp = 0
        # znacznik czasu w URL: bez tego przegladarka podaje stary font z cache
        # po przebudowaniu pliku pod ta sama nazwa (juz nas to raz oszukalo)
        faces.append('@font-face { font-family:"%s"; src:url("%s?v=%d"); }'
                     % (fam, os.path.basename(path), stamp))
        label = info["family"] or os.path.basename(path)
        body = []
        for size in rows:
            body.append('<div class="lbl">%d px</div>' % size)
            body.append('<div class="row s%d">%s</div>' % (size, _html.escape(args.text)))
        cls = "cmpname oryg" if note else "cmpname"
        compare.append(
            '<div class="cmpwrap">'
            '<span class="%s">%s%s</span>'
            '<div class="cmp" style="font-family:\'%s\'">%s</div></div>'
            % (cls, _html.escape(label), (" &nbsp;&mdash;&nbsp; " + note) if note else "",
               fam, _html.escape(args.text)))
        sections.append(
            '<section>'
            '<h2>%s%s</h2>'
            '<div class="meta">%s &nbsp;|&nbsp; glifow: %s &nbsp;|&nbsp; tabele: %s</div>'
            '<div style="font-family:\'%s\'">%s</div>'
            '</section>'
            % (_html.escape(label), (" &nbsp;&mdash;&nbsp; " + note) if note else "",
               _html.escape(os.path.basename(path)),
               info["glyphs"], ", ".join(info["colour"]) or "brak",
               fam, "".join(body)))

    if compare:
        # Wiersz odniesienia jest KONIECZNY. Bez zwyklej bieli SDR obok nie da
        # sie ocenic, czy font swieci: wszystkie wiersze wygladaja podobnie,
        # bo oko nie ma skali. Juz raz nas to kosztowalo szukanie nieistniejacego
        # bledu w foncie.
        ref = ('<div class="cmpwrap">'
               '<span class="cmpname">ZWYKLY TEKST &mdash; biel SDR, odniesienie</span>'
               '<div class="cmp" style="font-family:-apple-system,Helvetica">%s</div>'
               '</div>' % _html.escape(args.text))
        sections.insert(0, '<section><h2>Porownanie &mdash; oryginal vs kopie</h2>'
                           '<div class="meta">ten sam tekst, 64 px, kazda rodzina'
                           ' &nbsp;|&nbsp; patrz na roznice wzgledem pierwszego wiersza</div>'
                           + ref + "".join(compare) + '</section>')

    out = args.output or os.path.join(OUTDIR, "preview.html")
    with open(out, "w", encoding="utf-8") as fh:
        fh.write(PREVIEW_HTML
                 .replace("__FACES__", "\n".join(faces))
                 .replace("__SECTIONS__", "\n".join(sections)))
    print("zapisane: %s" % out)
    print("otworz  : http://127.0.0.1:%d/%s" % (args.port, os.path.relpath(out, ROOT)))
    if args.open:
        os.system('open "http://127.0.0.1:%d/%s"' % (args.port, os.path.relpath(out, ROOT)))
    return 0


def cmd_serve(args):
    """Serwuje katalog ~/web_hdr przez HTTP (wymagane dla @font-face)."""
    import functools
    import http.server
    import socketserver

    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=ROOT)
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", args.port), handler) as httpd:
        print("serwer: http://127.0.0.1:%d/  ->  %s   (Ctrl-C konczy)" % (args.port, ROOT))
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            print()
    return 0


def build_parser():
    p = argparse.ArgumentParser(
        prog="glowforge",
        description="Konwerter zainstalowanych fontow macOS na swiecace HDR.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""przyklady:
  glowforge list --query monaco
  glowforge inspect Monaco
  glowforge convert Monaco --charset pl --boost 8 -o Monaco-Glow.ttf
  glowforge convert Helvetica --mode srgb          # kontrola SDR
  glowforge verify glowforge/out/Monaco-iccp-32_64_128.ttf
""")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("list", help="lista zainstalowanych fontow")
    s.add_argument("--query", "-q", help="filtr tekstowy")
    s.add_argument("--colour", action="store_true", help="tylko fonty z tabelami koloru")
    s.add_argument("--tsv", action="store_true",
                   help="wyjscie maszynowe: rodzina<TAB>odmiana<TAB>PostScript<TAB>plik<TAB>tabele koloru")
    s.set_defaults(func=cmd_list)

    s = sub.add_parser("inspect", help="co jest w srodku jednego fontu")
    s.add_argument("font")
    s.set_defaults(func=cmd_inspect)

    s = sub.add_parser("convert", help="zbuduj swiecaca kopie")
    s.add_argument("font", help="nazwa, nazwa PostScript albo sciezka")
    s.add_argument("-o", "--output")
    s.add_argument("--face", type=int, default=0, help="numer czcionki w .ttc (domyslnie 0)")
    s.add_argument("--mode", choices=["srgb", "iccp", "cicp", "both"], default="iccp",
                   help="srgb = kontrola SDR (domyslnie iccp)")
    s.add_argument("--charset", choices=sorted(CHARSETS), default="latin")
    s.add_argument("--chars", help="wlasny zestaw znakow, np. 'ABCabc'")
    s.add_argument("--range", help="zakresy kodu, np. 0x20-0x7E,0x410-0x44F")
    s.add_argument("--ppem", default="32,64,128",
                   help="stopnie pisma bitmap (domyslnie 32,64,128)")
    s.add_argument("--color", default="FFFFFF", help="kolor tuszu RRGGBB (domyslnie FFFFFF)")
    s.add_argument("--boost", type=float, default=0.0,
                   help="ile razy jaśniej od bieli SDR (0 = pelny zakres PQ)")
    s.add_argument("--name", help="nazwa rodziny nowego fontu")
    s.add_argument("--profile", default=DEFAULT_PROFILE, help="profil ICC")
    s.add_argument("--install", action="store_true", help="skopiuj do ~/Library/Fonts")
    s.set_defaults(func=cmd_convert)

    s = sub.add_parser("verify", help="sprawdz gotowy plik")
    s.add_argument("font")
    s.set_defaults(func=cmd_verify)

    s = sub.add_parser("preview", help="strona HTML z podgladem")
    s.add_argument("fonts", nargs="+")
    s.add_argument("--original", help="dolacz oryginalny font jako punkt odniesienia")
    s.add_argument("-o", "--output")
    s.add_argument("--text", default="Zolw zjadl figi 0123")
    s.add_argument("--port", type=int, default=8765)
    s.add_argument("--open", action="store_true")
    s.set_defaults(func=cmd_preview)

    s = sub.add_parser("serve", help="serwer HTTP dla podgladu")
    s.add_argument("--port", type=int, default=8765)
    s.set_defaults(func=cmd_serve)
    return p


def main():
    args = build_parser().parse_args()
    try:
        return args.func(args)
    except KeyboardInterrupt:
        return 130
    except BrokenPipeError:
        return 0


if __name__ == "__main__":
    sys.exit(main())
