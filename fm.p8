; fm.p8 - X16 Files: the application (title bar, toolbar, mouse/keyboard loop, folder navigation,
; drag & drop). x16fm.p8 is the program; test/fmtest.p8 drives the same code headless.

%import syslib
%import strings
%import vid
%import ui
%import theme
%import sd
%import cloud
%import pane
%import ops

fm {
    const ubyte B_COPY = 1
    const ubyte B_MOVE = 2
    const ubyte B_DUP = 3
    const ubyte B_REN = 4
    const ubyte B_DEL = 5
    const ubyte B_MKDIR = 6
    const ubyte B_REFRESH = 7
    const ubyte B_QUIT = 8
    const ubyte B_QUILL = 9                 ; the theme mascot, row 29 columns 0-1

    ubyte[8] bx = [1, 10, 19, 31, 40, 49, 62, 0]
    ; button colours (theme roles): Copy accent 1, Move accent 2, New folder 4, Refresh 3, the rest plain
    ubyte[8] brole = [theme.R_BTN_1, theme.R_BTN_2, theme.R_BTN, theme.R_BTN, theme.R_BTN, theme.R_BTN_4, theme.R_BTN_3, 0]
    uword[8] blab_r = [iso:"Copy >", iso:"Move >", iso:"Duplicate", iso:"Rename", iso:"Delete", iso:"New folder", iso:"Refresh", 0]
    uword[8] blab_l = [iso:"< Copy", iso:"< Move", iso:"Duplicate", iso:"Rename", iso:"Delete", iso:"New folder", iso:"Refresh", 0]
    uword[8] tips = [iso:"Copy to the other side (F5; or drag there)", iso:"Move to the other side (F6)",
                     iso:"Copy inside this side, to a new name or folder (F3)", iso:"Rename, or move to another folder (F2)",
                     iso:"Delete (F8 / Del)", iso:"Make a new folder here (F7)", iso:"Read both sides again (F1)", 0]

    bool running = true
    ubyte[64] home                          ; the folder we were started in: the theme files are there
    ubyte last_tip = 255
    ; mouse
    bool rdown
    bool dragging
    bool pressed_row
    ubyte drag_p
    uword drag_r
    ubyte last_click_t
    uword last_click_r = $ffff
    ubyte last_click_p

    sub run() {
        init()
        while running {
            when ui.event() {
                ui.E_KEY -> key(ui.key)
                ui.E_PRESS -> press()
                ui.E_RELEASE -> release()
                else -> idle()
            }
        }
        cloud.quit()
        theme.off()
        vid.gfx_off()
    }

    sub init() {
        vid.load_fonts()
        vid.gfx_init()
        theme.init()
        draw_frame()
        ui.status(iso:"Starting...")
        sd.init()
        sys.memcopy(&sd.path, &home, 64)
        cloud.init()
        pane.active = 0
        pane.enter_list(0)
        pane.enter_list(1)
        redraw()
        if cloud.avail
            ui.status(iso:"Ready. Drag files across to copy, onto a folder to move. Right click marks.")
        else
            ui.status(&cloud.err)
    }

    ; ---------------- drawing ----------------
    sub draw_frame() {
        theme.stripes(0, 0, 80)
        ui.rtext(1, 0, iso:" X16 FILES ", vid.S_BOLD, theme.R_TTL_NAME)
        ui.rtext(29, 0, iso:" SD card <-> ownCloud ", 0, theme.R_TTL_TXT)
        ui.rtext(76, 0, iso:"[X]", vid.S_BOLD, theme.R_QUIT)
        draw_toolbar()
    }

    sub draw_toolbar() {
        ubyte tb = theme.rl[theme.R_TOOL]
        vid.fill(0, 1, 80, 0, tb)
        ubyte i
        uword lab
        for i in 0 to 6 {
            lab = blab_l[i]
            if pane.active == 0
                lab = blab_r[i]
            theme.pill(bx[i], 1, lab, ui.fg(brole[i]), ui.bg(brole[i]), tb)
        }
    }

    sub redraw() {
        draw_frame()
        pane.draw(0)
        pane.draw(1)
        ui.draw_status()
    }

    ; re-read both sides, keeping the selections where possible
    sub reload() {
        pane.list(0)
        pane.list(1)
        pane.draw(0)
        pane.draw(1)
        draw_toolbar()
    }

    sub button_at(ubyte cx, ubyte cy) -> ubyte {
        if cy == 0 and cx >= 76 and cx < 79
            return B_QUIT
        if theme.on_quill(cx, cy)
            return B_QUILL
        if cy != 1
            return 0
        ubyte i
        for i in 0 to 6 {
            if ui.hit(bx[i], 1, blab_r[i])
                return i + 1
        }
        return 0
    }

    ; ---------------- navigation ----------------
    ubyte[64] oldname

    ; open the selected row of pane p: a folder (or "..") is entered
    sub open_row(ubyte p) {
        if pane.rows(p) == 0 or not pane.load(p, pane.sel[p])
            return
        if pane.isup {
            go_up(p)
            return
        }
        if not pane.isdir {
            show_info(p)
            return
        }
        ubyte[64] np
        bool okj
        if p == 0
            okj = sd.join(&sd.path, pane.nm, &np)
        else
            okj = lkfs.join(&cloud.path, pane.nm, &np)
        if not okj {
            ui.status(iso:"Path too long")
            return
        }
        ubyte[64] back
        if p == 0 {
            sys.memcopy(&sd.path, &back, 64)
            sys.memcopy(&np, &sd.path, 64)
        } else {
            sys.memcopy(&cloud.path, &back, 64)
            sys.memcopy(&np, &cloud.path, 64)
        }
        pane.enter_list(p)
        if not pane.ok[p] {
            ; can't read it: stay where we were
            if p == 0
                sys.memcopy(&back, &sd.path, 64)
            else
                sys.memcopy(&back, &cloud.path, 64)
            pane.enter_list(p)
            if p == 0
                ui.status2(iso:"Can't open that folder: ", &sd.st)
            else
                ui.status(&cloud.err)
        } else
            ui.status(iso:"")
        pane.draw(p)
    }

    sub go_up(ubyte p) {
        if not pane.hasup(p)
            return
        if p == 0 {
            sys.memcopy(lkfs.leaf(&sd.path), &oldname, 64)
            sd.up(&sd.path)
        } else {
            sys.memcopy(lkfs.leaf(&cloud.path), &oldname, 64)
            lkfs.up(&cloud.path)
        }
        pane.enter_list(p)
        pane.draw(p)
        select_name(p, &oldname)
    }

    ; select the row named `name` in pane p (after going up, a new folder, ...)
    sub select_name(ubyte p, uword name) {
        uword r
        if pane.rows(p) == 0
            return
        for r in 0 to pane.rows(p) - 1 {
            if pane.load(p, r) and not pane.isup and strings.compare(pane.nm, name) == 0 {
                pane.select(p, r)
                return
            }
        }
    }

    ; status bar: what the selected row is
    ubyte[80] info
    sub show_info(ubyte p) {
        if pane.rows(p) == 0 or not pane.load(p, pane.sel[p]) or pane.isup {
            ui.status(iso:"")
            return
        }
        ubyte n = ui.slen(pane.nm)
        if n > 50
            n = 50
        sys.memcopy(pane.nm, &info, n)
        ubyte i = n
        if pane.isdir {
            sys.memcopy(iso:"  folder", &info + i, 9)
        } else {
            sys.memcopy(&pane.sizetxt, &info + i, 8)
            i += 7
            if p == 1 and cloud.date[1] != 0 {
                ; "  2026-11-17 14:05"
                info[i] = iso:' '
                info[i + 1] = iso:' '
                info[i + 2] = iso:'2'
                info[i + 3] = iso:'0'
                put2(&info + i + 4, cloud.date[0])
                info[i + 6] = iso:'-'
                put2(&info + i + 7, cloud.date[1])
                info[i + 9] = iso:'-'
                put2(&info + i + 10, cloud.date[2])
                info[i + 12] = iso:' '
                put2(&info + i + 13, cloud.date[3])
                info[i + 15] = iso:':'
                put2(&info + i + 16, cloud.date[4])
                i += 18
            }
            if p == 1 and cloud.bad {
                sys.memcopy(iso:"  (can't be copied)", &info + i, 20)
                i += 19
            }
            info[i] = 0
        }
        ui.status(&info)
    }

    sub put2(uword d, ubyte v) {
        @(d) = iso:'0' + v / 10
        @(d + 1) = iso:'0' + v % 10
    }

    ; ---------------- actions ----------------
    sub action(ubyte b) {
        when b {
            B_COPY -> ops.across(false, iso:"")
            B_MOVE -> ops.across(true, iso:"")
            B_DUP -> ops.rename_or_dup(true)
            B_REN -> ops.rename_or_dup(false)
            B_DEL -> ops.delete()
            B_MKDIR -> ops.new_folder()
            B_REFRESH -> {
                if not cloud.avail
                    cloud.init()
                reload()
                if cloud.avail and pane.ok[1] {
                    ui.status(iso:"Refreshed")
                    theme.cheer()
                }
                else
                    ui.status(&cloud.err)
            }
            B_QUIT -> running = false
            B_QUILL -> next_theme()
        }
    }

    ; Quill: the next theme, for every X16 Office app. The theme files and X16THEME.CFG are in the
    ; folder we were started in: go there for a moment, then back to the SD pane's folder.
    sub next_theme() {
        bool ok = sd.cd_abs(&home) and theme.next()
        sd.restore()
        if ok {
            redraw()
            ui.status(&theme.msg)
            theme.cheer()
        } else
            ui.status(iso:"No theme files (X16THEME1.BIN ...) in the start folder")
    }

    sub toggle_mark(ubyte p) {
        uword r = pane.sel[p]
        if r < pane.up_rows(p) or r >= pane.rows(p)
            return
        pane.toggle_mark(p, pane.entry_of(p, r))
        pane.draw_row(p, lsb(r - pane.top[p]))
        pane.draw_foot(p)
    }

    ; '*': mark everything, or clear the marks if there are any
    sub mark_all(ubyte p) {
        if pane.nmarked[p] != 0
            pane.clear_marks(p)
        else if pane.n[p] != 0 {
            uword i
            for i in 0 to pane.n[p] - 1
                pane.toggle_mark(p, i)
        }
        pane.draw_rows(p)
    }

    sub key(ubyte k) {
        ubyte p = pane.active
        when k {
            9 -> {
                pane.activate(1 - p)
                draw_toolbar()
            }
            $91 -> pane.move(p, -1)
            $11 -> pane.move(p, 1)
            $82 -> pane.move(p, -pane.ROWS)
            $02 -> pane.move(p, pane.ROWS)
            $13 -> pane.select(p, 0)
            $04 -> pane.select(p, $ffff)
            13 -> open_row(p)
            8, 20 -> go_up(p)
            32 -> {
                toggle_mark(p)
                pane.move(p, 1)
            }
            iso:'*' -> mark_all(p)
            133 -> action(B_REFRESH)        ; F1
            137 -> action(B_REN)            ; F2
            134 -> action(B_DUP)            ; F3
            135 -> action(B_COPY)           ; F5
            139 -> action(B_MOVE)           ; F6
            136 -> action(B_MKDIR)          ; F7
            140, 127, 25 -> action(B_DEL)   ; F8, Delete
            27 -> {
                if ui.yesno(iso:"Quit", iso:"Quit X16 Files?", 0)
                    running = false
                else
                    redraw()
            }
        }
        if k >= $91 or k == $11 or k == $13 or k == $04 or k == $02 or k == 32
            show_info(pane.active)
    }

    sub pane_at(ubyte cx) -> ubyte {
        if cx < pane.W
            return 0
        return 1
    }

    sub press() {
        ubyte cx = ui.mouse_cx
        ubyte cy = ui.mouse_cy
        pressed_row = false
        dragging = false
        ubyte b = button_at(cx, cy)
        if b != 0 {
            action(b)
            return
        }
        if cy < pane.TITLE_ROW or cy >= ui.STATUS_ROW
            return
        ubyte p = pane_at(cx)
        if p != pane.active {
            pane.activate(p)
            draw_toolbar()
        }
        if cx == pane.x0(p) + pane.W - 1 and cy >= pane.ROW0 and cy < pane.ROW0 + pane.ROWS {
            pane.scroll_click(p, cy - pane.ROW0)
            return
        }
        if pane.row_at(p, cx, cy) {
            uword r = cx16.r0
            pane.select(p, r)
            show_info(p)
            ubyte now = lsb(cbm.RDTIM16())
            if r == last_click_r and p == last_click_p and now - last_click_t < 30 {
                last_click_r = $ffff
                open_row(p)
                return
            }
            last_click_r = r
            last_click_p = p
            last_click_t = now
            pressed_row = true
            drag_p = p
            drag_r = r
        }
    }

    sub idle() {
        ; wheel scrolls the pane under the mouse
        if ui.mouse_wheel != 0 and ui.mouse_cy >= pane.ROW0 and ui.mouse_cy < pane.ROW0 + pane.ROWS {
            ubyte p = pane_at(ui.mouse_cx)
            if ui.mouse_wheel < 0
                pane.scroll_to(p, pane.top[p] - min(pane.top[p], 3))
            else
                pane.scroll_to(p, pane.top[p] + 3)
        }
        ; right click marks
        bool r = ui.mouse_btn & 2 != 0
        if r and not rdown {
            ubyte p2 = pane_at(ui.mouse_cx)
            if pane.row_at(p2, ui.mouse_cx, ui.mouse_cy) {
                if p2 != pane.active {
                    pane.activate(p2)
                    draw_toolbar()
                }
                pane.select(p2, cx16.r0)
                toggle_mark(p2)
            }
        }
        rdown = r
        ; a pressed row becomes a drag when the mouse leaves it
        if pressed_row and not dragging and ui.mouse_btn & 1 != 0 {
            bool same = pane_at(ui.mouse_cx) == drag_p and pane.row_at(drag_p, ui.mouse_cx, ui.mouse_cy) and cx16.r0 == drag_r
            if not same and drag_r >= pane.up_rows(drag_p) {
                dragging = true
                ui.status(iso:"Drop on the other side to copy, or on a folder to move it there")
            }
        }
        ; tool tips
        if not dragging and ui.mouse_btn == 0 {
            ubyte t = button_at(ui.mouse_cx, ui.mouse_cy)
            if t != last_tip {
                last_tip = t
                if t >= B_COPY and t <= B_REFRESH
                    ui.status(tips[t - 1])
                else if t == B_QUILL and theme.cur != 0
                    ui.status(&theme.tip)
            }
        }
    }

    sub release() {
        if not dragging {
            pressed_row = false
            return
        }
        dragging = false
        pressed_row = false
        ubyte tp = pane_at(ui.mouse_cx)
        ; the dragged row: all marked entries if it is marked, else just that row
        if not pane.marked(drag_p, pane.entry_of(drag_p, drag_r)) {
            pane.clear_marks(drag_p)
            pane.sel[drag_p] = drag_r
        }
        ubyte[64] target
        target[0] = 0
        if pane.row_at(tp, ui.mouse_cx, ui.mouse_cy) {
            uword r = cx16.r0
            if pane.load(tp, r) and pane.isdir and not (tp == drag_p and r == drag_r)
                sys.memcopy(pane.nm, &target, ui.slen(pane.nm) + 1)
        }
        if ui.mouse_cy < pane.TITLE_ROW or ui.mouse_cy >= ui.STATUS_ROW {
            ui.status(iso:"")
            return
        }
        if tp != drag_p {
            pane.active = drag_p
            ops.across(false, &target)
        } else if target[0] != 0 {
            ops.into(drag_p, &target)
        } else
            ui.status(iso:"")
    }
}
