; X16 FILES - a mouse-driven file manager for the Commander X16 (Prog8), part of the X16 Office suite.
; Left pane: the SD card. Right pane: ownCloud Documents/ through the X16 Office hub (X16Link).
; Copy / move between the two or inside one, folders included; rename, delete, new folder.
; The application is fm.p8; see README.md.

%import fm
%zeropage basicsafe

main {
    sub start() {
        fm.run()
    }
}
