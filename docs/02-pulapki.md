# Pułapki

Wszystko poniżej kosztowało czas i wszystko zostało potwierdzone pomiarem.
Kolejność jest przypadkowa — ale dwie pierwsze kategorie zbierają wzorce,
które wróciły po kilka razy.

---

## A. Wzorzec: brak odświeżenia wygląda jak brak działania

**To była najdroższa lekcja w całym projekcie.** Ten sam problem trafił się
cztery razy w czterech różnych miejscach i za każdym razem wyglądał jak błąd
w logice.

| gdzie | co się działo | objaw |
|---|---|---|
| przeglądarka | cache'owała font po URL | „HDR przestał działać" |
| widok Metalowy | nie rysował się sam | „suwak nic nie zmienia" |
| Font Book | trzymał listę z momentu startu | „czcionka się nie pojawia" |
| `CTFontManagerCopyAvailablePostScriptNames()` | zwracał nieaktualną listę | „system go nie widzi" |

**Wniosek praktyczny:** gdy pomiary mówią, że dane są poprawne, a efektu nie
widać — najpierw sprawdź, czy nie patrzysz na nieświeży stan. Dopiero potem
szukaj błędu w logice.

---

## B. Geometria `sbix` — dwie pułapki w jednej

### `originOffsetY` to DOLNA krawędź

OpenType mówi wprost:

> The vertical (y-axis) position of the **bottom edge** of the bitmap graphic
> in relation to the glyph design space origin.

Wpisałem pozycję górnej krawędzi. Obraz lądował o całą swoją wysokość za
wysoko, czyli **w całości poza glifem**.

### Renderery przycinają bitmapę do prostokąta obrysu glifu

To sprawiło, że objaw był zupełnie niepodobny do przyczyny. Z przesuniętego
obrazu zostawał **jednopikselowa kreska** na przecięciu prostokąta obrazu
i prostokąta obrysu — a nie przesunięty obraz.

Zmierzone dla litery `H` w Monaco przy `ppem 128`, obraz 62×97 px:

| `originOffsetY` | co pokazała przeglądarka |
|---|---|
| 97 (górna krawędź — błąd) | jeden wiersz na wysokości 98 px nad linią bazową |
| 0 (dolna krawędź — poprawnie) | pełny glif, 97 px wysokości |

Dowód algebraiczny: obraz zajmował `[97, 194]` nad linią bazową, prostokąt
obrysu `[0, 97]`. Przecięcie to dokładnie jeden punkt — `97`.

**Wniosek:** szukaj w dokumentacji, zanim zaczniesz zgadywać. Na specyfikację
`sbix` sięgnąłem po kilkunastu nieudanych próbach.

### Kontrola wartości

```
$ ./glowforge verify out/MonacoGlow8x.ttf
przyklad  : glif 'A', 404 B, originOffset=(0, 0)
```

Dla liter siedzących na linii bazowej `originOffsetY` = **0**.
Dla `p`, `g`, `,` wychodzi **ujemny**:

| glif | `originOffsetX` | `originOffsetY` |
|---|---|---|
| `H` | 7 | 0 |
| `A` | 2 | 0 |
| `p` | 8 | −27 |
| `g` | 7 | −29 |
| `,` | 26 | −27 |

Jeśli widzisz same duże liczby dodatnie — liczysz górną krawędź i to jest błąd.

---

## C. Pułapki pomiarowe

### `Image.convert("L")` na obrazie RGBA wyrzuca kanał alfa

Ten test miał odpowiedzieć „ile pikseli ma atrament":

```python
px = im.convert("L").load()          # ŹLE dla RGBA
rows = [sum(1 for x in range(w) if px[x, y] > 8) for y in range(h)]
```

`convert("L")` liczy **luminancję**, nie alfę. Zielony piksel `(0, 255, 0)` daje
149, więc wynik wyszedł „100% pikseli ma atrament" i bitmapa wyglądała na
wypełnioną. Spędziłem na tym rundę, zanim to zauważyłem.

Poprawnie: `im.getchannel("A")`.

### Kontekst float bez `byteOrder32Little` zwraca śmieci

```swift
CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
//                                     ^ to jest obowiązkowe
```

Bez tego odczyt daje `1.1569e-41` albo `3.38e38` — wartości, które **wyglądają
jak HDR**, bo są ogromne. Zmierzone porównanie:

```
extendedLinearSRGB / byteOrderDefault   → wpisane 0.5, odczyt 1.1569e-41
extendedLinearSRGB / byteOrder32Little  → wpisane 0.5, odczyt 0.5        OK
```

**Zawsze waliduj przyrząd znanymi wartościami**, zanim zmierzysz cokolwiek.
Wypełnij bufor `0.0 / 0.5 / 1.0 / 2.5 / 8.0` i sprawdź, czy odczyt się zgadza.

### `<canvas>` i `getImageData` to SDR

Nie zmierzysz tam HDR — źródło canvasu ma 8 bitów z definicji. Mierzy
rastryzację do atlasu, nie prezentację. Wcześniej wyciągnąłem z tego błędny
wniosek („przeglądarka przycina glify do SDR"), który użytkownik obalił
własnymi oczami.

### Metoda: jak sprawdzić zarządzanie kolorem, mając tylko zrzut SDR

Wyrenderuj **ten sam obraz dwa razy**: raz bez chunku koloru, raz z `cICP`.
Jeśli wynikowe piksele się różnią, profil jest honorowany.

Wartość **205** nadaje się idealnie: bez profilu zostaje 205 (szare),
z profilem PQ leci do 255. Czysta biel 255 nie rozróżni, bo obie wersje
klipują się do 255.

Wynik tego testu dla fontów:

| co | piksel | max na ekranie |
|---|---|---|
| obraz 205, bez chunku | 205 | **205** — SDR |
| obraz 205 + `cICP` | 205 | **255** |
| font 8x (205 + `cICP`) | 205 | **255** |

Ostatni wiersz dowodzi, że przeglądarka stosuje profil również do bitmap
`sbix`, nie tylko do zwykłych `<img>`.

### `ImageFont.getbbox` liczy y od linii ascentu

Linia bazowa jest na wysokości `ascent` z `getmetrics()`. Nie od zera.

---

## D. macOS: instalacja fontu

### Skopiowanie pliku do `~/Library/Fonts` NIE wystarcza

Font leży na dysku, wygląda dobrze, a system go nie widzi. Zmierzone
między procesami:

| krok | fontów widzianych przez system |
|---|---|
| plik skopiowany do `~/Library/Fonts` | 539 — **żadnego naszego** |
| po `CTFontManagerRegisterFontsForURL(..., .persistent, ...)` | 540 |
| **nowy proces** (czyli system, nie ten sam proces) | nasz font widoczny |

Trzeba zrobić jedno **i** drugie:

```swift
CTFontManagerRegisterFontsForURL(url, .persistent, &err)
```

`.persistent` obowiązuje wszystkie procesy i przeżywa restart. `.process`
(używane do podglądu w aplikacji) działa tylko w tym jednym procesie.

### Kody błędów kłamią — sprawdzaj skutek

```
kCTFontManagerErrorAlreadyRegistered = 105
```

Kod 105 wygląda jak porażka, a znaczy „już zarejestrowany" — czyli w porządku.
Instalowanie tego samego fontu drugi raz zawsze go zwróci, bo plik zostaje
nadpisany pod tą samą nazwą.

Zamiast interpretować kody, **weryfikuj użyciem**:

```swift
let f = CTFontCreateWithName(ps as CFString, 14, nil)
let got = CTFontCopyPostScriptName(f) as String
let widoczny = got.caseInsensitiveCompare(ps) == .orderedSame
```

### `CTFontManagerCopyAvailablePostScriptNames()` bywa nieaktualne

Ta lista **nie zawierała** fontu, który był zarejestrowany i działał.
Zmierzone:

```
CourierGlow16x  ->  PS=CourierGlow16x  PLIK=~/Library/Fonts/CourierGlow16x.ttf
lista systemowa zawiera CourierGlow16x: false    ← lista kłamie
```

Dlatego sprawdzanie obecności na liście jest błędem. Weryfikuj użyciem.

### Duplikat nazwy blokuje podgląd

Podgląd w aplikacji budował font pod domyślną nazwą (`MonacoGlow8x`).
Ten font był już zainstalowany w systemie, więc rejestracja w procesie została
odrzucona jako duplikat (`kCTFontManagerErrorAlreadyRegistered`) i podgląd
nigdy nie wchodził w tryb „na żywo".

Rozwiązanie: **podgląd i instalacja to dwa różne pliki**.

| | nazwa | po co |
|---|---|---|
| podgląd | na sztywno `GlowForgePreview` | tylko w procesie, nigdy nie koliduje |
| instalacja | naturalna (`Monaco Glow 8x`) | budowana dopiero po kliknięciu |

### Font bez tabeli `OS/2`

Stare fonty Mac (np. Courier) nie mają tabeli `OS/2`. CoreText taki font
wczyta, ale fontd może odmówić wpisania go na listę. glowforge tego **nie
naprawia** — jeśli font nie pojawia się w Font Book, to jest pierwsze miejsce
do sprawdzenia.

### Wylogowanie

macOS skanuje `~/Library/Fonts` przy logowaniu. Jeśli font nie pojawia się
w Font Book mimo poprawnej rejestracji — wylogowanie i zalogowanie to
standardowa droga, z której Font Book czyta.

---

## E. Przeglądarka

### Cache'uje fonty po URL

Po przebudowaniu pliku pod tą samą nazwą testy pokazują **stary** wynik.
Do iterowania dopisz znacznik czasu:

```css
@font-face { font-family: gf0; src: url("MonacoGlow.ttf?v=1789149404"); }
```

Bez tego można godzinami „naprawiać" coś, co już działa. Ratowało mnie to
kilka razy.

### Strona wskazująca na skasowany plik nie zgłasza błędu

Przeglądarka po cichu podstawia font domyślny. Wygląda to **dokładnie** jak
„HDR przestał działać". Po każdym `rm out/*.ttf` przebuduj podgląd i sprawdź,
czy każdy font odpowiada HTTP 200.

### `file://` blokuje `@font-face`

Fonty cross-origin nie wczytają się z pliku lokalnego. Potrzebny serwer HTTP:

```bash
./glowforge serve --port 8765
```

---

## F. Swift

### `String(format:)` z `%@` i swiftowym Stringiem → segfault

Trafiłem w to **trzy razy** w jednym projekcie:

```swift
print(String(format: "%-20s %@", name, swiftString))   // SEGFAULT
```

Do składania tekstu używaj interpolacji:

```swift
print("\(name) -> \(swiftString)")
```

### `CTFontCreateWithName` nigdy nie zwraca `nil`

Przy nieznanej nazwie **po cichu podstawia font domyślny**. Sprawdzenie
`if font == nil` nigdy nie zadziała.

```swift
// ŹLE — ten warunek nigdy nie będzie prawdziwy
sourceFont = CTFontCreateWithName(nazwa, 0, nil)
if sourceFont == nil { /* nigdy */ }

// DOBRZE — porównaj, co naprawdę przyszło
let t = CTFontCreateWithName(nazwa as CFString, 14, nil)
let got = CTFontCopyPostScriptName(t) as String
guard got.caseInsensitiveCompare(nazwa) == .orderedSame else { /* nie ma */ }
```

Ten błąd siedział w kodzie niezauważony — wybór fontu, który się nie wczytał,
dawałby Helvetikę bez jednego znaku ostrzeżenia.

### Przekazany rozmiar fontu bywał ignorowany

Funkcja rysująca przyjmowała `size` i nigdy go nie używała, a fonty były
tworzone raz przez `CTFontCreateWithName(nazwa, 0, nil)` — a **zero znaczy
„domyślny", czyli 12 punktów**. Cały tekst rysował się w 12 pt w buforze
1600×900, więc podgląd wyglądał, jakby nic się nie wczytało.

Rozmiar nadawaj w miejscu rysowania:

```swift
let fs = CTFontCreateCopyWithAttributes(f, size, nil, nil)
```

### `MTKView` z `isPaused` nie rysuje się sam

```swift
mtk.isPaused = true
mtk.enableSetNeedsDisplay = true
```

W tym trybie po każdej zmianie trzeba **jawnie** poprosić o przerysowanie:

```swift
mtk.needsDisplay = true      // NSView nie ma setNeedsDisplay() bez argumentu
```

Bez tego na ekranie zostaje pierwsza klatka z momentu startu i żadna zmiana
nie jest widoczna — mimo że cała logika działa poprawnie.

---

## G. Różne

### Nazwy: rozszerzenie nie jest formatem

`LastResort.otf` ma nagłówek `OTTO` (obrysy CFF), ale `.otf` może zawierać
również obrysy TrueType. O formacie decyduje nagłówek sfnt, nie końcówka:

| nagłówek | znaczenie |
|---|---|
| `0x00010000` | obrysy TrueType |
| `OTTO` | obrysy CFF |
| `ttcf` | kolekcja |
| `true` | archaiczny TrueType |

### CoreText czyta WOFF i WOFF2, ale system ich nie instaluje

CoreText ma wbudowany dekompresor na potrzeby treści webowych i **przetworzy**
plik `.woff`. Ale system nie deklaruje tego rozszerzenia jako typu fontu
(UTI `dyn.*`), więc Font Book go nie zainstaluje. „API to przetworzy" i „system
to zainstaluje" to dwie różne rzeczy.

### Kod 148 to biel SDR

W krzywej PQ biel SDR to **kod 148**, nie 255. 255 to 10 000 cd/m². Jeśli
widzisz w płynie obrazu wartość 255 i myślisz „to biały" — to jest 49× bieli.

## H. Ikona pakietu `.app`

### `SetFile -a C` ustawia „własną ikonę" i właśnie ją psuje

Nazwa tej flagi brzmi jak coś, czego się chce: *element ma własną ikonę*.
W praktyce znaczy ona **„ikonę znajdziesz w pliku `Icon\r` w środku tego
katalogu"**. Jeśli tego pliku nie ma, Finder nie ma czego pokazać — i zamiast
sięgnąć po `CFBundleIconFile`, pokazuje **zwykły niebieski folder**.

Pakiet wygląda wtedy na kompletnie zepsuty, choć jest bez zarzutu:

| kontrola | wynik |
|---|---|
| `CFBundleIconFile` w `Info.plist` | `AppIcon` — poprawnie |
| plik `.icns` obecny | tak, 507 KB |
| `iconutil` rozkłada go z powrotem | 10 rozmiarów, wszystkie zgodne |
| `sips` czyta | `1024 x 1024, format: icns` |
| `codesign -v` | `valid on disk` |
| **`xattr`** | **`com.apple.FinderInfo` ← jedyna różnica** |

Usunięcie atrybutu natychmiast przywraca ikonę — bez przebudowy, bez
wylogowania, bez czyszczenia cache:

```bash
/usr/bin/SetFile -a c Foo.app     # mała litera = zdejmij flagę
xattr Foo.app                     # powinno zostać tylko com.apple.provenance
```

Dlatego `build_app.sh` **zdejmuje** tę flagę zamiast ją ustawiać. Instrukcja
„ustaw `-a C`, żeby odświeżyć ikonę", krąży po internecie, ale dla pakietu
bez pliku `Icon\r` jest po prostu sabotażem.

### Test, który mówi „działa", gdy nie działa

Pierwsza wersja sondy porównywała zwróconą ikonę z generyczną ikoną
**aplikacji** i wobec braku zgodności ogłaszała sukces. Tymczasem system
zwracał generyczny **folder** — czyli zupełnie inny obraz, więc test uznał to
za „naszą własną ikonę".

Trzeba porównywać z **oboma** wzorcami i powiedzieć, który pasuje:

| zwrócony obraz | znaczenie |
|---|---|
| generyczna ikona aplikacji | system nie widzi `CFBundleIconFile` |
| generyczna ikona folderu | pakiet brany za katalog — patrz flaga wyżej |
| żaden z powyższych | własna ikona faktycznie działa |

To ten sam schemat, co w punkcie A: **test, który nie potrafi odróżnić awarii
od sukcesu, jest gorszy od braku testu.** Sonda `scripts/ikona_systemowa.swift`
sprawdza jedno i drugie — i flagę, i faktycznie renderowany obraz.

## I. Wydawanie pakietu

### Ścieżka zaszyta na sztywno działa na jednym komputerze

Aplikacja szukała konwertera tak:

```swift
for k in ["~/glowforge", "~/web_hdr/glowforge"] { ... }
```

Na maszynie autora trafiała za każdym razem. W pakiecie `.app` pobranym
z wydania nie ma ani katalogu domowego autora, ani tym bardziej `~/glowforge`
— więc nie trafiała nigdy i nie było po czym poznać, że to ścieżka, bo
aplikacja po prostu nie robiła nic.

Lekcja ogólniejsza: **kod, który zależy od `$HOME` autora, przechodzi
wszystkie testy u autora.** Dlatego workflow sprawdza samowystarczalność na
maszynie, która nie ma ani jednego z tych katalogów — to jedyny uczciwy test.

Rozwiązanie: konwerter jedzie w `Contents/Resources/glowforge/`, aplikacja
szuka najpierw tam, a pliki robocze trafiają do
`~/Library/Application Support/GlowForge/` — bo Zasoby pakietu są tylko do
czytania i zapis do nich unieważnia podpis.

### `minos` bierze się z maszyny, która buduje

Bez jawnego `-target` kompilator wpisuje w binarkę **wersję systemu, na którym
akurat pracuje**:

```
$ vtool -show-build GlowForge.app/Contents/MacOS/GlowForge
    minos 27.0                    <- macOS maszyny budującej
$ plutil -extract LSMinimumSystemVersion raw .../Info.plist
    12.0                          <- to, co obiecuje plik
```

Plik kłamał, a dwa wydania zbudowane na różnych runnerach wymagałyby różnych
systemów. Trzeba przypiąć jedno i drugie do tej samej wartości.

Uwaga praktyczna: ten sam `-target` trzeba powtórzyć przy sprawdzaniu, bo
inaczej mierzy się coś innego, niż się myśli.

### Dwa skrypty liczące wersję osobno zawsze się rozjadą

`build_app.sh` miał `1.0` wpisane na sztywno, a `make_dmg.sh` brał
`git describe`. W repozytorium bez tagów wychodziło:

| | |
|---|---|
| w `Info.plist` | `1.0` |
| nazwa pliku | `GlowForge-0fe6163.dmg` |

Numer wersji musi mieć **jedno źródło**. `make_dmg.sh` czyta go teraz
z już zbudowanego pakietu, więc nazwa pliku nie może się rozjechać z tym,
co jest w środku.

### `Float16` nie istnieje na x86_64

```
glowforge_app.swift:376:41: error: cannot convert value of type 'Int'
to expected argument type 'Float16'
```

To nie jest błąd w kodzie. `[Float16](repeating: 0, count: n)` jest poprawne,
ale Swift **nie udostępnia `Float16` na x86_64** — więc literał `0` nie ma
się do czego dopasować i kompilator zgłasza brak konwersji z `Int`. Błąd
wskazuje na linię, w której wszystko jest w porządku.

Sprawdzone dla `arm64-apple-macos12.0` (działa) i `x86_64-apple-macos12.0`,
`13.0`, `14.0` (zawsze to samo). Wniosek: ten kod nie zbuduje się na Intela
i żadne przełączniki tego nie zmienią. Trzeba albo się na to zgodzić, albo
zastąpić `Float16` ręcznym składaniem połówek.

### `hdiutil attach` nie mówi, czego nie znalazł

```
hdiutil: attach failed - No such file or directory
```

Gdy plik `.dmg` nie istnieje, komunikat nie podaje nazwy — a wygląda
identycznie jak błąd montowania. Warto wpisać ścieżkę do zmiennej i wypisać
ją przed montowaniem, zamiast szukać problemu w obrazie.
