#!/bin/sh
# Packages the ezpdf extension.
#   Chrome/Edge/Arc/Brave: build/chrome/ezpdf-extension (Load unpacked) + build/ezpdf-chrome.zip
#   Safari: build/safari (an Xcode project made by safari-web-extension-packager; build & run it once,
#           then enable ezpdf in Safari → Settings → Extensions).
# Adapted from utubmp3's scripts/build-chrome.sh.
set -eu
cd "$(dirname "$0")"
SRC="ezpdf-extension"
rm -rf build && mkdir -p build/chrome build/safari-src

cp -R "$SRC" build/chrome/
(cd build/chrome && zip -qr -X ../ezpdf-chrome.zip ezpdf-extension -x '*.DS_Store')
echo "Chrome: build/chrome/ezpdf-extension  (zip: build/ezpdf-chrome.zip)"

# Safari runs MV3 background pages from "scripts"; drop the Chrome service worker key.
cp -R "$SRC" build/safari-src/
python3 - "$SRC/manifest.json" build/safari-src/ezpdf-extension/manifest.json <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["background"] = {"scripts": ["background.js"]}
m["permissions"] = [p for p in m["permissions"]]
json.dump(m, open(sys.argv[2], "w"), indent=4)
PY
if [ "${1:-}" = "--safari" ]; then
  xcrun safari-web-extension-packager build/safari-src/ezpdf-extension \
    --project-location build/safari --app-name "ezpdf Safari" --bundle-identifier ai.harikanth.ezpdf.safari \
    --macos-only --swift --no-open --no-prompt --force
  # The packager derives the app id differently from the extension id; make the extension nest under the app.
  sed -i '' 's/"ai.harikanth.ezpdf.ezpdf-Safari"/ai.harikanth.ezpdf.safari/g' "build/safari/ezpdf Safari/ezpdf Safari.xcodeproj/project.pbxproj"
  echo "Safari: open build/safari/ezpdf Safari/ezpdf Safari.xcodeproj, build & run once, then enable in Safari settings."
fi
