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

# Python z fontTools i Pillow — potrzebny tylko do wygenerowania ikony
PY=""
for KANDYDAT in "$HERE/.venv/bin/python3" "$HOME/web_hdr/.venv/bin/python3"; do
    if [ -x "$KANDYDAT" ]; then PY="$KANDYDAT"; break; fi
done
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
swiftc -O "$HERE/glowforge_app.swift" -o "$BUDOWA/$NAZWA"

echo "3/5  pakiet"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUDOWA/$NAZWA" "$APP/Contents/MacOS/$NAZWA"
cp "$BUDOWA/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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
    <key>CFBundleShortVersionString</key>    <string>1.0</string>
    <key>CFBundleVersion</key>               <string>1</string>
    <key>LSMinimumSystemVersion</key>        <string>12.0</string>
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
/usr/bin/SetFile -a C "$APP" 2>/dev/null || true

echo "5/5  gotowe: $APP"

if [ "$1" = "--install" ]; then
    CEL="$HOME/Applications"
    mkdir -p "$CEL"
    rm -rf "$CEL/GlowForge.app"
    cp -R "$APP" "$CEL/"
    touch "$CEL/GlowForge.app"
    echo
    echo "zainstalowane: $CEL/GlowForge.app"
    echo "Launchpad powinien ją pokazać po chwili. Jeśli nie — wyloguj się"
    echo "i zaloguj, albo uruchom:  killall Dock"
fi
