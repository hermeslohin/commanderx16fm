; ops.p8 - X16 Files: file operations.
;   copy / move to the other side   SD <-> ownCloud: files with OPEN/READ and SAVE/WRITE/COMMIT (conv 3,
;                                   byte-for-byte), folders as whole trees
;   move into a folder (drag & drop), rename/move to a path, duplicate, delete, new folder
; Operations work on the marked entries of a pane, or on its selected row. Folder trees are walked
; with a queue in banked RAM (Prog8 subs are not re-entrant, so no recursion).
; Existing destinations are never replaced silently: Overwrite / All / Skip / Cancel.

%import ui
%import theme
%import sd
%import cloud
%import pane

ops {
    %option ignore_unused

    const ubyte BANK_ITEMS = 9          ; 2 banks: 256 items x 64 bytes ([0] folder flag, [1..] name)
    const ubyte BANK_Q = 11             ; 4 banks: 256 folders x 128 bytes (path a, path b)
    const uword MAXITEMS = 256
    const uword MAXQ = 256
    const ubyte S_CONFLICT = 8

    uword nitems
    ubyte[64] iname
    bool iisdir
    ubyte[64] qa
    ubyte[64] qb
    uword qn
    uword qhead
    bool over_all
    bool cancelled
    bool item_ok                        ; everything of the current item went fine
    uword nok
    uword nbad
    ubyte[80] lasterr
    ubyte[64] p1                        ; scratch paths
    ubyte[64] p2
    ubyte[64] fname
    ubyte[48] etag
    str TMPNAME = iso:"X16FM.TMP"

    ; ---------------- item list (what an operation works on) ----------------
    sub item_rec(uword i) -> uword {
        cx16.rambank(BANK_ITEMS + lsb(i >> 7))
        return $a000 + ((i & 127) << 6)
    }

    sub add_item(bool dir, uword name) {
        if nitems >= MAXITEMS
            return
        ubyte old = cx16.getrambank()
        uword r = item_rec(nitems)
        @(r) = dir as ubyte
        sys.memcopy(name, r + 1, ui.slen(name) + 1)
        cx16.rambank(old)
        nitems++
    }

    sub item(uword i) {
        ubyte old = cx16.getrambank()
        uword r = item_rec(i)
        iisdir = @(r) != 0
        sys.memcopy(r + 1, &iname, ui.slen(r + 1) + 1)
        cx16.rambank(old)
    }

    ; marked entries of pane p, or its selected row (not ".."); false = nothing to do
    sub gather(ubyte p) -> bool {
        nitems = 0
        uword r
        if pane.nmarked[p] != 0 {
            for r in pane.up_rows(p) to pane.rows(p) - 1 {
                if pane.marked(p, pane.entry_of(p, r)) and pane.load(p, r)
                    add_item(pane.isdir, pane.nm)
            }
        } else if pane.rows(p) != 0 and pane.load(p, pane.sel[p]) and not pane.isup
            add_item(pane.isdir, pane.nm)
        if nitems == 0 {
            ui.status(iso:"Select a file or folder first (Space or right click marks several)")
            return false
        }
        return true
    }

    ; ---------------- folder queue ----------------
    sub q_reset() {
        qn = 0
        qhead = 0
    }

    sub q_push(uword a, uword b) -> bool {
        if qn >= MAXQ {
            seterr(iso:"Too many folders (max 256)")
            return false
        }
        ubyte old = cx16.getrambank()
        cx16.rambank(BANK_Q + lsb(qn >> 6))
        uword r = $a000 + ((qn & 63) << 7)
        sys.memcopy(a, r, ui.slen(a) + 1)
        sys.memcopy(b, r + 64, ui.slen(b) + 1)
        cx16.rambank(old)
        qn++
        return true
    }

    sub q_get(uword i) {
        ubyte old = cx16.getrambank()
        cx16.rambank(BANK_Q + lsb(i >> 6))
        uword r = $a000 + ((i & 63) << 7)
        sys.memcopy(r, &qa, ui.slen(r) + 1)
        sys.memcopy(r + 64, &qb, ui.slen(r + 64) + 1)
        cx16.rambank(old)
    }

    ; ---------------- messages ----------------
    sub seterr(uword s) {
        ubyte i = 0
        while @(s + i) != 0 and i < 78 {
            lasterr[i] = @(s + i)
            i++
        }
        lasterr[i] = 0
    }

    ; lasterr = what + ": " + detail
    sub seterr2(uword what, uword detail) {
        seterr(what)
        ubyte i = ui.slen(&lasterr)
        lasterr[i] = iso:':'
        lasterr[i + 1] = iso:' '
        lasterr[i + 2] = 0
        i += 2
        ubyte j = 0
        while @(detail + j) != 0 and i < 78 {
            lasterr[i] = @(detail + j)
            i++
            j++
        }
        lasterr[i] = 0
    }

    sub fail_sd(uword name) {
        seterr2(name, &sd.st)
        item_ok = false
        nbad++
    }

    ubyte[64] lkerr
    sub fail_cloud(uword name, bool docs) {
        if docs
            lkapi.get_error(&lkerr, 63)
        else
            lkapi.link_error(&lkerr, 63)
        seterr2(name, &lkerr)
        item_ok = false
        nbad++
    }

    sub progress_name(uword verb, uword name) {
        ui.status2(verb, name)
    }

    ; Esc stops a running operation between two files
    sub check_cancel() -> bool {
        if cbm.GETIN2() == 27
            cancelled = true
        return cancelled
    }

    ; destination exists: 0 = overwrite, 1 = skip, 2 = cancel
    sub ask_over(uword name) -> ubyte {
        if over_all
            return 0
        ubyte c = ui.choose(iso:"Already exists", ui.C_RED, name, iso:"is already there. Replace it?",
                            iso:"Overwrite", iso:"All", iso:"Skip", iso:"Cancel")
        when c {
            0 -> return 0
            1 -> {
                over_all = true
                return 0
            }
            2 -> {
                item_ok = false
                return 1
            }
        }
        cancelled = true
        item_ok = false
        return 2
    }

    ; ---------------- one file across ----------------
    ; SD file sdir/name -> ownCloud folder cdir
    sub up_file(uword sdir, uword name, uword cdir) {
        if not lkfs.join(cdir, name, &p2) {
            seterr2(name, iso:"path too long for ownCloud")
            item_ok = false
            nbad++
            return
        }
        progress_name(iso:"Uploading ", name)
        if not sd.cd_abs(sdir) or cloud.ensure() != 0 {
            fail_sd(name)
            return
        }
        etag[0] = 0
        lkapi.set_etag(&etag)
        ubyte st = lkapi.upload(name, &p2, 0, cloud.CONV_RAW)
        if st == S_CONFLICT {
            void lkapi.conflict(&etag, 48)
            if ask_over(name) != 0
                return
            lkapi.set_etag(&etag)
            progress_name(iso:"Uploading ", name)
            st = lkapi.upload(name, &p2, 1, cloud.CONV_RAW)
        }
        if st != 0
            fail_cloud(name, true)
        else
            nok++
    }

    ; ownCloud file cdir/name -> SD folder sdir (via a temp file, so a failed download never
    ; touches an existing file)
    sub down_file(uword cdir, uword name, uword sdir) {
        if not lkfs.join(cdir, name, &p2) {
            seterr2(name, iso:"path too long")
            item_ok = false
            nbad++
            return
        }
        bool replace = sd.exists(sdir, name)
        if replace and ask_over(name) != 0
            return
        progress_name(iso:"Downloading ", name)
        if not sd.cd_abs(sdir) {
            fail_sd(name)
            return
        }
        ubyte st = cloud.ensure()
        if st == 0
            st = lkapi.download(&p2, TMPNAME, cloud.CONV_RAW)
        if st != 0 {
            void sd.scratch(sdir, TMPNAME)
            fail_cloud(name, true)
            return
        }
        if replace
            void sd.scratch(sdir, name)
        if not sd.ok(sd.rename(sdir, TMPNAME, sdir, name)) {
            fail_sd(name)
            void sd.scratch(sdir, TMPNAME)
            return
        }
        nok++
    }

    ; ---------------- one file on the SD card ----------------
    sub sd_copy_file(uword sdir, uword name, uword ddir, uword dname) {
        progress_name(iso:"Copying ", name)
        if sd.exists(ddir, dname) {
            if ask_over(dname) != 0
                return
            void sd.scratch(ddir, dname)
        }
        if sd.ok(sd.copy(sdir, name, ddir, dname))
            nok++
        else
            fail_sd(name)
    }

    sub sd_move(uword sdir, uword name, uword ddir, uword dname, bool dir) {
        progress_name(iso:"Moving ", name)
        if sd.exists(ddir, dname) {
            if dir {
                seterr2(dname, iso:"a folder or file of that name exists there")
                item_ok = false
                nbad++
                return
            }
            if ask_over(dname) != 0
                return
            void sd.scratch(ddir, dname)
        }
        if sd.ok(sd.rename(sdir, name, ddir, dname))
            nok++
        else
            fail_sd(name)
    }

    ; ---------------- ownCloud server-side copy / move ----------------
    sub cl_copymove(bool move, uword src, uword dst) {
        progress_name(iso:"Working on ", lkfs.leaf(src))
        if cloud.ensure() != 0 {
            fail_cloud(lkfs.leaf(src), false)
            return
        }
        ubyte st
        if move
            st = lkfs.move(0, src, dst)
        else
            st = lkfs.copy(0, src, dst)
        if st == S_CONFLICT {
            if ask_over(lkfs.leaf(dst)) != 0
                return
            if move
                st = lkfs.move(1, src, dst)
            else
                st = lkfs.copy(1, src, dst)
        }
        if st != 0
            fail_cloud(lkfs.leaf(src), false)
        else
            nok++
    }

    ; ---------------- folder trees ----------------
    ; cloud folder listing -> the SD scratch list (so transfers can't disturb it)
    sub cloud_tlist(uword path) -> bool {
        sd.tcount = 0
        if cloud.ensure() != 0 or lkfs.dir_begin(path) != 0
            return false
        uword j
        uword e
        ubyte old = cx16.getrambank()
        if lkfs.total == 0
            return true
        for j in 0 to lkfs.total - 1 {
            if j >= sd.MAXN
                break
            e = lkfs.entry(j)
            if e == 0 {
                cx16.rambank(old)
                return false
            }
            lkfs.name(e, &fname, 61)
            uword r = sd.rec(sd.BANK_TMP, sd.tcount)
            @(r) = lkfs.is_dir(e) as ubyte
            sys.memcopy(&fname, r + 3, ui.slen(&fname) + 1)
            cx16.rambank(old)
            sd.tcount++
        }
        return true
    }

    const ubyte K_UP = 0                ; SD -> ownCloud
    const ubyte K_DOWN = 1              ; ownCloud -> SD
    const ubyte K_SDCOPY = 2            ; SD -> SD

    ; make folder `full` on the destination side; an existing folder is fine (merge)
    ubyte[64] mdp
    sub make_dest(ubyte kind, uword full) -> bool {
        ubyte st
        if kind == K_UP {
            if cloud.ensure() != 0 {
                fail_cloud(lkfs.leaf(full), false)
                return false
            }
            st = lkfs.mkdir(full)
            if st != 0 and st != S_CONFLICT {
                fail_cloud(lkfs.leaf(full), false)
                return false
            }
            return true
        }
        sys.memcopy(full, &mdp, ui.slen(full) + 1)
        sd.up(&mdp)
        uword lf = full + ui.slen(&mdp)
        if @(lf) == iso:'/'
            lf++
        st = sd.mkdir(&mdp, lf)
        if st == 63 {
            ; exists: fine if it is a folder (CD works)
            if sd.cd_abs(full)
                return true
            fail_sd(lf)
            return false
        }
        if not sd.ok(st) {
            fail_sd(lf)
            return false
        }
        return true
    }

    sub join_kind(bool cloudside, uword dir, uword name, uword dst) -> bool {
        if cloudside
            return lkfs.join(dir, name, dst)
        return sd.join(dir, name, dst)
    }

    ; copy the folder tree `src` to `dst` (full paths of the folders themselves)
    sub tree(ubyte kind, uword src, uword dst) {
        bool srccloud = kind == K_DOWN
        bool dstcloud = kind == K_UP
        if not make_dest(kind, dst)
            return
        q_reset()
        if not q_push(src, dst) {
            item_ok = false
            return
        }
        uword j
        while qhead < qn and not check_cancel() {
            q_get(qhead)
            qhead++
            progress_name(iso:"Reading ", &qa)
            bool listed
            if srccloud
                listed = cloud_tlist(&qa)
            else
                listed = sd.tlist(&qa)
            if not listed {
                if srccloud
                    fail_cloud(lkfs.leaf(&qa), false)
                else
                    fail_sd(&qa)
                continue
            }
            if sd.tcount == 0
                continue
            for j in 0 to sd.tcount - 1 {
                if check_cancel()
                    break
                sd.tget(j)
                sys.memcopy(&sd.nm, &fname, ui.slen(&sd.nm) + 1)
                bool isdir = sd.isdir
                if isdir {
                    if not join_kind(srccloud, &qa, &fname, &p1) or not join_kind(dstcloud, &qb, &fname, &p2) {
                        seterr2(&fname, iso:"path too long")
                        item_ok = false
                        nbad++
                        continue
                    }
                    if make_dest(kind, &p2) {
                        if not q_push(&p1, &p2) {
                            item_ok = false
                            nbad++
                        }
                    }
                } else {
                    when kind {
                        K_UP -> up_file(&qa, &fname, &qb)
                        K_DOWN -> down_file(&qa, &fname, &qb)
                        K_SDCOPY -> sd_copy_file(&qa, &fname, &qb, &fname)
                    }
                }
                ; q_get again: the transfer helpers use p1/p2, qa/qb stay as they were
            }
        }
        if cancelled
            item_ok = false
    }

    ; delete an SD folder with everything in it
    sub sd_delete_tree(uword full) {
        q_reset()
        if not q_push(full, iso:"") {
            item_ok = false
            nbad++
            return
        }
        uword i = 0
        uword j
        while i < qn and not check_cancel() {
            q_get(i)
            i++
            progress_name(iso:"Deleting in ", &qa)
            if not sd.tlist(&qa) {
                fail_sd(&qa)
                return
            }
            if sd.tcount == 0
                continue
            for j in 0 to sd.tcount - 1 {
                sd.tget(j)
                sys.memcopy(&sd.nm, &fname, ui.slen(&sd.nm) + 1)
                if sd.isdir {
                    if not sd.join(&qa, &fname, &p1) or not q_push(&p1, iso:"") {
                        fail_sd(&fname)
                        return
                    }
                } else if not sd.ok(sd.scratch(&qa, &fname)) {
                    fail_sd(&fname)
                    return
                }
            }
        }
        if cancelled {
            item_ok = false
            return
        }
        void sd.cd_abs(iso:"/")             ; never remove the current directory
        i = qn
        while i != 0 {
            i--
            q_get(i)
            if not sd.rmdir(&qa) {
                seterr2(&qa, iso:"could not remove the folder")
                item_ok = false
                nbad++
                return
            }
        }
        nok++
    }

    ; ---------------- operations ----------------
    sub begin() {
        nok = 0
        nbad = 0
        over_all = false
        cancelled = false
        lasterr[0] = 0
    }

    ; summary in the status bar, then both panes are re-read
    ubyte[80] msg
    sub finish(uword verb) {
        sd.restore()
        if nbad != 0 {
            ui.status(&lasterr)
        } else if cancelled {
            ui.status(iso:"Stopped")
        } else {
            sys.memcopy(verb, &msg, ui.slen(verb) + 1)
            ui.status(&msg)
            theme.cheer()
        }
        fm.reload()
    }

    sub need_cloud() -> bool {
        if cloud.avail
            return true
        ui.message(iso:"ownCloud", iso:"ownCloud is not available:", &cloud.err)
        fm.redraw()
        return false
    }

    ; copy (or move) the items of the active pane to the other pane's folder (+ `subdir`, "" = none,
    ; ".." = its parent)
    sub across(bool move, uword subdir) {
        ubyte p = pane.active
        if not need_cloud() or not gather(p)
            return
        ; destination folder
        if p == 0
            sys.memcopy(&cloud.path, &qb, ui.slen(&cloud.path) + 1)
        else
            sys.memcopy(&sd.path, &qb, ui.slen(&sd.path) + 1)
        if @(subdir) != 0 {
            if @(subdir) == iso:'.' {
                if p == 0
                    lkfs.up(&qb)
                else
                    sd.up(&qb)
            } else {
                if p == 0
                    void lkfs.join(&cloud.path, subdir, &qb)
                else
                    void sd.join(&sd.path, subdir, &qb)
            }
        }
        ubyte[64] ddir
        sys.memcopy(&qb, &ddir, ui.slen(&qb) + 1)
        begin()
        uword i
        for i in 0 to nitems - 1 {
            if cancelled
                break
            item(i)
            item_ok = true
            if p == 0 {
                if iisdir {
                    if sd.join(&sd.path, &iname, &p1) and lkfs.join(&ddir, &iname, &p2) {
                        ubyte[64] t1
                        ubyte[64] t2
                        sys.memcopy(&p1, &t1, 64)
                        sys.memcopy(&p2, &t2, 64)
                        tree(K_UP, &t1, &t2)
                    } else {
                        seterr2(&iname, iso:"path too long")
                        item_ok = false
                        nbad++
                    }
                } else
                    up_file(&sd.path, &iname, &ddir)
            } else {
                if iisdir {
                    if lkfs.join(&cloud.path, &iname, &p1) and sd.join(&ddir, &iname, &p2) {
                        ubyte[64] t3
                        ubyte[64] t4
                        sys.memcopy(&p1, &t3, 64)
                        sys.memcopy(&p2, &t4, 64)
                        tree(K_DOWN, &t3, &t4)
                    } else {
                        seterr2(&iname, iso:"path too long")
                        item_ok = false
                        nbad++
                    }
                } else
                    down_file(&cloud.path, &iname, &ddir)
            }
            if move and item_ok and not cancelled
                delete_one(p, iisdir, &iname)
        }
        if move
            finish(iso:"Moved")
        else
            finish(iso:"Copied")
    }

    ; delete item `name` of pane p's folder (no questions)
    sub delete_one(ubyte p, bool dir, uword name) {
        uword b = nok
        if p == 0 {
            if dir {
                if sd.join(&sd.path, name, &p1) {
                    ubyte[64] t
                    sys.memcopy(&p1, &t, 64)
                    sd_delete_tree(&t)
                }
            } else {
                progress_name(iso:"Deleting ", name)
                if not sd.ok(sd.scratch(&sd.path, name))
                    fail_sd(name)
            }
        } else {
            progress_name(iso:"Deleting ", name)
            if not lkfs.join(&cloud.path, name, &p1) or cloud.ensure() != 0 or lkfs.delete(&p1) != 0
                fail_cloud(name, false)
        }
        nok = b                             ; a delete inside a move does not count twice
    }

    sub delete() {
        ubyte p = pane.active
        if p == 1 and not need_cloud()
            return
        if not gather(p)
            return
        if nitems == 1 {
            item(0)
            sys.memcopy(iso:"Delete ", &msg, 8)
            sys.memcopy(&iname, &msg + 7, ui.slen(&iname) + 1)
        } else {
            sys.memcopy(iso:"Delete the marked entries?", &msg, 27)
        }
        bool yes = ui.yesno(iso:"Delete", &msg, iso:"Folders are deleted with everything in them.")
        fm.redraw()
        if not yes
            return
        begin()
        uword i
        for i in 0 to nitems - 1 {
            if cancelled
                break
            item(i)
            item_ok = true
            uword b = nok
            delete_one(p, iisdir, &iname)
            if item_ok
                nok = b + 1
        }
        finish(iso:"Deleted")
    }

    ; move the items of pane p into its subfolder `subdir` (".." = parent): drag & drop in one pane
    sub into(ubyte p, uword subdir) {
        if p == 1 and not need_cloud()
            return
        if not gather(p)
            return
        ubyte[64] ddir
        if p == 0
            sys.memcopy(&sd.path, &ddir, ui.slen(&sd.path) + 1)
        else
            sys.memcopy(&cloud.path, &ddir, ui.slen(&cloud.path) + 1)
        if @(subdir) == iso:'.' {
            if p == 0
                sd.up(&ddir)
            else
                lkfs.up(&ddir)
        } else {
            if p == 0
                void sd.join(&sd.path, subdir, &ddir)
            else
                void lkfs.join(&cloud.path, subdir, &ddir)
        }
        begin()
        uword i
        for i in 0 to nitems - 1 {
            if cancelled
                break
            item(i)
            item_ok = true
            if p == 0
                sd_move(&sd.path, &iname, &ddir, &iname, iisdir)
            else {
                if lkfs.join(&cloud.path, &iname, &p1) and lkfs.join(&ddir, &iname, &p2) {
                    ubyte[64] t
                    sys.memcopy(&p2, &t, 64)
                    cl_copymove(true, &p1, &t)
                } else {
                    seterr2(&iname, iso:"path too long")
                    nbad++
                }
            }
        }
        finish(iso:"Moved")
    }

    ; is path b inside folder a ("/A" and "/A/B")?
    sub inside(uword a, uword b) -> bool {
        ubyte i = 0
        while @(a + i) != 0 {
            if @(a + i) != @(b + i)
                return false
            i++
        }
        return @(b + i) == iso:'/'
    }

    ; "/A/B/name" or "name" (relative to folder `cur`) -> target folder p1 + leaf fname; for the
    ; cloud side the folder is Documents-relative without the leading '/'. false = bad path
    sub parse_target(bool cloudside, uword input, uword cur) -> bool {
        ubyte n = ui.slen(input)
        if n == 0
            return false
        while n > 1 and @(input + n - 1) == iso:'/' {
            n--
            @(input + n) = 0
        }
        ; split at the last '/'
        ubyte k = n
        while k != 0 and @(input + k - 1) != iso:'/'
            k--
        if k == n
            return false
        sys.memcopy(input + k, &fname, n - k + 1)
        if k == 0 {
            sys.memcopy(cur, &p1, ui.slen(cur) + 1)
        } else if @(input) == iso:'/' {
            ; absolute
            if k == 1 {
                if cloudside
                    p1[0] = 0
                else {
                    p1[0] = iso:'/'
                    p1[1] = 0
                }
            } else {
                if cloudside {
                    sys.memcopy(input + 1, &p1, k - 2)
                    p1[k - 2] = 0
                } else {
                    sys.memcopy(input, &p1, k - 1)
                    p1[k - 1] = 0
                }
            }
        } else {
            ; relative with folders: cur + "/" + input[0..k-1)
            @(input + k - 1) = 0
            bool okj
            if cloudside
                okj = lkfs.join(cur, input, &p1)
            else
                okj = sd.join(cur, input, &p1)
            @(input + k - 1) = iso:'/'
            if not okj
                return false
        }
        ; no "." / ".." segments, names only
        if fname[0] == iso:'.' and (fname[1] == 0 or (fname[1] == iso:'.' and fname[2] == 0))
            return false
        return true
    }

    ; F2 Rename / move (copy = false) and F3 Duplicate (copy = true) of the selected entry
    ubyte[64] inbuf
    sub rename_or_dup(bool copy) {
        ubyte p = pane.active
        if p == 1 and not need_cloud()
            return
        if not gather(p)
            return
        if nitems != 1 {
            ui.status(iso:"Rename and Duplicate work on one entry: clear the marks first")
            return
        }
        item(0)
        ; start value: the entry's full path, with a leading '/'
        if p == 0 {
            void sd.join(&sd.path, &iname, &inbuf)
        } else {
            inbuf[0] = iso:'/'
            void lkfs.join(&cloud.path, &iname, &inbuf + 1)
        }
        bool ok
        if copy
            ok = ui.ask(iso:"Duplicate", iso:"Copy to (full path, or a name in this folder):", &inbuf, 62)
        else
            ok = ui.ask(iso:"Rename / Move", iso:"New name or path (folders separated by /):", &inbuf, 62)
        fm.redraw()
        if not ok
            return
        if p == 0 {
            if not parse_target(false, &inbuf, &sd.path) {
                ui.status(iso:"That is not a valid name")
                return
            }
        } else {
            if not parse_target(true, &inbuf, &cloud.path) {
                ui.status(iso:"That is not a valid name")
                return
            }
        }
        ubyte[64] tdir
        sys.memcopy(&p1, &tdir, ui.slen(&p1) + 1)
        ubyte[64] tname
        sys.memcopy(&fname, &tname, ui.slen(&fname) + 1)
        begin()
        item_ok = true
        if p == 0 {
            if copy {
                if iisdir {
                    if sd.join(&sd.path, &iname, &p1) and sd.join(&tdir, &tname, &p2) {
                        ubyte[64] t1
                        ubyte[64] t2
                        sys.memcopy(&p1, &t1, 64)
                        sys.memcopy(&p2, &t2, 64)
                        if inside(&t1, &t2)
                            seterr2(&iname, iso:"can't copy a folder into itself")
                        else {
                            tree(K_SDCOPY, &t1, &t2)
                            if item_ok
                                nok = 1
                        }
                        if lasterr[0] != 0 and nbad == 0
                            nbad = 1
                    }
                } else
                    sd_copy_file(&sd.path, &iname, &tdir, &tname)
            } else
                sd_move(&sd.path, &iname, &tdir, &tname, iisdir)
        } else {
            if lkfs.join(&cloud.path, &iname, &p1) and lkfs.join(&tdir, &tname, &p2) {
                ubyte[64] t
                sys.memcopy(&p2, &t, 64)
                cl_copymove(not copy, &p1, &t)
            } else {
                seterr2(&iname, iso:"path too long")
                nbad++
            }
        }
        if copy
            finish(iso:"Duplicated")
        else
            finish(iso:"Renamed")
    }

    sub new_folder() {
        ubyte p = pane.active
        if p == 1 and not need_cloud()
            return
        inbuf[0] = 0
        bool ok = ui.ask(iso:"New folder", iso:"Name of the new folder:", &inbuf, 60)
        fm.redraw()
        if not ok or inbuf[0] == 0
            return
        begin()
        item_ok = true
        if p == 0 {
            if sd.ok(sd.mkdir(&sd.path, &inbuf))
                nok++
            else
                fail_sd(&inbuf)
        } else {
            if not lkfs.join(&cloud.path, &inbuf, &p1) {
                seterr2(&inbuf, iso:"path too long")
                nbad++
            } else if cloud.ensure() != 0 or lkfs.mkdir(&p1) != 0
                fail_cloud(&inbuf, false)
            else
                nok++
        }
        finish(iso:"Folder created")
        fm.select_name(p, &inbuf)
    }
}
