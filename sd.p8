; sd.p8 - X16 Files: the SD card side (CMDR-DOS on device 8).
; The current folder is tracked as an absolute path ("/" or "/A/B") and is also the DOS current
; directory (CD), so plain names work for the X16Link transfers. Every other command uses CMDR-DOS
; absolute path syntax: "//A/B/:NAME" (root: "//:NAME"). DOS command letters must be upper case.
; Listings go to banked RAM (64-byte records) with a sorted index in main RAM: folders first.

%import syslib
%import diskio

sd {
    %option ignore_unused

    const ubyte MAXPATH = 63
    const uword MAXN = 512
    const ubyte REC = 64                ; [0] 1 = folder, [1..2] blocks, [3..] name (max 60 + 0)
    const ubyte NAMEMAX = 60

    ; pane listing: banks 1-4; scratch listing of one folder for tree operations: banks 5-8
    const ubyte BANK_PANE = 1
    const ubyte BANK_TMP = 5

    ubyte[64] path                      ; current folder (the pane's), set by init
    uword count
    uword idx = memory("sd_idx", MAXN * 2, 0)     ; sorted order -> record number (words)
    uword tcount                        ; scratch listing (unsorted)
    ubyte[80] st                        ; last DOS status line
    ubyte[80] cmd
    ubyte[64] nm                        ; name of the entry being read / compared
    uword blocks
    bool isdir

    ; pointer to record r of the pane (b = BANK_PANE) or scratch (BANK_TMP) listing; maps the bank
    sub rec(ubyte b, uword r) -> uword {
        cx16.rambank(b + lsb(r >> 7))
        return $a000 + ((r & 127) << 6)
    }

    ; ---------------- DOS commands ----------------
    ; read the status channel into st; returns the 2-digit code (255 = no drive)
    sub status() -> ubyte {
        ubyte n = 0
        ubyte c
        st[0] = 0
        cbm.SETNAM(0, &cmd)
        cbm.SETLFS(15, 8, 15)
        void cbm.OPEN()
        if_cs {
            cbm.CLOSE(15)
            return 255
        }
        void cbm.CHKIN(15)
        while cbm.READST() == 0 {
            c = cbm.CHRIN()
            if c == 13 or c == 10
                break
            if n < 79 {
                st[n] = c
                n++
            }
        }
        st[n] = 0
        cbm.CLRCHN()
        cbm.CLOSE(15)
        if n < 2
            return 255
        return (st[0] - iso:'0') * 10 + st[1] - iso:'0'
    }

    ; third field of the status ("01, FILES SCRATCHED,01,00" -> 1)
    sub status_count() -> ubyte {
        ubyte i = 0
        ubyte commas = 0
        while st[i] != 0 and commas < 2 {
            if st[i] == iso:','
                commas++
            i++
        }
        if commas < 2
            return 0
        return (st[i] - iso:'0') * 10 + st[i + 1] - iso:'0'
    }

    ; send cmd (built by the c_* helpers) and return the status code (< 20 = ok)
    sub send() -> ubyte {
        ubyte n = 0
        while cmd[n] != 0
            n++
        cbm.SETNAM(n, &cmd)
        cbm.SETLFS(15, 8, 15)
        void cbm.OPEN()
        cbm.CLRCHN()
        cbm.CLOSE(15)
        return status()
    }

    ubyte cn
    sub c_begin(uword s) {
        cn = 0
        c_add(s)
    }
    sub c_add(uword s) {
        while @(s) != 0 and cn < 79 {
            cmd[cn] = @(s)
            cn++
            s++
        }
        cmd[cn] = 0
    }
    ; absolute DOS name of `name` in folder `dir` ("/A/B" -> "//A/B/:name", "/" -> "//:name")
    sub c_abs(uword dir, uword name) {
        c_add(iso:"/")
        if @(dir + 1) != 0 {
            c_add(dir)
            c_add(iso:"/")
        } else
            c_add(iso:"/")
        c_add(iso:":")
        c_add(name)
    }

    sub ok(ubyte code) -> bool {
        return code < 20
    }

    ; CD to an absolute folder path
    sub cd_abs(uword dir) -> bool {
        c_begin(iso:"CD:")
        c_add(dir)
        return ok(send())
    }

    sub restore() {
        void cd_abs(&path)
    }

    ; ---------------- path helpers ----------------
    sub slen(uword s) -> ubyte {
        ubyte n = 0
        while @(s + n) != 0
            n++
        return n
    }

    ; dst = dir + "/" + name; false if too long
    sub join(uword dir, uword name, uword dst) -> bool {
        ubyte a = slen(dir)
        ubyte b = slen(name)
        if a == 1
            a = 0                       ; "/" + name
        if a + 1 + b > MAXPATH or b == 0
            return false
        sys.memcopy(dir, dst, a)
        @(dst + a) = iso:'/'
        sys.memcopy(name, dst + a + 1, b)
        @(dst + a + 1 + b) = 0
        return true
    }

    ; parent of an absolute path, in place ("/A/B" -> "/A", "/A" -> "/")
    sub up(uword p) {
        ubyte n = slen(p)
        while n > 1 {
            n--
            if @(p + n) == iso:'/'
                break
        }
        if n == 0
            n = 1
        @(p + n) = 0
    }

    sub at_root() -> bool {
        return path[1] == 0
    }

    ; ---------------- directory reading (bounded: names longer than 60 are skipped) ----------------
    const ubyte LFN = 12

    sub dir_open() -> bool {
        cbm.SETNAM(1, iso:"$")
        cbm.SETLFS(LFN, 8, 0)
        void cbm.OPEN()
        if_cs {
            cbm.CLOSE(LFN)
            return false
        }
        void cbm.CHKIN(LFN)
        repeat 4
            void cbm.CHRIN()            ; load address + link of the header line
        if cbm.READST() != 0 {
            dir_close()
            return false
        }
        ; skip the header line (line number, then the disk name)
        void cbm.CHRIN()
        void cbm.CHRIN()
        while cbm.CHRIN() != 0 {
            if cbm.READST() != 0
                break
        }
        return true
    }

    sub dir_close() {
        cbm.CLRCHN()
        cbm.CLOSE(LFN)
    }

    ; next entry -> nm, blocks, isdir; false at the end. Skips "." / ".." and over-long names.
    sub dir_next() -> bool {
        ubyte c
        ubyte n
        bool toolong
        repeat {
            void cbm.CHRIN()            ; line link
            void cbm.CHRIN()
            c = cbm.CHRIN()
            blocks = mkword(cbm.CHRIN(), c)
            if cbm.READST() != 0
                return false
            ; up to the opening quote (the "blocks free" line has none)
            repeat {
                c = cbm.CHRIN()
                if c == iso:'"'
                    break
                if c == 0 or cbm.READST() != 0
                    return false
            }
            n = 0
            toolong = false
            repeat {
                c = cbm.CHRIN()
                if c == iso:'"' or c == 0 or cbm.READST() != 0
                    break
                if n < NAMEMAX {
                    nm[n] = c
                    n++
                } else
                    toolong = true
            }
            nm[n] = 0
            do {
                c = cbm.CHRIN()
            } until c != iso:' ' or cbm.READST() != 0
            isdir = c == iso:'D'
            while cbm.CHRIN() != 0 {
                if cbm.READST() != 0
                    break
            }
            if toolong or n == 0
                continue
            if nm[0] == iso:'.' and (n == 1 or (n == 2 and nm[1] == iso:'.'))
                continue
            return true
        }
    }

    ; ---------------- pane listing ----------------
    ; case-insensitive compare of nm (folder flag isdir) against record r: <0, 0, >0
    sub cmp_rec(uword r) -> byte {
        uword p = rec(BANK_PANE, peekw(idx + r * 2))
        bool rdir = @(p) != 0
        if isdir != rdir {
            if isdir
                return -1
            return 1
        }
        ubyte i = 0
        ubyte a
        ubyte b
        repeat {
            a = nm[i]
            b = @(p + 3 + i)
            if a >= iso:'A' and a <= iso:'Z'
                a |= 32
            if b >= iso:'A' and b <= iso:'Z'
                b |= 32
            if a != b {
                if a < b
                    return -1
                return 1
            }
            if a == 0
                return 0
            i++
        }
    }

    ; list the current folder (CD to `path` first); false = the folder can't be read
    sub list() -> bool {
        count = 0
        if not cd_abs(&path)
            return false
        if not dir_open()
            return false
        uword p
        uword lo
        uword hi
        uword mid
        ubyte old = cx16.getrambank()
        while count < MAXN and dir_next() {
            p = rec(BANK_PANE, count)
            @(p) = isdir as ubyte
            @(p + 1) = lsb(blocks)
            @(p + 2) = msb(blocks)
            sys.memcopy(&nm, p + 3, slen(&nm) + 1)
            ; binary search for the place in the sorted index
            lo = 0
            hi = count
            while lo < hi {
                mid = (lo + hi) >> 1
                if cmp_rec(mid) > 0
                    lo = mid + 1
                else
                    hi = mid
            }
            if lo < count {
                ; shift idx[lo..count) up by one word (from the top: the ranges overlap)
                uword k = count
                while k > lo {
                    pokew(idx + k * 2, peekw(idx + k * 2 - 2))
                    k--
                }
            }
            pokew(idx + lo * 2, count)
            count++
        }
        dir_close()
        cx16.rambank(old)
        return true
    }

    ; entry i of the pane listing -> nm, isdir, blocks
    sub get(uword i) {
        ubyte old = cx16.getrambank()
        uword p = rec(BANK_PANE, peekw(idx + i * 2))
        isdir = @(p) != 0
        blocks = mkword(@(p + 2), @(p + 1))
        sys.memcopy(p + 3, &nm, slen(p + 3) + 1)
        cx16.rambank(old)
    }

    ; ---------------- scratch listing of any folder (tree operations) ----------------
    sub tlist(uword dir) -> bool {
        tcount = 0
        if not cd_abs(dir)
            return false
        if not dir_open()
            return false
        ubyte old = cx16.getrambank()
        uword p
        while tcount < MAXN and dir_next() {
            p = rec(BANK_TMP, tcount)
            @(p) = isdir as ubyte
            sys.memcopy(&nm, p + 3, slen(&nm) + 1)
            tcount++
        }
        dir_close()
        cx16.rambank(old)
        return true
    }

    sub tget(uword i) {
        ubyte old = cx16.getrambank()
        uword p = rec(BANK_TMP, i)
        isdir = @(p) != 0
        sys.memcopy(p + 3, &nm, slen(p + 3) + 1)
        cx16.rambank(old)
    }

    ; ---------------- file operations (absolute paths) ----------------
    sub exists(uword dir, uword name) -> bool {
        c_begin(iso:"")
        c_abs(dir, name)
        cbm.SETNAM(cn, &cmd)
        cbm.SETLFS(LFN, 8, 0)
        void cbm.OPEN()
        bool e = false
        if_cc
            e = status() < 20
        cbm.CLOSE(LFN)
        return e
    }

    sub scratch(uword dir, uword name) -> ubyte {
        c_begin(iso:"S")
        c_abs(dir, name)
        return send()
    }

    sub mkdir(uword dir, uword name) -> ubyte {
        c_begin(iso:"MD")
        c_abs(dir, name)
        return send()
    }

    ; remove an empty folder (absolute path); CMDR-DOS answers "01,FILES SCRATCHED,nn": nn = 0 -> not removed
    sub rmdir(uword full) -> bool {
        c_begin(iso:"RD:")
        c_add(full)
        ubyte code = send()
        return code < 20 and (code != 1 or status_count() != 0)
    }

    ; copy a file: C<dst>=<src>
    sub copy(uword sdir, uword sname, uword ddir, uword dname) -> ubyte {
        c_begin(iso:"C")
        c_abs(ddir, dname)
        c_add(iso:"=")
        c_abs(sdir, sname)
        return send()
    }

    ; rename / move a file or folder: R<dst>=<src>
    sub rename(uword sdir, uword sname, uword ddir, uword dname) -> ubyte {
        c_begin(iso:"R")
        c_abs(ddir, dname)
        c_add(iso:"=")
        c_abs(sdir, sname)
        return send()
    }

    ; the DOS current directory when we were started (curdir), as an absolute path
    sub init() {
        path[0] = iso:'/'
        path[1] = 0
        uword d = diskio.curdir()
        if d != 0 and @(d) == iso:'/' and slen(d) <= MAXPATH {
            sys.memcopy(d, &path, slen(d) + 1)
            ubyte n = slen(&path)
            if n > 1 and path[n - 1] == iso:'/'
                path[n - 1] = 0
        }
    }
}
