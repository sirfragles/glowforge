# Mechanizm — jak font może nieść HDR

## 1. Dlaczego font wektorowy nie niesie koloru

Glif w zwykłym foncie to **kształt**: zestaw konturów w `glyf` (TrueType)
albo charstringów w `CFF ` (PostScript). Kolor nie jest częścią glifu —
aplikacja decyduje, czym go wypełni. Ten sam font może narysować czarny tekst
na białym i biały na czarnym.

Dlatego nie da się „zapisać HDR" w zwykłym foncie. Nie ma gdzie. Można
zapisać kształt litery, ale nie jej jasność.

## 2. Cztery tabele, które definiują wygląd glifu

Kolor mogą nieść tylko tabele, które zawierają **gotowy obraz** albo **przepis
na jego złożenie**:

| tabela | co zawiera | HDR? | kto czyta |
|---|---|---|---|
| **`sbix`** | całe obrazy: PNG / JPEG / TIFF | **tak** | Apple — CoreText, iOS, iPadOS |
| `CBDT`/`CBLC` | całe obrazy, tylko PNG | tak | Chrome, Android, FreeType |
| `SVG ` | dokumenty SVG | teoretycznie tak | Chrome, Firefox |
| `COLR`/`CPAL` | warstwy i palety | **nie** | nowoczesne przeglądarki |

`COLR`/`CPAL` odpada strukturalnie: rekordy koloru są 8-bitowe w sRGB. Można
narysować kolorową literę, ale nie da się wyjść ponad biel — format tego
nie przewiduje.

`SVG ` odpada w praktyce: obrazy HDR w SVG wymagają profilu, a Chrome nie
obsługuje `rec2100-pq` w tym kontekście.

`CBDT` jest odpowiednikiem `sbix` od Google i działa tak samo, ale **CoreText
go nie czyta** — na macOS nie ma z niego pożytku.

Zostaje `sbix`.

Co ważne: **`sbix` działa tylko dlatego, że zawiera całe obrazy.** Profil
koloru jest własnością obrazu, nie fontu. Font jest w tym układzie tylko
pojemnikiem — nośnikiem jest PNG.

## 3. Struktura tabeli `sbix`

Tabela zaczyna się nagłówkiem (Apple, *TrueType Reference Manual*, rozdział
o `sbix`):

| typ | pole | znaczenie |
|---|---|---|
| `UInt16` | `version` | 1 |
| `UInt16` | `flags` | bit 0 = 1 (wymóg historyczny), bit 1 = rysuj obrysy |
| `UInt32` | `numStrikes` | liczba stopni pisma |
| `UInt32[]` | `strikeOffset` | przesunięcia do poszczególnych stopni |

Bit 1 flag to `sbixDrawOutlines`:

* **0** — rysuj **tylko** bitmapy,
* **1** — rysuj bitmapę, a na niej obrys.

Ustawiamy 0. Glify bez bitmapy i tak spadają na obrysy — ten bit dotyczy
wyłącznie glifów, które bitmapę mają.

### Stopień pisma (strike)

| typ | pole |
|---|---|
| `UInt16` | `ppem` — dla jakiego stopnia |
| `UInt16` | `resolution` — gęstość, u nas 72 |
| `UInt32[numGlyphs+1]` | `glyphDataOffset` |

Tablica przesunięć ma **o jeden wpis więcej** niż glifów, żeby dało się wyliczyć
długość danych ostatniego glifu. Wpis zerowej długości znaczy „ten glif nie ma
bitmapy w tym stopniu".

Liczba glifów pochodzi z tabeli `maxp`. glowforge zostawia puste wpisy
wszystkim glifom, których nie rasteryzował — dzięki temu font zachowuje się
jak normalny font i nie wymaga konwersji wszystkich 1678 glifów.

### Rekord glifu

| typ | pole | znaczenie |
|---|---|---|
| `SInt16` | `originOffsetX` | pozycja **lewej** krawędzi obrazu |
| `SInt16` | `originOffsetY` | pozycja **dolnej** krawędzi obrazu |
| `FourCharCode` | `graphicType` | `'png '`, `'jpg '`, `'tiff'` |
| `UInt8[]` | `data` | obraz |

**To jest miejsce, w którym się przewróciłem.** `originOffsetY` opisuje
**dolną** krawędź, nie górną. Definicja z OpenType brzmi dosłownie:

> The vertical (y-axis) position of the **bottom edge** of the bitmap graphic
> in relation to the glyph design space origin.

Wpisanie tam górnej krawędzi przesuwa obraz o całą jego wysokość w górę.
Uwaga na konsekwencję: renderery **przycinają bitmapę do prostokąta obrysu
glifu**, więc z przesuniętego obrazu zostaje jednopikselowa kreska na
przecięciu obu prostokątów. Wygląda to jak zupełnie inny błąd i szuka się go
w złym miejscu. Szczegóły w [`02-pulapki.md`](02-pulapki.md).

Dla litery siedzącej na linii bazowej `originOffsetY` wychodzi **0**
(obraz kończy się dokładnie na linii bazowej). Apple w swojej
`Apple Color Emoji` też używa `(0, 0)` dla emoji o wysokości `ppem`.

## 4. Sygnalizacja koloru w PNG

PNG Third Edition (W3C, czerwiec 2025) ustala kolejność pierwszeństwa chunków
opisujących kolor:

```
cICP  >  iCCP  >  sRGB  >  cHRM + gAMA
```

Czyli `cICP` wygrywa z profilem ICC, a profil wygrywa z chunkiem `sRGB`.

### `cICP` — 4 bajty

| bajt | pole | wartość u nas |
|---|---|---|
| 1 | colour primaries | `9` — BT.2020 |
| 2 | transfer function | `16` — PQ (ST.2084) |
| 3 | matrix coefficients | `0` — identity |
| 4 | video full range flag | `1` — pełny zakres |

### `iCCP` — cały profil ICC

Format chunku: nazwa + bajt zerowy + metoda kompresji (0 = zlib) +
spakowany profil. Nasz profil ma 13 300 bajtów i deklaruje
„Rec. ITU-R BT.2100 PQ" z tagiem `cicp` w środku.

**Kosztuje 4,7 KB po kompresji na każdy glif**, bo siedzi osobno w każdym
obrazie. Stąd `--mode cicp` daje plik trzykrotnie mniejszy przy identycznym
efekcie.

### Pułapka: profil RGB w obrazie w skali szarości

Specyfikacja PNG wymaga, żeby profil był RGB dla obrazów kolorowych
i szarościowy dla obrazów w skali szarości. Profil PQ jest RGB, więc w obrazie
`colortype 0` (grayscale) jest **niezgodny i czytniki go odrzucają** — obraz
po cichu degraduje się do SDR.

glowforge pisze glify jako `colortype 6` (RGBA). Typy 2 (RGB) i 6 (RGBA) są
oparte na RGB, więc profil RGB jest z nimi zgodny.

## 5. Skąd bierze się jasność — krzywa PQ

PQ (Perceptual Quantizer, SMPTE ST.2084) opisuje zakres od 0 do 10 000 cd/m²
w jednym bajcie. Kod piksela nie jest liniowy — liczba wynika z odwrotności
funkcji EOTF:

```
m1 = 2610/16384        c1 = 3424/4096
m2 = 2523/4096 * 128   c2 = 2413/4096 * 32
                       c3 = 2392/4096 * 32

Y  = jasność / 10000
Yn = Y^m1
Y' = ((c1 + c2·Yn) / (1 + c3·Yn))^m2
kod = Y' * 255
```

Kilka wartości dla orientacji:

| cd/m² | kod PQ | ile to bieli SDR |
|---|---|---|
| 100 | 119 | 0,5× |
| 203 (biel SDR) | 148 | 1× |
| 406 | 167 | 2× |
| 1624 | 205 | 8× |
| 10 000 | 255 | ~49× |

**Kod 148 to biel SDR.** Wszystko powyżej to nadmiar światła.

Dlatego `--boost` skalowało kod, a nie „rozjaśniało" obraz: `--boost 8` wpisuje
205, `--boost 0` wpisuje 255.

## 6. Strona ekranu — EDR

Apple nazywa swoją implementację HDR **Extended Dynamic Range (EDR)**
i to jest jedyne określenie, jakiego używa w API. Wartość `1.0`
w przestrzeni `extendedLinearSRGB` to biel SDR, a wartości powyżej 1.0 są
legalne i wychodzą z ekranu jako realny nadmiar światła.

Żeby to działało, muszą zachodzić **trzy warunki jednocześnie**:

```swift
// 1. kontekst rysowania w przestrzeni rozszerzonej
CGContext(..., space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)

// 2. tekstura i kolor docelowy warstwy
mtk.colorPixelFormat = .rgba16Float
mtk.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)

// 3. ten jeden włącznik
(layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
```

`CGBitmapInfo.byteOrder32Little` jest **obowiązkowe**. Bez niego odczyt
z kontekstu float zwraca śmieci (`1.15e-41`, `3.38e38`) wyglądające dokładnie
jak HDR. Zmierzone:

```
extendedLinearSRGB / byteOrderDefault   → wpisane 2.5, odczyt 1.1569e-41
extendedLinearSRGB / byteOrder32Little  → wpisane 2.5, odczyt 2.5        OK
```

Zapas EDR zależy od panelu i od jasności podświetlenia — patrz
[`03-edr-i-panel.md`](03-edr-i-panel.md).

## 7. Cały łańcuch

```
   font źródłowy (obrysy)
        │
        │  rasteryzacja przez Pillow/FreeType, --ppem
        ▼
   bitmapa glifu (alfa, 8 bit)
        │
        │  + chunk koloru: cICP albo iCCP z profilem PQ
        ▼
   PNG z zakodowaną jasnością
        │
        │  tabela sbix: strike, rekord glifu, originOffset
        ▼
   font z bitmapowymi glifami
        │
        │  CoreText / przeglądarka czyta sbix przy rysowaniu
        ▼
   obraz w przestrzeni rozszerzonej (wartości > 1.0)
        │
        │  CAMetalLayer.wantsExtendedDynamicRangeContent
        ▼
   nadmiar światła z panelu XDR
```

Font jest tylko pojemnikiem. Cała treść techniczna siedzi w PNG.

## 8. Zmierzone wyniki

Glif wyjęty z gotowego pliku `.ttf`, zmierzony przez ColorSync
(`scripts/` z pierwotnego projektu badawczego):

| tryb | jasność vs biel SDR |
|---|---|
| `srgb` — kontrola | 1,05× |
| `iccp` z `--boost 8` | 8,31× |
| `cicp` z `--boost 8` | 8,31× |
| pełny zakres PQ (kod 255) | 51,79× przez CoreText |

Wartość 51,79× to dokładnie tyle, ile dawało logo z ogłoszenia, od którego
projekt się zaczął.
