#!/bin/bash
# Regenerates the app icon. Optional argument: a photo of you to use as the icon.
#   tools/make-icon.sh                 logo icon
#   tools/make-icon.sh ~/Pictures/me.jpg
set -euo pipefail
cd "$(dirname "$0")/.."
SET="Assets.xcassets/AppIcon.appiconset"
swift tools/make-icon.swift "$SET" "$@"
python3 - <<PY
import json, subprocess
src="$SET/mac-1024.png"
images=[{"filename":"ios-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"}]
for base in (16,32,128,256,512):
    for scale in (1,2):
        name=f"mac-{base}@{scale}x.png"
        subprocess.run(["sips","-z",str(base*scale),str(base*scale),src,"--out","$SET/"+name],check=True,capture_output=True)
        images.append({"filename":name,"idiom":"mac","scale":f"{scale}x","size":f"{base}x{base}"})
json.dump({"images":images,"info":{"author":"xcode","version":1}},open("$SET/Contents.json","w"),indent=2)
PY
echo "Icon updated. Rebuild the app to see it."
