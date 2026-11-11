#!/bin/bash
# Builds raw/en/works-with.png: the "Works with" browser strip card for the photo banners.
# Official app icons come unmodified from the installed browsers (/Applications/*.app);
# a supported browser that isn't installed is shown by name only. Supported list:
# Sources/FastTab/SourceSelectionStore.swift (chrome, edge, brave, safari).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; OUT="$HERE/raw/en"; TMP="$(mktemp -d)"; mkdir -p "$OUT"
for B in "Safari" "Google Chrome" "Microsoft Edge" "Brave Browser"; do
  APP="/Applications/$B.app"
  if [ -d "$APP" ]; then
    ICON=$(/usr/libexec/PlistBuddy -c "Print CFBundleIconFile" "$APP/Contents/Info.plist"); ICON="${ICON%.icns}.icns"
    sips -s format png -Z 256 "$APP/Contents/Resources/$ICON" --out "$TMP/$B.png" >/dev/null
  fi
done
PY=python3; for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do $c -c 'import PIL' 2>/dev/null && { PY=$c; break; }; done
"$PY" - "$TMP" "$OUT/works-with.png" <<'PYEOF'
import sys, os
from PIL import Image, ImageDraw, ImageFont
tmp, out = sys.argv[1], sys.argv[2]
names = [("Safari","Safari"),("Google Chrome","Chrome"),("Microsoft Edge","Edge"),("Brave Browser","Brave")]
W, H, S = 1170, 380, 200
im = Image.new("RGB", (W, H), (250, 249, 246)); d = ImageDraw.Draw(im)
f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 44)
slot = W // len(names)
for i, (app, label) in enumerate(names):
    cx = slot * i + slot // 2; p = os.path.join(tmp, app + ".png")
    if os.path.exists(p):
        ic = Image.open(p).convert("RGBA").resize((S, S), Image.LANCZOS)
        im.paste(ic, (cx - S // 2, 40), ic)
    else:  # not installed: name only, no imitation logo
        bf = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 64)
        d.text((cx, 40 + S // 2), label, font=bf, fill=(60, 60, 60), anchor="mm")
        continue
    d.text((cx, 40 + S + 50), label, font=f, fill=(40, 40, 40), anchor="mm")
im.save(out)
PYEOF
echo "$OUT/works-with.png"
