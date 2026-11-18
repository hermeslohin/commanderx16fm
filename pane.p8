; pane.p8 - X16 Files: the two file panes. Pane 0 (left) = SD card, pane 1 (right) = ownCloud.
; A row is ".." (when not at the top folder) or an entry; folders come first. Rows can be marked
; (right click / Space) for operations on several entries at once.

%import ui
%import sd
%import cloud

pane {
    %option ignore_unused

    const ubyte TITLE_ROW = 2
    const ubyte PATH_ROW = 3
    const ubyte HEAD_ROW = 4
    const ubyte ROW0 = 5
    const ubyte ROWS = 23
    const ubyte FOOT_ROW = 28
    const ubyte W = 40                  ; 38 text cells + 1 gap + scroll bar
    const ubyte NAMEW = 29

    ubyte active
    uword[2] top
    uword[2] sel                        ; selected row
    uword[2] n                          ; entries (without the ".." row)
    bool[2] ok                          ; listing succeeded
    ubyte[256] marks                    ; 2 x 128 bytes: one bit per entry (1024 entries)
    uword[2] nmarked

    ; the row being looked at (load)
    uword nm                            ; name (0-terminated)
    bool isdir
    bool isup
    bool bad
    ubyte[8] sizetxt

    sub x0(ubyte p) -> ubyte {
        return p * W
    }

    sub hasup(ubyte p) -> bool {
        if p == 0
            return not sd.at_root()
        return cloud.path[0] != 0
    }

    sub up_rows(ubyte p) -> ubyte {
        if hasup(p)
            return 1
        return 0
    }

    sub rows(ubyte p) -> uword {
        return n[p] + up_rows(p)
    }

    ; entry index of row r (row must not be the ".." row)
    sub entry_of(ubyte p, uword r) -> uword {
        return r - up_rows(p)
    }

    ; ---------------- marks ----------------
    sub marked(ubyte p, uword i) -> bool {
        if i >= 1024
            return false
        return marks[p * 128 + lsb(i >> 3)] & (1 << (lsb(i) & 7)) != 0
    }

    sub toggle_mark(ubyte p, uword i) {
        if i >= 1024
            return
        ubyte k = p * 128 + lsb(i >> 3)
        ubyte b = 1 << (lsb(i) & 7)
        marks[k] ^= b
        if marks[k] & b != 0
            nmarked[p]++
        else
            nmarked[p]--
    }

    sub clear_marks(ubyte p) {
        sys.memset(&marks + p * 128, 128, 0)
        nmarked[p] = 0
    }

    ; ---------------- loading ----------------
    sub list(ubyte p) {
        clear_marks(p)
        if p == 0 {
            ok[0] = sd.list()
            n[0] = sd.count
        } else {
            ok[1] = cloud.avail and cloud.list() == 0
            n[1] = cloud.count
        }
        if sel[p] >= rows(p)
            sel[p] = 0
        if sel[p] < top[p] or sel[p] >= top[p] + ROWS
            top[p] = 0
    }

    ; reset selection (new folder)
    sub enter_list(ubyte p) {
        top[p] = 0
        sel[p] = 0
        list(p)
    }

    ; 16-bit decimal, right-aligned in sizetxt[0..6]
    sub size_num(uword v, ubyte suffix) {
        sys.memset(&sizetxt, 7, iso:' ')
        sizetxt[7] = 0
        ubyte i = 6
        if suffix != 0 {
            sizetxt[6] = suffix
            i = 5
        }
        repeat {
            sizetxt[i] = iso:'0' + lsb(v % 10)
            v /= 10
            if v == 0 or i == 0
                break
            i--
        }
    }

    ; fill nm/isdir/isup/bad/sizetxt for row r of pane p
    sub load(ubyte p, uword r) -> bool {
        isup = false
        bad = false
        if r < up_rows(p) {
            isup = true
            isdir = true
            nm = iso:".."
            sys.memcopy(iso:" <UP>  ", &sizetxt, 8)
            return true
        }
        uword i = r - up_rows(p)
        if p == 0 {
            sd.get(i)
            nm = &sd.nm
            isdir = sd.isdir
            if not isdir {
                ; CMDR-DOS reports 254-byte blocks: show about how many KB
                uword kb = (sd.blocks >> 2) + ((sd.blocks >> 7) & 1)
                if sd.blocks != 0 and kb == 0
                    kb = 1
                size_num(kb, iso:'K')
            }
        } else {
            void cloud.get(i)
            nm = &cloud.nm
            isdir = cloud.isdir
            bad = cloud.bad
            if not isdir {
                if cloud.size[3] == 0 and cloud.size[2] == 0 and (cloud.size[1] < $27 or (cloud.size[1] == $27 and cloud.size[0] < $10))
                    size_num(mkword(cloud.size[1], cloud.size[0]), 0)       ; < 10000 bytes: exact
                else
                    size_num(mkword(cloud.size[2], cloud.size[1]) >> 2, iso:'K')
            }
        }
        if isdir
            sys.memcopy(iso:" <DIR> ", &sizetxt, 8)
        return true
    }

    ; ---------------- drawing ----------------
    sub draw_title(ubyte p) {
        ubyte bg = vid.C_PURPLE
        if p == active
            bg = ui.C_RED
        vid.fill(x0(p), TITLE_ROW, W, ui.C_BLACK, bg)
        if p == 0
            ui.bold(x0(p) + 1, TITLE_ROW, iso:"X16 SD card", ui.C_BLACK, bg)
        else
            ui.bold(x0(p) + 1, TITLE_ROW, iso:"ownCloud", ui.C_BLACK, bg)
        ; path line: the end of the path if it is too long
        uword s
        ubyte[80] pb
        if p == 0 {
            s = &sd.path
        } else {
            sys.memcopy(iso:"/Documents", &pb, 11)
            if cloud.path[0] != 0 {
                pb[10] = iso:'/'
                sys.memcopy(&cloud.path, &pb + 11, ui.slen(&cloud.path) + 1)
            }
            s = &pb
        }
        ubyte l = ui.slen(s)
        if l > W - 2
            s += l - (W - 2)
        vid.fill(x0(p), PATH_ROW, W, 0, ui.C_LGRAY)
        ui.field(x0(p) + 1, PATH_ROW, s, W - 2, 0, ui.C_LGRAY)
        vid.fill(x0(p), HEAD_ROW, W, ui.C_BLACK, ui.C_YELLOW)
        ui.put(x0(p) + 2, HEAD_ROW, iso:"Name", ui.C_BLACK, ui.C_YELLOW)
        ui.put(x0(p) + 34, HEAD_ROW, iso:"Size", ui.C_BLACK, ui.C_YELLOW)
    }

    sub thumb(ubyte p) -> ubyte {
        uword total = rows(p)
        if total <= ROWS
            return 1
        uword t = 1 + (top[p] * (ROWS - 3)) / (total - ROWS)
        if t > ROWS - 2
            t = ROWS - 2
        return lsb(t)
    }

    sub draw_row(ubyte p, ubyte vr) {
        uword r = top[p] + vr
        ubyte fg = ui.C_BLACK
        ubyte bg = ui.C_WHITE
        ubyte sty = 0
        ubyte i
        for i in 0 to W - 1 {
            vid.r_ch[i] = 32
            vid.r_sty[i] = 0
        }
        if r < rows(p) and load(p, r) {
            bool mk = not isup and marked(p, entry_of(p, r))
            if isdir {
                fg = ui.C_BLUE
                sty = vid.S_BOLD
            }
            if bad
                fg = ui.C_GRAY
            if mk
                fg = vid.C_BROWN
            if r == sel[p] {
                if p == active {
                    bg = ui.C_RED
                    fg = ui.C_BLACK
                } else
                    bg = ui.C_LGRAY
            }
            if mk {
                vid.r_ch[0] = iso:'*'
                sty |= vid.S_BOLD
            }
            ubyte l = ui.slen(nm)
            for i in 0 to NAMEW - 1 {
                if i < l
                    vid.r_ch[1 + i] = @(nm + i)
                vid.r_sty[1 + i] = sty
            }
            if isdir and l < NAMEW
                vid.r_ch[1 + l] = iso:'/'
            if l > NAMEW
                vid.r_ch[NAMEW] = iso:'~'
            for i in 0 to 6
                vid.r_ch[31 + i] = sizetxt[i]
        }
        ubyte k = (bg << 4) | fg
        for i in 0 to W - 2
            vid.r_col[i] = k
        ; scroll bar
        ubyte sb = (ui.C_BLACK << 4) | ui.C_BLACK
        if vr == 0 {
            vid.r_ch[W - 1] = iso:'^'
            sb = (ui.C_BLACK << 4) | ui.C_RED
        } else if vr == ROWS - 1 {
            vid.r_ch[W - 1] = iso:'v'
            sb = (ui.C_BLACK << 4) | ui.C_RED
        } else if vr == thumb(p) and rows(p) > ROWS
            sb = (ui.C_RED << 4) | ui.C_RED
        vid.r_col[W - 1] = sb
        vid.render_run(ROW0 + vr, x0(p), W)
    }

    sub draw_rows(ubyte p) {
        ubyte vr
        for vr in 0 to ROWS - 1
            draw_row(p, vr)
        draw_foot(p)
    }

    ubyte[48] fb
    sub draw_foot(ubyte p) {
        vid.fill(x0(p), FOOT_ROW, W, 0, ui.C_LGRAY)
        if p == 1 and not ok[1] {
            ui.field(x0(p) + 1, FOOT_ROW, &cloud.err, W - 2, ui.C_RED, ui.C_LGRAY)
            return
        }
        if p == 0 and not ok[0] {
            ui.field(x0(p) + 1, FOOT_ROW, &sd.st, W - 2, ui.C_RED, ui.C_LGRAY)
            return
        }
        fb[0] = 0
        fadd(conv.str_uw(n[p]))
        fadd(iso:" items")
        if nmarked[p] != 0 {
            fadd(iso:", ")
            fadd(conv.str_uw(nmarked[p]))
            fadd(iso:" marked")
        }
        ui.field(x0(p) + 1, FOOT_ROW, &fb, W - 2, ui.C_DGRAY, ui.C_LGRAY)
    }

    sub fadd(uword s) {
        ubyte i = ui.slen(&fb)
        while @(s) != 0 and i < 46 {
            fb[i] = @(s)
            i++
            s++
        }
        fb[i] = 0
    }

    sub draw(ubyte p) {
        draw_title(p)
        draw_rows(p)
    }

    ; ---------------- selection / scrolling ----------------
    sub scroll_to(ubyte p, uword t) {
        uword total = rows(p)
        uword maxt = 0
        if total > ROWS
            maxt = total - ROWS
        if t > maxt
            t = maxt
        if t != top[p] {
            top[p] = t
            draw_rows(p)
        }
    }

    sub select(ubyte p, uword r) {
        uword total = rows(p)
        if total == 0
            return
        if r >= total
            r = total - 1
        uword old = sel[p]
        sel[p] = r
        if r < top[p]
            scroll_to(p, r)
        else if r >= top[p] + ROWS
            scroll_to(p, r - ROWS + 1)
        if old >= top[p] and old < top[p] + ROWS
            draw_row(p, lsb(old - top[p]))
        draw_row(p, lsb(r - top[p]))
    }

    sub move(ubyte p, word d) {
        word r = (sel[p] as word) + d
        if r < 0
            r = 0
        select(p, r as uword)
    }

    sub activate(ubyte p) {
        if p != active {
            active = p
            draw(0)
            draw(1)
        }
    }

    ; screen position -> row of pane p (false if not on a list row)
    sub row_at(ubyte p, ubyte cx, ubyte cy) -> bool {
        if cy < ROW0 or cy >= ROW0 + ROWS or cx < x0(p) or cx >= x0(p) + W - 1
            return false
        cx16.r0 = top[p] + cy - ROW0
        return cx16.r0 < rows(p)
    }

    ; click on the scroll bar column
    sub scroll_click(ubyte p, ubyte vr) {
        if vr == 0
            scroll_to(p, top[p] - min(top[p], 3))
        else if vr == ROWS - 1
            scroll_to(p, top[p] + 3)
        else if rows(p) > ROWS
            scroll_to(p, ((rows(p) - ROWS) * (vr - 1)) / (ROWS - 3))
    }
}
