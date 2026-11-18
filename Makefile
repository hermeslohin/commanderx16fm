# X16 Files - build with Prog8 12.3.x (https://prog8.readthedocs.io) + 64tass + Java 11+.
# PROG8C = compiler command (default: the jar in your home dir). Output goes to build/.
# `make sd SD=/path/to/sdcard` also copies the files there.
PROG8C ?= java -jar $(HOME)/prog8c.jar
export PROG8C
EMU ?= x16emu

.PHONY: all sd run run-modem test clean
all:
	./build.sh

sd:
	./build.sh $(SD)

# plain run on the host file system (SD card side only: ownCloud needs the virtual modem)
run: all
	mkdir -p build/run && ./build.sh build/run > /dev/null
	cd build/run && $(EMU) -scale 2 -prg X16FM.PRG -run

# with the emulator's virtual modem for ownCloud; copies the hub key in (KEY=path to override)
KEY ?= $(HOME)/Downloads/X16LINK.KEY
run-modem: all
	mkdir -p build/run && ./build.sh build/run > /dev/null
	@if [ -f "$(KEY)" ]; then cp "$(KEY)" build/run/X16LINK.KEY; \
	 elif [ ! -f build/run/X16LINK.KEY ]; then echo "warning: no X16LINK.KEY (set KEY=...)"; fi
	cd build/run && $(EMU) -scale 2 -uart1 ximodem -prg X16FM.PRG -run

# end to end: FAT32 SD image + emulator + the real hub link server (needs ../x16-office-hub); SHOT=1 adds a screenshot
test:
	test/run_fmtest.sh

clean:
	rm -rf build
