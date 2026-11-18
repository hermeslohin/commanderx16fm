# X16 Files - a mouse-driven file manager for the Commander X16 (Prog8)

Part of the X16 Office suite, with the look of [X16 Write](../commanderx16wp) and
[X16 Sheets](../commanderx16sheets). The **left pane is the X16's SD card**, the **right pane is
ownCloud** (`Documents/` of the hub account, through the X16 Office hub). Files and folders can be
copied and moved between the two, or inside one of them; folders can be made, renamed and deleted.

Build: `make` (Prog8 12.3.x as `~/prog8c.jar` or `PROG8C=...`, 64tass, Java 11+). Everything lands in
`build/`. `make sd SD=<dir>` copies what goes on the SD card:

| File | What |
|---|---|
| `X16FM.PRG` | the program |
| `X16LINK.BIN` `X16DOCS.BIN` | X16Link libraries (banks 60/61), for ownCloud |
| `X16LINK.KEY` | this X16's hub key (the same file X16 Write and X16 Sheets use) |

Without the X16Link files or the key the SD card side still works; the ownCloud pane shows why it is
unavailable. Needs a mouse and 512 KB of RAM.

## Screen

Row 0 title + close box - row 1 toolbar - two panes (title, folder path, column header, 23 rows with a
scroll bar, item count) - status bar (tool tips, what the selected row is, progress, results).
The active pane has a pink title; the toolbar's arrows point from it to the other pane.

The colours are the X16 Office **Sunset Arcade** theme (`theme.p8`, the same file in every app of the
suite): striped title bar, pill buttons, cream lists on a dark violet desk, and **Quill**, a little
pencil (hardware sprite 1) at the left end of the status bar who blinks now and then and hops when an
operation went well.

Rows: `..` (when not in the top folder), then folders (blue, bold, `/`), then files, each sorted by
name. Marked rows have a `*` and are rust-coloured. Sizes: SD card files in KB (CMDR-DOS reports 254-byte blocks, so it is approximate), ownCloud
files exact below 10000 bytes. The status bar shows the selected file's size and, for ownCloud, its
modification date. Files that can't be transferred (name not representable, over 1 MiB) are grey.

## Using it

| Mouse | |
|---|---|
| click | select a row (and make its pane active) |
| double-click a folder / `..` | open it / go up |
| right click | mark / unmark a row (operations then work on all marked rows) |
| drag rows to the other pane | **copy** them there (onto a folder row: into that folder) |
| drag rows onto a folder (or `..`) in the same pane | **move** them into it |
| wheel, scroll bar | scroll |

| Toolbar | Key | |
|---|---|---|
| Copy > / < Copy | F5 | copy the marked rows (or the selected one) to the other pane's folder |
| Move > / < Move | F6 | same, then delete the originals (only those that copied completely) |
| Duplicate | F3 | copy inside the same side, to a new name or path (asks) |
| Rename | F2 | rename, or move to another folder: type a new name or a full path like `/LETTERS/2026/mom.rtf` |
| Delete | F8, Del | delete (asks first); folders are deleted with everything in them |
| New folder | F7 | make a folder in the active pane's folder |
| Refresh | F1 | read both sides again (and retry the hub if it was unreachable) |
| | Tab | switch panes |
| | arrows, PgUp/PgDn, Home/End | move the selection |
| | Enter / Backspace | open the folder / go up |
| | Space, `*` | mark and move down / mark everything (or clear the marks) |
| [X] | Esc | quit (Esc asks first) |

Nothing is replaced silently: when a file or folder of that name is already there, X16 Files asks
**Overwrite / All / Skip / Cancel** (All = overwrite the rest of this operation without asking).
Esc stops a running operation between two files.

**Folders** are copied as whole trees in both directions (made on the other side, merged into a
folder of the same name if there is one). Paths are limited to 63 bytes on both sides.

**Transfers are byte-for-byte** (X16Link `conv 3`): any file type, including `.PRG`, `.BIN` and
text files (a `.txt` arrives exactly as it was, with no character set conversion). Files are
limited to 1 MiB, as for the other apps. A download goes to `X16FM.TMP` in the destination folder
and replaces the target only after its CRC-32 checked out, so a failed download never damages an
existing file. A dropped hub connection resumes (uploads and downloads) or reconnects (folder
operations) by itself. X16 Files keeps the hub key in RAM while it runs (it reconnects whenever the
hub drops an idle session) and wipes it when you quit.

## How it works

* SD card: CMDR-DOS commands with absolute paths (`//A/B/:NAME`): `C` copy, `R` rename/move (files
  and folders), `S` scratch, `MD`, `RD`, `CD`. The left pane's folder is also the DOS current
  directory. The emulator's host file system (no `-sdcard`) does not support `C` or moves between
  folders; use an SD card image (as the test does) or real hardware.
* ownCloud: the hub's docs channel, PROTOCOL.md 3.4 in the hub repo: DIR (one folder at a time),
  MKDIR, DELETE, MOVE, COPY (server side, so ownCloud copies/moves whole folders itself), and
  OPEN/READ + SAVE/WRITE/COMMIT with `conv 3` for transfers. The folder ops are in
  `lib/x16link/lk_fs.p8`.
* Memory: listings in banked RAM (SD pane banks 1-4, scratch listing 5-8, operation items 9-10,
  folder queue 11-14); X16Link in banks 60/61; theme glyphs in font slot 3 (codes 240-244) and Quill
  at VRAM $18000 (sprite 1); golden RAM `$0400-$07FF` is left to X16Link.
  Folder trees are walked with a queue (Prog8 subroutines are not re-entrant).

| File | |
|---|---|
| `x16fm.p8` | the program (calls `fm.run`) |
| `fm.p8` | title bar, toolbar, mouse/keyboard loop, navigation, drag & drop |
| `pane.p8` | the two panes: rows, marks, scrolling |
| `ops.p8` | the operations, folder trees, overwrite questions |
| `sd.p8` | SD card: bounded directory reader, sorted listing, DOS commands |
| `cloud.p8` | hub session (key, reconnect), ownCloud listing, transfer progress |
| `ui.p8` | events, text fields, buttons, dialogs |
| `vid.p8` | X16 Write's 80x30 bitmap text renderer (with the Sunset palette) |
| `theme.p8` | the suite's Sunset Arcade theme: palette roles, title stripes, desk stars, pill buttons, Quill (shared, keep identical in every app) |
| `lib/x16link/` | vendored X16Link client library (from x16-office-hub, `tools/vendor_x16link.sh`) |

## Tests

`make test` (`test/run_fmtest.sh`, macOS: needs `hdiutil`/`diskutil` and `../x16-office-hub` with its
venv): makes a FAT32 SD card image with test files, runs `test/fmtest.p8` (the real application code)
in x16emu with the virtual modem against the hub's link server with an in-memory ownCloud
(`test/fmhub.py`), then checks byte by byte what landed on both sides: copies and moves of files and
folder trees in both directions, binary files, Overwrite/Skip, new folders, rename/move, duplicate
and delete of folder trees on both sides, marked rows into a folder, navigation. `SHOT=1` also saves
a screenshot (`build/fmtest/shot.png`).

## License

Copyright (C) 2026 hermeslohin

X16 Files is free software: you can redistribute it and/or modify it under the terms of the GNU General
Public License as published by the Free Software Foundation, either version 3 of the License, or (at
your option) any later version. It is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
See [LICENSE](LICENSE) for the full text of the GNU General Public License v3.
