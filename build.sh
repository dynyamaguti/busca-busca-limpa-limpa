#!/bin/bash
# Compila o "Busca Busca Limpa Limpa.app" (Apple Silicon + Intel) em ./build
set -euo pipefail
cd "$(dirname "$0")"

# Monta no disco interno (discos exFAT criam arquivos "._" que quebram a assinatura)
STAGE="$(mktemp -d)"
APP="$STAGE/Busca Busca Limpa Limpa.app"
rm -rf build
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library -target "$arch-apple-macos13.0" \
    Sources/main.swift -o "$STAGE/LimpaLimpa-$arch" 2> >(grep -v "CompatibilityPacks" >&2)
done
lipo -create "$STAGE/LimpaLimpa-arm64" "$STAGE/LimpaLimpa-x86_64" -output "$APP/Contents/MacOS/LimpaLimpa"

if [ ! -f AppIcon.icns ]; then
  swift make_icon.swift   # a partir de Resources/icon-source.png
  iconutil -c icns AppIcon.iconset -o AppIcon.icns
  rm -rf AppIcon.iconset
fi
cp AppIcon.icns "$APP/Contents/Resources/"
cp Resources/*.ttf Resources/OFL.txt "$APP/Contents/Resources/"   # Poppins (licença OFL)
cp Info.plist "$APP/Contents/"

codesign --force --deep -s - "$APP"
ditto -c -k --keepParent --norsrc "$APP" "build/Busca Busca Limpa Limpa.zip"
rm -rf "$STAGE"
echo "OK: build/Busca Busca Limpa Limpa.zip  (descompacte e arraste o app para Aplicativos)"
