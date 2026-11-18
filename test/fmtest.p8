; fmtest.p8 - X16 Files end to end: the real application code (fm, panes, operations, X16Link
; libraries) on a FAT32 SD card image (real CMDR-DOS), through the emulator's virtual modem to the
; real hub link server with an in-memory ownCloud (test/fmhub.py). Dialog answers come from
; ui.script. Prints PASS/FAIL lines and DONE; run_fmtest.sh checks the files on both sides after.
%import fm
%import textio
%zeropage basicsafe

main {
    ubyte fails

    sub ok(bool b, str what) {
        txt.print(what)
        if b
            txt.print(iso:"  PASS\r")
        else {
            txt.print(iso:"  FAIL  [")
            txt.print(&ui.stmsg)
            txt.print(iso:"]\r")
            fails++
        }
    }

    ; is `name` listed in pane p (re-reads it)?
    sub has(ubyte p, str name) -> bool {
        pane.list(p)
        uword r
        if pane.rows(p) == 0
            return false
        for r in 0 to pane.rows(p) - 1 {
            if pane.load(p, r) and not pane.isup and strings.compare(pane.nm, name) == 0
                return true
        }
        return false
    }

    ; make pane p active and select `name`
    sub sel(ubyte p, str name) -> bool {
        pane.active = p
        pane.clear_marks(p)
        if not has(p, name)
            return false
        fm.select_name(p, name)
        return pane.load(p, pane.sel[p]) and strings.compare(pane.nm, name) == 0
    }

    ; mark `name` without re-reading the pane (that would clear the marks)
    sub mark(ubyte p, str name) {
        uword r
        for r in pane.up_rows(p) to pane.rows(p) - 1 {
            if pane.load(p, r) and strings.compare(pane.nm, name) == 0
                pane.toggle_mark(p, pane.entry_of(p, r))
        }
    }

    sub in_folder(ubyte p, str folder, str name) -> bool {
        void sel(p, folder)
        fm.open_row(p)
        bool r = has(p, name)
        fm.go_up(p)
        return r
    }

    sub start() {
        txt.iso()
        fm.init()
        ok(cloud.avail and pane.ok[1], iso:"hub connected, ownCloud listed")
        ok(has(0, iso:"HELLO.TXT") and has(0, iso:"TREE"), iso:"SD card listed")
        ok(has(1, iso:"seed.txt") and has(1, iso:"Photos"), iso:"ownCloud root listed")
        pane.list(1)
        ok(pane.load(1, 0) and pane.isdir and strings.compare(pane.nm, iso:"Photos") == 0, iso:"folders first")

        ; ---- SD -> ownCloud
        ok(sel(0, iso:"HELLO.TXT"), iso:"select HELLO.TXT")
        ops.across(false, iso:"")
        ok(ops.nok == 1 and ops.nbad == 0 and has(1, iso:"HELLO.TXT"), iso:"copy file to ownCloud")
        void sel(0, iso:"BIN.PRG")
        ops.across(false, iso:"")
        ok(ops.nok == 1 and has(1, iso:"BIN.PRG"), iso:"copy binary file to ownCloud")
        void sel(0, iso:"HELLO.TXT")
        ui.script = iso:"s"
        ops.across(false, iso:"")
        ok(ops.nok == 0 and ops.nbad == 0, iso:"exists on ownCloud: Skip")
        ui.script = iso:"o"
        void sel(0, iso:"HELLO.TXT")
        ops.across(false, iso:"")
        ok(ops.nok == 1 and ops.nbad == 0, iso:"exists on ownCloud: Overwrite")

        ; ---- ownCloud: new folder, move into it (drag onto a folder)
        pane.active = 1
        ui.script = iso:"Letters\r"
        ops.new_folder()
        ok(has(1, iso:"Letters"), iso:"new folder on ownCloud")
        void sel(1, iso:"HELLO.TXT")
        ops.into(1, iso:"Letters")
        ok(not has(1, iso:"HELLO.TXT") and in_folder(1, iso:"Letters", iso:"HELLO.TXT"), iso:"move into a folder on ownCloud")

        ; ---- folder trees across
        void sel(0, iso:"TREE")
        ops.across(false, iso:"")
        ok(ops.nbad == 0 and in_folder(1, iso:"TREE", iso:"SUB"), iso:"copy folder tree to ownCloud")
        void sel(1, iso:"Photos")
        ops.across(false, iso:"")
        ok(ops.nbad == 0 and in_folder(0, iso:"Photos", iso:"cat.bin"), iso:"copy folder tree to the SD card")
        void sel(1, iso:"seed.txt")
        ops.across(false, iso:"")
        ok(ops.nok == 1 and has(0, iso:"seed.txt"), iso:"copy file to the SD card")
        void sel(1, iso:"seed.txt")
        ui.script = iso:"o"
        ops.across(false, iso:"")
        ok(ops.nok == 1 and ops.nbad == 0 and has(0, iso:"seed.txt"), iso:"exists on SD: Overwrite")

        ; ---- SD card: new folder, move, rename, duplicate a tree, delete a tree
        pane.active = 0
        ui.script = iso:"NEWDIR\r"
        ops.new_folder()
        ok(has(0, iso:"NEWDIR"), iso:"new folder on the SD card")
        void sel(0, iso:"seed.txt")
        ops.into(0, iso:"NEWDIR")
        ok(not has(0, iso:"seed.txt") and in_folder(0, iso:"NEWDIR", iso:"seed.txt"), iso:"move into a folder on the SD card")
        void sel(0, iso:"BIN.PRG")
        ui.script = iso:"\x14\x14\x14\x14\x14\x14\x14\x14/NEWDIR/RENAMED.PRG\r"
        ops.rename_or_dup(false)
        ok(not has(0, iso:"BIN.PRG") and in_folder(0, iso:"NEWDIR", iso:"RENAMED.PRG"), iso:"rename + move on the SD card")
        void sel(0, iso:"TREE")
        ui.script = iso:"\x14\x14\x14\x14\x14/TREE2\r"
        ops.rename_or_dup(true)
        ok(ops.nbad == 0 and has(0, iso:"TREE") and in_folder(0, iso:"TREE2", iso:"SUB"), iso:"duplicate a folder tree on the SD card")
        void sel(0, iso:"TREE2")
        ui.script = iso:"y"
        ops.delete()
        ok(ops.nbad == 0 and not has(0, iso:"TREE2"), iso:"delete a folder tree on the SD card")

        ; ---- ownCloud: rename into a folder, duplicate a folder, delete it
        void sel(1, iso:"BIN.PRG")
        ui.script = iso:"\x14\x14\x14\x14\x14\x14\x14\x14/Letters/game.prg\r"
        ops.rename_or_dup(false)
        ok(not has(1, iso:"BIN.PRG") and in_folder(1, iso:"Letters", iso:"game.prg"), iso:"rename + move on ownCloud")
        void sel(1, iso:"TREE")
        ui.script = iso:"\x14\x14\x14\x14\x14/TREE3\r"
        ops.rename_or_dup(true)
        ok(has(1, iso:"TREE3"), iso:"duplicate a folder on ownCloud")
        void sel(1, iso:"TREE3")
        ui.script = iso:"y"
        ops.delete()
        ok(not has(1, iso:"TREE3") and has(1, iso:"TREE"), iso:"delete a folder on ownCloud")

        ; ---- move across, marked entries into a folder of the other side (a drop on a folder)
        void sel(0, iso:"HELLO.TXT")
        ops.across(true, iso:"")
        ok(ops.nbad == 0 and not has(0, iso:"HELLO.TXT") and has(1, iso:"HELLO.TXT"), iso:"move file to ownCloud")
        pane.active = 0
        pane.list(0)
        mark(0, iso:"NEWDIR")
        mark(0, iso:"Photos")
        ok(pane.nmarked[0] == 2, iso:"two entries marked")
        ops.across(false, iso:"Letters")
        ok(ops.nbad == 0 and in_folder(1, iso:"Letters", iso:"NEWDIR") and in_folder(1, iso:"Letters", iso:"Photos"), iso:"copy marked entries into a folder")

        ; ---- navigation
        void sel(0, iso:"NEWDIR")
        fm.open_row(0)
        ok(strings.compare(&sd.path, iso:"/NEWDIR") == 0 and has(0, iso:"RENAMED.PRG"), iso:"open a folder on the SD card")
        fm.go_up(0)
        ok(strings.compare(&sd.path, iso:"/") == 0 and pane.load(0, pane.sel[0]) and strings.compare(pane.nm, iso:"NEWDIR") == 0, iso:"up selects the folder we came from")
        void sel(1, iso:"Letters")
        fm.open_row(1)
        ok(strings.compare(&cloud.path, iso:"Letters") == 0 and pane.hasup(1), iso:"open a folder on ownCloud")
        fm.go_up(1)
        ok(cloud.path[0] == 0, iso:"back to Documents")

        cloud.quit()
        if fails == 0
            txt.print(iso:"ALL PASS\r")
        txt.print(iso:"DONE\r")
    }
}
