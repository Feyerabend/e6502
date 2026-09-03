; =============================================================================
;  Nano BASIC  --  a minimal BASIC interpreter for the e6502 emulator
;  Released to the public domain (CC0 1.0)
;
;  This interpreter shows the core pipeline of a language runtime:
;      character stream -> tokenise -> parse -> evaluate -> execute
;
;  Supported features
;  ------------------
;    Statements  : PRINT  LET  INPUT  IF expr THEN lineno  GOTO  END  REM
;    Variables   : A-Z  (16-bit signed integers)
;    Expressions : constant, variable, +  -  *  /  (  )
;    Commands    : RUN  LIST  NEW
;    Line edit   : numbered lines, stored sorted; blank line number deletes it
;
;  I/O ports (e6502 emulator)
;  --------------------------
;    $F001  write  output one character
;    $F002  read   non-zero when an input character is waiting
;    $F003  read   read next character (clears "ready" flag)
;
;  Memory map
;  ----------
;    $0000-$00FF   zero page (ZP equates below)
;    $0100-$01FF   6502 hardware stack
;    $0200-$02FF   line input buffer  (INBUF)
;    $0300-$07FF   program storage  (~1.25 KB; ~50 lines)
;    $0800-$xxxx   interpreter code  (this file)
;    $FFFA-$FFFF   interrupt vectors
;
;  Program line record layout
;  --------------------------
;    byte 0   line number low
;    byte 1   line number high
;    byte 2   total record length (3 + text length; max 255)
;    byte 3+  ASCII text (no trailing NUL stored in memory)
; =============================================================================

IO_OUT    = $F001
IO_STAT   = $F002
IO_IN     = $F003
IO_BRK    = $F004     ; read: 0xFF if Ctrl-C/BREAK pending

; ---------- zero-page layout ----------
; temporaries
TMP       = $00     ; 1-byte scratch
TMP2      = $01     ; 1-byte scratch

; parse cursor  (points into INBUF or program text)
CPTR      = $02     ; 2 bytes ($02-$03)

; end-of-program pointer  (first free byte after last record)
PEND      = $04     ; 2 bytes ($04-$05)

; execution pointer  (start of the currently-executing line record)
EPTR      = $06     ; 2 bytes ($06-$07)

; flags
RUNNING   = $08     ; 0 = interactive, 1 = program executing
GOFLAG    = $09     ; 1 = GOTO just happened (skip normal advance in run_loop)

; expression evaluator value stack  (8 entries × 2 bytes)
ESTKP     = $0A     ; stack depth (0-7)
ESTACK    = $0B     ; 16 bytes ($0B-$1A)  -- entry k at ESTACK + k*2

; keyword buffer
KWBUF     = $1B     ; 7 bytes ($1B-$21)
KWLEN     = $22     ; 1 byte

; arithmetic scratch  ($23-$2C, 10 bytes)
AR        = $23     ; generic arithmetic pair  (AR/AR+1 = result of EVAL / PARSE_DEC)
                    ; $23-$24: result
                    ; $25-$26: aux pair 1
                    ; $27-$28: aux pair 2
                    ; $29-$2A: aux pair 3
                    ; $2B-$2C: aux pair 4

; variables A-Z  (26 × 2 bytes = 52 bytes)
VARS      = $40     ; $40-$73  (var X at VARS + (X-'A')*2)

; ZP scratch used by shift_right / shift_left  ($74-$77)
SP1       = $74     ; 2 bytes: source pointer
SP2       = $76     ; 2 bytes: dest pointer
PDEPTH    = $78     ; expression paren-nesting depth (overflow guard)

; ---------- other RAM ----------
INBUF     = $0200
PROG      = $0300

; =============================================================================
         .org $0800

; =============================================================================
;  Boot
; =============================================================================
RESET:
         cld
         ldx  #$FF
         txs                  ; init stack pointer

         ; zero the ZP variables we use
         lda  #0
         ldx  #0
zp0:     sta  $00,x
         inx
         cpx  #$78
         bne  zp0

         ; PEND = PROG  (empty program)
         lda  #<PROG
         sta  PEND
         lda  #>PROG
         sta  PEND+1

         ; print banner
         ldx  #0
bnr:     lda  s_banner,x
         beq  bnr_done
         jsr  PUTCH
         inx
         bne  bnr
bnr_done:

; =============================================================================
;  Main REPL
; =============================================================================
REPL:
         jsr  NEWLINE
         lda  #'>'
         jsr  PUTCH
         lda  #' '
         jsr  PUTCH
         jsr  READLINE        ; fills INBUF with NUL-terminated line

         lda  #<INBUF
         sta  CPTR
         lda  #>INBUF
         sta  CPTR+1
         jsr  SKIP_SPC
         jsr  PEEK
         beq  REPL            ; empty line

         ; digit -> numbered-line edit
         cmp  #'0'
         bcc  rp_stmt
         cmp  #'9'+1
         bcs  rp_stmt
         jsr  STORE_LINE
         jmp  REPL

rp_stmt:
         lda  #0
         sta  RUNNING
         jsr  EXEC_STMT
         jmp  REPL

; =============================================================================
;  EXEC_STMT  --  execute one statement at CPTR
;
;  Pattern for far dispatch:  jsr kw_xxx / bne skip / jmp cmd_xxx / skip:
; =============================================================================
EXEC_STMT:
         lda  #0
         sta  PDEPTH
         jsr  SKIP_SPC
         jsr  READ_KW

         ; --- direct commands ---
         jsr  kw_RUN
         bne  es1
         jmp  cmd_RUN
es1:
         jsr  kw_LIST
         bne  es2
         jmp  cmd_LIST
es2:
         jsr  kw_NEW
         bne  es3
         jmp  cmd_NEW
es3:
         ; --- statements ---
         jsr  kw_PRINT
         bne  es4
         jmp  cmd_PRINT
es4:
         jsr  kw_LET
         bne  es5
         jmp  cmd_LET_kw
es5:
         jsr  kw_INPUT
         bne  es6
         jmp  cmd_INPUT
es6:
         jsr  kw_IF
         bne  es7
         jmp  cmd_IF
es7:
         jsr  kw_GOTO
         bne  es8
         jmp  cmd_GOTO
es8:
         jsr  kw_END
         bne  es9
         jmp  cmd_END
es9:
         jsr  kw_REM
         bne  es10
         rts                  ; REM: ignore rest of line

es10:
         jsr  kw_MON
         bne  es11
         jmp  cmd_MON
es11:
         jsr  kw_HELP
         bne  es12
         jmp  cmd_HELP
es12:
         ; implicit LET: A = expr  (single-letter variable)
         lda  KWLEN
         cmp  #1
         bne  es_err
         lda  KWBUF
         cmp  #'A'
         bcc  es_err
         cmp  #'Z'+1
         bcs  es_err
         jmp  do_LET          ; A = variable letter

es_err:
         jsr  NEWLINE
         ldx  #0
er_lp:   lda  s_syntax,x
         beq  er_done
         jsr  PUTCH
         inx
         bne  er_lp
er_done:
         lda  #0
         sta  RUNNING
         rts

; =============================================================================
;  Commands
; =============================================================================

; ---- HELP ----
cmd_HELP:
         jsr  NEWLINE
         ldx  #0
ch_lp:   lda  s_help,x
         beq  ch_done
         jsr  PUTCH
         inx
         bne  ch_lp
ch_done: rts

; ---- MON ----
cmd_MON:
         lda  #0
         sta  RUNNING
         brk                  ; drop into monitor; 'g' resumes BASIC at REPL

; ---- END ----
cmd_END:
         lda  #0
         sta  RUNNING
         rts

; ---- NEW ----
cmd_NEW:
         lda  #<PROG
         sta  PEND
         lda  #>PROG
         sta  PEND+1
         rts

; ---- RUN ----
cmd_RUN:
         lda  IO_BRK          ; clear any stale Ctrl-C before running
         lda  #<PROG
         sta  EPTR
         lda  #>PROG
         sta  EPTR+1
         lda  #1
         sta  RUNNING

run_loop:
         ; quit if EPTR >= PEND
         jsr  past_end
         bcs  run_done

         lda  IO_BRK          ; Ctrl-C / BREAK ?
         bne  do_break

         lda  #0
         sta  GOFLAG

         ; CPTR = EPTR + 3  (skip header to text)
         lda  EPTR
         clc
         adc  #3
         sta  CPTR
         lda  EPTR+1
         adc  #0
         sta  CPTR+1

         jsr  EXEC_STMT

         lda  RUNNING
         beq  run_done

         ; GOTO sets GOFLAG=1 and updates EPTR already
         lda  GOFLAG
         bne  run_loop

         ; advance EPTR by record length
         ldy  #2
         lda  (EPTR),y
         clc
         adc  EPTR
         sta  EPTR
         lda  EPTR+1
         adc  #0
         sta  EPTR+1
         jmp  run_loop

do_break:
         jsr  NEWLINE
         ldx  #0
dbk_lp:  lda  s_break,x
         beq  dbk_num
         jsr  PUTCH
         inx
         bne  dbk_lp
dbk_num: ldy  #0
         lda  (EPTR),y
         sta  AR
         iny
         lda  (EPTR),y
         sta  AR+1
         jsr  PRINT_U16
         jsr  NEWLINE
run_done:
         lda  #0
         sta  RUNNING
         rts

; past_end: carry set if EPTR >= PEND
past_end:
         lda  EPTR+1
         cmp  PEND+1
         bne  pe_done
         lda  EPTR
         cmp  PEND            ; C=1 iff EPTR >= PEND
pe_done: rts

; ---- LIST ----
cmd_LIST:
         ; scan ptr in TMP/TMP2
         lda  #<PROG
         sta  TMP
         lda  #>PROG
         sta  TMP2

ls_loop:
         lda  TMP2
         cmp  PEND+1
         bne  ls_go
         lda  TMP
         cmp  PEND
         beq  ls_done

ls_go:
         ; print line number  (bytes 0-1 of record at TMP/TMP2)
         ldy  #0
         lda  (TMP),y
         sta  AR              ; save lo
         iny
         lda  (TMP),y
         sta  AR+1            ; save hi
         jsr  PRINT_U16       ; print AR/AR+1

         lda  #' '
         jsr  PUTCH

         ; print text  (bytes 3 .. reclen-1)
         ldy  #2
         lda  (TMP),y         ; record length
         sta  AR+2            ; use as end index
         ldy  #3
ls_ch:   cpy  AR+2
         beq  ls_eol
         lda  (TMP),y
         beq  ls_eol          ; stop at NUL terminator
         jsr  PUTCH
         iny
         jmp  ls_ch
ls_eol:  jsr  NEWLINE

         ; advance by record length
         ldy  #2
         lda  (TMP),y
         clc
         adc  TMP
         sta  TMP
         lda  TMP2
         adc  #0
         sta  TMP2
         jmp  ls_loop

ls_done: rts

; =============================================================================
;  Statements
; =============================================================================

; ---- PRINT ----
cmd_PRINT:
         jsr  SKIP_SPC
         jsr  PEEK
         beq  pr_nl

         cmp  #'"'
         beq  pr_str

         jsr  EVAL_EXPR
         jsr  PRINT_S16

pr_more: jsr  SKIP_SPC        ; check for ',' continuation
         jsr  PEEK
         cmp  #','
         bne  pr_nl
         jsr  GETCH
         lda  #' '
         jsr  PUTCH
         jmp  cmd_PRINT

pr_nl:   jsr  NEWLINE
         rts

pr_str:
         jsr  GETCH           ; consume '"'
prs_lp:  jsr  GETCH
         beq  pr_nl
         cmp  #'"'
         beq  pr_more         ; string done: allow ',' to chain more items
         jsr  PUTCH
         jmp  prs_lp

; ---- LET (explicit: keyword already consumed) ----
cmd_LET_kw:
         jsr  SKIP_SPC
         jsr  GET_VARLET      ; variable letter

; ---- LET core (A = variable letter) ----
do_LET:
         sta  TMP             ; save letter
         jsr  SKIP_SPC
         jsr  GETCH           ; consume '='
         jsr  SKIP_SPC
         jsr  EVAL_EXPR       ; result -> AR/AR+1
         lda  TMP
         sec
         sbc  #'A'
         asl  A
         tax
         lda  AR
         sta  VARS,x
         lda  AR+1
         sta  VARS+1,x
         rts

; ---- INPUT ----
cmd_INPUT:
         jsr  SKIP_SPC

         ; optional prompt string
         jsr  PEEK
         cmp  #'"'
         bne  inp_np
         jsr  GETCH           ; consume '"'
inp_str: jsr  GETCH
         beq  inp_np_done
         cmp  #'"'
         beq  inp_np_done
         jsr  PUTCH
         jmp  inp_str
inp_np_done:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #','
         bne  inp_np
         jsr  GETCH
inp_np:
         jsr  SKIP_SPC
         jsr  GET_VARLET      ; variable letter
         sta  TMP

         lda  #'?'
         jsr  PUTCH
         lda  #' '
         jsr  PUTCH

         ; save CPTR, use INBUF for number input
         lda  CPTR
         sta  AR+2
         lda  CPTR+1
         sta  AR+3
         jsr  READLINE
         lda  #<INBUF
         sta  CPTR
         lda  #>INBUF
         sta  CPTR+1
         jsr  SKIP_SPC
         jsr  PARSE_DEC       ; -> AR/AR+1
         ; restore CPTR
         lda  AR+2
         sta  CPTR
         lda  AR+3
         sta  CPTR+1

         lda  TMP
         sec
         sbc  #'A'
         asl  A
         tax
         lda  AR
         sta  VARS,x
         lda  AR+1
         sta  VARS+1,x
         rts

; ---- IF expr THEN lineno ----
cmd_IF:
         jsr  SKIP_SPC
         jsr  EVAL_EXPR       ; condition -> AR/AR+1
         jsr  SKIP_SPC
         jsr  READ_KW         ; consume "THEN"
         jsr  SKIP_SPC
         lda  AR
         ora  AR+1
         beq  cmd_IF_false    ; condition is 0: skip
         jsr  PARSE_DEC       ; line number -> AR/AR+1
         jmp  do_GOTO
cmd_IF_false:
         rts

; ---- GOTO ----
cmd_GOTO:
         jsr  SKIP_SPC
         jsr  PARSE_DEC       ; line number -> AR/AR+1

do_GOTO:
         jsr  FIND_LINE       ; carry=1: found, EPTR -> record
         bcs  gt_found
         ldx  #0
gt_err:  lda  s_noln,x
         beq  gt_done
         jsr  PUTCH
         inx
         bne  gt_err
gt_done: lda  #0
         sta  RUNNING
         rts
gt_found:
         lda  #1
         sta  GOFLAG
         rts

; =============================================================================
;  Line storage
; =============================================================================

; ---- STORE_LINE ----
;  Called when input starts with a digit.
;  Parses line number, stores/replaces/deletes the line.
STORE_LINE:
         jsr  PARSE_DEC       ; line number -> AR/AR+1

         ; save line number
         lda  AR
         sta  TMP
         lda  AR+1
         sta  TMP2

         jsr  SKIP_SPC
         jsr  FIND_LINE       ; carry=1: found, EPTR = record address

         bcs  sl_exists

; ---- insert new line ----
sl_ins:
         ; if blank input: nothing to do
         jsr  PEEK
         beq  sl_done

         ; measure text length at CPTR
         ldy  #0
sl_mlen: lda  (CPTR),y
         beq  sl_mlen_done
         iny
         bne  sl_mlen
sl_mlen_done:
         ; reject lines whose record length would overflow one byte
         cpy  #252
         bcs  sl_toobig
         ; Y = text length (without NUL); record = Y + 1 (NUL) + 3 (header)
         tya
         clc
         adc  #4
         sta  AR+2            ; new record length
         ; out-of-memory guard: PEND + reclen must not reach code at $0800
         lda  PEND
         clc
         adc  AR+2
         sta  TMP
         lda  PEND+1
         adc  #0
         cmp  #$08
         bcc  sl_fits
         bne  sl_toobig
         lda  TMP
         bne  sl_toobig       ; PEND + reclen > $0800
sl_fits:

         ; EPTR is the insert position (from FIND_LINE)
         ; shift [EPTR .. PEND) right by AR+2 bytes to make room
         jsr  shift_right

         ; write header (AR/AR+1 = line#; TMP/TMP2 clobbered by shift_right)
         ldy  #0
         lda  AR
         sta  (EPTR),y        ; line# lo
         iny
         lda  AR+1
         sta  (EPTR),y        ; line# hi
         iny
         lda  AR+2
         sta  (EPTR),y        ; record length

         ; copy text from CPTR into EPTR+3 .. EPTR+reclen-1
         ; use SP1 as write pointer = EPTR+3
         lda  EPTR
         clc
         adc  #3
         sta  SP1
         lda  EPTR+1
         adc  #0
         sta  SP1+1
         ; read from CPTR (offset 0)
         ldy  #0
sl_cpy:  lda  (CPTR),y
         sta  (SP1),y         ; copy char (including NUL terminator)
         beq  sl_done
         iny
         bne  sl_cpy          ; text < 252 bytes so Y won't wrap

sl_done: rts

sl_toobig:
         jsr  NEWLINE
         ldx  #0
stb_lp:  lda  s_toobig,x
         beq  stb_done
         jsr  PUTCH
         inx
         bne  stb_lp
stb_done:
         rts

; ---- existing line with same number ----
sl_exists:
         ; EPTR points at the existing record
         jsr  PEEK
         bne  sl_replace

         ; blank text: delete the line
         ldy  #2
         lda  (EPTR),y        ; old record length
         sta  AR+2
         jsr  shift_left      ; close the gap
         rts

sl_replace:
         ; measure new text length
         ldy  #0
sl_rl:   lda  (CPTR),y
         beq  sl_rl_done
         iny
         bne  sl_rl
sl_rl_done:
         tya
         clc
         adc  #4              ; +1 NUL +3 header
         sta  AR+2            ; new record length

         ; get old record length
         ldy  #2
         lda  (EPTR),y
         sta  AR+3            ; old record length

sl_repl_resize:
         ; delete old, then insert
         ; AR/AR+1 = line number; shift_left only clobbers TMP/TMP2/SP1/SP2
         lda  AR+3
         sta  AR+2
         jsr  shift_left
         ; AR/AR+1 still hold the line number; find new insert position
         jsr  FIND_LINE
         jmp  sl_ins          ; re-enter insert path

; ---- FIND_LINE ----
;  In : AR/AR+1 = target line number
;  Out: carry=1: found, EPTR = start of matching record
;       carry=0: not found, EPTR = insert-before position (or PEND)
FIND_LINE:
         lda  #<PROG
         sta  EPTR
         lda  #>PROG
         sta  EPTR+1

fl_lp:
         ; at end?
         lda  EPTR+1
         cmp  PEND+1
         bne  fl_cmp
         lda  EPTR
         cmp  PEND
         bcs  fl_no           ; >= PEND: not found

fl_cmp:
         ; compare record hi byte with target hi
         ldy  #1
         lda  (EPTR),y
         cmp  AR+1
         bcc  fl_adv          ; record.hi < target.hi: advance
         bne  fl_no           ; record.hi > target.hi: insert here
         ; hi bytes equal: compare lo
         ldy  #0
         lda  (EPTR),y
         cmp  AR              ; record.lo vs target.lo
         bcc  fl_adv
         bne  fl_no           ; record.lo > target: insert here
         ; equal: found
         sec
         rts

fl_adv:
         ldy  #2
         lda  (EPTR),y
         clc
         adc  EPTR
         sta  EPTR
         lda  EPTR+1
         adc  #0
         sta  EPTR+1
         jmp  fl_lp

fl_no:   clc
         rts

; ---- shift_right ----
;  Shift bytes [EPTR .. PEND) rightward by AR+2 bytes.
;  Updates PEND (increases by AR+2).
shift_right:
         ; count = PEND - EPTR  (bytes to move)
         lda  PEND
         sec
         sbc  EPTR
         sta  TMP
         lda  PEND+1
         sbc  EPTR+1
         sta  TMP2

         ; if count == 0, nothing to move
         lda  TMP
         ora  TMP2
         beq  sr_update_pend

         ; src = PEND - 1  (last byte)
         ; dst = PEND - 1 + AR+2
         ; copy backwards (high to low address)
         lda  PEND
         bne  sr_s_ok
         dec  PEND+1
sr_s_ok: dec  PEND           ; SP1 = PEND - 1  (before we update PEND)
         lda  PEND
         sta  SP1
         lda  PEND+1
         sta  SP1+1
         inc  PEND            ; restore PEND
         bne  sr_d_ok
         inc  PEND+1
sr_d_ok:

         ; compute dst = src + AR+2
         lda  SP1
         clc
         adc  AR+2
         sta  SP2
         lda  SP1+1
         adc  #0
         sta  SP2+1

         ; copy TMP/TMP2 bytes from SP1 down to EPTR, to SP2 down
sr_loop:
         ldy  #0
         lda  (SP1),y
         sta  (SP2),y
         ; dec SP1
         lda  SP1
         bne  sr_d1
         dec  SP1+1
sr_d1:   dec  SP1
         ; dec SP2
         lda  SP2
         bne  sr_d2
         dec  SP2+1
sr_d2:   dec  SP2
         ; dec count
         lda  TMP
         bne  sr_d3
         dec  TMP2
sr_d3:   dec  TMP
         lda  TMP
         ora  TMP2
         bne  sr_loop

sr_update_pend:
         lda  PEND
         clc
         adc  AR+2
         sta  PEND
         bcc  sr_done
         inc  PEND+1
sr_done: rts

; ---- shift_left ----
;  Shift bytes [EPTR+AR+2 .. PEND) leftward by AR+2 bytes.
;  Updates PEND (decreases by AR+2).
shift_left:
         ; src = EPTR + AR+2
         lda  EPTR
         clc
         adc  AR+2
         sta  SP1
         lda  EPTR+1
         adc  #0
         sta  SP1+1

         ; dst = EPTR
         lda  EPTR
         sta  SP2
         lda  EPTR+1
         sta  SP2+1

         ; count = PEND - src = PEND - (EPTR + AR+2)
         lda  PEND
         sec
         sbc  SP1
         sta  TMP
         lda  PEND+1
         sbc  SP1+1
         sta  TMP2

         lda  TMP
         ora  TMP2
         beq  sl_update_pend

sl_loop:
         ldy  #0
         lda  (SP1),y
         sta  (SP2),y
         ; inc SP1
         inc  SP1
         bne  sl_s1
         inc  SP1+1
sl_s1:
         ; inc SP2
         inc  SP2
         bne  sl_d1
         inc  SP2+1
sl_d1:
         ; dec count
         lda  TMP
         bne  sl_d2
         dec  TMP2
sl_d2:   dec  TMP
         lda  TMP
         ora  TMP2
         bne  sl_loop

sl_update_pend:
         lda  PEND
         sec
         sbc  AR+2
         sta  PEND
         bcs  shl_end
         dec  PEND+1
shl_end: rts

; =============================================================================
;  Expression evaluator  (recursive descent)
;  Result in AR/AR+1 (signed 16-bit)
; =============================================================================

; comparison layer  (< > = <> <= >=)  result: $FFFF=true, $0000=false
EVAL_EXPR:
         jsr  ev_additive
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'<'
         beq  evc_lt
         cmp  #'>'
         beq  evc_gt
         cmp  #'='
         bne  evc_exit
         ; '='
         jsr  GETCH
         jsr  ev_push
         jsr  ev_additive
         jsr  ev_pop
         lda  AR
         cmp  AR+2
         bne  evc_eq_f
         lda  AR+1
         cmp  AR+3
         bne  evc_eq_f
         lda  #$FF
         sta  AR
         sta  AR+1
evc_exit: rts
evc_eq_f:
         lda  #0
         sta  AR
         sta  AR+1
         rts

evc_lt:  jsr  GETCH
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'>'
         bne  evc_lt_notne
         jmp  evc_ne
evc_lt_notne:
         cmp  #'='
         bne  evc_lt_plain
         jmp  evc_le
evc_lt_plain:
         ; '<': left < right
         jsr  ev_push
         jsr  ev_additive
         jsr  ev_pop
         lda  AR+2
         sec
         sbc  AR
         lda  AR+3
         sbc  AR+1
         bcs  evc_lt_f
         lda  #$FF
         sta  AR
         sta  AR+1
         rts
evc_lt_f:
         lda  #0
         sta  AR
         sta  AR+1
         rts

evc_gt:  jsr  GETCH
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'='
         bne  evc_gt_plain
         jmp  evc_ge
evc_gt_plain:
         ; '>': left > right iff right < left
         jsr  ev_push
         jsr  ev_additive
         jsr  ev_pop
         lda  AR
         sec
         sbc  AR+2
         lda  AR+1
         sbc  AR+3
         bcs  evc_gt_f
         lda  #$FF
         sta  AR
         sta  AR+1
         rts
evc_gt_f:
         lda  #0
         sta  AR
         sta  AR+1
         rts

evc_le:  ; '<='  right >= left
         jsr  GETCH
         jsr  ev_push
         jsr  ev_additive
         jsr  ev_pop
         lda  AR
         sec
         sbc  AR+2
         lda  AR+1
         sbc  AR+3
         bcc  evc_le_f
         lda  #$FF
         sta  AR
         sta  AR+1
         rts
evc_le_f:
         lda  #0
         sta  AR
         sta  AR+1
         rts

evc_ge:  ; '>='  left >= right
         jsr  GETCH
         jsr  ev_push
         jsr  ev_additive
         jsr  ev_pop
         lda  AR+2
         sec
         sbc  AR
         lda  AR+3
         sbc  AR+1
         bcc  evc_ge_f
         lda  #$FF
         sta  AR
         sta  AR+1
         rts
evc_ge_f:
         lda  #0
         sta  AR
         sta  AR+1
         rts

evc_ne:  ; '<>'
         jsr  GETCH
         jsr  ev_push
         jsr  ev_additive
         jsr  ev_pop
         lda  AR
         cmp  AR+2
         bne  evc_ne_t
         lda  AR+1
         cmp  AR+3
         beq  evc_ne_f
evc_ne_t:
         lda  #$FF
         sta  AR
         sta  AR+1
         rts
evc_ne_f:
         lda  #0
         sta  AR
         sta  AR+1
         rts

; additive level  (+ -)
ev_additive:
         jsr  ev_term
ev_loop:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'+'
         beq  ev_add
         cmp  #'-'
         beq  ev_sub
         rts

ev_add:  jsr  GETCH
         jsr  ev_push
         jsr  ev_term
         jsr  ev_pop_add
         jmp  ev_loop

ev_sub:  jsr  GETCH
         jsr  ev_push
         jsr  ev_term
         jsr  ev_pop_sub
         jmp  ev_loop

ev_term:
         jsr  ev_unary
et_loop:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'*'
         beq  et_mul
         cmp  #'/'
         beq  et_div
         rts

et_mul:  jsr  GETCH
         jsr  ev_push
         jsr  ev_unary
         jsr  ev_pop_mul
         jmp  et_loop

et_div:  jsr  GETCH
         jsr  ev_push
         jsr  ev_unary
         jsr  ev_pop_div
         jmp  et_loop

ev_unary:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'-'
         bne  ev_primary
         jsr  GETCH
         jsr  ev_primary
         lda  #0
         sec
         sbc  AR
         sta  AR
         lda  #0
         sbc  AR+1
         sta  AR+1
         rts

ev_primary:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'('
         beq  evp_paren
         cmp  #'0'
         bcc  evp_var
         cmp  #'9'+1
         bcs  evp_var
         jmp  PARSE_DEC

evp_var:
         cmp  #'A'
         bcc  evp_zero
         cmp  #'Z'+1
         bcs  evp_zero
         jsr  GETCH
         sec
         sbc  #'A'
         asl  A
         tax
         lda  VARS,x
         sta  AR
         lda  VARS+1,x
         sta  AR+1
         rts

evp_zero:
         lda  #0
         sta  AR
         sta  AR+1
         rts

evp_paren:
         jsr  GETCH           ; consume '('
         inc  PDEPTH          ; bound nesting: protects CPU stack + value stack
         lda  PDEPTH
         cmp  #8
         bcs  evp_deep
         jsr  EVAL_EXPR
         dec  PDEPTH
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #')'
         bne  evp_done
         jsr  GETCH
evp_done: rts
evp_deep:
         dec  PDEPTH          ; too deep: discard rest of line, yield 0
         lda  #0
         sta  AR
         sta  AR+1
evd_skip:jsr  GETCH
         cmp  #0
         bne  evd_skip
         rts

; ---- eval stack ----

ev_push:
         lda  ESTKP
         asl  A
         tay
         lda  AR
         sta  ESTACK,y
         lda  AR+1
         sta  ESTACK+1,y
         inc  ESTKP
         rts

ev_pop:
         ; pops left operand into AR+2/AR+3
         dec  ESTKP
         lda  ESTKP
         asl  A
         tay
         lda  ESTACK,y
         sta  AR+2            ; left lo
         lda  ESTACK+1,y
         sta  AR+3            ; left hi
         rts

ev_pop_add:
         jsr  ev_pop          ; left -> AR+2/AR+3
         lda  AR+2
         clc
         adc  AR
         sta  AR
         lda  AR+3
         adc  AR+1
         sta  AR+1
         rts

ev_pop_sub:
         jsr  ev_pop          ; left in AR+2/AR+3
         lda  AR+2
         sec
         sbc  AR
         sta  AR
         lda  AR+3
         sbc  AR+1
         sta  AR+1
         rts

ev_pop_mul:
         ; left * right (16x16 -> 16 low bits)
         ; left in stack, right in AR/AR+1
         jsr  ev_pop          ; left -> AR+2/AR+3
         ; result in AR+4/AR+5 (accumulate there)
         lda  #0
         sta  AR+4
         sta  AR+5
         ldx  #16
evmul:
         lsr  AR+3
         ror  AR+2            ; right >>= 1, bit into carry
         bcc  evm_skip
         lda  AR+4
         clc
         adc  AR             ; AR = right; AR+2 = left (swapped vs typical)
         sta  AR+4
         lda  AR+5
         adc  AR+1
         sta  AR+5
evm_skip:
         asl  AR             ; left <<= 1
         rol  AR+1
         dex
         bne  evmul
         lda  AR+4
         sta  AR
         lda  AR+5
         sta  AR+1
         rts

; Note: in ev_pop_mul, AR holds right operand (it was the last EVAL result)
; and AR+2/AR+3 holds left (popped from stack).  We want left*right.
; The shift-and-add multiplies left by each bit of right, accumulating.
; left = AR+2/AR+3 (multiplicand, shift left each step)
; right = AR/AR+1 (multiplier, shift right each step)
; result = AR+4/AR+5

ev_pop_div:
         ; left / right  (signed)
         ; left in stack, right in AR/AR+1
         jsr  ev_pop          ; left -> AR+2/AR+3
         ; check for division by zero
         lda  AR
         ora  AR+1
         bne  evd_ok
         lda  #0
         sta  AR
         sta  AR+1
         rts
evd_ok:
         ; dividend (left) in AR+2/AR+3, divisor (right) in AR/AR+1
         ; result sign = sign(dividend) EOR sign(divisor); divide absolute values
         lda  AR+1
         eor  AR+3
         and  #$80
         pha                  ; save quotient sign
         lda  AR+1            ; abs(divisor)
         bpl  evd_dpos
         lda  #0
         sec
         sbc  AR
         sta  AR
         lda  #0
         sbc  AR+1
         sta  AR+1
evd_dpos:
         lda  AR+3            ; abs(dividend)
         bpl  evd_npos
         lda  #0
         sec
         sbc  AR+2
         sta  AR+2
         lda  #0
         sbc  AR+3
         sta  AR+3
evd_npos:
         lda  #0
         sta  AR+4
         sta  AR+5            ; quotient
         sta  SP1             ; remainder lo
         sta  SP1+1           ; remainder hi
         lda  AR
         sta  SP2             ; divisor lo
         lda  AR+1
         sta  SP2+1           ; divisor hi
         ldx  #16
evdiv:
         asl  AR+2
         rol  AR+3
         rol  SP1
         rol  SP1+1
         ; shift quotient left FIRST, then set bit 0 if remainder >= divisor
         asl  AR+4
         rol  AR+5
         lda  SP1
         sec
         sbc  SP2
         tay
         lda  SP1+1
         sbc  SP2+1
         bcc  evd_no          ; remainder < divisor: bit stays 0
         sty  SP1
         sta  SP1+1           ; commit subtraction
         inc  AR+4            ; set quotient bit 0
evd_no:
         dex
         bne  evdiv
         lda  AR+4
         sta  AR
         lda  AR+5
         sta  AR+1
         pla                  ; apply quotient sign
         bpl  evd_ret
         lda  #0
         sec
         sbc  AR
         sta  AR
         lda  #0
         sbc  AR+1
         sta  AR+1
evd_ret:
         rts

; =============================================================================
;  PARSE_DEC  --  parse unsigned decimal integer at CPTR
;  Result in AR/AR+1.
; =============================================================================
PARSE_DEC:
         lda  #0
         sta  AR
         sta  AR+1
pd_lp:
         jsr  PEEK
         cmp  #'0'
         bcc  pd_done
         cmp  #'9'+1
         bcs  pd_done
         jsr  GETCH
         sec
         sbc  #'0'            ; digit 0-9
         pha

         ; AR = AR * 10  using:  *10 = (*8) + (*2)
         ; save original AR in AR+2/AR+3
         lda  AR
         sta  AR+2
         lda  AR+1
         sta  AR+3
         ; compute *2
         asl  AR
         rol  AR+1
         ; save *2 in AR+4/AR+5
         lda  AR
         sta  AR+4
         lda  AR+1
         sta  AR+5
         ; compute *4 from *2
         asl  AR
         rol  AR+1
         ; compute *8 from *4
         asl  AR
         rol  AR+1
         ; AR = *8 + *2
         lda  AR
         clc
         adc  AR+4
         sta  AR
         lda  AR+1
         adc  AR+5
         sta  AR+1

         pla                  ; digit
         clc
         adc  AR
         sta  AR
         bcc  pd_nc
         inc  AR+1
pd_nc:   jmp  pd_lp
pd_done: rts

; =============================================================================
;  Number printing
; =============================================================================

; PRINT_U16: print AR/AR+1 as unsigned decimal
PRINT_U16:
         lda  AR
         sta  AR+2
         lda  AR+1
         sta  AR+3            ; working copy in AR+2/AR+3

         lda  #0
         pha                  ; sentinel

pu_loop:
         ; divide AR+2/AR+3 by 10 -> quotient in AR+2/AR+3, remainder -> A
         jsr  div10
         clc
         adc  #'0'
         pha
         lda  AR+2
         ora  AR+3
         bne  pu_loop

pu_print:
         pla
         beq  pu_done
         jsr  PUTCH
         jmp  pu_print
pu_done: rts

; PRINT_S16: print AR/AR+1 as signed decimal
PRINT_S16:
         lda  AR+1
         bpl  ps16_pos
         lda  #'-'
         jsr  PUTCH
         lda  #0
         sec
         sbc  AR
         sta  AR
         lda  #0
         sbc  AR+1
         sta  AR+1
ps16_pos:
         jmp  PRINT_U16

; div10: divide AR+2/AR+3 by 10
;  Out: AR+2/AR+3 = quotient, A = remainder
;  Uses: AR+4/AR+5 as remainder accumulator, AR+6/AR+7 as quotient build
div10:
         lda  #0
         sta  AR+4
         sta  AR+5            ; remainder = 0
         sta  AR+6
         sta  AR+7            ; quotient = 0
         ldx  #16
d10:
         ; shift dividend MSB into remainder
         asl  AR+2
         rol  AR+3
         rol  AR+4
         rol  AR+5
         ; if remainder >= 10: subtract, set quotient bit
         lda  AR+4
         sec
         sbc  #10
         tay
         lda  AR+5
         sbc  #0
         bcc  d10_no
         ; remainder >= 10
         sty  AR+4
         sta  AR+5
         sec                  ; quotient bit = 1
         jmp  d10_con
d10_no:  clc
d10_con:
         rol  AR+6
         rol  AR+7
         dex
         bne  d10
         lda  AR+6
         sta  AR+2
         lda  AR+7
         sta  AR+3
         lda  AR+4            ; remainder
         rts

; =============================================================================
;  I/O
; =============================================================================

PUTCH:
         sta  IO_OUT
         rts

NEWLINE:
         lda  #13
         jsr  PUTCH
         lda  #10
         jmp  PUTCH

; GETCH: read char at CPTR and advance (A=0 if at NUL, no advance)
GETCH:
         ldy  #0
         lda  (CPTR),y
         beq  gc_ret
         inc  CPTR
         bne  gc_ret
         inc  CPTR+1
gc_ret:  rts

; GET_VARLET: read a variable letter and force it upper-case, so lower-case
; input works everywhere (expression reads are upper-cased via READ_KW).
GET_VARLET:
         jsr  GETCH
         cmp  #'a'
         bcc  gvl_done
         cmp  #'z'+1
         bcs  gvl_done
         sec
         sbc  #32
gvl_done:
         rts

; PEEK: read char at CPTR without advancing
PEEK:
         ldy  #0
         lda  (CPTR),y
         rts

; SKIP_SPC: skip spaces and tabs at CPTR
SKIP_SPC:
         jsr  PEEK
         cmp  #' '
         beq  ss_adv
         cmp  #9
         bne  ss_done
ss_adv:  inc  CPTR
         bne  SKIP_SPC
         inc  CPTR+1
         jmp  SKIP_SPC
ss_done: rts

; READLINE: read console input into INBUF, NUL-terminated
READLINE:
         ldx  #0
         ldy  #0              ; Y != 0 while inside a "..." string literal
rl_lp:
         lda  IO_STAT
         beq  rl_lp           ; wait for char
         lda  IO_IN
         cmp  #13
         beq  rl_done
         cmp  #10
         beq  rl_done
         cmp  #8
         beq  rl_bs
         cmp  #127
         beq  rl_bs
         cmp  #'"'
         bne  rl_noq
         pha                  ; quote: flip the in-quote flag, keep char as-is
         tya
         eor  #1
         tay
         pla
         jmp  rl_put
rl_noq:
         cpy  #0
         bne  rl_put          ; inside quotes: preserve case
         cmp  #'a'
         bcc  rl_put
         cmp  #'z'+1
         bcs  rl_put
         sec
         sbc  #32             ; fold to upper-case outside quotes
rl_put:
         cpx  #255
         bcs  rl_lp           ; buffer full: drop char, keep reading until CR
         sta  INBUF,x
         inx
         jmp  rl_lp
rl_bs:
         cpx  #0
         beq  rl_lp
         dex
         jmp  rl_lp
rl_done:
         lda  #0
         sta  INBUF,x
         rts

; =============================================================================
;  Keyword reading
; =============================================================================

; READ_KW: read alphabetic run at CPTR -> KWBUF (uppercase), KWLEN
READ_KW:
         ldx  #0
rk_lp:
         jsr  PEEK
         beq  rk_done
         cmp  #'a'
         bcc  rk_uc
         cmp  #'z'+1
         bcs  rk_uc
         sec
         sbc  #32             ; to uppercase
rk_uc:
         cmp  #'A'
         bcc  rk_done
         cmp  #'Z'+1
         bcs  rk_done
         jsr  GETCH           ; consume (returns lowercase if lowercase)
         ; convert again in case GETCH returned original (which it does)
         cmp  #'a'
         bcc  rk_store
         cmp  #'z'+1
         bcs  rk_store
         sec
         sbc  #32
rk_store:
         sta  KWBUF,x
         inx
         cpx  #6
         bne  rk_lp
rk_done:
         lda  #0
         sta  KWBUF,x
         stx  KWLEN
         rts

; Keyword comparators
; Each returns Z=1 if KWBUF matches, Z=0 otherwise.

kw_RUN:
         lda  KWLEN
         cmp  #3
         bne  kw_ne
         lda  KWBUF+0
         cmp  #'R'
         bne  kw_ne
         lda  KWBUF+1
         cmp  #'U'
         bne  kw_ne
         lda  KWBUF+2
         cmp  #'N'
kw_ne:   rts

kw_LIST:
         lda  KWLEN
         cmp  #4
         bne  kl_ne
         lda  KWBUF+0
         cmp  #'L'
         bne  kl_ne
         lda  KWBUF+1
         cmp  #'I'
         bne  kl_ne
         lda  KWBUF+2
         cmp  #'S'
         bne  kl_ne
         lda  KWBUF+3
         cmp  #'T'
kl_ne:   rts

kw_NEW:
         lda  KWLEN
         cmp  #3
         bne  kn_ne
         lda  KWBUF+0
         cmp  #'N'
         bne  kn_ne
         lda  KWBUF+1
         cmp  #'E'
         bne  kn_ne
         lda  KWBUF+2
         cmp  #'W'
kn_ne:   rts

kw_PRINT:
         lda  KWLEN
         cmp  #5
         bne  kp_ne
         lda  KWBUF+0
         cmp  #'P'
         bne  kp_ne
         lda  KWBUF+1
         cmp  #'R'
         bne  kp_ne
         lda  KWBUF+2
         cmp  #'I'
         bne  kp_ne
         lda  KWBUF+3
         cmp  #'N'
         bne  kp_ne
         lda  KWBUF+4
         cmp  #'T'
kp_ne:   rts

kw_LET:
         lda  KWLEN
         cmp  #3
         bne  klt_ne
         lda  KWBUF+0
         cmp  #'L'
         bne  klt_ne
         lda  KWBUF+1
         cmp  #'E'
         bne  klt_ne
         lda  KWBUF+2
         cmp  #'T'
klt_ne:  rts

kw_INPUT:
         lda  KWLEN
         cmp  #5
         bne  ki_ne
         lda  KWBUF+0
         cmp  #'I'
         bne  ki_ne
         lda  KWBUF+1
         cmp  #'N'
         bne  ki_ne
         lda  KWBUF+2
         cmp  #'P'
         bne  ki_ne
         lda  KWBUF+3
         cmp  #'U'
         bne  ki_ne
         lda  KWBUF+4
         cmp  #'T'
ki_ne:   rts

kw_IF:
         lda  KWLEN
         cmp  #2
         bne  kif_ne
         lda  KWBUF+0
         cmp  #'I'
         bne  kif_ne
         lda  KWBUF+1
         cmp  #'F'
kif_ne:  rts

kw_GOTO:
         lda  KWLEN
         cmp  #4
         bne  kg_ne
         lda  KWBUF+0
         cmp  #'G'
         bne  kg_ne
         lda  KWBUF+1
         cmp  #'O'
         bne  kg_ne
         lda  KWBUF+2
         cmp  #'T'
         bne  kg_ne
         lda  KWBUF+3
         cmp  #'O'
kg_ne:   rts

kw_END:
         lda  KWLEN
         cmp  #3
         bne  ke_ne
         lda  KWBUF+0
         cmp  #'E'
         bne  ke_ne
         lda  KWBUF+1
         cmp  #'N'
         bne  ke_ne
         lda  KWBUF+2
         cmp  #'D'
ke_ne:   rts

kw_REM:
         lda  KWLEN
         cmp  #3
         bne  kr_ne
         lda  KWBUF+0
         cmp  #'R'
         bne  kr_ne
         lda  KWBUF+1
         cmp  #'E'
         bne  kr_ne
         lda  KWBUF+2
         cmp  #'M'
kr_ne:   rts

kw_MON:
         lda  KWLEN
         cmp  #3
         bne  km_ne
         lda  KWBUF+0
         cmp  #'M'
         bne  km_ne
         lda  KWBUF+1
         cmp  #'O'
         bne  km_ne
         lda  KWBUF+2
         cmp  #'N'
km_ne:   rts

kw_HELP:
         lda  KWLEN
         cmp  #4
         bne  kh_ne
         lda  KWBUF+0
         cmp  #'H'
         bne  kh_ne
         lda  KWBUF+1
         cmp  #'E'
         bne  kh_ne
         lda  KWBUF+2
         cmp  #'L'
         bne  kh_ne
         lda  KWBUF+3
         cmp  #'P'
kh_ne:   rts

; =============================================================================
;  String data
; =============================================================================
s_banner:
         .asc "Nano BASIC  (CC0 1.0)"
         .byte 13, 10, 0

s_syntax:
         .asc "?SYNTAX ERROR"
         .byte 13, 10, 0

s_noln:
         .asc "?LINE NOT FOUND"
         .byte 13, 10, 0

s_toobig:
         .asc "?PROGRAM TOO BIG"
         .byte 13, 10, 0

s_break:
         .asc "BREAK IN "
         .byte 0

s_help:
         .asc "Commands:"
         .byte 13, 10
         .asc "  LET v=expr   assign variable (A-Z)"
         .byte 13, 10
         .asc "  PRINT e,..   number or 'string'"
         .byte 13, 10
         .asc "  INPUT 'p',v  prompt and read var"
         .byte 13, 10
         .asc "  IF e THEN n  branch if nonzero"
         .byte 13, 10
         .asc "  GOTO n       jump to line n"
         .byte 13, 10
         .asc "  RUN LIST NEW END REM MON"
         .byte 13, 10, 0

; =============================================================================
;  Vectors
; =============================================================================
         .org $FFFA
         .word RESET          ; NMI
         .word RESET          ; RESET
         .word RESET          ; IRQ/BRK
