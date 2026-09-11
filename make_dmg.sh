#!/bin/bash
# Pakuje GlowForge.app w obraz dyskowy .dmg gotowy do wydania.
#
#   ./make_dmg.sh            numer wersji z GLOWFORGE_WERSJA albo z git describe
#   ./make_dmg.sh 1.2.3      wymuś numer
#
# Wynik: dist/GlowForge-<wersja>.dmg
#
# Obraz jest kompresowany (UDZO) i zawiera trzy rzeczy: sam pakiet, skrót do
# /Applications oraz tekst wyjaśniający, czego jeszcze trzeba. Bez tego
# ostatniego użytkownik dostaje aplikację, która pokazuje listę fontów,
# odmawia przebudowania czegokolwiek i nie mówi dlaczego.
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$HERE/GlowForge.app"
DIST="$HERE/dist"
STAGE="$HERE/build/dmg"

# Numer wersji. Kolejnosc jest wazna: nazwa pliku .dmg MUSI zgadzac sie
# z wersja aplikacji w srodku, inaczej nie da sie ich pary skojarzyc.
# Dlatego pytamy najpierw zbudowany pakiet, a dopiero na koncu zgadujemy
# z gita. Wczesniej oba skrypty liczyly wersje osobno i rozjezdzaly sie:
# plist mowil 1.0, a obraz nazywal sie skrotem commita.
WERSJA="${1:-${GLOWFORGE_WERSJA:-}}"
if [ -z "$WERSJA" ]; then
    WERSJA=$(plutil -extract CFBundleShortVersionString raw \
             "$APP/Contents/Info.plist" 2>/dev/null || true)
fi
if [ -z "$WERSJA" ]; then
    WERSJA=$(git -C "$HERE" describe --tags --always 2>/dev/null || echo 0.0.0)
fi
WERSJA="${WERSJA#v}"          # tagi bywają w postaci v1.2.3

if [ ! -d "$APP" ]; then
    echo "BŁĄD: nie ma $APP — najpierw uruchom ./build_app.sh" >&2
    exit 1
fi

rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
cp -R "$APP" "$STAGE/GlowForge.app"

# Skrót do /Applications. Bez niego obraz to jedno okno z ikoną i zagadka.
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/PRZECZYTAJ.txt" <<TEKST
GlowForge — świecące fonty w HDR
===============================

Instalacja
----------
Przeciągnij GlowForge.app na skrót Applications obok.

Zanim zadziała
--------------
Aplikacja jest tylko interfejsem. Same fonty przetwarza skrypt w Pythonie
dołączony w środku pakietu, a on potrzebuje dwóch bibliotek:

    python3 -m venv ~/Library/Application\ Support/GlowForge/.venv
    ~/Library/Application\ Support/GlowForge/.venv/bin/pip install fonttools Pillow

Bez tego zobaczysz listę fontów, ale żaden się nie przebuduje.

Pierwsze uruchomienie
---------------------
Pakiet nie jest podpisany certyfikatem Apple, więc system zablokuje go
komunikatem o niesprawdzonym twórcy. Otwórz go raz z klawiszem Control
(kliknij prawym przyciskiem, wybierz Otwórz, potwierdź) — system zapamięta
ten wybór i więcej nie będzie pytał.

Ekran
-----
Świecenie widać tylko na ekranie z obsługą EDR, czyli XDR. Na zwykłym
monitorze ten sam font będzie po prostu biały — to nie awaria, tylko brak
zapasu jasności w panelu.

Wersja
------
Numer wersji tego obrazu: $WERSJA
TEKST

WYJSCIE="$DIST/GlowForge-$WERSJA.dmg"
rm -f "$WYJSCIE"
hdiutil create -volname "GlowForge $WERSJA" -srcfolder "$STAGE" \
    -ov -format UDZO -quiet "$WYJSCIE"

echo "gotowe: $WYJSCIE"
echo "rozmiar: $(du -h "$WYJSCIE" | cut -f1)"
