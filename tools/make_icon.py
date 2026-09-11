#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generuje ikonę aplikacji glowforge.

Ikona jest rysowana programowo, a nie trzymana jako plik binarny w
repozytorium — dzięki temu da się ją zmienić jednym poleceniem i widać
w historii gita, co się zmieniło.

Wygląd: ciemny zaokrąglony kwadrat (squircle wg zaleceń Apple dla macOS)
z literą G otoczoną poświatą. Poświata to kilka warstw tego samego kształtu
rozmytych coraz mocniej — tania sztuczka, ale daje wrażenie świecenia,
które jest tematem projektu.

Użycie:
    python3 tools/make_icon.py <katalog.iconset>
"""

import os
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

# Rozmiary wymagane przez iconutil (nazwy plików tworzy funkcja niżej)
ROZMIARY = [16, 32, 64, 128, 256, 512, 1024]

# Canvas 1024, zawartość 824 — tak zaleca Apple dla ikon w stylu Big Sur.
MARGINES = 100
BOK = 824
PROMIEN = 185

# Kolejne warstwy poświaty: (promień rozmycia, krycie, barwa).
# Zewnętrzna chłodna, wewnętrzna biała — dzięki temu poświata ma głębię
# zamiast być jednolitym rozmyciem.
POSWIATA = [(110, 165, (140, 185, 255)),
            (52, 160, (190, 215, 255)),
            (20, 150, (255, 255, 255))]


def czcionka(rozmiar):
    """Pierwsza dostępna czcionka systemowa z listy."""
    for sciezka, indeks in (("/System/Library/Fonts/HelveticaNeue.ttc", 0),
                            ("/System/Library/Fonts/Helvetica.ttc", 0),
                            ("/System/Library/Fonts/Monaco.ttf", 0),
                            ("/System/Library/Fonts/SFNSDisplay.ttf", 0)):
        if os.path.exists(sciezka):
            try:
                return ImageFont.truetype(sciezka, rozmiar, index=indeks)
            except Exception:
                continue
    # ostateczność: wbudowana czcionka Pillow
    return ImageFont.load_default()


def rysuj(rozmiar=1024):
    """Kompozycja wzorowana na ikonie Font Booka: zaokrąglony kwadrat
    z dużą literą w dolnej części. Dwie zmiany: litera to G, a tło jest
    ciemne — na jasnym poświata nie ma gdzie błysnąć, bo brak kontrastu."""
    s = float(rozmiar) / 1024.0
    img = Image.new("RGBA", (rozmiar, rozmiar), (0, 0, 0, 0))

    bok = max(2, int(BOK * s))
    m = int(MARGINES * s)
    promien = int(PROMIEN * s)

    # --- tło: ciemny gradient, jaśniejszy u góry (efekt szkła)
    tlo = Image.new("RGBA", (bok, bok), (0, 0, 0, 0))
    td = ImageDraw.Draw(tlo)
    for y in range(bok):
        t = y / max(1, bok - 1)
        td.line([(0, y), (bok, y)],
                fill=(int(30 - 22 * t), int(33 - 24 * t), int(44 - 31 * t), 255))

    maska = Image.new("L", (bok, bok), 0)
    md = ImageDraw.Draw(maska)
    md.rounded_rectangle([0, 0, bok - 1, bok - 1], radius=promien, fill=255)
    img.paste(tlo, (m, m), maska)

    # delikatna jasna krawędź u góry — takiego drobiazgu używa Apple.
    # Wygaszamy ją ku dołowi, żeby wyglądała jak odblask, a nie obwódka.
    krawedz = Image.new("RGBA", (bok, bok), (0, 0, 0, 0))
    ImageDraw.Draw(krawedz).rounded_rectangle(
        [0, 0, bok - 1, bok - 1], radius=promien,
        outline=(255, 255, 255, 110), width=max(1, int(3 * s)))
    wygaszenie = Image.new("L", (bok, bok), 0)
    wd2 = ImageDraw.Draw(wygaszenie)
    for y in range(bok):
        t = y / max(1, bok - 1)
        wd2.line([(0, y), (bok, y)], fill=int(255 * max(0.0, 1.0 - 2.4 * t)))
    krawedz.putalpha(ImageChops.multiply(krawedz.getchannel("A"), wygaszenie))
    img.alpha_composite(krawedz, (m, m))

    # --- litera G, jak „a" w Font Booku: duża, w dolnej części, na środku.
    # Proporcje zmierzone z oryginału: litera zajmuje ~49% wysokości
    # zawartości, a jej środek wypada na ~0,68 wysokości.
    f = czcionka(int(490 * s))
    warstwa = Image.new("RGBA", (rozmiar, rozmiar), (0, 0, 0, 0))
    wd = ImageDraw.Draw(warstwa)
    wd.text((rozmiar // 2, m + int(0.66 * bok)), "G", font=f,
            fill=(255, 255, 255, 255),
            stroke_width=max(0, int(22 * s)),
            stroke_fill=(255, 255, 255, 255),
            anchor="mm")

    # --- poświata: warstwy rozmyte coraz mocniej, z lekkim chłodnym odcieniem
    for r, alfa, barwa in POSWIATA:
        rozmyta = warstwa.filter(ImageFilter.GaussianBlur(max(1, int(r * s))))
        rozmyta = Image.composite(
            Image.new("RGBA", rozmyta.size, barwa + (255,)), rozmyta,
            rozmyta.getchannel("A"))
        a = rozmyta.getchannel("A").point(lambda v: int(v * alfa / 255.0))
        rozmyta.putalpha(a)
        img.alpha_composite(rozmyta)

    img.alpha_composite(warstwa)
    return img


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    iconset = sys.argv[1]
    os.makedirs(iconset, exist_ok=True)

    # iconutil oczekuje dokładnie takich nazw
    nazwy = {16: ["icon_16x16.png"],
             32: ["icon_16x16@2x.png", "icon_32x32.png"],
             64: ["icon_32x32@2x.png"],
             128: ["icon_128x128.png"],
             256: ["icon_128x128@2x.png", "icon_256x256.png"],
             512: ["icon_256x256@2x.png", "icon_512x512.png"],
             1024: ["icon_512x512@2x.png"]}

    for r in ROZMIARY:
        obraz = rysuj(r)
        for nazwa in nazwy.get(r, []):
            obraz.save(os.path.join(iconset, nazwa))
    print("ikona: %d plików w %s" % (sum(len(v) for v in nazwy.values()), iconset))
    return 0


if __name__ == "__main__":
    sys.exit(main())
