; ui.p8 - X16 Files: mouse/keyboard events, text fields, buttons and the modal dialogs
; (input, yes/no, up to four-way choice, message), in the X16 Write / X16 Sheets look.

%import syslib
%import conv
%import vid
%import theme

ui {
    %option ignore_unused

    const ubyte C_BLACK = vid.C_BLACK
    const ubyte C_WHITE = vid.C_WHITE
    const ubyte C_RED = vid.C_RED
    const ubyte C_BLUE = vid.C_BLUE
    const ubyte C_YELLOW = vid.C_YELLOW
    const ubyte C_DGRAY = vid.C_DGRAY
    const ubyte C_GRAY = vid.C_GRAY
    const ubyte C_LBLUE = vid.C_LBLUE
    const ubyte C_LGRAY = vid.C_LGRAY
    const ubyte STATUS_ROW = 29

    ubyte mouse_btn
    ubyte mouse_cx
    ubyte mouse_cy
    byte mouse_wheel
    bool prev_down = true           ; left button was down at the last poll
    ubyte key                       ; key of the last E_KEY event

    const ubyte E_NONE = 0
    const ubyte E_PRESS = 1         ; left button went down (mouse_cx/cy)
    const ubyte E_KEY = 2           ; a key (ui.key)
    const ubyte E_RELEASE = 3       ; left button went up

    sub poll_mouse() {
        ubyte b
        uword mx
        uword my
        byte wh
        b, mx, my, wh = cx16.mouse_pos()
        mouse_btn = b
        mouse_wheel = wh
        mouse_cx = lsb(mx >> 3)
        mouse_cy = lsb(my >> 3)
        if mx >= 640
            mouse_cx = 79
        if my >= 240
            mouse_cy = 29
    }

    ; one input event per call (waits for the next frame first)
    uword script                    ; tests: keys to feed to the dialogs (0-terminated), 0 = none

    sub event() -> ubyte {
        sys.waitvsync()
        theme.tick()
        if script != 0 and @(script) != 0 {
            key = @(script)
            script++
            return E_KEY
        }
        key = cbm.GETIN2()
        poll_mouse()
        if key != 0
            return E_KEY
        bool down = mouse_btn & 1 != 0
        if down != prev_down {
            prev_down = down
            if down
                return E_PRESS
            return E_RELEASE
        }
        return E_NONE
    }

    ; draw exactly n cells: s (cut, or padded with spaces)
    sub field(ubyte col, ubyte row, uword s, ubyte n, ubyte fg, ubyte bg) {
        ubyte i
        ubyte k = (bg << 4) | fg
        bool ended = false
        if n == 0
            return
        for i in 0 to n - 1 {
            vid.r_sty[i] = 0
            vid.r_col[i] = k
            if not ended and @(s + i) == 0
                ended = true
            if ended
                vid.r_ch[i] = 32
            else
                vid.r_ch[i] = @(s + i)
        }
        vid.render_run(row, col, n)
    }

    sub put(ubyte col, ubyte row, uword s, ubyte fg, ubyte bg) {
        vid.text(col, row, s, 0, fg, bg)
    }

    sub bold(ubyte col, ubyte row, uword s, ubyte fg, ubyte bg) {
        vid.text(col, row, s, vid.S_BOLD, fg, bg)
    }

    ; ---------------- theme roles (theme.rl: pairs are (bg << 4) | fg) ----------------
    sub fg(ubyte role) -> ubyte {
        return theme.rl[role] & 15
    }

    sub bg(ubyte role) -> ubyte {
        return theme.rl[role] >> 4
    }

    ; text in the colours of a pair role
    sub rtext(ubyte col, ubyte row, uword s, ubyte sty, ubyte role) {
        vid.text(col, row, s, sty, fg(role), bg(role))
    }

    ; n cells in the colours of a pair role
    sub rfill(ubyte col, ubyte row, ubyte n, ubyte role) {
        vid.fill(col, row, n, 0, bg(role))
    }

    ; exactly n cells of s in the colours of a pair role
    sub rfield(ubyte col, ubyte row, uword s, ubyte n, ubyte role) {
        field(col, row, s, n, fg(role), bg(role))
    }

    sub num(ubyte col, ubyte row, uword n, ubyte fg, ubyte bg) {
        vid.text(col, row, conv.str_uw(n), 0, fg, bg)
    }

    sub box(ubyte x, ubyte y, ubyte w, ubyte h) {
        ubyte r
        for r in y to y + h - 1
            rfill(x, r, w, theme.R_DLG)
        vid.fill(x, y, w, 0, theme.rl[theme.R_DLG_EDGE])
        vid.fill(x, y + h - 1, w, 0, theme.rl[theme.R_DLG_EDGE])
    }

    ; dialog frame with a title bar
    ; titlebg C_RED: a warning title bar (R_DLG_WARN), anything else the normal one (R_DLG_TTL)
    sub frame(ubyte x, ubyte y, ubyte w, ubyte h, uword title, ubyte titlebg) {
        ubyte role = theme.R_DLG_TTL
        if titlebg == C_RED
            role = theme.R_DLG_WARN
        box(x, y, w, h)
        rfill(x, y, w, role)
        rtext(x + 2, y, title, vid.S_BOLD, role)
    }

    sub button(ubyte x, ubyte y, uword label) {
        theme.pill(x, y, label, fg(theme.R_DLG_BTN), bg(theme.R_DLG_BTN), bg(theme.R_DLG))
    }

    sub hit(ubyte x, ubyte y, uword label) -> bool {
        return mouse_cy == y and mouse_cx >= x and mouse_cx < x + slen(label) + 2
    }

    sub slen(uword s) -> ubyte {
        ubyte n = 0
        while @(s + n) != 0
            n++
        return n
    }

    ; ---------------- status bar ----------------
    ubyte[80] stmsg

    sub status(uword s) {
        ubyte i = 0
        while @(s + i) != 0 and i < 78 {
            stmsg[i] = @(s + i)
            i++
        }
        stmsg[i] = 0
        draw_status()
    }

    ; status = a + b (b cut to fit)
    sub status2(uword a, uword b) {
        ubyte i = 0
        ubyte j = 0
        while @(a + i) != 0 and i < 78 {
            stmsg[i] = @(a + i)
            i++
        }
        while @(b + j) != 0 and i < 78 {
            stmsg[i] = @(b + j)
            i++
            j++
        }
        stmsg[i] = 0
        draw_status()
    }

    sub draw_status() {
        ; Quill (theme sprite) sits in columns 0-1
        rfill(0, STATUS_ROW, 3, theme.R_STAT)
        rfield(3, STATUS_ROW, &stmsg, 77, theme.R_STAT)
    }

    ; ---------------- dialogs ----------------
    const ubyte DX = 10
    const ubyte DW = 60

    ; text input: label above a 56-character field; buf holds the start value; true = OK
    sub ask(uword title, uword label, uword buf, ubyte maxlen) -> bool {
        ubyte y = 10
        ubyte n = slen(buf)
        frame(DX, y, DW, 8, title, C_BLUE)
        rtext(DX + 2, y + 2, label, 0, theme.R_DLG)
        put(DX + 2, y + 5, iso:"Enter = OK   Esc = Cancel", theme.rl[theme.R_BAR_DIM], bg(theme.R_DLG))
        button(DX + 36, y + 6, iso:" OK ")
        button(DX + 45, y + 6, iso:"Cancel")
        bool dirty = true
        repeat {
            if dirty {
                ; show the tail of the text if it is longer than the field, cursor at the end
                dirty = false
                ubyte first = 0
                if n > 55
                    first = n - 55
                ubyte i
                ubyte k = theme.rl[theme.R_FIELD]
                for i in 0 to 55 {
                    vid.r_sty[i] = 0
                    vid.r_col[i] = k
                    vid.r_ch[i] = 32
                    if first + i < n
                        vid.r_ch[i] = @(buf + first + i)
                }
                vid.r_col[n - first] = (k << 4) | (k >> 4)         ; the cursor: inverse
                vid.render_run(y + 3, DX + 2, 56)
            }
            when event() {
                E_KEY -> {
                    if key == 13
                        return true
                    if key == 27 or key == 3
                        return false
                    if (key == 8 or key == 20) and n > 0 {
                        n--
                        @(buf + n) = 0
                        dirty = true
                    } else if ((key >= 32 and key < 127) or key >= 160) and n < maxlen {
                        @(buf + n) = key
                        n++
                        @(buf + n) = 0
                        dirty = true
                    }
                }
                E_PRESS -> {
                    if hit(DX + 36, y + 6, iso:" OK ")
                        return true
                    if hit(DX + 45, y + 6, iso:"Cancel")
                        return false
                }
            }
        }
    }

    ; up to four buttons (labels 0 = unused); returns 0..3, 255 = Esc. line2 may be 0
    uword[4] lab
    ubyte[4] lx
    sub choose(uword title, ubyte titlebg, uword line1, uword line2, uword a, uword b, uword c, uword d) -> ubyte {
        ubyte y = 10
        ubyte i
        lab[0] = a
        lab[1] = b
        lab[2] = c
        lab[3] = d
        frame(DX, y, DW, 7, title, titlebg)
        rfield(DX + 2, y + 2, line1, DW - 4, theme.R_DLG)
        if line2 != 0
            rfield(DX + 2, y + 3, line2, DW - 4, theme.R_DLG)
        ubyte x = DX + 2
        for i in 0 to 3 {
            lx[i] = x
            if lab[i] != 0 {
                button(x, y + 5, lab[i])
                x += slen(lab[i]) + 4
            }
        }
        repeat {
            when event() {
                E_KEY -> {
                    if key == 27 or key == 3
                        return 255
                    if key == 13
                        return 0
                    ; first letter of a label chooses it
                    for i in 0 to 3 {
                        if lab[i] != 0 and (@(lab[i]) | 32) == (key | 32)
                            return i
                    }
                }
                E_PRESS -> {
                    for i in 0 to 3 {
                        if lab[i] != 0 and hit(lx[i], y + 5, lab[i])
                            return i
                    }
                }
            }
        }
    }

    sub yesno(uword title, uword line1, uword line2) -> bool {
        return choose(title, C_RED, line1, line2, iso:"Yes", iso:"No", 0, 0) == 0
    }

    sub message(uword title, uword line1, uword line2) {
        void choose(title, C_BLUE, line1, line2, iso:" OK ", 0, 0, 0)
    }
}
