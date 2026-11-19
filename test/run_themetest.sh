#!/usr/bin/env bash
# Themes, headless: themetest.prg + X16THEME1..6.BIN in x16emu on the host file system (a folder with
# a LETTERS subfolder). Checks the PASS lines and that X16THEME.CFG lands in the start folder; one
# screenshot per theme: build/themetest/snap-1.png .. snap-6.png.
# Env: PROG8C (default java -jar ~/prog8c.jar), EMU (default /usr/local/x16emu/x16emu), PY (a python3
# with Pillow to split the screenshots; without it only the first one).
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
B="${BUILD:-$HERE/build/themetest}"
EMU="${EMU:-/usr/local/x16emu/x16emu}"
P8="${PROG8C:-java -jar $HOME/prog8c.jar} -target cx16 -srcdirs $HERE/lib/x16link -srcdirs $HERE"
rm -rf "$B"; mkdir -p "$B/fs/LETTERS/OLD"
$P8 -out "$B" "$HERE/test/themetest.p8" > "$B/themetest.log" 2>&1 || { cat "$B/themetest.log"; exit 1; }
python3 "$HERE/tools/mkthemes.py" "$B/fs" > /dev/null
cp "$B/themetest.prg" "$B/fs/"
for f in NOTES.TXT GAME.PRG; do printf 'hello\n' > "$B/fs/$f"; done
for f in A.TXT B.TXT C.PRG; do printf 'hello\n' > "$B/fs/LETTERS/$f"; done
cd "$B/fs"
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "$EMU" -sound none -echo iso -fsroot . -gif ../snap.gif,wait \
  -prg themetest.prg -run > ../out.txt 2>&1 &
P=$!
for _ in $(seq 600); do grep -aq "DONE" ../out.txt 2>/dev/null && break; kill -0 $P 2>/dev/null || break; sleep 0.2; done
sleep 0.5; kill $P 2>/dev/null; wait $P 2>/dev/null || true
cd "$B"
tr '\r' '\n' < out.txt | tr -d '\000' | grep -a -E "PASS|FAIL|DONE" || tail -20 out.txt
ok=1
grep -aq "ALL PASS" out.txt || ok=0
if [ -f fs/X16THEME.CFG ] && [ ! -e fs/LETTERS/X16THEME.CFG ]; then
  echo "PASS X16THEME.CFG in the start folder only"
else
  echo "FAIL X16THEME.CFG in the start folder only"; ok=0
fi
if [ -f snap.gif ]; then
  # one PNG per frame (sips only converts the first)
  "${PY:-python3}" - <<'PY' 2>/dev/null || sips -s format png snap.gif --out snap-1.png > /dev/null 2>&1
from PIL import Image
im = Image.open("snap.gif")
i = 0
while True:
    i += 1
    im.convert("RGB").save(f"snap-{i}.png")
    try:
        im.seek(im.tell() + 1)
    except EOFError:
        break
PY
  echo "screenshots: $B/snap-*.png"
fi
[ $ok = 1 ] && echo "RESULT PASS" || { echo "RESULT FAIL"; exit 1; }
