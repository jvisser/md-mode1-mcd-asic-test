    Opt c+,     & ; Case sensitive
        l+,     & ; Use . prefix for local labels
        ws+,    & ; Allow white space
        op+,    & ; PC relative optimisation
        os+,    & ; Short branch optimisation
        ow+,    & ; Absolute word addressing optimisation
        oz+,    & ; Zero offset optimisation
        oaq+,   & ; addq optimisation
        osq+,   & ; subq optimisation
        omq+      ; moveq optimisation

; Constants shared between main/sub cpu
WordRAM_Size                Equ (((1024 * 1024) / 8) * 2) ; 2 mbit

; ----------------------------------
; Word ram allocation is as follows
; Offset from bottom of wordram
    ; stamps
    ; image buffer (fixed size)
    ; trace table (variable size)
; Offset from top of word ram
    ; stamp map2    sprites (32x32 stamps 1x1 screen)
    ; stamp map1    floor   (16x16 stamps, 16x16 screens)
; ----------------------------------
ImageBufferCellWidth        Equ 32
ImageBufferDotWidth         Equ (ImageBufferCellWidth * 8)
ImageBufferCellHeight       Equ 16
ImageBufferDotHeight        Equ (ImageBufferCellHeight * 8)
ImageBufferSize             Equ (ImageBufferCellWidth * ImageBufferCellHeight * 32)
ImageBufferOffset           Equ (((StampsEnd - Stamps) + $0f) & ~$0f)  ; aligned to 16 byte boundary
TraceTableOffset            Equ (ImageBufferOffset + ImageBufferSize)
StampMap1Offset             Equ ((WordRAM_Size - (FloorStampMapEnd - FloorStampMap)) & ~$ff)   ; aligned to 256 byte boundary
StampMap2Offset             Equ (StampMap1Offset - 0)   ; todo


; --------------------------------------------------------------------------------------
; --------------------------------------------------------------------------------------
; --------------------------------------------------------------------------------------
; Main CPU program

    Org 0

    ; 68000 Vector table
    dc.l   $00000000                                                ; Initial SP
    dc.l   Init                                                     ; Initial PC
    dcb.l  26, Exception                                            ; Unused
    dc.l   HBlankInterrupt                                          ; IRQ level 4 (horizontal retrace interrupt)
    dc.l   Exception                                                ; Unused
    dc.l   VBlankInterrupt                                          ; IRQ level 6 (vertical retrace interrupt)
    dcb.l  33, Exception                                            ; Unused

    ; ROM header
    dc.b  'SEGA MEGA DRIVE '                                        ; Console name
    dc.b  '(C)JV 2021      '                                        ; Copyright holder and release date
    dc.b  'md-mode1-mcd-asic-test                          '        ; Domestic name
    dc.b  'md-mode1-mcd-asic-test                          '        ; International name
    dc.b  'GM 13371337   '                                          ; Serial number
    dc.w  $0000                                                     ; Checksum
    dc.b  'JC              '                                        ; Supported devices C = CD ROM support https://plutiedev.com/rom-header#devices
    dc.l  $00000000                                                 ; Start address of ROM
    dc.l  RomImageEnd                                               ; End address of ROM
    dc.l  $00ff0000                                                 ; Start address of RAM
    dc.l  $00ffffff                                                 ; End address of RAM
    dc.l  $00000000                                                 ; SRAM descriptor
    dc.l  $00000000                                                 ; Start address of SRAM
    dc.l  $00000000                                                 ; End address of SRAM
    dcb.b 52, ' '                                                   ; Unused
    dc.b  'JUE             '                                        ; Supported regions

    Include 'vdp.asm'

M_RegHwVersion          Equ $a10001
M_RegTMSS               Equ $a14000

; In mode 1 the main cpu memory map as indicated in the official mega cd manual is moved up by $400000 (Mega CD Software Development Manual: Mapping page 1)
M_CDBootROMAddress      Equ $400000
M_CDProgramRAMAddress   Equ $420000

M_WordRAMBaseAddress    Equ $600000
M_WordRAMTopAddress     Equ (M_WordRAMBaseAddress + WordRAM_Size)

M_RegSubCPUCtrl         Equ $a12000   ; Sub-CPU reset/busreq, etc.
M_RegSubMemCtrl         Equ $a12002   ; Mega CD memory mode, bank, etc.

M_RegCommMainFlag       Equ $a1200e
M_RegCommSubFlag        Equ $a1200f
M_RegSubComm0           Equ $a12010
M_RegSubComm1           Equ $a12012
M_RegSubStat0           Equ $a12020


ASICTileDataBase            Equ (M_WordRAMBaseAddress + ImageBufferOffset)
ASICTileDataSize            Equ ImageBufferSize
ASICTileDataTransferSize1   Equ ((8 * 32 * 32) + (20 * 32))
ASICTileDataTransferSize2   Equ (ASICTileDataSize - ASICTileDataTransferSize1)
ASICTileData1               Equ ASICTileDataBase
ASICTileData2               Equ (ASICTileDataBase + ASICTileDataTransferSize1)
ASICTileData1Target         Equ ASICPatternBase_VRAMAddress
ASICTileData2Target         Equ (ASICPatternBase_VRAMAddress + ASICTileDataTransferSize1)


    ; Variables
    rsset   $ff0000
subCommandCycle     rs.w 1
hintHandled         rs.b 1
frameReady          rs.b 1
cameraAngle         rs.w 1


; See Mega CD Hardware Manual: Supplements (page 61/63) for details
DMA_ASIC_2_VRAM Macro source, target, size
        DMA_VRAM (\source + 2), \target, \size
        VRAM_WRITE_ADDR_SET \target
        move.l  \source, VdpData
    Endm


Exception
        SET_BACKGROUND_COLOR 19 ; Red screen
        stop    #$2700


TMSS:
        move.b  M_RegHwVersion, d0
        andi.b  #$0f, d0
        beq.s   .noTMSS
        move.l  #'SEGA', M_RegTMSS
    .noTMSS:
        rts


; https://plutiedev.com/subcpu-in-mode1#check-if-present
CheckMegaCD:
        btst    #5, M_RegHwVersion                  ; "Disk" indicator bit (=Fdd (super magic drive? ;) connected according to the mega drive manual)
        beq.s   .present
        cmpi.l  #'SEGA', (M_CDBootROMAddress+$100)  ; This is the only check used by the msu-md driver https://github.com/krikzz/msu-md/blob/2dd4475e05a6871f017bbdd8f8cdca11d9b5500c/msu-md-drv/main.s#L15
        beq.s   .present
    .notPresent:
        moveq   #0, d0
        rts
    .present:
        moveq   #1, d0
        rts


SubCPUBusRequest:
        lea     M_RegSubCPUCtrl + 1, a0
        move.b  #$02, (a0)  ; bit 1: SBRQ
    .subBusReqWait:
        btst.b    #1, (a0)
        beq.s   .subBusReqWait
        rts


SubCPUReset:
        ; Reset sub cpu and release bus
        lea     M_RegSubCPUCtrl + 1, a0
        move.b  #$00, (a0)
    .subResetWait:
        move.b  (a0), d0
        andi.b  #$03, d0
        cmp.b   #$01, d0        ; Reset in progress + bus request cancelled
        beq.s   .subResetWait

        ; Resume sub cpu (sub cpu will execute from reset vector)
        move.b  #$01, (a0)
    .subResumeWait:
        btst.b  #0, (a0)        ; Wait for reset finished
        beq.s   .subResumeWait
        rts


LoadASICData:
        ; Load stamps
        lea     M_WordRAMBaseAddress, a0
        lea     Stamps, a1
        move.w  #((StampsEnd - Stamps) / 2) - 1, d0
    .stampLoop:
        move.w  (a1)+, (a0)+
        dbra    d0, .stampLoop

        ; Load stamp maps
        lea     M_WordRAMTopAddress + StampMaps - StampMapsEnd, a0
        lea     StampMaps, a1
        move.w  #((StampMapsEnd - StampMaps) / 2) - 1, d0
    .stampMapLoop:
        move.w  (a1)+, (a0)+
        dbra    d0, .stampMapLoop
        rts


Init:
        bsr     TMSS
        bsr     VDPInit

        ; Load palette
        DMA_CRAM Palette, $00, PaletteEnd - Palette

        ; Check if mega cd present
        bsr     CheckMegaCD
        bne     .megaCdAvailable
            trap #0

    .megaCdAvailable:

        ; Load graphics data into VRAM
        DMA_VRAM StaticTiles,       PatternBase_VRAMAddress,    StaticTilesEnd - StaticTiles
        DMA_VRAM NameTableA,        PlaneA_VRAMAddress,         NameTableAEnd - NameTableA
        DMA_VRAM NameTableB,        PlaneB_VRAMAddress,         NameTableBEnd - NameTableB

        ; Mega CD Hardware Manual: 4-1 Initialization (Gate array forced reset)
        move.w  #$ff00, M_RegSubMemCtrl
        move.b  #$03,   M_RegSubCPUCtrl + 1
        move.b  #$02,   M_RegSubCPUCtrl + 1
        move.b  #$00,   M_RegSubCPUCtrl + 1

        ; Load sub cpu program into mega cd program ram and start
        bsr     SubCPUBusRequest
        move.w  #0, M_RegSubMemCtrl ; Disable write protection
        lea     SubCPUProgram, a0
        lea     M_CDProgramRAMAddress, a1
        move.w  #((SubCPUProgramEnd - SubCPUProgram) / 2) - 1, d0
    .copySubPrgLoop:
        move.w  (a0)+, (a1)+
        dbra    d0, .copySubPrgLoop
        bsr     SubCPUReset

        ; Wait for sub cpu program ready state
    .waitSubCPUReady:
        cmpi.b   #'R', M_RegCommSubFlag
        bne.s   .waitSubCPUReady

        ; Load sub cpu graphics data into word ram (Sub cpu program has given us access to word ram after initialisation)
        bsr     LoadASICData

        ; Render first image and wait for frame ready
        move.w  #'IR', subCommandCycle
        move.w  subCommandCycle, M_RegSubComm0
        move.w  #$02, M_RegSubMemCtrl           ; Give word ram to sub cpu (DMNA=1)
        move.b  #$01, M_RegSubCPUCtrl           ; Generate level 2 interrupt on the sub cpu (IFL2=1)
    .frameReadyWait:
        move.w  M_RegSubStat0, d0
        cmp.w   subCommandCycle, d0
        bne.s   .frameReadyWait

        ; Init variables
        sf     hintHandled
        sf     frameReady
        clr.w  cameraAngle

        ; Start accepting interrupts
        move.w  #$2000, sr

        bra Main


Main:

    ; vsync wait

    .loop:

        tst.b   frameReady
        beq     .notReady

            ; TODO: read controller input and update camera position (this must be finished before hint)
            addq.w  #1, cameraAngle

            bsr     HintWait

            ; Can update the VDP here in limited capacity (for example to update scores etc). But must completed before vint
            ; ...

    .notReady:

        bsr     VDPVSyncWait

        bra     .loop
        rts


HintWait:
    .wait:
        tst.b   hintHandled
        beq     .wait
        rts


HBlankInterrupt:
        SET_BACKGROUND_COLOR 9  ; do first to prevent change in active display (slightly more inefficient due to second entrance)

        tst.b   hintHandled
        beq     .notHandled

            rte

    .notHandled:
        st      hintHandled
        SET_HINT $ff

        DISABLE_DISPLAY

        ; DMA transfer current frame (part 2)
        DMA_ASIC_2_VRAM ASICTileData2, ASICTileData2Target, ASICTileDataTransferSize2

        ENABLE_DISPLAY

        ; Signal the sub cpu to start processing (render next frame and preprocess the frame after)
        move.w  subCommandCycle, M_RegSubComm0  ; Set current command cycle id
        move.w  cameraAngle, M_RegSubComm1      ; Player position
        move.w  #$02, M_RegSubMemCtrl           ; Give word ram to sub cpu (DMNA=1)
        move.b  #$01, M_RegSubCPUCtrl           ; Generate level 2 interrupt on the sub cpu (IFL2=1)

        rte


VBlankInterrupt:
        move.l  d0, -(sp)

        move.w  subCommandCycle, d0
        cmp.w   M_RegSubStat0, d0      ; Check if last command finished processing
        seq     frameReady
        sne     hintHandled
        bne     .frameSkip

            addq.w  #1, subCommandCycle

            SET_HINT $20

            DISABLE_DISPLAY

            SET_BACKGROUND_COLOR 7

            ; DMA transfer current frame (part 1)
            DMA_ASIC_2_VRAM ASICTileData1, ASICTileData1Target, ASICTileDataTransferSize1

            ; Wait until the end of the line to prevent artifacting
            moveq   #30, d0
            dbra    d0, *

            ENABLE_DISPLAY

            bra     .done
    .frameSkip:
        ; Skip next hint
        SET_HINT $ff
    .done:
        move.l  (sp)+, d0
        rte

    Even
    Include 'vdp_data.asm'
    Include 'asic_data.asm'

; --------------------------------------------------------------------------------------
; --------------------------------------------------------------------------------------
; --------------------------------------------------------------------------------------
; Sub CPU program

    Even

S_RegReset              Equ $ff8000
S_RegMemoryMode         Equ $ff8003 ; dont care about the write protect bits in upper byte from the sub cpu side
S_RegInterrupt          Equ $ff8032

S_RegCommMainFlag       Equ $ff800e
S_RegCommSubFlag        Equ $ff800f
S_RegMainComm0          Equ $ff8010
S_RegMainComm1          Equ $ff8012
S_RegSubStat0           Equ $ff8020


S_RegStampDataSize      Equ $ff8058
S_RegStampMapBaseAddr   Equ $ff805a

S_RegImgBufVCellSize    Equ $ff805c
S_RegImgBufStartAddr    Equ $ff805e
S_RegImgBufOffset       Equ $ff8060
S_RegImgBufHDotSize     Equ $ff8062
S_RegImgBufVDotSize     Equ $ff8064
S_RegTraceVecBaseAddr   Equ $ff8066

S_WordRAMBase           Equ $080000


SubCPUProgram:
    Obj 0

    ; 68000 Vector table
    dc.l    $20000                                                  ; Initial SP
    dc.l    Sub_Init                                                ; Initial PC
    dcb.l   23, Sub_Exception
    dc.l    Sub_RenderReady                                         ; IRQ level 1
    dc.l    Sub_MainRequest                                         ; IRQ level 2

    ; Variables
    angle:                  dc.w    0
    renderRequestId:        dc.w    0
    renderRequestPending:   dc.b    0


Sub_Exception:
        stop #$2700


; Int 1
Sub_RenderReady:
        ; Return word ram back to the main cpu
        move.b  #$01, (a6)
    .wordRAMRetWait:
        btst.b  #0, (a6)
        beq.s   .wordRAMRetWait  ; wait for RET = 1

        move.w  #$04, S_RegInterrupt  ; Disable level 1 interrupts and enable level 2 interrupts

        ; Signal frame ready
        move.w  renderRequestId, S_RegSubStat0
        rte


; Int 2
Sub_MainRequest:
        move.w  #$02, S_RegInterrupt  ; Disable level 2 interrupts and enable level 1 interrupt (this is reflected in bit 15 of M_RegSubCPUCtrl on the main cpu)

        ; Store render request and position
        move.w  S_RegMainComm0, renderRequestId
        move.w  S_RegMainComm1, angle

        st  renderRequestPending
        rte


; Reset
Sub_Init:
        ; a6 if permanently allocated to S_RegMemoryMode
        lea     S_RegMemoryMode, a6

        ; Set word ram in 2m mode and return access to the main cpu
        move.b  #$01, (a6)
    .wordRAMRetWait:
        btst.b  #0, (a6)
        beq.s   .wordRAMRetWait

        ; Calculate trace table for initial frame
        bsr     Sub_CalcTraceTable

        ; Configure image buffer
        move.w  #ImageBufferCellHeight - 1, S_RegImgBufVCellSize
        move.w  #ImageBufferOffset >> 2, S_RegImgBufStartAddr
        move.w  #0, S_RegImgBufOffset                               ; NB: Must be recalculated per render operation
        move.w  #ImageBufferDotWidth, S_RegImgBufHDotSize

        ; Configure ASIC interrupts
        move.w  #$04, S_RegInterrupt  ; Enable level 2 interrupts

        ; Indicate we are ready to accept commands from the main cpu
        move.b  #'R', S_RegCommSubFlag


Sub_Main:
            sf      renderRequestPending

    .loop:
            ; Wait for next command from the main cpu
            stop    #$2000
            tst.b   renderRequestPending
            beq.s   .loop

            sf      renderRequestPending

            ; First wait for word ram access
        .wordRAMWait:
            btst.b  #1, (a6)
            beq.s   .wordRAMWait ; wait for DMNA = 1

;            ; Wait for previous rendering cycle to finish
;        .renderWait:
;            move.w  S_RegStampDataSize, d0
;            btst    #15, d0
;            bne.s   .renderWait

            ; Copy trace table into word ram
            bsr     Sub_CopyTraceTable2WordRAM

            ; Render setup
            move.w  #ImageBufferDotHeight, S_RegImgBufVDotSize
            move.w  #$05, S_RegStampDataSize                    ; 16x16 dot stamps, 16x16 screens (repeat)
            move.w  #StampMap1Offset >> 2, S_RegStampMapBaseAddr

            ; Start rendering
            move.w  #TraceTableOffset >> 2, S_RegTraceVecBaseAddr

            ; Calculate the trace table for the next frame in parallel with rendering the current frame
            bsr     Sub_CalcTraceTable
        bra.s   .loop


Sub_CopyTraceTable2WordRAM:
        lea     TraceTable, a0
        lea     S_WordRAMBase + TraceTableOffset, a1

        moveq   #(ImageBufferDotHeight / 16) - 1, d0
    .copyTraceTableLoop:

        Rept 16
            move.l  (a0)+, (a1)+
            move.l  (a0)+, (a1)+
        Endr

        dbra    d0, .copyTraceTableLoop
        rts


; Just generate some test pattern based on angle received from main cpu...
Sub_CalcTraceTable:
        lea     TraceTable, a0
        lea     Sin, a1

        move.w   #ImageBufferDotHeight, d0   ; n lines to render

        moveq   #0, d1
        moveq   #0, d2
        move.w  angle, d1
        andi.w  #$ff, d1
        add.w   d1, d1
        move.w  (a1, d1), d2    ; d2 = sin
        ext.l   d2
        addi.w  #64 * 2, d1
        andi.w  #$1fe, d1
        move.w  (a1, d1), d1    ; d1 = cos
        ext.l   d1

        ; Zoomfactor derived from angle
        moveq   #11, d4
        move.l  d2, d3
        add.l   d3, d3
        add.l   d3, d3
        add.l   #4 << 11, d3
        muls    d3, d1
        asr.l   d4, d1
        muls    d3, d2
        asr.l   d4, d2

        ; Position in map (top left on screen)
        move.l   #(4096/2) << 11, d3  ; x
        move.l   d3, d4  ; y
    .traceLineLoop:

        move.l  d3, d5
        move.l  d4, d6
        asr.l   #8, d5
        asr.l   #8, d6

        move.w  d5, (a0)+   ; x start
        move.w  d6, (a0)+   ; y start
        move.w  d1, (a0)+   ; x delta
        move.w  d2, (a0)+   ; y delta

        add.l   d2, d3
        sub.l   d1, d4

        dbra    d0, .traceLineLoop
        rts

    Include 'sin.asm'

    Even

TraceTable: ; RAM copy of trace table for next frame

    ObjEnd
SubCPUProgramEnd:

RomImageEnd:
