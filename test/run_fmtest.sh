#!/usr/bin/env bash
# X16 Files end to end (macOS): FAT32 SD card image (real CMDR-DOS, not the emulator's host FS, which
# lacks copy/move across folders) <-> x16emu -uart1 ximodem <-> the real hub link server with an
# in-memory ownCloud (test/fmhub.py). Needs ../x16-office-hub (HUB=...), its Python (HUBPY=...),
# Prog8 12.3 (PROG8C=...), hdiutil + diskutil.
set -eu
HERE="$(cd "$(dirname "$0")/.." && pwd)"
HUB="${HUB:-$HERE/../x16-office-hub/hub}"
HUBPY="${HUBPY:-$HUB/.venv/bin/python}"
B="${BUILD:-$HERE/build/fmtest}"
EMU="${EMU:-/usr/local/x16emu/x16emu}"
P8="${PROG8C:-java -jar $HOME/prog8c.jar} -target cx16 -srcdirs $HERE/lib/x16link -srcdirs $HERE"
rm -rf "$B/out" "$B/key" "$B/mnt" "$B/ximodem"; mkdir -p "$B/out" "$B/key" "$B/mnt" "$B/ximodem"
$P8 -out "$B" "$HERE/test/fmtest.p8" > "$B/fmtest.log" 2>&1 || { cat "$B/fmtest.log"; exit 1; }
$P8 -out "$B" "$HERE/lib/x16link/x16link.p8" > /dev/null 2>&1
$P8 -out "$B" "$HERE/lib/x16link/x16docs.p8" > /dev/null 2>&1

"$HUBPY" "$HERE/test/fmhub.py" "$HUB" "$B/key" "$B/out" 6502 > "$B/hub.log" 2>&1 &
HUBPID=$!
for _ in $(seq 50); do grep -q "hub up" "$B/hub.log" 2>/dev/null && break; sleep 0.2; done

# SD card image with the libraries, the key and some files
IMG="$B/sd.img"
rm -f "$IMG"; dd if=/dev/zero of="$IMG" bs=1m count=40 2> /dev/null
DEV=$(hdiutil attach -nomount -imagekey diskimage-class=CRawDiskImage "$IMG" | head -1 | awk '{print $1}')
diskutil partitionDisk "$DEV" MBR "MS-DOS FAT32" X16FMTEST 100% > /dev/null
hdiutil detach "$DEV" > /dev/null
mount_img() { hdiutil attach -imagekey diskimage-class=CRawDiskImage -mountpoint "$B/mnt" "$IMG" > /dev/null; }
umount_img() { hdiutil detach "$B/mnt" > /dev/null; }
mount_img
cp "$B/x16link.bin" "$B/mnt/X16LINK.BIN"; cp "$B/x16docs.bin" "$B/mnt/X16DOCS.BIN"; cp "$B/key/X16LINK.KEY" "$B/mnt/"
printf 'Hello from the X16\n' > "$B/mnt/HELLO.TXT"
python3 -c "import sys; sys.stdout.buffer.write(bytes(range(256))*4)" > "$B/mnt/BIN.PRG"
mkdir -p "$B/mnt/TREE/SUB"
printf 'top\n' > "$B/mnt/TREE/TOP.TXT"
python3 -c "import sys; sys.stdout.buffer.write(bytes((i*13)&255 for i in range(3000)))" > "$B/mnt/TREE/SUB/DEEP.BIN"
rm -rf "$B/mnt/.fseventsd" "$B/mnt/.Spotlight-V100" "$B/mnt/.Trashes" "$B/mnt"/._* 2> /dev/null || true
umount_img

cd "$B"
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "$EMU" -sound none -warp -echo iso -sdcard "$IMG" \
  -uart1 "ximodem:$B/ximodem" -prg fmtest.prg -run > fmtest.out 2>&1 &
EMUPID=$!
for _ in $(seq 1500); do grep -aq "DONE" fmtest.out 2>/dev/null && break; kill -0 $EMUPID 2>/dev/null || break; sleep 0.2; done
sleep 0.5; kill $EMUPID 2>/dev/null; wait $EMUPID 2>/dev/null || true
tr '\r' '\n' < fmtest.out | tr -d '\000' > fmtest.out.txt
grep -a -E "PASS|FAIL|DONE" fmtest.out.txt || tail -20 fmtest.out.txt
# screenshot of the app on the state the test left behind (build/fmtest/shot.png)
if [ -n "${SHOT:-}" ]; then
  $P8 -out "$B" "$HERE/test/shot.p8" > "$B/shot.log" 2>&1 || cat "$B/shot.log"
  rm -f shot.gif shot.png
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "$EMU" -sound none -echo iso -sdcard "$IMG" \
    -uart1 "ximodem:$B/ximodem" -gif shot.gif,wait -prg shot.prg -run > shot.out 2>&1 &
  EMUPID=$!
  for _ in $(seq 300); do grep -aq "DONE" shot.out 2>/dev/null && break; sleep 0.2; done
  sleep 0.5; kill $EMUPID 2>/dev/null; wait $EMUPID 2>/dev/null || true
  sips -s format png shot.gif --out shot.png > /dev/null && echo "screenshot: $B/shot.png"
fi
touch "$B/out/STOP"; wait $HUBPID || cat "$B/hub.log"

# what landed where
mount_img
set +e
"$HUBPY" - "$B/out/Documents" "$B/mnt" <<'PY'
import sys
from pathlib import Path
oc, sd = Path(sys.argv[1]), Path(sys.argv[2])
bad = 0
def chk(c, what):
    global bad
    print(("PASS " if c else "FAIL ") + what); bad += 0 if c else 1
def rd(p):
    return p.read_bytes() if p.is_file() else None
BIN = bytes(range(256)) * 4
DEEP = bytes((i * 13) & 255 for i in range(3000))
CAT = bytes((i * 7 + 3) & 255 for i in range(1500))
chk(rd(oc / "HELLO.TXT") == b"Hello from the X16\n", "ownCloud HELLO.TXT byte-exact (moved across)")
chk(rd(oc / "Letters/game.prg") == BIN, "ownCloud Letters/game.prg byte-exact (binary, renamed)")
chk(rd(oc / "TREE/SUB/DEEP.BIN") == DEEP and rd(oc / "TREE/TOP.TXT") == b"top\n", "ownCloud TREE copied with its subfolder")
chk(not (oc / "TREE3").exists() and not (oc / "BIN.PRG").exists(), "ownCloud TREE3 deleted, BIN.PRG renamed away")
chk(rd(oc / "Letters/NEWDIR/RENAMED.PRG") == BIN and rd(oc / "Letters/Photos/cat.bin") == CAT, "ownCloud Letters/ got the marked folders")
chk(rd(sd / "Photos/cat.bin") == CAT, "SD Photos/cat.bin byte-exact (folder downloaded)")
chk(rd(sd / "NEWDIR/seed.txt") == b"seed from ownCloud\n", "SD NEWDIR/seed.txt (downloaded, overwritten, moved)")
chk(rd(sd / "NEWDIR/RENAMED.PRG") == BIN and not (sd / "BIN.PRG").exists(), "SD BIN.PRG renamed into NEWDIR")
chk(rd(sd / "TREE/SUB/DEEP.BIN") == DEEP and not (sd / "TREE2").exists(), "SD TREE kept, its duplicate deleted")
chk(not (sd / "HELLO.TXT").exists() and not (sd / "X16FM.TMP").exists(), "SD HELLO.TXT moved away, no temp file left")
print("HOST CHECKS " + ("ALL PASS" if bad == 0 else f"{bad} FAILED"))
PY
R=$?
umount_img
exit $R
