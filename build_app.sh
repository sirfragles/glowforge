#!/bin/bash
# Buduje GlowForge.app — pakiet aplikacji z ikoną, gotowy do Launchpadu.
#
#   ./build_app.sh            zbuduj pakiet w repozytorium
#   ./build_app.sh --install  zbuduj i skopiuj do ~/Applications
#
# Pakiet musi mieć postać katalogu .app, bo tylko wtedy system czyta
# Info.plist i ikonę, a Launchpad w ogóle go zauważa. Sam plik wykonywalny
# nie wystarczy — nie da się go przeciągnąć na Launchpad.
set -e

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUDOWA="$HERE/build"
APP="$HERE/GlowForge.app"
NAZWA="GlowForge"

# Wersja trafia do Info.plist. Przy wydaniu podaje ja workflow z taga.
# Lokalnie zostaje 1.0, co jest zupelnie w porzadku.
WERSJA="${GLOWFORGE_WERSJA:-1.0}"
NUMER="${GLOWFORGE_BUDOWA:-1}"

# Minimalna wersja systemu. Musi byc TAKA SAMA w dwoch miejscach: w pliku
# wykonywalnym (przez -target) i w Info.plist (LSMinimumSystemVersion).
# Bez -target kompilator przyjmuje wersje maszyny, na ktorej buduje — na
# macOS 27 powstawala binarka z minos 27.0, choc w plist stalo 12.0.
# Skutek: plik klamal, a wydania z roznych runnerow mialyby rozne wymagania.
CEL="arm64-apple-macos12.0"
MINIMUM="12.0"

# Python z Pillow — potrzebny tylko do wygenerowania ikony (make_icon.py
# korzysta wylacznie z PIL, nie z fontTools).
PY=""
for KANDYDAT in "$HERE/.venv/bin/python3" "$HOME/web_hdr/.venv/bin/python3"; do
    if [ -x "$KANDYDAT" ]; then PY="$KANDYDAT"; break; fi
done
# Na maszynie CI nie ma zadnego z tych srodowisk, a Python z systemu bywa
# wystarczajacy — trzeba tylko sprawdzic, czy ma Pillow.
if [ -z "$PY" ] && python3 -c "import PIL" 2>/dev/null; then
    PY="python3"
fi
if [ -z "$PY" ]; then
    echo "BŁĄD: nie znalazłem Pythona z Pillow (potrzebny do ikony)." >&2
    echo "      Utwórz środowisko: python3 -m venv .venv && .venv/bin/pip install Pillow" >&2
    exit 1
fi

echo "1/5  ikona"
"$PY" "$HERE/tools/make_icon.py" "$BUDOWA/AppIcon.iconset"
rm -f "$BUDOWA/AppIcon.icns"
iconutil -c icns "$BUDOWA/AppIcon.iconset" -o "$BUDOWA/AppIcon.icns"

echo "2/5  kompilacja"
mkdir -p "$BUDOWA"
# Tylko arm64 i nie da sie tego obejsc: aplikacja wypelnia teksture
# .rgba16Float polowkowymi liczbami zmiennoprzecinkowymi, a Swift NIE
# UDOSTEPNIA `Float16` na x86_64. Proba -target x86_64-apple-macosXX konczy
# sie bledem "cannot convert value of type 'Int' to expected argument type
# 'Float16'", ktory wyglada jak blad w kodzie, a jest brakiem typu
# w bibliotece dla tej architektury. Sprawdzone na celach 12.0, 13.0, 14.0.
swiftc -O -target "$CEL" "$HERE/glowforge_app.swift" -o "$BUDOWA/$NAZWA"

echo "3/5  pakiet"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUDOWA/$NAZWA" "$APP/Contents/MacOS/$NAZWA"
cp "$BUDOWA/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Konwerter jedzie DO SRODKA pakietu. Bez tego wydane .app dziala tylko na
# komputerze autora: aplikacja szukalaby ~/glowforge, ktorego odbiorca nie
# ma i miec nie bedzie. Zasoby sa przy tym tylko do czytania, wiec pliki
# robocze trafiaja do ~/Library/Application Support/GlowForge.
NARZ="$APP/Contents/Resources/glowforge"
mkdir -p "$NARZ/profiles"
cp "$HERE/glowforge.py" "$NARZ/glowforge.py"
cp "$HERE/glowforge"    "$NARZ/glowforge"
cp "$HERE/profiles/pq-bt2020.icc" "$NARZ/profiles/"
chmod +x "$NARZ/glowforge"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>$NAZWA</string>
    <key>CFBundleDisplayName</key>           <string>GlowForge</string>
    <key>CFBundleIdentifier</key>            <string>local.glowforge</string>
    <key>CFBundleExecutable</key>            <string>$NAZWA</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleShortVersionString</key>    <string>$WERSJA</string>
    <key>CFBundleVersion</key>               <string>$NUMER</string>
    <key>LSMinimumSystemVersion</key>        <string>$MINIMUM</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.graphics-design</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>      <string>glowforge</string>
</dict>
</plist>
PLIST

# Podpis ad-hoc. Bez tego system traktuje aplikację jak uszkodzoną i potrafi
# odmówić uruchomienia po skopiowaniu w inne miejsce.
codesign --force --deep --sign - "$APP" 2>/dev/null || \
    echo "     (podpisywanie pominięte — aplikacja i tak się uruchomi)"

echo "4/5  odświeżenie ikony w Finderze"
touch "$APP"
# UWAGA: tutaj wcześniej było SetFile -a C, czyli „ten element ma własną
# ikonę". Ta flaga każe Finderowi szukać pliku Icon\r W ŚRODKU pakietu,
# a gdy go tam nie ma — przestaje czytać CFBundleIconFile i pokazuje
# zwykły niebieski folder. Ustawianie jej to sabotaż własnej ikony.
# Zdejmujemy ją na wszelki wypadek, gdyby została po starym budowaniu.
/usr/bin/SetFile -a c "$APP" 2>/dev/null || true

echo "5/5  gotowe: $APP"

if [ "$1" = "--install" ]; then
    CEL="$HOME/Applications"
    mkdir -p "$CEL"
    rm -rf "$CEL/GlowForge.app"
    cp -R "$APP" "$CEL/"
    /usr/bin/SetFile -a c "$CEL/GlowForge.app" 2>/dev/null || true
    touch "$CEL/GlowForge.app"
    echo
    echo "zainstalowane: $CEL/GlowForge.app"
    echo "Launchpad powinien ją pokazać po chwili. Jeśli nie — wyloguj się"
    echo "i zaloguj, albo uruchom:  killall Dock"
fi
