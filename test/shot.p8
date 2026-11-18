; shot.p8 - screenshot of X16 Files for the docs/review: run with -gif <file>,wait (see run_fmtest.sh).
%import fm
%import textio
%zeropage basicsafe
main {
    sub start() {
        fm.init()
        pane.active = 1
        pane.draw(0)
        pane.draw(1)
        fm.draw_toolbar()
        fm.select_name(1, iso:"Letters")
        fm.select_name(0, iso:"NEWDIR")
        pane.list(0)
        pane.toggle_mark(0, 1)
        pane.toggle_mark(0, 2)
        pane.draw(0)
        fm.show_info(1)
        repeat 5
            sys.waitvsync()
        @($9fb5) = 1
        repeat 5
            sys.waitvsync()
        cloud.quit()
        txt.print(iso:"DONE\r")
    }
}
