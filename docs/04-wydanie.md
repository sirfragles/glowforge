# Wydanie

Obraz `.dmg` buduje GitHub Actions przy wypchnięciu taga. Ten dokument
opisuje, co dokładnie się wtedy dzieje, co workflow sprawdza i dlaczego
akurat to — oraz czego wydanie **nie** rozwiązuje.

## Jak zrobić wydanie

```bash
git tag v1.0.0
git push origin v1.0.0
```

Workflow `.github/workflows/wydanie.yml` uruchamia się na tagu, buduje pakiet,
pakuje go w obraz i dołącza `.dmg` do wydania na GitHubie. Przy ręcznym
uruchomieniu z zakładki Actions obraz nie trafia do wydania — zostaje jako
artefakt do pobrania.

To samo lokalnie, bez gita:

```bash
./build_app.sh            # pakiet w repozytorium
./make_dmg.sh             # dist/GlowForge-<wersja>.dmg
open dist/GlowForge-*.dmg # obejrzyj, co wyszło
```

## Co jest w obrazie

| element | po co |
|---|---|
| `GlowForge.app` | aplikacja, a w środku konwerter w `Contents/Resources/glowforge/` |
| `Applications` | skrót do `/Applications`, żeby dało się przeciągnąć |
| `PRZECZYTAJ.txt` | czego brakuje, żeby to zadziałało |

Trzy pliki, nie jeden. Aplikacja bez instrukcji jest bezużyteczna — patrz
pod „Czego wydanie nie rozwiązuje".

## Skąd bierze się numer wersji

Trzy miejsca muszą się zgadzać: `CFBundleShortVersionString` w `Info.plist`,
nazwa pliku `.dmg` i tag w gicie. Wersja wędruje tak:

```
tag v1.0.0  →  GLOWFORGE_WERSJA=1.0.0  →  build_app.sh  →  Info.plist
                                       ↘  make_dmg.sh   →  GlowForge-1.0.0.dmg
```

W obu skryptach jest **jedna** zmienna środowiskowa, a nie dwa niezależne
obliczenia. Wcześniej `build_app.sh` miał wpisane na sztywno `1.0`, a
`make_dmg.sh` brał `git describe` — i przy braku tagów powstawał pakiet
w wersji 1.0 w pliku `GlowForge-0fe6163.dmg`. `make_dmg.sh` czyta teraz numer
z już zbudowanego pakietu, więc nazwa pliku nie może się rozjechać z tym,
co jest w środku.

## Co sprawdza workflow

Runner GitHub Actions nie ma ani `~/glowforge`, ani `~/web_hdr/glowforge`,
ani żadnego z komputerów, na których ten projekt powstawał. Jest więc
**dokładnie tym komputerem, na którym wydany pakiet ma działać** — i jedynym
miejscem, gdzie samowystarczalność da się sprawdzić bez zgadywania.

| krok | czego pilnuje |
|---|---|
| `--sciezki` | że konwerter jest znajdowany w `Contents/Resources`, a nie obok |
| `--sciezki` | że skrypt i profil PQ faktycznie są w pakiecie |
| `--sciezki` | że katalog wyjściowy jest zapisywalny |
| `vtool` vs `plutil` | że binarka wymaga tej samej wersji systemu, co obiecuje plist |
| `convert` na próbę | że konwersja faktycznie przechodzi, a nie tylko startuje |
| zajrzenie do DMG | że obraz zawiera binarkę i konwerter |

Krok z konwersją tworzy środowisko Pythona **tam, gdzie wskazuje instrukcja
z obrazu, i tymi samymi poleceniami** co użytkownik. Pierwsze uruchomienie
tego kroku tak właśnie poległo: CI budowało `.venv` w repozytorium, a launcher
z pakietu szuka go w katalogu danych użytkownika. Instrukcja była poprawna,
ale nic jej nie sprawdzało — dopiero wykonanie jej dosłownie to pokazało.

Dwa ostatnie pytają o **skutek**, nie o zamiar. To ta sama zasada, co przy
sprawdzaniu czcionek: lista zainstalowanych rzeczy bywa nieaktualna, więc
trzeba sprawdzić, czy da się jej użyć.

## Tylko arm64

I nie da się tego obejść bez przepisania kodu. Aplikacja wypełnia teksturę
`.rgba16Float` połówkowymi liczbami zmiennoprzecinkowymi, a Swift **nie
udostępnia `Float16` na x86_64**. Próba zbudowania na Intel kończy się tak:

```
glowforge_app.swift:376:41: error: cannot convert value of type 'Int'
to expected argument type 'Float16'
```

Błąd wygląda jak pomyłka w kodzie, a jest brakiem typu w bibliotece
standardowej dla tej architektury. Sprawdzone dla celów 12.0, 13.0 i 14.0 —
wszędzie identycznie. Żeby wydać uniwersalny obraz, trzeba by zastąpić
`Float16` ręcznym składaniem połówek.

## Wersja systemu jest przypięta

`build_app.sh` kompiluje z jawnym `-target arm64-apple-macos12.0` i tę samą
wartość wpisuje jako `LSMinimumSystemVersion`. Bez tego kompilator przyjmuje
wersję maszyny, na której akurat buduje:

| gdzie budowane | co wpisane w binarkę | co obiecuje plist |
|---|---|---|
| ten komputer (macOS 27) | `minos 27.0` | `12.0` |
| runner `macos-14` | `minos 14.0` | `12.0` |

Plik kłamał, a wydania z różnych runnerów miałyby różne wymagania. Workflow
porównuje jedno z drugim i przerywa, gdy się rozjadą.

## Czego wydanie nie rozwiązuje

### Konwerter potrzebuje Pythona

Pakiet zawiera **skrypty**, nie interpreter. Dołączony jest `glowforge.py`,
launcher i profil PQ — ale `fontTools` i `Pillow` muszą być w systemie:

```bash
python3 -m venv ~/Library/Application\ Support/GlowForge/.venv
~/Library/Application\ Support/GlowForge/.venv/bin/pip install fonttools Pillow
```

Launcher szuka środowiska w `.venv` obok skryptu, a gdy skrypt leży
w pakiecie — w `~/Library/Application Support/GlowForge/.venv`, bo Zasoby
pakietu są tylko do czytania. Bez tego zobaczysz listę fontów i ani jednej
udanej konwersji.

### Nie jest podpisany certyfikatem Apple

Podpis jest ad-hoc (`codesign --sign -`), więc pobrany obraz zostanie
oznaczony kwarantanną i system odmówi uruchomienia. Trzeba raz otworzyć
aplikację z klawiszem Control. Alternatywa to podpis Developer ID
i notaryzacja, czyli konto w Apple Developer Program.

### Świecenie zależy od ekranu

Na monitorze bez EDR font będzie po prostu biały. To nie awaria pakietu,
tylko brak zapasu jasności w panelu — patrz [03-edr-i-panel.md](03-edr-i-panel.md).

## Podpisywanie, gdy pojawi się certyfikat

Workflow da się rozszerzyć o `codesign` z prawdziwym certyfikatem i
`notarytool`. Potrzebne będą sekrety: `APPLE_CERT_P12`, `APPLE_CERT_HASŁO`,
`APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_HASŁO_APLIKACJI`. Kroki należy wtedy
wstawić **przed** `make_dmg.sh` (podpisujemy pakiet, nie obraz) i dodać
osobny krok notaryzacji już po zbudowaniu obrazu, bo notaryzuje się `.dmg`.
