; cloud.p8 - X16 Files: the ownCloud side, through the X16 Office hub (X16Link).
; X16LINK.BIN (bank 60) + X16DOCS.BIN (bank 61) are loaded at start, the key is read once from
; X16LINK.KEY next to the program (before any CD) and wiped from RAM when the program quits.
; Folder ops use lkfs (lk_fs.p8, compiled in); transfers use the docs library with conv 3 (raw).

%import x16link_api
%import lk_fs
%import ui

cloud {
    %option ignore_unused

    const ubyte CONV_RAW = 3
    const ubyte S_OFFLINE = 41

    bool avail                      ; libraries and key loaded
    ubyte[64] path                  ; folder in Documents/ ("" = Documents itself)
    uword count
    ubyte[64] err                   ; why ownCloud is unavailable / last error

    ; current entry (get)
    ubyte[64] nm
    bool isdir
    bool bad                        ; can't be transferred (name/size)
    ubyte[4] size
    ubyte[5] date                   ; y-2000, month, day, hour, minute (local time); month 0 = none

    sub seterr(uword what) {
        ubyte i = 0
        while @(what + i) != 0 and i < 40 {
            err[i] = @(what + i)
            i++
        }
        err[i] = 0
    }

    ; err = what + ": " + the libraries' error text
    sub fail(uword what, bool docs) {
        seterr(what)
        ubyte i = ui.slen(&err)
        err[i] = iso:':'
        err[i + 1] = iso:' '
        if docs
            lkapi.get_error(&err + i + 2, 62 - i)
        else
            lkapi.link_error(&err + i + 2, 62 - i)
    }

    sub init() {
        path[0] = 0
        avail = false
        if not lkload.load() {
            seterr(iso:"X16LINK.BIN / X16DOCS.BIN not on the SD card")
            return
        }
        if lkapi.load_key(iso:"X16LINK.KEY") != 0 {
            fail(iso:"No hub key", false)
            return
        }
        lkapi.set_progress(&progress)
        avail = true
    }

    ; be connected: dial if needed, otherwise check the session is still alive (the hub drops
    ; idle sessions after 5 minutes). 0 = ok
    sub ensure() -> ubyte {
        if not avail
            return 32
        ubyte st
        if lkapi.is_online() {
            st = lkapi.request(mkword($03, 0), 0, 300)       ; NOOP
            if st == 0
                return 0
            lkapi.hangup()
        }
        ui.status(iso:"Connecting to the hub...")
        st = lkapi.connect()
        if st != 0
            fail(iso:"Hub unreachable", false)
        return st
    }

    sub quit() {
        if avail {
            if lkapi.is_online()
                lkapi.hangup()
            lkapi.forget()
        }
    }

    ; list `path`; 0 = ok
    sub list() -> ubyte {
        count = 0
        ubyte st = ensure()
        if st != 0
            return st
        st = lkfs.dir_begin(&path)
        if st != 0 {
            fail(iso:"Can't list", false)
            return st
        }
        count = lkfs.total
        return 0
    }

    ; entry i -> nm, isdir, size, date, bad
    sub get(uword i) -> bool {
        uword e = lkfs.entry(i)
        if e == 0 {
            nm[0] = 0
            isdir = false
            bad = true
            return false
        }
        lkfs.name(e, &nm, 64)
        isdir = lkfs.is_dir(e)
        bad = @(e + lkfs.E_FLAGS) & lkfs.FL_UNSUPPORTED != 0
        sys.memcopy(e + lkfs.E_SIZE, &size, 4)
        sys.memcopy(e + lkfs.E_DATE, &date, 5)
        return true
    }

    ; transfer progress from X16DOCS.BIN: r0 = done >> 8, r1 = total >> 8.
    ; Runs with RAM bank 61 mapped: only draws (VERA), never touches banked RAM.
    str pct = iso:"    %"
    sub progress() {
        uword d = cx16.r0
        uword t = cx16.r1
        while t >= 600 {
            t >>= 1
            d >>= 1
        }
        ubyte p = 100
        if t != 0 and d < t
            p = lsb((d * 100) / t)
        pct[0] = iso:' '
        pct[1] = iso:' '
        if p >= 100 {
            pct[0] = iso:'1'
            pct[1] = iso:'0'
            p = 0
        } else if p >= 10
            pct[1] = iso:'0' + p / 10
        pct[2] = iso:'0' + p % 10
        vid.text(74, ui.STATUS_ROW, pct, vid.S_BOLD, theme.rl[theme.R_STAT_HI], ui.bg(theme.R_STAT))
    }
}
