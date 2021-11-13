; Partially based on code from https://plutiedev.com/vdp-setup

VdpCtrl:                        Equ $c00004             ; VDP control port
VdpData:                        Equ $c00000             ; VDP data port
HvCounter:                      Equ $c00008             ; H/V counter

VDPREG_MODE1:                   Equ $8000               ; Mode register #1
VDPREG_MODE2:                   Equ $8100               ; Mode register #2
VDPREG_MODE3:                   Equ $8b00               ; Mode register #3
VDPREG_MODE4:                   Equ $8c00               ; Mode register #4

VDPREG_PLANEA:                  Equ $8200               ; Plane A table address
VDPREG_PLANEB:                  Equ $8400               ; Plane B table address
VDPREG_SPRITE:                  Equ $8500               ; Sprite table address
VDPREG_WINDOW:                  Equ $8300               ; Window table address
VDPREG_HSCROLL:                 Equ $8d00               ; HScroll table address

VDPREG_SIZE:                    Equ $9000               ; Plane A and B size
VDPREG_WINX:                    Equ $9100               ; Window X split position
VDPREG_WINY:                    Equ $9200               ; Window Y split position
VDPREG_INCR:                    Equ $8f00               ; Autoincrement
VDPREG_BGCOL:                   Equ $8700               ; Background color
VDPREG_HRATE:                   Equ $8a00               ; HBlank interrupt rate

VDPREG_DMALEN_L:                Equ $9300               ; DMA length (low)
VDPREG_DMALEN_H:                Equ $9400               ; DMA length (high)
VDPREG_DMASRC_L:                Equ $9500               ; DMA source (low)
VDPREG_DMASRC_M:                Equ $9600               ; DMA source (mid)
VDPREG_DMASRC_H:                Equ $9700               ; DMA source (high)

VRAM_ADDR_CMD:                  Equ $40000000
CRAM_ADDR_CMD:                  Equ $c0000000
VSRAM_ADDR_CMD:                 Equ $40000010

VRAM_SIZE:                      Equ 65536
CRAM_SIZE:                      Equ 128
VSRAM_SIZE:                     Equ 80

PlaneA_VRAMAddress:             Equ $2000
PlaneB_VRAMAddress:             Equ $0000
SpriteAttrTable_VRAMAddress:    Equ $1000
HScroll_VRAMAddress:            Equ $1400
PatternBase_VRAMAddress:        Equ $3000
ASICPatternBase_VRAMAddress:    Equ (PatternBase_VRAMAddress + (StaticTilesEnd - StaticTiles))


DMA_SETUP Macro source, size
        move.w #VDPREG_DMALEN_L + (((\size) >> 1) & $ff), VdpCtrl
        move.w #VDPREG_DMALEN_H + ((((\size) >> 1) & $ff00) >> 8), VdpCtrl
        move.w #VDPREG_DMASRC_L + (((\source) >> 1) & $ff), VdpCtrl
        move.w #VDPREG_DMASRC_M + ((((\source) >> 1) & $ff00) >> 8), VdpCtrl
        move.w #VDPREG_DMASRC_H + ((((\source) >> 1) & $7f0000) >> 16), VdpCtrl
    Endm


VRAM_WRITE_ADDR_SET Macro target, flags
        If (narg=2)
            move.l #VRAM_ADDR_CMD + (\flags) + (((\target) & $3fff) << 16) + (((\target) & $c000) >> 14), VdpCtrl
        Else
            move.l #VRAM_ADDR_CMD + (((\target) & $3fff) << 16) + (((\target) & $c000) >> 14), VdpCtrl
        EndIf
    Endm


DMA_VRAM Macro source, target, size
        DMA_SETUP \source, \size
        VRAM_WRITE_ADDR_SET \target, $80
    Endm


DMA_CRAM Macro source, target, size
        DMA_SETUP \source, \size
        move.l #CRAM_ADDR_CMD + $80 + ((\target) << 16), VdpCtrl
    Endm


ENABLE_DISPLAY Macro
        move.w  #VDPREG_MODE2|$74, VdpCtrl
    Endm


DISABLE_DISPLAY Macro
        move.w  #VDPREG_MODE2|$34, VdpCtrl
    Endm


SET_HINT Macro line
        move.w  #VDPREG_HRATE|(\line), VdpCtrl
    Endm


SET_BACKGROUND_COLOR Macro color
        move.w  #VDPREG_BGCOL|(\color), VdpCtrl
    Endm


VDPInit:
        lea     (VdpCtrl), a0
        tst.w   (a0)

        ; Setup registers
        move.w  #VDPREG_HRATE|$ff, (a0)
        move.w  #VDPREG_MODE1|$14, (a0)                 ; Mode register #1; Enable hint
        move.w  #VDPREG_MODE2|$34, (a0)                 ; Mode register #2: Enable DMA + vint
        move.w  #VDPREG_MODE3|$00, (a0)                 ; Mode register #3: Full plane scrolling
        move.w  #VDPREG_MODE4|$00, (a0)                 ; Mode register #4: 32 cell mode (256x224 pixels)

        move.w  #VDPREG_PLANEA|(PlaneA_VRAMAddress >> 10), (a0)
        move.w  #VDPREG_PLANEB|(PlaneB_VRAMAddress >> 10), (a0)
        move.w  #VDPREG_SPRITE|(SpriteAttrTable_VRAMAddress >> 9), (a0)
        move.w  #VDPREG_WINDOW|$00, (a0)
        move.w  #VDPREG_HSCROLL|(HScroll_VRAMAddress >> 10), (a0)

        move.w  #VDPREG_SIZE|$00, (a0)                  ; 32x32 tilemap size
        move.w  #VDPREG_WINX|$00, (a0)
        move.w  #VDPREG_WINY|$00, (a0)
        move.w  #VDPREG_INCR|$02, (a0)                  ; Autoincrement
        move.w  #VDPREG_BGCOL|$00, (a0)

        ; Clear VRAM
        moveq   #0, d0                                  ; To write zeroes
        lea     (VdpCtrl), a0                           ; VDP control port
        lea     (VdpData), a1                           ; VDP data port

        ; Clear VRAM
        move.l  #VRAM_ADDR_CMD, (a0)
        move.w  #(VRAM_SIZE/4)-1, d1
    .clearVram:
        move.l  d0, (a1)
        dbf     d1, .clearVram

        ; Clear CRAM
        move.l  #CRAM_ADDR_CMD, (a0)
        move.w  #(CRAM_SIZE/4)-1, d1
    .clearCram:
        move.l  d0, (a1)
        dbf     d1, .clearCram

        ; Clear VSRAM
        move.l  #VSRAM_ADDR_CMD, (a0)
        move.w  #(VSRAM_SIZE/4)-1, d1
    .clearVsram:
        move.l  d0, (a1)
        dbf     d1, .clearVsram
        rts


VDPVSyncWait:
        lea     VdpCtrl + 1, a0

    .waitVBLankEndLoop:
        btst    #3, (a0)
        bne     .waitVBLankEndLoop

    .waitVBlankStartLoop:
        btst    #3, (a0)
        beq     .waitVBlankStartLoop
        rts
