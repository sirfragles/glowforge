# Strona ekranu — EDR, zapas, jasność

Font może nieść dowolnie jasne glify, ale **ile z tego zobaczysz, decyduje
panel**. Ten dokument jest o tym, dlaczego efekt czasem jest spektakularny,
a czasem znika — i dlaczego to nie jest wina fontu.

## Czym jest EDR

Apple nazywa swoją implementację HDR **Extended Dynamic Range** i tylko tego
określenia używa w API. Nie ma tu „HDR10" ani metadanych scenicznych — jest
zapas jasności, o który aplikacja może poprosić ponad biel SDR.

Punkty odniesienia:

* `1.0` w przestrzeni `extendedLinearSRGB` = **biel SDR**
* wartości powyżej `1.0` = nadmiar światła, wychodzący z panelu
* `maximumExtendedDynamicRangeColorComponentValue` = ile tego nadmiaru jest
  **teraz** dostępne

## Zapas zależy od jasności podświetlenia

To jest najważniejsza rzecz w tym dokumencie i źródło większości nieporozumień
typu „raz działa, raz nie".

Na panelach XDR zapas EDR działa **odwrotnie do jasności**:

| jasność podświetlenia | zapas EDR |
|---|---|
| maksymalna | ~1× — **HDR fizycznie nie ma gdzie się pokazać** |
| średnia | kilka razy |
| niska | w stronę 16× |

Zmierzone na MacBooku Pro M4 (wbudowany ekran Retina):

```
zapas AKTUALNY      8.79x
zapas POTENCJALNY  16.00x
```

Sprawdź u siebie:

```bash
swiftc -O scripts/headroom.swift -o scripts/headroom && ./scripts/headroom
```

Program sam ostrzega, jeśli zapas spadnie poniżej `1.5×`:

```
>>> ZAPAS PRAWIE ZERO - HDR nie bedzie widoczny.
    Zjedz jasnoscia ekranu w dol i sprawdz ponownie.
```

**Wniosek praktyczny:** jeśli efekt zniknął, a nic nie zmieniałeś w foncie —
zejdź z jasnością ekranu o połowę i patrz na tę samą linię tekstu.

## Duże jasne plamy obniżają zapas

Panel ogranicza **szczytową** jasność, gdy rośnie **średnia** jasność obrazu
(ang. *average picture level*, APL). To ochrona przed przegrzaniem i poborem
prądu — nie da się jej obejść.

W praktyce oznacza to, że **jasny prostokąt na ekranie zabiera zapas, którego
potrzebuje tekst**. Zmierzone w naszej aplikacji: pasek bieli rozciągnięty na
całą szerokość okna zjadał większość zapasu i efekt „full power glow" nie
występował, mimo poprawnych danych w foncie.

Po zamianie paska na małą próbkę (80×44 px) efekt się pojawił, bez żadnej
zmiany w pliku fontu.

| układ okna | co widać |
|---|---|
| biały pasek przez całą szerokość | efekt zredukowany |
| małe próbki, reszta czarna | pełny efekt |

Dlatego aplikacja rysuje **prawie całe czarne okno** z małymi próbkami
odniesienia. To nie kosmetyka — to warunek działania.

## Co wynika dla `--boost`

Font przy pełnym zakresie PQ ma 10 000 cd/m², czyli ~49× bieli SDR:

| `--boost` | cd/m² | ile to bieli SDR | kiedy ma sens |
|---|---|---|---|
| 0 | 10 000 | ~49× | zawsze przycięte do zapasu panelu |
| 8 | 1624 | 8× | ≈ maksimum tego panelu |
| 4 | 812 | 4× | wyraźne, ale nie agresywne |
| 2 | 406 | 2× | subtelne |

**Powyżej zapasu panelu font nie da więcej.** Wszystko zostanie przycięte.
Dalszy suwak jest po stronie ekranu, nie pliku — i to jest odpowiedź na
pytanie „dlaczego 16× nie wygląda jaśniej niż 8×".

## Gdzie to działa, a gdzie nie

Żeby efekt był widoczny, **aplikacja musi poprosić system o EDR**. Sam font
tego nie wymusi.

| środowisko | zmierzone / potwierdzone |
|---|---|
| natywna aplikacja Apple (CoreText) | **51,79×** zmierzone na glifie |
| Chrome — obrazy z `cICP` | potwierdzone wizualnie |
| Chrome — glify `sbix` z `cICP` | profil stosowany (205 → 255) |
| Terminal | potwierdzone przez użytkownika |

Aplikacja, która nie prosi o EDR, pokaże tekst jako zwykłą biel — font będzie
wyglądał poprawnie, tylko bez nadmiaru.

## Minimalna konfiguracja działająca

```swift
// kontekst float w przestrzeni rozszerzonej (byteOrder32Little OBOWIĄZKOWE)
CGContext(data: nil, width: w, height: h, bitsPerComponent: 32,
          bytesPerRow: w * 16,
          space: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.floatComponents.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)

// warstwa Metalowa
mtk.colorPixelFormat = .rgba16Float
mtk.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
(layer as? CAMetalLayer)?.wantsExtendedDynamicRangeContent = true
```

I pamiętaj, że widok z `isPaused = true` nie przerysuje się sam — patrz
[`02-pulapki.md`](02-pulapki.md), sekcja F.

## Jak sprawdzić, że to naprawdę działa

Test, w którym **jedyną zmienną jest font**:

1. Ten sam tekst, ta sama wartość koloru (`1.0`), dwie linie.
2. Górna — oryginalny font, obrysy wektorowe.
3. Dolna — skonwertowany font, bitmapy `sbix` z kodem PQ.

Jeśli dolna jest jaśniejsza, działa. Jeśli obie wyglądają tak samo, to nie
font jest problemem — patrz na zapas EDR i na to, ile jasnych plam jest
w oknie.

Dokładnie tak zbudowana jest aplikacja `glowforge_app`.
