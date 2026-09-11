# glowforge

Fonty, które świecą **mocniej niż biel ekranu**. macOS, Extended Dynamic Range,
i jedna tabela dokładana do pliku fontu.

```
./glowforge convert Monaco --boost 8 --install
```

Bierze dowolny zainstalowany font, robi jego kopię i dokłada tabelę `sbix` —
Apple'owe glify bitmapowe. Każdy glif to osobny obraz PNG, a PNG potrafi nieść
profil koloru. Wystarczy wpisać w jego piksele kod **PQ** (SMPTE ST.2084),
żeby biel glifu wyszła z ekranu jako realny nadmiar światła — do ośmiu razy
jaśniejsza niż zwykła biel na tym panelu.

Font zachowuje wszystkie oryginalne tabele, więc składa się dokładnie tak samo
jak oryginał. Zmienia się tylko sposób rysowania glifów.

---

## Szybki start

```bash
cd ~/glowforge

./glowforge list --query monaco        # co jest w systemie
./glowforge inspect Monaco             # co siedzi w środku fontu
./glowforge convert Monaco --boost 8 --install
./glowforge verify out/MonacoGlow8x.ttf
```

Aplikacja z podglądem na żywo:

```bash
./build_app.sh --install        # pakiet z ikoną + instalacja w ~/Applications
open ~/Applications/GlowForge.app
```

Lista 372 fontów, pole na własny tekst, suwak jasności 1–16×, podgląd na żywo
i instalacja jednym przyciskiem. `build_app.sh` bez `--install` zostawia
pakiet w repozytorium.

Gotowy pakiet `.app` jest potrzebny, żeby aplikacja trafiła do **Launchpadu**
— sam plik wykonywalny tam nie trafi, bo system czyta ikonę i metadane tylko
z katalogu z `Info.plist`.

---

## Jak to działa, w trzech zdaniach

Font wektorowy **nie niesie koloru** — glif to sam kształt, a o kolorze decyduje
aplikacja. Kolor mogą nieść tylko tabele, które same definiują wygląd glifu:
`sbix`, `CBDT`, `COLR`/`CPAL`, `SVG`. Z tych czterech **tylko `sbix` i `CBDT`
potrafią nieść HDR**, bo zawierają całe obrazy, a obraz może mieć profil koloru.
glowforge rasteryzuje więc glify do PNG, wpisuje im kod PQ i pakuje je do
tabeli `sbix`.

---

## Poziom świecenia

`--boost N` = ile razy jaśniej od bieli SDR ma świecić glif.
Biel SDR przyjmuję jako 203 cd/m² (wartość odniesienia z BT.2408).

| `--boost` | jasność | uwagi |
|---|---|---|
| `0` (domyślne) | 10 000 cd/m² — pełny zakres PQ | ~49× bieli SDR |
| `8` | 1624 cd/m² | ≈ maksymalny zapas tego panelu |
| `2` | 406 cd/m² | subtelnie |
| `1` | 203 cd/m² | praktycznie SDR |

Jasność jest **wypalona w pliku fontu**, nie ustawiana w locie. Każdy poziom to
osobny plik i osobna rodzina — tak działa `sbix` i nie da się tego obejść.

---

## Tryby sygnalizacji koloru

| `--mode` | co wstawia do PNG | rozmiar (Monaco, ASCII) |
|---|---|---|
| `srgb` | chunk `sRGB` — **kontrola SDR** | 703 KB |
| `iccp` | `iCCP` + profil BT.2100 PQ (13 300 B) | 2003 KB |
| `cicp` | `cICP` = `09 10 00 01` (4 bajty) | 703 KB |
| `both` | oba — `cICP` ma priorytet | 2003 KB |

`iccp` jest domyślne (najszersza zgodność), ale **`cicp` daje identyczny efekt
przy trzykrotnie mniejszym pliku** — profil ICC siedzi w każdym glifie osobno.

---

## Ograniczenia — przeczytaj przed użyciem

**Glify są białe i ignorują kolor tekstu.** To bitmapy: aplikacja rysuje obraz,
nie obrys, więc atrybut koloru nie ma znaczenia. Na jasnym tle tekst będzie
**niewidoczny**. Ten font jest do ciemnych interfejsów.

**Jasność jest częścią nazwy rodziny.** `Monaco Glow 8x` i `Monaco Glow 16x`
to dwa różne fonty. Nie da się mieć jednej rodziny z regulowaną jasnością.

**Zmieniają się tylko znaki, które skonwertowałeś.** Reszta glifów zostaje
wektorowa i wygląda normalnie — font jest mieszany i zachowuje się poprawnie.

**Najmniejszy stopień pisma to `--ppem`.** Na zewnętrznym monitorze bez Retiny
mały tekst będzie rozmyty, bo bitmapa jest skalowana w dół. Dorób wersję
z `--ppem 16,32,64,128`, jeśli to przeszkadza.

**Efekt zależy od ekranu, nie tylko od fontu.** Zapas EDR zależy od jasności
podświetlenia i od tego, ile jasnych plam jest na ekranie. Szczegóły
w [`docs/03-edr-i-panel.md`](docs/03-edr-i-panel.md).

**Font jest zrobiony z cudzej czcionki.** Do użytku u siebie, nie do
rozpowszechniania.

---

## Komendy

```
glowforge list    [--query Q] [--colour] [--tsv]
glowforge inspect FONT
glowforge convert FONT [opcje]
glowforge verify  PLIK.ttf
glowforge preview FONTS... [--original FONT]
glowforge serve   [--port 8765]
```

Ważniejsze opcje `convert`: `--boost`, `--mode`, `--charset`
(`ascii`/`latin`/`pl`/`all`), `--chars`, `--range`, `--ppem`, `--color`,
`--name`, `--profile`, `--install`, `--face`, `-o`.

`list --tsv` daje wyjście maszynowe dla aplikacji:
rodzina, odmiana, PostScript, plik, tabele koloru.

---

## Struktura

```
glowforge.py            konwerter (fontTools + Pillow)
glowforge               launcher, szuka środowiska z zależnościami
glowforge_app.swift     aplikacja z podglądem EDR
build_app.sh            buduje GlowForge.app (ikona + pakiet)
tools/make_icon.py      generuje ikonę programowo
profiles/pq-bt2020.icc  profil BT.2100 PQ używany w trybie iccp
scripts/headroom.swift  ile zapasu EDR ma teraz ekran
scripts/rejestracja_trwala.swift
                        rejestracja fontu widoczna dla całego systemu
docs/                   opis techniczny
out/                    wygenerowane fonty
```

---

## Wymagania

Python 3 z `fontTools` i `Pillow`, oraz Swift do aplikacji.

```bash
python3 -m venv .venv
.venv/bin/pip install fonttools Pillow

./build_app.sh                  # kompiluje aplikację i buduje pakiet
swiftc -O scripts/headroom.swift -o scripts/headroom
swiftc -O scripts/rejestracja_trwala.swift -o scripts/rejestracja_trwala
```

Launcher sam znajdzie `.venv` w repozytorium.

---

## Dokumentacja

| plik | o czym |
|---|---|
| [docs/01-mechanizm.md](docs/01-mechanizm.md) | dlaczego font nie niesie koloru i jak `sbix` to obchodzi |
| [docs/02-pulapki.md](docs/02-pulapki.md) | pułapki, na które się nabrałem — z dowodami |
| [docs/03-edr-i-panel.md](docs/03-edr-i-panel.md) | strona ekranu: zapas EDR, jasność, APL |

---

## Skąd się wzięło

Projekt zaczął się od logo w ogłoszeniu na LinkedInie, które świeciło
nietypowo mocno. Okazało się, że plik to **grayscale JPEG z profilem
„Rec. ITU-R BT.2100 PQ"** — 13 300 z 15 991 bajtów, czyli 83% pliku.

Pytanie „czy tak samo da się z fontem?" doprowadziło tutaj. Font wektorowy
nie niesie koloru, więc odpowiedź brzmiała „nie tym sposobem" — ale istnieje
inny sposób i to on jest tym projektem. Zmierzone na glifie wyjętym z fontu:
**8,31× bieli SDR** przy `--boost 8`, i **51,79×** dla pełnego zakresu przez
CoreText — dokładnie tyle, ile dawało logo z ogłoszenia.
