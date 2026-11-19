; themetest.p8 - themes, headless (test/run_themetest.sh): X16 Files reads X16THEME.CFG and the theme
; files at start (fm.init), opens a subfolder, then Quill's next() (fm.next_theme) goes through all
; six themes and back to the first while the SD pane stays in that subfolder. A screenshot of every
; theme goes into snap.gif (one frame each). Prints PASS/FAIL lines and DONE.
%import fm
%import textio
%zeropage basicsafe

main {
    ubyte fails

    sub check(bool ok, str what) {
        if ok
            txt.print(iso:"PASS ")
        else {
            txt.print(iso:"FAIL ")
            fails++
        }
        txt.print(what)
        txt.nl()
    }

    sub in_letters() -> bool {
        return strings.compare(&sd.path, iso:"/LETTERS") == 0 and pane.ok[0] and pane.n[0] == 4
    }

    ; the whole screen with a bit of everything: panes (folder, marked row, selection active and
    ; inactive), a warning dialog, a dialog with an input field, the transfer percentage
    sub snap() {
        pane.sel[0] = 2
        fm.redraw()
        ; and a dim (inactive pane) selection on the folder row, as the other pane would show it
        pane.active = 1
        pane.sel[0] = 1
        pane.draw_row(0, 1)
        pane.active = 0
        pane.sel[0] = 2
        ui.frame(ui.DX, 10, ui.DW, 7, iso:"Delete", ui.C_RED)
        ui.rfield(ui.DX + 2, 12, iso:"Delete A.TXT?", ui.DW - 4, theme.R_DLG)
        ui.button(ui.DX + 2, 15, iso:"Yes")
        ui.button(ui.DX + 9, 15, iso:"No")
        ui.frame(ui.DX, 19, ui.DW, 7, iso:"New folder", ui.C_BLUE)
        ui.rtext(ui.DX + 2, 20, iso:"Name:", 0, theme.R_DLG)
        ui.rfield(ui.DX + 2, 21, iso:"Holiday", 56, theme.R_FIELD)
        ui.put(ui.DX + 2, 23, iso:"Enter = OK   Esc = Cancel", theme.rl[theme.R_BAR_DIM], ui.bg(theme.R_DLG))
        ui.button(ui.DX + 36, 24, iso:" OK ")
        ui.button(ui.DX + 45, 24, iso:"Cancel")
        ui.status(&theme.msg)
        cx16.r0 = 1
        cx16.r1 = 2
        cloud.progress()
        repeat 40 {
            sys.waitvsync()
            theme.tick()
        }
        @($9fb5) = 1                    ; x16emu: one frame into snap.gif
        sys.wait(4)
    }

    ubyte[6] seen

    sub start() {
        txt.iso()
        void diskio.delete(iso:"X16THEME.CFG")
        fm.init()
        check(theme.cur == 1, iso:"no X16THEME.CFG: theme 1")
        check(theme.rl[theme.R_TTL_CH] == 240 and theme.rl[theme.R_DESK_A] == 7 and theme.rl[theme.R_SEL] == $20, iso:"theme 1 is Sunset Arcade")
        check(strings.compare(&fm.home, iso:"/") == 0, iso:"start folder recorded")

        ; into a subfolder: the SD pane (and the DOS current folder) are there now
        fm.select_name(0, iso:"LETTERS")
        fm.open_row(0)
        check(in_letters(), iso:"SD pane in /LETTERS")
        pane.toggle_mark(0, 3)
        seen[0] = theme.rl[theme.R_DESK]
        snap()

        ubyte i
        for i in 2 to 6 {
            fm.next_theme()
            check(theme.cur == i and in_letters(), iso:"Quill: next theme, the pane stays in /LETTERS")
            seen[i - 1] = theme.rl[theme.R_DESK]
            snap()
        }
        check(seen[1] == vid.C_ORANGE and seen[2] == vid.C_LGRAY and seen[4] == vid.C_DGRAY, iso:"each theme's desk colour")
        ; hovering Quill shows its tip, a click on it is the next theme (here: the first again)
        ui.mouse_cx = 1
        ui.mouse_cy = 29
        ui.mouse_btn = 0
        ui.mouse_wheel = 0
        fm.idle()
        check(strings.compare(&ui.stmsg, &theme.tip) == 0, iso:"hovering Quill: its tip")
        fm.press()
        check(theme.cur == 1 and in_letters(), iso:"click on Quill: after the last theme the first again")
        ; the DOS current folder is the pane's again: a plain name there
        check(diskio.exists(iso:"A.TXT"), iso:"DOS current folder is /LETTERS again")

        ; restart: the saved choice (X16THEME.CFG in the start folder)
        fm.next_theme()
        fm.next_theme()
        theme.cur = 0
        theme.rl[theme.R_DESK] = 99
        void sd.cd_abs(&fm.home)
        theme.init()
        sd.restore()
        check(theme.cur == 3 and theme.rl[theme.R_DESK] == vid.C_LGRAY, iso:"X16THEME.CFG brings back theme 3")
        check(theme.msg[7] == iso:'C' and theme.msg[13] == iso:'B', iso:"its name for the status bar")

        ; the start folder is gone: nothing changes
        fm.home[1] = iso:'X'
        fm.home[2] = 0
        fm.next_theme()
        check(theme.cur == 3 and in_letters(), iso:"no theme files: same theme, pane unchanged")
        fm.home[1] = 0
        fm.next_theme()
        fm.next_theme()
        fm.next_theme()
        fm.next_theme()
        check(theme.cur == 1 and in_letters(), iso:"back to theme 1")
        theme.off()

        if fails == 0
            txt.print(iso:"ALL PASS\r")
        else
            txt.print(iso:"SOME FAILED\r")
        txt.print(iso:"DONE\r")
    }
}
