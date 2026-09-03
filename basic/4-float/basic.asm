; =============================================================================
;  Float BASIC  --  tier 4: decimal floating-point numbers
;  Released to the public domain (CC0 1.0)
;
;  Forked from tier 3 (MS-style).  Numbers are decimal floats: value = sign *
;  M * 10^E with a 7-digit mantissa (see the "Floating point" section).  Decimal
;  (not binary) so 0.1 + 0.2 = 0.3 exactly and I/O is exact for shown digits.
;
;  Everything is float-wired: numeric literals (incl. 3.14 / 1E3 / .5), + - * /,
;  unary minus, parentheses, scalar variables A-Z, arrays (5-byte packed float
;  elements), PRINT, comparisons (< > = <> <= >=), IF, GOTO/GOSUB, ON..GOTO,
;  FOR/NEXT (float limit/step), INPUT, READ/DATA/RESTORE, the numeric functions
;  LEN/ASC/VAL/ABS/SGN/RND, STR$ (via PRINT_FAC into the string buffer), and the
;  logical operators AND/OR/NOT (operands truncated to signed integers, then
;  bitwise-combined and returned as a float).  Bridges: INT_TO_FAC / SINT_TO_FAC
;  (int -> FAC) and FAC_TO_INT (FAC -> signed int, truncating toward zero).
;
;  Transcendentals (SIN/COS/...) remain deferred to a later tier.
;
;  Supported features
;  ------------------
;    Statements  : PRINT (',' or ';')  LET  INPUT  GOTO  END  REM  DIM
;                  IF expr THEN (lineno | statement)
;                  FOR v=a TO b [STEP s] ... NEXT [v]
;                  GOSUB lineno ... RETURN
;                  DATA n,..   READ v,..   RESTORE
;                  ON expr GOTO n,..   ON expr GOSUB n,..
;    Multiple statements per line, separated by ':'
;    Variables   : A-Z scalars, A-Z arrays, A$-Z$ strings (<=63 chars)
;    Numeric fns : ABS SGN RND LEN ASC VAL
;    String fns  : CHR$ STR$ LEFT$ RIGHT$ MID$   concatenation with '+'
;    Expressions : constant, variable, array elem, +  -  *  /  (  )
;                  comparisons < > = <> <= >=   logic AND OR NOT (bitwise)
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
PFDEST    = $2D     ; PRINT_FAC output sink: 0 = console (PUTCH), $80 = STRWRK (STR$)

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
VARS      = $6A00   ; 26 float scalars, 5-byte slots (var at VARS+(X-'A')*5)

; ZP scratch used by shift_right / shift_left  ($74-$77)
SP1       = $74     ; 2 bytes: source pointer
SP2       = $76     ; 2 bytes: dest pointer

; ---- Integer BASIC additions ----
GSTKO     = $78     ; GOSUB stack byte-offset (top); frame = 4 bytes
FSTKO     = $79     ; FOR stack byte-offset (top);  frame = 9 bytes
ENDFLG    = $7A     ; 1 = END/STOP/error hit; abort statement chain
RESUMF    = $7B     ; 1 = run_loop should resume at CPTR (not EPTR+3)
AHP       = $7C     ; 2 bytes: array heap allocation pointer (next free)
APTR      = $7E     ; 2 bytes: scratch pointer (array element / kw peek save)
ASTP      = $80     ; 2 bytes: array store pointer (survives RHS evaluation)

; ---- MS BASIC additions ----
SPTR      = $82     ; 2 bytes: string slot / source pointer
SLEN      = $84     ; length of the string being built in STRWRK
CNT       = $85     ; byte counter for string copies
DPTR      = $86     ; 2 bytes: DATA read pointer (record + offset via EPTR-style)
DOFF      = $88     ; DATA offset within the current record
ARGLEN    = $89     ; length of a string-function argument (from STR_SRC)
RSEED     = $8A     ; 2 bytes: RND seed (LCG state)
DIVSOR    = $8C     ; 2 bytes: divisor for UMOD16 (used by RND)
DREC      = $8E     ; 2 bytes: current DATA line record address
PDEPTH    = $90     ; expression paren-nesting depth (overflow guard)

; ---- Floating point: decimal float  value = sign * M * 10^E ----
; FAC / ARG are the working accumulators.  Mantissa M is 48-bit little-endian
; (6 bytes) during arithmetic; a normalized number keeps M in [10^6, 10^7).
FSGN      = $91     ; FAC sign: 0 = +, $FF = -
FEXP      = $92     ; FAC decimal exponent (signed byte)
FM        = $93     ; FAC mantissa, 6 bytes ($93-$98)
ASGN      = $99     ; ARG sign
AEXP      = $9A     ; ARG decimal exponent
AM        = $9B     ; ARG mantissa, 6 bytes ($9B-$A0)
MTMP      = $A1     ; scratch mantissa, 6 bytes ($A1-$A6)
MTMP2     = $A7     ; scratch mantissa, 6 bytes ($A7-$AC)
DCNT      = $AD     ; loop / digit counter
FTMP      = $AE     ; misc scratch ($AE-$AF)

; ---------- other RAM ----------
INBUF     = $0200
PROG      = $0300

; ---- Integer BASIC runtime storage (zero-filled RAM above the code) ----
GSTK      = $4000   ; GOSUB return stack: frame = EPTRlo,EPTRhi,CPTRlo,CPTRhi
FSTK      = $4100   ; FOR loop stack: varoff, limitlo,hi, steplo,hi,
                    ;                 EPTRlo,hi, CPTRlo,hi   (9 bytes)
ARRD      = $4200   ; array descriptors: 26 * (baselo,hi, sizelo,hi) = 104 bytes
AHEAP     = $4400   ; array element storage, grows upward

; ---- MS BASIC string storage ----
STRVARS   = $6000   ; 26 string vars, 64-byte slots: [len][up to 63 chars]
STRWRK    = $6800   ; 256-byte work buffer: the string accumulator

; ---- float value stack: 8 entries x 5 packed bytes (ESTKP = depth) ----
FSTACK    = $6B00

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
         cpx  #$80
         bne  zp0

         jsr  CLR_RT           ; init control stacks + array heap

         lda  #$A5             ; seed the RND generator (deterministic)
         sta  RSEED
         lda  #$3C
         sta  RSEED+1

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
;  EXEC_STMT  --  execute a line: one or more ':'-separated statements
;
;  STMT_ONE dispatches a single statement.  We loop while a ':' follows, unless
;  a control transfer (GOFLAG) or END/error (ENDFLG) asks us to stop.
;
;  Pattern for far dispatch:  jsr kw_xxx / bne skip / jmp cmd_xxx / skip:
; =============================================================================
EXEC_STMT:
         lda  #0
         sta  ENDFLG
exs_loop:
         jsr  STMT_ONE
         lda  ENDFLG
         bne  exs_ret
         lda  GOFLAG
         bne  exs_ret
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #':'
         bne  exs_ret
         jsr  GETCH           ; consume ':'
         jmp  exs_loop
exs_ret: rts

; ---- STMT_ONE: execute a single statement at CPTR ----
STMT_ONE:
         lda  #0
         sta  PDEPTH
         jsr  SKIP_SPC
         jsr  PEEK
         bne  so_go
         rts                  ; empty statement (end of line) -> no-op
so_go:
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
         bne  esG
do_REM:  jsr  GETCH           ; REM: swallow rest of line (incl. ':')
         cmp  #0
         bne  do_REM
         rts

esG:
         jsr  kw_GOSUB
         bne  esR
         jmp  cmd_GOSUB
esR:
         jsr  kw_RETURN
         bne  esF
         jmp  cmd_RETURN
esF:
         jsr  kw_FOR
         bne  esN
         jmp  cmd_FOR
esN:
         jsr  kw_NEXT
         bne  esD
         jmp  cmd_NEXT
esD:
         jsr  kw_DIM
         bne  esDA
         jmp  cmd_DIM
esDA:
         jsr  kw_DATA
         bne  esRD
         jmp  cmd_DATA
esRD:
         jsr  kw_READ
         bne  esRS
         jmp  cmd_READ
esRS:
         jsr  kw_RESTORE
         bne  esON
         jmp  cmd_RESTORE
esON:
         jsr  kw_ON
         bne  es10
         jmp  cmd_ON

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

; ---- es_err / es_sub: report an error and hard-abort back to the prompt.
;  Errors can fire deep inside expression evaluation, so we reset the CPU stack
;  to unwind any half-finished frames (otherwise the interpreter would return
;  through them and print garbage) and re-enter the REPL from the top.
es_err:
         ldx  #$FF
         txs                  ; unwind: discard any mid-expression call frames
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
         sta  GOFLAG
         sta  RESUMF
         lda  #1
         sta  ENDFLG          ; abort the rest of the statement chain
         jmp  REPL            ; stack is reset; return cleanly to the prompt

; ---- es_sub: ?BAD SUBSCRIPT (array index out of range) ----
es_sub:  ldx  #$FF
         txs
         jsr  NEWLINE
         ldx  #0
esub_lp: lda  s_subscr,x
         beq  er_done
         jsr  PUTCH
         inx
         bne  esub_lp

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
         lda  #1
         sta  ENDFLG
         rts

; ---- NEW ----
cmd_NEW:
         lda  #<PROG
         sta  PEND
         lda  #>PROG
         sta  PEND+1
         jmp  CLR_RT          ; also clear arrays / control stacks

; ---- CLR_RT: reset control stacks and array heap ----
CLR_RT:
         lda  #0
         sta  GSTKO
         sta  FSTKO
         sta  DPTR            ; DATA pointer not yet positioned
         sta  DPTR+1
         lda  #<AHEAP
         sta  AHP
         lda  #>AHEAP
         sta  AHP+1
         ldx  #0
         lda  #0
clr_ad:  sta  ARRD,x          ; clear 26 array descriptors (104 bytes)
         inx
         cpx  #104
         bne  clr_ad
         ; zero the array heap + string storage window ($4400..$6DFF = 40 pages)
         lda  #<AHEAP
         sta  APTR
         lda  #>AHEAP
         sta  APTR+1
         ldx  #40
         ldy  #0
         lda  #0
clr_hp:  sta  (APTR),y
         iny
         bne  clr_hp
         inc  APTR+1
         dex
         bne  clr_hp
         rts

; ---- RUN ----
cmd_RUN:
         lda  IO_BRK           ; clear any stale Ctrl-C before running
         jsr  CLR_RT           ; fresh control stacks + arrays for this run
         lda  #0
         sta  RESUMF
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

         ; RETURN / NEXT resume mid-line: keep CPTR, skip the header reset
         lda  RESUMF
         beq  rl_reset
         lda  #0
         sta  RESUMF
         jmp  rl_exec
rl_reset:
         ; CPTR = EPTR + 3  (skip header to text)
         lda  EPTR
         clc
         adc  #3
         sta  CPTR
         lda  EPTR+1
         adc  #0
         sta  CPTR+1
rl_exec:
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
;  Items are string- or numeric-valued; separators are ',' (space) or ';'
;  (nothing).  A trailing separator suppresses the closing newline.
cmd_PRINT:
pr_item: jsr  SKIP_SPC
         jsr  PEEK
         beq  pr_nl           ; nothing left -> newline
         cmp  #':'
         beq  pr_nl
         jsr  IS_STR
         bcc  pr_pnum
         jsr  EVAL_STR        ; -> STRWRK / SLEN
         jsr  PRINT_STR
         jmp  pr_after
pr_pnum: jsr  EVAL_EXPR
         jsr  PRINT_FAC
pr_after:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #','
         beq  pr_c
         cmp  #$3B            ; ';'  (char literal ';' would start a comment)
         beq  pr_s
         jmp  pr_nl           ; no separator -> end this PRINT with newline
pr_c:    jsr  GETCH
         lda  #' '
         jsr  PUTCH
         jmp  pr_tail
pr_s:    jsr  GETCH
pr_tail: jsr  SKIP_SPC        ; trailing separator (end/':' next) -> no newline
         jsr  PEEK
         beq  pr_ret
         cmp  #':'
         beq  pr_ret
         jmp  pr_item
pr_nl:   jsr  NEWLINE
pr_ret:  rts

; PRINT_STR: output STRWRK[0..SLEN-1]
PRINT_STR:
         ldy  #0
ps_lp:   cpy  SLEN
         beq  ps_done
         lda  STRWRK,y
         jsr  PUTCH
         iny
         bne  ps_lp
ps_done: rts

; ---- LET (explicit: keyword already consumed) ----
cmd_LET_kw:
         jsr  SKIP_SPC
         jsr  GET_VARLET      ; variable letter

; ---- LET core (A = variable letter) ----
do_LET:
         sta  TMP             ; save letter
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'$'
         beq  do_LET_str
         cmp  #'('
         beq  do_LET_arr
         jsr  GETCH           ; consume '='
         jsr  SKIP_SPC
         jsr  EVAL_EXPR       ; result -> FAC
         lda  TMP
         jsr  VOFF
         jmp  VSTORE

do_LET_arr:
         lda  TMP             ; array letter -> A for ARR_ADDR
         jsr  ARR_ADDR        ; element address -> APTR (consumes '(' idx ')')
         lda  APTR
         sta  ASTP            ; preserve across RHS evaluation
         lda  APTR+1
         sta  ASTP+1
         jsr  SKIP_SPC
         jsr  GETCH           ; consume '='
         jsr  SKIP_SPC
         jsr  EVAL_EXPR       ; RHS -> FAC
         ldy  #0
         lda  FSGN            ; store packed float (sign, exp, M0, M1, M2)
         sta  (ASTP),y
         iny
         lda  FEXP
         sta  (ASTP),y
         iny
         lda  FM
         sta  (ASTP),y
         iny
         lda  FM+1
         sta  (ASTP),y
         iny
         lda  FM+2
         sta  (ASTP),y
         rts

do_LET_str:
         jsr  GETCH           ; consume '$'
         jsr  SKIP_SPC
         jsr  GETCH           ; consume '='
         jsr  EVAL_STR        ; result -> STRWRK / SLEN
         lda  TMP             ; target letter
         jmp  STR_STORE

; ---- DATA: at runtime just skip the rest of the line ----
cmd_DATA:
cda_lp:  jsr  GETCH
         cmp  #0
         bne  cda_lp
         rts

; ---- RESTORE: rewind the DATA pointer ----
cmd_RESTORE:
         lda  #0
         sta  DPTR
         sta  DPTR+1
         rts

; ---- READ var[,var] ...  (numeric variables) ----
cmd_READ:
crd_var: jsr  SKIP_SPC
         jsr  GET_VARLET      ; variable letter
         sta  TMP
         jsr  DATA_VAL        ; next DATA value -> FAC
         lda  ENDFLG          ; OUT OF DATA aborts
         bne  crd_done
         lda  TMP
         jsr  VOFF            ; X = slot offset
         jsr  VSTORE          ; target var <- FAC
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #','
         bne  crd_done
         jsr  GETCH
         jmp  crd_var
crd_done:
         rts

; DATA_VAL: fetch the next DATA value into AR (advances DPTR/DREC).
DATA_VAL:
         lda  CPTR            ; save the main parse cursor
         sta  ASTP
         lda  CPTR+1
         sta  ASTP+1
         lda  DPTR
         ora  DPTR+1
         bne  dv_have
         jsr  DATA_FIND       ; first READ: locate first DATA line
         lda  ENDFLG
         bne  dv_ret          ; out of data
dv_have: lda  DPTR
         sta  CPTR
         lda  DPTR+1
         sta  CPTR+1
dv_scan: jsr  SKIP_SPC
         jsr  PEEK
         beq  dv_endln
         cmp  #':'
         beq  dv_endln
         cmp  #'-'
         bne  dv_pos
         jsr  GETCH
         jsr  PARSE_FLOAT     ; -> FAC
         jsr  FAC_NEG
         jmp  dv_after
dv_pos:  jsr  PARSE_FLOAT     ; -> FAC
dv_after:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #','
         bne  dv_setp
         jsr  GETCH
dv_setp: lda  CPTR
         sta  DPTR
         lda  CPTR+1
         sta  DPTR+1
dv_ret:  lda  ASTP            ; restore the main parse cursor
         sta  CPTR
         lda  ASTP+1
         sta  CPTR+1
         rts
dv_endln:
         jsr  DATA_NEXTLN     ; move to next DATA line
         lda  ENDFLG
         bne  dv_ret
         lda  DPTR
         sta  CPTR
         lda  DPTR+1
         sta  CPTR+1
         jmp  dv_scan

; DATA_FIND: DREC = PROG, then scan for a DATA line.
DATA_FIND:
         lda  #<PROG
         sta  DREC
         lda  #>PROG
         sta  DREC+1
         jmp  DATA_SCAN

; DATA_NEXTLN: advance DREC past its record, then scan for the next DATA line.
DATA_NEXTLN:
         ldy  #2
         lda  (DREC),y
         clc
         adc  DREC
         sta  DREC
         lda  DREC+1
         adc  #0
         sta  DREC+1
         ; fall through

; DATA_SCAN: from DREC, find the next DATA line; set DPTR after its keyword.
DATA_SCAN:
         lda  DREC+1
         cmp  PEND+1
         bcc  dsc_ok
         bne  dsc_ooo
         lda  DREC
         cmp  PEND
         bcs  dsc_ooo
dsc_ok:  lda  DREC            ; CPTR = DREC + 3 (line text)
         clc
         adc  #3
         sta  CPTR
         lda  DREC+1
         adc  #0
         sta  CPTR+1
         jsr  SKIP_SPC
         jsr  READ_KW
         jsr  kw_DATA
         beq  dsc_found
         ldy  #2              ; not DATA: skip to next record
         lda  (DREC),y
         clc
         adc  DREC
         sta  DREC
         lda  DREC+1
         adc  #0
         sta  DREC+1
         jmp  DATA_SCAN
dsc_found:
         lda  CPTR
         sta  DPTR
         lda  CPTR+1
         sta  DPTR+1
         rts
dsc_ooo:
         jsr  NEWLINE
         ldx  #0
ooo_lp:  lda  s_ooo,x
         beq  ooo_done
         jsr  PUTCH
         inx
         bne  ooo_lp
ooo_done:
         lda  #0
         sta  RUNNING
         lda  #1
         sta  ENDFLG
         rts

; ---- ON expr GOTO|GOSUB n1, n2, ... ----
cmd_ON:
         jsr  SKIP_SPC
         jsr  EVAL_EXPR       ; selector -> FAC
         jsr  FAC_TO_INT      ; -> AR
         jsr  SKIP_SPC
         jsr  READ_KW         ; GOTO or GOSUB
         jsr  kw_GOTO
         beq  on_goto
         jsr  kw_GOSUB
         beq  on_gosub
         jmp  es_err
on_goto:
         lda  AR+1
         bmi  onn
         lda  AR
         ora  AR+1
         beq  onn
         ldx  AR              ; 1-based selector as countdown
ong_lp:  jsr  SKIP_SPC
         jsr  PARSE_DEC       ; a line number -> AR
         dex
         beq  on_goto_hit
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #','
         bne  onn
         jsr  GETCH
         jmp  ong_lp
on_goto_hit:
         jmp  do_GOTO
onn:     jmp  on_none         ; trampoline (keeps branches in range)
on_gosub:
         lda  AR+1
         bmi  onn
         lda  AR
         ora  AR+1
         beq  onn
         ldx  AR
ons_lp:  jsr  SKIP_SPC
         jsr  PARSE_DEC
         dex
         beq  on_gosub_hit
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #','
         bne  onn
         jsr  GETCH
         jmp  ons_lp
on_gosub_hit:
         lda  AR
         pha
         lda  AR+1
         pha
ons_skip:
         jsr  GETCH           ; resume point = end of the ON line
         cmp  #0
         bne  ons_skip
         ldx  GSTKO
         cpx  #240
         bcs  ons_over
         lda  EPTR
         sta  GSTK,x
         lda  EPTR+1
         sta  GSTK+1,x
         lda  CPTR
         sta  GSTK+2,x
         lda  CPTR+1
         sta  GSTK+3,x
         lda  GSTKO
         clc
         adc  #4
         sta  GSTKO
         pla
         sta  AR+1
         pla
         sta  AR
         jmp  do_GOTO
ons_over:
         pla
         pla
         jmp  es_err
on_none:
         jsr  GETCH           ; selector out of range: skip rest of line
         cmp  #0
         bne  on_none
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
         jsr  PEEK            ; optional leading '-'
         cmp  #'-'
         bne  inp_pos
         jsr  GETCH
         jsr  PARSE_FLOAT     ; -> FAC
         jsr  FAC_NEG
         jmp  inp_store
inp_pos: jsr  PARSE_FLOAT     ; -> FAC
inp_store:
         ; restore CPTR
         lda  AR+2
         sta  CPTR
         lda  AR+3
         sta  CPTR+1

         lda  TMP
         jsr  VOFF            ; X = slot offset
         jmp  VSTORE          ; loop/target var <- FAC

; ---- IF expr THEN lineno | statement ----
cmd_IF:
         jsr  SKIP_SPC
         jsr  EVAL_EXPR       ; condition -> AR/AR+1
         jsr  SKIP_SPC
         jsr  READ_KW         ; consume "THEN"
         jsr  SKIP_SPC
         jsr  FM_ISZERO       ; condition is FAC; zero = false
         beq  cmd_IF_false    ; condition false: skip the rest of the line
         ; true: a line number means GOTO, otherwise run the rest as statements
         jsr  PEEK
         cmp  #'0'
         bcc  if_stmt
         cmp  #'9'+1
         bcs  if_stmt
         jsr  PARSE_DEC       ; line number -> AR/AR+1
         jmp  do_GOTO
if_stmt:
         jmp  EXEC_STMT       ; execute remaining statements on this line
cmd_IF_false:
         jsr  GETCH           ; consume rest of line (whole THEN part is skipped)
         cmp  #0
         bne  cmd_IF_false
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

; SKIP_COLON: skip spaces, then consume one ':' if present.
; Used to position a saved resume point at the statement after ':'.
SKIP_COLON:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #':'
         bne  sc_done
         jsr  GETCH
sc_done: rts

; ---- GOSUB ----
cmd_GOSUB:
         jsr  SKIP_SPC
         jsr  PARSE_DEC       ; target line -> AR
         jsr  SKIP_COLON      ; resume point = statement after this GOSUB
         ; push return frame (EPTR, CPTR) at GSTK[GSTKO]
         ldx  GSTKO
         cpx  #240            ; overflow guard (60 frames)
         bcs  gs_over
         lda  EPTR
         sta  GSTK,x
         lda  EPTR+1
         sta  GSTK+1,x
         lda  CPTR
         sta  GSTK+2,x
         lda  CPTR+1
         sta  GSTK+3,x
         lda  GSTKO
         clc
         adc  #4
         sta  GSTKO
         jmp  do_GOTO         ; jump to subroutine (sets EPTR, GOFLAG)
gs_over: jmp  es_err          ; too many nested GOSUBs

; ---- RETURN ----
cmd_RETURN:
         lda  GSTKO
         bne  rt_ok
         rts                  ; RETURN without GOSUB: ignore
rt_ok:
         sec
         sbc  #4
         sta  GSTKO
         tax
         lda  GSTK,x
         sta  EPTR
         lda  GSTK+1,x
         sta  EPTR+1
         lda  GSTK+2,x
         sta  CPTR
         lda  GSTK+3,x
         sta  CPTR+1
         lda  #1
         sta  RESUMF          ; resume mid-line at restored CPTR
         sta  GOFLAG
         rts

; ---- FOR var = start TO limit [STEP step] ----
;  Frame (15 bytes) at FSTK[FSTKO]:
;    +0     varoff (VARS slot offset = (letter-'A')*5)
;    +1..+5 limit (packed float: sign, exp, M0, M1, M2)
;    +6..+10 step (packed float)
;    +11/+12 resume EPTR   +13/+14 resume CPTR
cmd_FOR:
         lda  FSTKO
         cmp  #241            ; overflow guard (17 frames of 15 bytes)
         bcc  for_ok
         jmp  es_err
for_ok:
         jsr  SKIP_SPC
         jsr  GET_VARLET      ; loop variable letter
         jsr  VOFF            ; X = varoff = (letter-'A')*5
         txa
         ldx  FSTKO
         sta  FSTK+0,x        ; stash varoff in the (uncommitted) frame
         jsr  SKIP_SPC
         jsr  GETCH           ; '='
         jsr  EVAL_EXPR       ; start value -> FAC
         ldx  FSTKO
         lda  FSTK+0,x
         tax                  ; X = varoff
         jsr  VSTORE          ; loop var <- start
         jsr  SKIP_SPC
         jsr  READ_KW         ; consume "TO"
         jsr  EVAL_EXPR       ; limit -> FAC
         ldx  FSTKO
         lda  FSGN
         sta  FSTK+1,x
         lda  FEXP
         sta  FSTK+2,x
         lda  FM
         sta  FSTK+3,x
         lda  FM+1
         sta  FSTK+4,x
         lda  FM+2
         sta  FSTK+5,x
         ; optional STEP
         jsr  SKIP_SPC
         lda  CPTR
         sta  APTR
         lda  CPTR+1
         sta  APTR+1          ; save cursor to un-read a non-STEP word
         jsr  READ_KW
         jsr  kw_STEP
         beq  for_step
         lda  APTR            ; no STEP: restore cursor, step = 1
         sta  CPTR
         lda  APTR+1
         sta  CPTR+1
         lda  #1
         sta  AR
         lda  #0
         sta  AR+1
         jsr  INT_TO_FAC      ; FAC = 1
         jmp  for_setstep
for_step:
         jsr  EVAL_EXPR       ; step -> FAC
for_setstep:
         ldx  FSTKO
         lda  FSGN
         sta  FSTK+6,x
         lda  FEXP
         sta  FSTK+7,x
         lda  FM
         sta  FSTK+8,x
         lda  FM+1
         sta  FSTK+9,x
         lda  FM+2
         sta  FSTK+10,x
for_resume:
         ; NEXT resumes at the statement after FOR (past an optional ':'),
         ; but the live cursor must stay so the inline chain runs the body now.
         lda  CPTR
         sta  APTR
         lda  CPTR+1
         sta  APTR+1
         jsr  SKIP_COLON      ; advance past optional ':' for the saved point
         ldx  FSTKO
         lda  EPTR
         sta  FSTK+11,x
         lda  EPTR+1
         sta  FSTK+12,x
         lda  CPTR
         sta  FSTK+13,x
         lda  CPTR+1
         sta  FSTK+14,x
         lda  APTR            ; restore live cursor (chain continues inline)
         sta  CPTR
         lda  APTR+1
         sta  CPTR+1
         lda  FSTKO           ; commit frame
         clc
         adc  #15
         sta  FSTKO
         rts

; ---- NEXT [var] ----
;  Frame offset held in TMP2 across the float arithmetic (FADD/FSUB do not
;  touch $00/$01).  Loop test compares D = limit - var as floats.
cmd_NEXT:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'A'
         bcc  nx_novar
         cmp  #'Z'+1
         bcs  nx_novar
         jsr  GET_VARLET      ; explicit loop variable
         jsr  VOFF            ; X = varoff = (letter-'A')*5
         txa
         sta  TMP2            ; wanted varoff
nx_find:
         lda  FSTKO
         bne  nx_h
         rts                  ; NEXT without matching FOR: ignore
nx_h:
         sec
         sbc  #15
         tax                  ; X = top frame offset
         lda  FSTK+0,x
         cmp  TMP2
         beq  nx_do
         stx  FSTKO           ; abandon a non-matching inner loop
         jmp  nx_find

nx_novar:
         lda  FSTKO
         bne  nx_nv
         rts
nx_nv:
         sec
         sbc  #15
         tax                  ; X = top frame offset
         ; fall through

nx_do:                        ; X = frame offset
         stx  TMP2            ; TMP2 = frame offset
         lda  FSTK+0,x        ; varoff
         tax                  ; X = variable slot offset
         jsr  VLOAD           ; FAC = loop var
         ldy  TMP2            ; ARG = step
         lda  FSTK+6,y
         sta  ASGN
         lda  FSTK+7,y
         sta  AEXP
         lda  FSTK+8,y
         sta  AM
         lda  FSTK+9,y
         sta  AM+1
         lda  FSTK+10,y
         sta  AM+2
         lda  #0
         sta  AM+3
         sta  AM+4
         sta  AM+5
         jsr  FADD            ; FAC = var + step
         ldy  TMP2            ; store new value back into the loop var
         lda  FSTK+0,y
         tax
         jsr  VSTORE          ; var <- new value  (FAC still = new var)
         ldy  TMP2            ; ARG = limit
         lda  FSTK+1,y
         sta  ASGN
         lda  FSTK+2,y
         sta  AEXP
         lda  FSTK+3,y
         sta  AM
         lda  FSTK+4,y
         sta  AM+1
         lda  FSTK+5,y
         sta  AM+2
         lda  #0
         sta  AM+3
         sta  AM+4
         sta  AM+5
         jsr  FSUB            ; FAC = ARG - FAC = limit - var = D
         ldy  TMP2
         lda  FSTK+6,y        ; step sign byte (0 = +, $FF = -)
         bne  nx_neg
         ; positive step: continue while D >= 0  (D zero or positive)
         jsr  FM_ISZERO
         beq  nx_cont
         lda  FSGN
         beq  nx_cont
         jmp  nx_stop
nx_neg:  ; negative step: continue while D <= 0  (D zero or negative)
         jsr  FM_ISZERO
         beq  nx_cont
         lda  FSGN
         bne  nx_cont
         jmp  nx_stop

nx_cont:                      ; loop back to statement after FOR
         ldy  TMP2
         lda  FSTK+11,y
         sta  EPTR
         lda  FSTK+12,y
         sta  EPTR+1
         lda  FSTK+13,y
         sta  CPTR
         lda  FSTK+14,y
         sta  CPTR+1
         lda  #1
         sta  RESUMF
         sta  GOFLAG
         rts
nx_stop:                      ; loop finished: pop frame, fall through
         lda  TMP2
         sta  FSTKO
         rts

; ---- DIM var(max) [, var(max)] ...  (1-D integer arrays, index 0..max) ----
cmd_DIM:
dm_one:
         jsr  SKIP_SPC
         jsr  GET_VARLET      ; array letter
         sta  TMP
         jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  EVAL_EXPR       ; max index -> FAC
         jsr  FAC_TO_INT      ; -> AR
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         ; size (element count) = max + 1
         inc  AR
         bne  dm_sz
         inc  AR+1
dm_sz:
         ; descriptor offset = (letter-'A')*4  -> X
         lda  TMP
         sec
         sbc  #'A'
         asl  A
         asl  A
         tax
         lda  AHP             ; base = current heap pointer
         sta  ARRD+0,x
         lda  AHP+1
         sta  ARRD+1,x
         lda  AR              ; size (elements)
         sta  ARRD+2,x
         lda  AR+1
         sta  ARRD+3,x
         ; AHP += size*5  (bytes; 5-byte packed float elements)
         lda  AR
         asl  A
         sta  TMP             ; size*2
         lda  AR+1
         rol  A
         sta  TMP2
         asl  TMP
         rol  TMP2            ; size*4
         lda  TMP
         clc
         adc  AR
         sta  TMP             ; size*4 + size = size*5
         lda  TMP2
         adc  AR+1
         sta  TMP2
         lda  AHP
         clc
         adc  TMP
         sta  AHP
         lda  AHP+1
         adc  TMP2
         sta  AHP+1
         ; more dimensions?
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #','
         bne  dm_done
         jsr  GETCH
         jmp  dm_one
dm_done: rts

; ARR_ADDR: element address of <letter>(<index>) -> APTR.
;  On entry A = letter, CPTR at '('.  Auto-dimensions to 11 (0..10) if needed.
;  The letter is held on the stack so nested subscripts (e.g. A(B(2))) work.
ARR_ADDR:
         pha                  ; save array letter across the index evaluation
         jsr  GETCH           ; consume '('
         jsr  EVAL_EXPR       ; index -> FAC
         jsr  FAC_TO_INT      ; -> AR
         jsr  SKIP_SPC
         jsr  GETCH           ; consume ')'
         pla                  ; array letter
         sec
         sbc  #'A'
         asl  A
         asl  A
         tax                  ; X = descriptor offset
         lda  ARRD+0,x
         ora  ARRD+1,x
         bne  aa_have
         ; auto-dimension to 11 elements
         lda  AHP
         sta  ARRD+0,x
         lda  AHP+1
         sta  ARRD+1,x
         lda  #11
         sta  ARRD+2,x
         lda  #0
         sta  ARRD+3,x
         lda  AHP
         clc
         adc  #55             ; 11 elements * 5 bytes
         sta  AHP
         lda  AHP+1
         adc  #0
         sta  AHP+1
aa_have:
         lda  AR              ; bounds check: index must be < element count
         cmp  ARRD+2,x
         lda  AR+1
         sbc  ARRD+3,x
         bcc  aa_ok
         jmp  es_sub          ; index >= size (or negative) -> ?BAD SUBSCRIPT
aa_ok:
         ; APTR = base + index*5
         lda  AR
         asl  A
         sta  APTR
         lda  AR+1
         rol  A
         sta  APTR+1          ; index*2
         asl  APTR
         rol  APTR+1          ; index*4
         lda  APTR
         clc
         adc  AR
         sta  APTR
         lda  APTR+1
         adc  AR+1
         sta  APTR+1          ; index*5
         lda  APTR
         clc
         adc  ARRD+0,x
         sta  APTR
         lda  APTR+1
         adc  ARRD+1,x
         sta  APTR+1
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

; =============================================================================
;  Expression evaluator (lowest precedence first)
;    EVAL_EXPR -> ev_or -> ev_and -> ev_not -> ev_cmp
;              -> ev_additive -> ev_term -> ev_unary -> ev_primary
;  Booleans are $FFFF (true) / $0000 (false); AND/OR/NOT are bitwise.
; =============================================================================
EVAL_EXPR:
         jmp  ev_or

; PEEKW: skip spaces, save cursor to APTR, read the next word into KWBUF/KWLEN.
; UNPEEKW restores the cursor (used to "un-read" a word that isn't an operator).
PEEKW:
         jsr  SKIP_SPC
         lda  CPTR
         sta  APTR
         lda  CPTR+1
         sta  APTR+1
         jmp  READ_KW
UNPEEKW:
         lda  APTR
         sta  CPTR
         lda  APTR+1
         sta  CPTR+1
         rts

ev_or:
         jsr  ev_and
eo_lp:   jsr  PEEKW
         jsr  kw_OR
         bne  eo_no
         jsr  ev_push
         jsr  ev_and
         jsr  ev_pop_or
         jmp  eo_lp
eo_no:   jsr  UNPEEKW
         rts

ev_and:
         jsr  ev_not
ea_lp:   jsr  PEEKW
         jsr  kw_AND
         bne  ea_no
         jsr  ev_push
         jsr  ev_not
         jsr  ev_pop_and
         jmp  ea_lp
ea_no:   jsr  UNPEEKW
         rts

ev_not:
         jsr  PEEKW
         jsr  kw_NOT
         bne  en_no
         jsr  ev_not          ; NOT binds tighter than AND/OR, allows NOT NOT
         jsr  FAC_TO_INT      ; operand -> AR (signed)
         lda  AR
         eor  #$FF
         sta  AR
         lda  AR+1
         eor  #$FF
         sta  AR+1
         jmp  SINT_TO_FAC     ; -> FAC
en_no:   jsr  UNPEEKW
         jmp  ev_cmp

; ---- OR / AND: both operands are integers; bitwise-combine, then back to FAC.
;  On entry FAC = right operand, float stack top = left operand.
ev_pop_or:
         jsr  FAC_TO_INT      ; right -> AR
         lda  AR
         sta  AR+2
         lda  AR+1
         sta  AR+3            ; stash right in AR+2/AR+3
         jsr  FPOP            ; left -> ARG
         jsr  ARG_TO_FAC      ; left -> FAC
         jsr  FAC_TO_INT      ; left -> AR
         lda  AR
         ora  AR+2
         sta  AR
         lda  AR+1
         ora  AR+3
         sta  AR+1
         jmp  SINT_TO_FAC

ev_pop_and:
         jsr  FAC_TO_INT      ; right -> AR
         lda  AR
         sta  AR+2
         lda  AR+1
         sta  AR+3
         jsr  FPOP            ; left -> ARG
         jsr  ARG_TO_FAC      ; left -> FAC
         jsr  FAC_TO_INT      ; left -> AR
         lda  AR
         and  AR+2
         sta  AR
         lda  AR+1
         and  AR+3
         sta  AR+1
         jmp  SINT_TO_FAC

; =============================================================================
;  String evaluation
;    A string value is built in STRWRK with its length in SLEN.
;    EVAL_STR parses a string expression (primaries joined by '+').
; =============================================================================

; IS_STR: look ahead (cursor restored) - carry set if the next primary is a
; string: a literal, a string variable (letter'$'), or a string function
; (name followed by '$').  Numeric otherwise.
IS_STR:
         jsr  SKIP_SPC
         lda  CPTR
         sta  APTR
         lda  CPTR+1
         sta  APTR+1
         jsr  PEEK
         cmp  #'"'
         beq  is_yes
         cmp  #'A'
         bcc  is_no
         cmp  #'Z'+1
         bcs  is_no
         jsr  READ_KW         ; read the leading word
         jsr  PEEK
         cmp  #'$'            ; string var or string function ends with '$'
         beq  is_yes_r
is_no:   jsr  UNPEEKW
         clc
         rts
is_yes_r:
         jsr  UNPEEKW
is_yes:  sec
         rts

; EVAL_STR: evaluate a string expression -> STRWRK / SLEN
EVAL_STR:
         lda  #0
         sta  SLEN
         jsr  str_prim
estr_lp: jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'+'
         bne  estr_done
         jsr  GETCH
         jsr  str_prim
         jmp  estr_lp
estr_done:
         rts

; str_prim: append one string primary to STRWRK/SLEN
str_prim:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'"'
         beq  sp_lit
         jsr  READ_KW
         lda  KWLEN
         cmp  #1
         bne  sp_func
         ; string variable: consume '$', append its characters
         jsr  GETCH           ; '$'
         lda  KWBUF+0
         jsr  STRVAR_PTR      ; SPTR -> slot
         jmp  COPY_SLOT
sp_lit:
         jsr  GETCH           ; consume opening '"'
spl_lp:  jsr  GETCH
         beq  spl_done
         cmp  #'"'
         beq  spl_done
         jsr  APPEND_CH
         jmp  spl_lp
spl_done:
         rts
sp_func:
         jmp  STR_FUNC        ; string-returning functions (see below)

; APPEND_CH: append A to STRWRK, bump SLEN
APPEND_CH:
         ldy  SLEN
         sta  STRWRK,y
         inc  SLEN
         rts

; COPY_SLOT: append the string at (SPTR) [len byte + chars] to STRWRK/SLEN
COPY_SLOT:
         ldy  #0
         lda  (SPTR),y
         sta  CNT
         beq  cs_done
         ldy  #1
         ldx  SLEN
cs_lp:   lda  (SPTR),y
         sta  STRWRK,x
         inx
         iny
         dec  CNT
         bne  cs_lp
         stx  SLEN
cs_done: rts

; STRVAR_PTR: A = letter -> SPTR = STRVARS + (letter-'A')*64
STRVAR_PTR:
         sec
         sbc  #'A'
         sta  SPTR
         lda  #0
         sta  SPTR+1
         ldx  #6
svp_sh:  asl  SPTR
         rol  SPTR+1
         dex
         bne  svp_sh
         lda  SPTR+1
         clc
         adc  #>STRVARS
         sta  SPTR+1
         rts

; STR_SRC: read a single string term (variable or literal) directly, without
;  touching the STRWRK accumulator.  -> SPTR = first char, ARGLEN = length.
;  Used for string-function arguments (so functions can nest inside strings).
STR_SRC:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'"'
         beq  src_lit
         jsr  READ_KW         ; string variable letter
         jsr  GETCH           ; '$'
         lda  KWBUF+0
         jsr  STRVAR_PTR      ; SPTR -> slot
         ldy  #0
         lda  (SPTR),y
         sta  ARGLEN          ; length byte
         inc  SPTR            ; advance to first char
         bne  src_done
         inc  SPTR+1
src_done:
         rts
src_lit:
         jsr  GETCH           ; consume '"'
         lda  CPTR
         sta  SPTR
         lda  CPTR+1
         sta  SPTR+1          ; SPTR -> first char in program text
         lda  #0
         sta  ARGLEN
src_l2:  jsr  PEEK
         beq  src_l3
         cmp  #'"'
         beq  src_l4
         inc  ARGLEN
         jsr  GETCH
         jmp  src_l2
src_l4:  jsr  GETCH           ; consume closing '"'
src_l3:  rts

; STR_APP: append ARGLEN' chars starting at source offset TMP2 from (SPTR),
;  count in CNT.  (helper for LEFT$/RIGHT$/MID$ - Y recomputed each char)
STR_APP:
         ldx  #0
sa_lp:   cpx  CNT
         beq  sa_done
         txa
         clc
         adc  TMP2            ; source offset = start + x
         tay
         lda  (SPTR),y
         jsr  APPEND_CH
         inx
         jmp  sa_lp
sa_done: rts

; APPEND_S16 / APPEND_U16: append decimal text of AR to STRWRK (like PRINT_S16
;  but into the accumulator).  Used by STR$().
APPEND_S16:
         lda  AR+1
         bpl  aps_pos
         lda  #'-'
         jsr  APPEND_CH
         lda  #0
         sec
         sbc  AR
         sta  AR
         lda  #0
         sbc  AR+1
         sta  AR+1
aps_pos:
APPEND_U16:
         lda  AR
         sta  AR+2
         lda  AR+1
         sta  AR+3
         lda  #0
         pha                  ; sentinel
apu_lp:  jsr  div10           ; AR+2/3 /= 10, remainder -> A
         clc
         adc  #'0'
         pha
         lda  AR+2
         ora  AR+3
         bne  apu_lp
apu_pr:  pla
         beq  apu_done
         jsr  APPEND_CH
         jmp  apu_pr
apu_done:
         rts

; ---- STR_FUNC: string-returning functions (KWBUF holds the name) ----
STR_FUNC:
         jsr  kw_CHR
         bne  sfd1
         jmp  sf_chr
sfd1:    jsr  kw_STR
         bne  sfd2
         jmp  sf_str
sfd2:    jsr  kw_LEFT
         bne  sfd3
         jmp  sf_left
sfd3:    jsr  kw_RIGHT
         bne  sfd4
         jmp  sf_right
sfd4:    jsr  kw_MID
         bne  sfd5
         jmp  sf_mid
sfd5:    jmp  es_err

sf_chr:  jsr  GETCH           ; '$'
         jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  EVAL_EXPR       ; code -> FAC
         jsr  FAC_TO_INT      ; -> AR
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         lda  AR
         jmp  APPEND_CH

sf_str:  jsr  GETCH           ; '$'
         jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  EVAL_EXPR       ; value -> FAC
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         lda  #$80            ; route PRINT_FAC output into STRWRK
         sta  PFDEST
         jsr  PRINT_FAC       ; append the number's decimal text
         lda  #0
         sta  PFDEST
         rts

sf_left: jsr  GETCH           ; '$'
         jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  STR_SRC         ; SPTR, ARGLEN
         jsr  SKIP_SPC
         jsr  GETCH           ; ','
         jsr  EVAL_EXPR       ; n -> FAC
         jsr  FAC_TO_INT      ; -> AR
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         lda  AR
         cmp  ARGLEN
         bcc  lf_cnt
         lda  ARGLEN
lf_cnt:  sta  CNT
         lda  #0
         sta  TMP2            ; start at char 0
         jmp  STR_APP

sf_right:jsr  GETCH           ; '$'
         jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  STR_SRC
         jsr  SKIP_SPC
         jsr  GETCH           ; ','
         jsr  EVAL_EXPR       ; n -> FAC
         jsr  FAC_TO_INT      ; -> AR
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         lda  AR
         cmp  ARGLEN
         bcc  rt_cnt
         lda  ARGLEN
rt_cnt:  sta  CNT
         lda  ARGLEN          ; start = ARGLEN - CNT
         sec
         sbc  CNT
         sta  TMP2
         jmp  STR_APP

sf_mid:  jsr  GETCH           ; '$'
         jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  STR_SRC
         jsr  SKIP_SPC
         jsr  GETCH           ; ','
         jsr  EVAL_EXPR       ; start (1-based) -> FAC
         jsr  FAC_TO_INT      ; -> AR
         lda  AR
         sec
         sbc  #1
         sta  TMP2            ; start0 (0-based)
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #','
         bne  mid_deflen
         jsr  GETCH
         jsr  EVAL_EXPR       ; explicit length -> FAC
         jsr  FAC_TO_INT      ; -> AR
         lda  AR
         sta  CNT
         jmp  mid_close
mid_deflen:
         lda  ARGLEN          ; default: to end of string
         sec
         sbc  TMP2
         sta  CNT
mid_close:
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         lda  TMP2            ; start0 past end -> empty
         cmp  ARGLEN
         bcc  mid_clamp
         rts
mid_clamp:
         lda  TMP2            ; if start0+CNT > ARGLEN, shrink CNT
         clc
         adc  CNT
         cmp  ARGLEN
         bcc  mid_app
         beq  mid_app
         lda  ARGLEN
         sec
         sbc  TMP2
         sta  CNT
mid_app: jmp  STR_APP

; ---- NUM_FUNC: numeric-returning functions (KWBUF holds the name) ----
NUM_FUNC:
         jsr  kw_LEN
         beq  nf_len
         jsr  kw_ASC
         beq  nf_asc
         jsr  kw_VAL
         beq  nf_val
         jmp  NUM_FUNC2       ; ABS/SGN/RND (Stage H)

nf_len:  jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  STR_SRC
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         lda  ARGLEN
         sta  AR
         lda  #0
         sta  AR+1
         jmp  INT_TO_FAC      ; length -> FAC

nf_asc:  jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  STR_SRC
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         lda  #0
         sta  AR+1
         ldy  ARGLEN
         beq  nf_asc0
         ldy  #0
         lda  (SPTR),y        ; first character
         sta  AR
         jmp  INT_TO_FAC
nf_asc0: sta  AR
         jmp  INT_TO_FAC      ; empty string -> 0

nf_val:  jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  STR_SRC
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         lda  CPTR            ; parse the string chars as an integer
         sta  ASTP
         lda  CPTR+1
         sta  ASTP+1
         lda  SPTR
         sta  CPTR
         lda  SPTR+1
         sta  CPTR+1
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'-'
         bne  nfv_pos
         jsr  GETCH
         jsr  PARSE_DEC
         lda  #0
         sec
         sbc  AR
         sta  AR
         lda  #0
         sbc  AR+1
         sta  AR+1
         jmp  nfv_rest
nfv_pos: jsr  PARSE_DEC
nfv_rest:
         lda  ASTP
         sta  CPTR
         lda  ASTP+1
         sta  CPTR+1
         jmp  SINT_TO_FAC     ; parsed integer -> FAC

; ---- NUM_FUNC2: ABS / SGN / RND ----
NUM_FUNC2:
         jsr  kw_ABS
         bne  nf2a
         jmp  nf_abs
nf2a:    jsr  kw_SGN
         bne  nf2b
         jmp  nf_sgn
nf2b:    jsr  kw_RND
         bne  nf2c
         jmp  nf_rnd
nf2c:    jmp  es_err

nf_abs:  jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  EVAL_EXPR       ; value -> FAC
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         lda  #0              ; |FAC| = clear sign
         sta  FSGN
         rts

nf_sgn:  jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  EVAL_EXPR       ; value -> FAC
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         jsr  FM_ISZERO
         beq  sgn_zero
         lda  FSGN
         bne  sgn_neg
         lda  #1              ; positive -> 1
         sta  AR
         lda  #0
         sta  AR+1
         jmp  INT_TO_FAC
sgn_neg: jmp  FTRUE           ; negative -> -1
sgn_zero:jmp  FAC_ZERO        ; zero -> 0

nf_rnd:  jsr  SKIP_SPC
         jsr  GETCH           ; '('
         jsr  EVAL_EXPR       ; n -> FAC
         jsr  SKIP_SPC
         jsr  GETCH           ; ')'
         jsr  FAC_TO_INT      ; n -> AR (truncated)
         lda  AR+1            ; n <= 0 -> 0
         bmi  rnd_zero
         lda  AR
         ora  AR+1
         beq  rnd_zero
         lda  AR              ; divisor = n
         sta  DIVSOR
         lda  AR+1
         sta  DIVSOR+1
         jsr  RND_NEXT        ; advance seed
         lda  RSEED           ; dividend = seed
         sta  AR+2
         lda  RSEED+1
         sta  AR+3
         jsr  UMOD16          ; AR = seed mod n
         jmp  INT_TO_FAC      ; result -> FAC
rnd_zero:jmp  FAC_ZERO

; RND_NEXT: advance the LCG   seed = seed*5 + 1  (mod 65536)
RND_NEXT:
         lda  RSEED
         sta  AR+4
         lda  RSEED+1
         sta  AR+5
         asl  RSEED
         rol  RSEED+1
         asl  RSEED
         rol  RSEED+1         ; seed *= 4
         lda  RSEED
         clc
         adc  AR+4
         sta  RSEED
         lda  RSEED+1
         adc  AR+5
         sta  RSEED+1         ; seed = seed*4 + seed
         inc  RSEED
         bne  rn_done
         inc  RSEED+1
rn_done: rts

; UMOD16: AR = (AR+2/AR+3) mod DIVSOR   (unsigned 16-bit)
UMOD16:
         lda  #0
         sta  AR
         sta  AR+1
         ldx  #16
umod_lp: asl  AR+2
         rol  AR+3
         rol  AR
         rol  AR+1
         lda  AR
         sec
         sbc  DIVSOR
         tay
         lda  AR+1
         sbc  DIVSOR+1
         bcc  umod_no
         sty  AR
         sta  AR+1
umod_no: dex
         bne  umod_lp
         rts

; STR_STORE: copy STRWRK/SLEN into the string variable whose letter is in A.
;  Length is truncated to 63 (slot capacity).
STR_STORE:
         jsr  STRVAR_PTR      ; SPTR -> slot
         lda  SLEN
         cmp  #64
         bcc  sst_ok
         lda  #63
         sta  SLEN
sst_ok:  ldy  #0
         lda  SLEN
         sta  (SPTR),y        ; slot[0] = length
         ldx  #0
         ldy  #1
sst_lp:  cpx  SLEN
         beq  sst_done
         lda  STRWRK,x
         sta  (SPTR),y
         inx
         iny
         jmp  sst_lp
sst_done: rts

; comparison layer  (< > = <> <= >=)  result: $FFFF=true, $0000=false
ev_cmp:
         jsr  ev_additive          ; left -> FAC
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'<'
         beq  ec_lt
         cmp  #'>'
         beq  ec_gt
         cmp  #'='
         beq  ec_eq
         rts
ec_eq:   jsr  GETCH
         lda  #2                   ; OP_EQ
         jmp  ec_do
ec_lt:   jsr  GETCH
         jsr  PEEK
         cmp  #'='
         beq  ec_le
         cmp  #'>'
         beq  ec_ne
         lda  #0                   ; OP_LT
         jmp  ec_do
ec_le:   jsr  GETCH
         lda  #3                   ; OP_LE
         jmp  ec_do
ec_ne:   jsr  GETCH
         lda  #5                   ; OP_NE
         jmp  ec_do
ec_gt:   jsr  GETCH
         jsr  PEEK
         cmp  #'='
         beq  ec_ge
         lda  #1                   ; OP_GT
         jmp  ec_do
ec_ge:   jsr  GETCH
         lda  #4                   ; OP_GE
ec_do:   pha                       ; operator code
         jsr  ev_push              ; save left (FAC)
         jsr  ev_additive          ; right -> FAC
         jsr  FPOP                 ; left -> ARG
         jsr  FSUB                 ; FAC = left - right = D
         jsr  FM_ISZERO
         bne  ec_nz
         lda  #0                   ; D == 0
         jmp  ec_sv
ec_nz:   lda  FSGN
         beq  ec_dp
         lda  #$FF                 ; D < 0
         jmp  ec_sv
ec_dp:   lda  #1                   ; D > 0
ec_sv:   sta  FTMP
         pla                       ; operator code -> A
         cmp  #0
         bne  ec_c1
         lda  FTMP                 ; LT: true if D<0
         cmp  #$FF
         beq  ec_true
         jmp  ec_false
ec_c1:   cmp  #1
         bne  ec_c2
         lda  FTMP                 ; GT: true if D>0
         cmp  #1
         beq  ec_true
         jmp  ec_false
ec_c2:   cmp  #2
         bne  ec_c3
         lda  FTMP                 ; EQ: true if D==0
         beq  ec_true
         jmp  ec_false
ec_c3:   cmp  #3
         bne  ec_c4
         lda  FTMP                 ; LE: true if D<=0 (FTMP != 1)
         cmp  #1
         bne  ec_true
         jmp  ec_false
ec_c4:   cmp  #4
         bne  ec_c5
         lda  FTMP                 ; GE: true if D>=0 (FTMP != $FF)
         cmp  #$FF
         bne  ec_true
         jmp  ec_false
ec_c5:   lda  FTMP                 ; NE: true if D!=0
         bne  ec_true
         jmp  ec_false
ec_true: jmp  FTRUE
ec_false:jmp  FAC_ZERO
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
         jmp  FAC_NEG

ev_primary:
         jsr  SKIP_SPC
         jsr  PEEK
         cmp  #'('
         beq  evp_paren
         cmp  #'.'             ; a literal like ".5"
         beq  evp_num
         cmp  #'0'
         bcc  evp_var
         cmp  #'9'+1
         bcs  evp_var
evp_num: jmp  PARSE_FLOAT

evp_var:
         cmp  #'A'
         bcc  evp_zero
         cmp  #'Z'+1
         bcs  evp_zero
         jsr  READ_KW         ; identifier: single letter = variable, else func
         lda  KWLEN
         cmp  #1
         bne  evp_fn
         lda  KWBUF+0
         pha                  ; hold letter across PEEK (TMP must stay intact)
         jsr  PEEK
         cmp  #'('
         beq  evp_arr
         pla                  ; scalar variable
         jsr  VOFF
         jmp  VLOAD
evp_fn:
         jmp  NUM_FUNC        ; numeric function (KWBUF holds the name)
evp_arr:
         pla                  ; letter -> A
         jsr  ARR_ADDR        ; <letter>(<index>) -> APTR
         ldy  #0
         lda  (APTR),y        ; load packed float -> FAC
         sta  FSGN
         iny
         lda  (APTR),y
         sta  FEXP
         iny
         lda  (APTR),y
         sta  FM
         iny
         lda  (APTR),y
         sta  FM+1
         iny
         lda  (APTR),y
         sta  FM+2
         lda  #0
         sta  FM+3
         sta  FM+4
         sta  FM+5
         rts

evp_zero:
         jmp  FAC_ZERO

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
         jsr  FAC_ZERO
evd_skip:jsr  GETCH
         cmp  #0
         bne  evd_skip
         rts

; ---- eval stack ----

; ---- eval stack + binary ops are float (see the float library) ----
ev_push: jmp  FPUSH           ; push FAC onto the float value stack

ev_pop_add:
         jsr  FPOP            ; left -> ARG
         jmp  FADD            ; FAC = ARG + FAC
ev_pop_sub:
         jsr  FPOP
         jmp  FSUB            ; FAC = ARG - FAC
ev_pop_mul:
         jsr  FPOP
         jmp  FMUL            ; FAC = ARG * FAC
ev_pop_div:
         jsr  FPOP
         jmp  FDIV            ; FAC = ARG / FAC

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
         cpx  #7              ; allow 7-char keywords (e.g. RESTORE)
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

kw_GOSUB:
         lda  KWLEN
         cmp  #5
         bne  kgs_ne
         lda  KWBUF+0
         cmp  #'G'
         bne  kgs_ne
         lda  KWBUF+1
         cmp  #'O'
         bne  kgs_ne
         lda  KWBUF+2
         cmp  #'S'
         bne  kgs_ne
         lda  KWBUF+3
         cmp  #'U'
         bne  kgs_ne
         lda  KWBUF+4
         cmp  #'B'
kgs_ne:  rts

kw_RETURN:
         lda  KWLEN
         cmp  #6
         bne  krt_ne
         lda  KWBUF+0
         cmp  #'R'
         bne  krt_ne
         lda  KWBUF+1
         cmp  #'E'
         bne  krt_ne
         lda  KWBUF+2
         cmp  #'T'
         bne  krt_ne
         lda  KWBUF+3
         cmp  #'U'
         bne  krt_ne
         lda  KWBUF+4
         cmp  #'R'
         bne  krt_ne
         lda  KWBUF+5
         cmp  #'N'
krt_ne:  rts

kw_FOR:
         lda  KWLEN
         cmp  #3
         bne  kfr_ne
         lda  KWBUF+0
         cmp  #'F'
         bne  kfr_ne
         lda  KWBUF+1
         cmp  #'O'
         bne  kfr_ne
         lda  KWBUF+2
         cmp  #'R'
kfr_ne:  rts

kw_NEXT:
         lda  KWLEN
         cmp  #4
         bne  knx_ne
         lda  KWBUF+0
         cmp  #'N'
         bne  knx_ne
         lda  KWBUF+1
         cmp  #'E'
         bne  knx_ne
         lda  KWBUF+2
         cmp  #'X'
         bne  knx_ne
         lda  KWBUF+3
         cmp  #'T'
knx_ne:  rts

kw_STEP:
         lda  KWLEN
         cmp  #4
         bne  kst_ne
         lda  KWBUF+0
         cmp  #'S'
         bne  kst_ne
         lda  KWBUF+1
         cmp  #'T'
         bne  kst_ne
         lda  KWBUF+2
         cmp  #'E'
         bne  kst_ne
         lda  KWBUF+3
         cmp  #'P'
kst_ne:  rts

kw_DIM:
         lda  KWLEN
         cmp  #3
         bne  kdm_ne
         lda  KWBUF+0
         cmp  #'D'
         bne  kdm_ne
         lda  KWBUF+1
         cmp  #'I'
         bne  kdm_ne
         lda  KWBUF+2
         cmp  #'M'
kdm_ne:  rts

kw_OR:
         lda  KWLEN
         cmp  #2
         bne  kor_ne
         lda  KWBUF+0
         cmp  #'O'
         bne  kor_ne
         lda  KWBUF+1
         cmp  #'R'
kor_ne:  rts

kw_AND:
         lda  KWLEN
         cmp  #3
         bne  kan_ne
         lda  KWBUF+0
         cmp  #'A'
         bne  kan_ne
         lda  KWBUF+1
         cmp  #'N'
         bne  kan_ne
         lda  KWBUF+2
         cmp  #'D'
kan_ne:  rts

kw_NOT:
         lda  KWLEN
         cmp  #3
         bne  knt_ne
         lda  KWBUF+0
         cmp  #'N'
         bne  knt_ne
         lda  KWBUF+1
         cmp  #'O'
         bne  knt_ne
         lda  KWBUF+2
         cmp  #'T'
knt_ne:  rts

; ---- function-name matchers (KWBUF holds the identifier) ----
kw_LEN:
         lda  KWLEN
         cmp  #3
         bne  klen_ne
         lda  KWBUF+0
         cmp  #'L'
         bne  klen_ne
         lda  KWBUF+1
         cmp  #'E'
         bne  klen_ne
         lda  KWBUF+2
         cmp  #'N'
klen_ne: rts

kw_ASC:
         lda  KWLEN
         cmp  #3
         bne  kasc_ne
         lda  KWBUF+0
         cmp  #'A'
         bne  kasc_ne
         lda  KWBUF+1
         cmp  #'S'
         bne  kasc_ne
         lda  KWBUF+2
         cmp  #'C'
kasc_ne: rts

kw_VAL:
         lda  KWLEN
         cmp  #3
         bne  kval_ne
         lda  KWBUF+0
         cmp  #'V'
         bne  kval_ne
         lda  KWBUF+1
         cmp  #'A'
         bne  kval_ne
         lda  KWBUF+2
         cmp  #'L'
kval_ne: rts

kw_CHR:
         lda  KWLEN
         cmp  #3
         bne  kchr_ne
         lda  KWBUF+0
         cmp  #'C'
         bne  kchr_ne
         lda  KWBUF+1
         cmp  #'H'
         bne  kchr_ne
         lda  KWBUF+2
         cmp  #'R'
kchr_ne: rts

kw_STR:
         lda  KWLEN
         cmp  #3
         bne  kstr_ne
         lda  KWBUF+0
         cmp  #'S'
         bne  kstr_ne
         lda  KWBUF+1
         cmp  #'T'
         bne  kstr_ne
         lda  KWBUF+2
         cmp  #'R'
kstr_ne: rts

kw_LEFT:
         lda  KWLEN
         cmp  #4
         bne  klft_ne
         lda  KWBUF+0
         cmp  #'L'
         bne  klft_ne
         lda  KWBUF+1
         cmp  #'E'
         bne  klft_ne
         lda  KWBUF+2
         cmp  #'F'
         bne  klft_ne
         lda  KWBUF+3
         cmp  #'T'
klft_ne: rts

kw_RIGHT:
         lda  KWLEN
         cmp  #5
         bne  krgt_ne
         lda  KWBUF+0
         cmp  #'R'
         bne  krgt_ne
         lda  KWBUF+1
         cmp  #'I'
         bne  krgt_ne
         lda  KWBUF+2
         cmp  #'G'
         bne  krgt_ne
         lda  KWBUF+3
         cmp  #'H'
         bne  krgt_ne
         lda  KWBUF+4
         cmp  #'T'
krgt_ne: rts

kw_MID:
         lda  KWLEN
         cmp  #3
         bne  kmid_ne
         lda  KWBUF+0
         cmp  #'M'
         bne  kmid_ne
         lda  KWBUF+1
         cmp  #'I'
         bne  kmid_ne
         lda  KWBUF+2
         cmp  #'D'
kmid_ne: rts

kw_ABS:
         lda  KWLEN
         cmp  #3
         bne  kabs_ne
         lda  KWBUF+0
         cmp  #'A'
         bne  kabs_ne
         lda  KWBUF+1
         cmp  #'B'
         bne  kabs_ne
         lda  KWBUF+2
         cmp  #'S'
kabs_ne: rts

kw_SGN:
         lda  KWLEN
         cmp  #3
         bne  ksgn_ne
         lda  KWBUF+0
         cmp  #'S'
         bne  ksgn_ne
         lda  KWBUF+1
         cmp  #'G'
         bne  ksgn_ne
         lda  KWBUF+2
         cmp  #'N'
ksgn_ne: rts

kw_RND:
         lda  KWLEN
         cmp  #3
         bne  krnd_ne
         lda  KWBUF+0
         cmp  #'R'
         bne  krnd_ne
         lda  KWBUF+1
         cmp  #'N'
         bne  krnd_ne
         lda  KWBUF+2
         cmp  #'D'
krnd_ne: rts

kw_DATA:
         lda  KWLEN
         cmp  #4
         bne  kda_ne
         lda  KWBUF+0
         cmp  #'D'
         bne  kda_ne
         lda  KWBUF+1
         cmp  #'A'
         bne  kda_ne
         lda  KWBUF+2
         cmp  #'T'
         bne  kda_ne
         lda  KWBUF+3
         cmp  #'A'
kda_ne:  rts

kw_READ:
         lda  KWLEN
         cmp  #4
         bne  krd_ne
         lda  KWBUF+0
         cmp  #'R'
         bne  krd_ne
         lda  KWBUF+1
         cmp  #'E'
         bne  krd_ne
         lda  KWBUF+2
         cmp  #'A'
         bne  krd_ne
         lda  KWBUF+3
         cmp  #'D'
krd_ne:  rts

kw_RESTORE:
         lda  KWLEN
         cmp  #7
         bne  krs_ne
         lda  KWBUF+0
         cmp  #'R'
         bne  krs_ne
         lda  KWBUF+1
         cmp  #'E'
         bne  krs_ne
         lda  KWBUF+2
         cmp  #'S'
         bne  krs_ne
         lda  KWBUF+3
         cmp  #'T'
         bne  krs_ne
         lda  KWBUF+4
         cmp  #'O'
         bne  krs_ne
         lda  KWBUF+5
         cmp  #'R'
         bne  krs_ne
         lda  KWBUF+6
         cmp  #'E'
krs_ne:  rts

kw_ON:
         lda  KWLEN
         cmp  #2
         bne  kon_ne
         lda  KWBUF+0
         cmp  #'O'
         bne  kon_ne
         lda  KWBUF+1
         cmp  #'N'
kon_ne:  rts

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
;  Floating point  --  decimal float:  value = sign * M * 10^E
;    M is a 7-digit mantissa (normalized to [10^6, 10^7)); E is a signed
;    decimal exponent.  FAC/ARG hold M as a 48-bit little-endian integer.
;    Decimal (not binary) means PRINT/parse are exact for the shown digits and
;    0.1 + 0.2 = 0.3 with no surprises.
; =============================================================================

; ---- FM *= 10   (48-bit) ----
FM_MUL10:
         ldx  #5              ; MTMP = FM
fmm_cp:  lda  FM,x
         sta  MTMP,x
         dex
         bpl  fmm_cp
         asl  MTMP            ; MTMP = FM << 1  (x2)
         rol  MTMP+1
         rol  MTMP+2
         rol  MTMP+3
         rol  MTMP+4
         rol  MTMP+5
         ldx  #3              ; FM <<= 3  (x8)
fmm_sh:  asl  FM
         rol  FM+1
         rol  FM+2
         rol  FM+3
         rol  FM+4
         rol  FM+5
         dex
         bne  fmm_sh
         clc                  ; FM = FM(x8) + MTMP(x2)  = x10
         lda  FM
         adc  MTMP
         sta  FM
         lda  FM+1
         adc  MTMP+1
         sta  FM+1
         lda  FM+2
         adc  MTMP+2
         sta  FM+2
         lda  FM+3
         adc  MTMP+3
         sta  FM+3
         lda  FM+4
         adc  MTMP+4
         sta  FM+4
         lda  FM+5
         adc  MTMP+5
         sta  FM+5
         rts

; ---- FM /= 10   (48-bit);  remainder digit -> A ----
FM_DIV10:
         lda  #0
         sta  FTMP            ; remainder accumulator
         ldx  #48
fmd_lp:  asl  FM
         rol  FM+1
         rol  FM+2
         rol  FM+3
         rol  FM+4
         rol  FM+5
         rol  FTMP
         lda  FTMP
         cmp  #10
         bcc  fmd_no
         sbc  #10
         sta  FTMP
         inc  FM              ; set quotient bit 0 (vacated by the shift)
fmd_no:  dex
         bne  fmd_lp
         lda  FTMP
         rts

; ---- FM = FM*10 + A   (push a decimal digit) ----
FM_PUSHDIG:
         pha
         jsr  FM_MUL10
         pla
         clc
         adc  FM
         sta  FM
         bcc  fpd_ok
         inc  FM+1
         bne  fpd_ok
         inc  FM+2
         bne  fpd_ok
         inc  FM+3
         bne  fpd_ok
         inc  FM+4
         bne  fpd_ok
         inc  FM+5
fpd_ok:  rts

; ---- FM_ISZERO: Z=1 if the 48-bit mantissa is zero ----
FM_ISZERO:
         lda  FM
         ora  FM+1
         ora  FM+2
         ora  FM+3
         ora  FM+4
         ora  FM+5
         rts

; ---- M_GE_1E7: carry set if FM >= 10^7 ----
M_GE_1E7:
         lda  FM+3
         ora  FM+4
         ora  FM+5
         bne  mge_yes         ; any high byte set -> >= 2^24 > 10^7
         lda  FM+2            ; compare 24-bit FM vs $989680
         cmp  #$98
         bcc  mge_no
         bne  mge_yes
         lda  FM+1
         cmp  #$96
         bcc  mge_no
         bne  mge_yes
         lda  FM
         cmp  #$80            ; carry = (FM >= 10^7)
         rts
mge_yes: sec
         rts
mge_no:  clc
         rts

; ---- M_LT_1E6: carry set if FM < 10^6 ----
M_LT_1E6:
         lda  FM+3
         ora  FM+4
         ora  FM+5
         bne  mlt_no          ; high bytes set -> huge -> not < 10^6
         lda  FM+2            ; compare 24-bit FM vs $0F4240
         cmp  #$0F
         bcc  mlt_yes
         bne  mlt_no
         lda  FM+1
         cmp  #$42
         bcc  mlt_yes
         bne  mlt_no
         lda  FM
         cmp  #$40
         bcc  mlt_yes
         clc                  ; FM == 10^6 -> not < 10^6
         rts
mlt_yes: sec
         rts
mlt_no:  clc
         rts

; ---- FNORM: normalize FAC so M is 7 digits [10^6,10^7); adjust FEXP.  Zero->0 ----
FNORM:
         jsr  FM_ISZERO
         bne  fn_hi
         lda  #0              ; value is zero: canonical form
         sta  FEXP
         sta  FSGN
         rts
fn_hi:   jsr  M_GE_1E7        ; shrink while too big
         bcc  fn_lo
         jsr  FM_DIV10
         inc  FEXP
         jmp  fn_hi
fn_lo:   jsr  M_LT_1E6        ; grow while too small
         bcc  fn_done
         jsr  FM_MUL10
         dec  FEXP
         jmp  fn_lo
fn_done: rts

; ---- INT_TO_FAC: AR (unsigned 16-bit) -> FAC (positive) ----
INT_TO_FAC:
         lda  AR
         sta  FM
         lda  AR+1
         sta  FM+1
         lda  #0
         sta  FM+2
         sta  FM+3
         sta  FM+4
         sta  FM+5
         sta  FEXP
         sta  FSGN
         jmp  FNORM

; ---- SINT_TO_FAC: AR (signed two's-complement 16-bit) -> FAC ----
SINT_TO_FAC:
         lda  AR+1
         bpl  INT_TO_FAC      ; non-negative: unsigned conversion
         lda  #0              ; negate AR into a positive magnitude
         sec
         sbc  AR
         sta  AR
         lda  #0
         sbc  AR+1
         sta  AR+1
         jsr  INT_TO_FAC
         lda  #$FF            ; then flag negative
         sta  FSGN
         rts

; ---- PARSE_FLOAT: numeric literal at CPTR -> FAC (unsigned; caller handles -) ----
PARSE_FLOAT:
         lda  #0
         sta  FM
         sta  FM+1
         sta  FM+2
         sta  FM+3
         sta  FM+4
         sta  FM+5
         sta  FEXP
         sta  FSGN
pf_int:  jsr  PEEK            ; integer part
         cmp  #'0'
         bcc  pf_dot
         cmp  #'9'+1
         bcs  pf_dot
         jsr  GETCH
         sec
         sbc  #'0'
         jsr  FM_PUSHDIG
         jmp  pf_int
pf_dot:  jsr  PEEK
         cmp  #'.'
         bne  pf_exp
         jsr  GETCH
pf_frac: jsr  PEEK            ; fractional part
         cmp  #'0'
         bcc  pf_exp
         cmp  #'9'+1
         bcs  pf_exp
         jsr  GETCH
         sec
         sbc  #'0'
         jsr  FM_PUSHDIG
         dec  FEXP
         jmp  pf_frac
pf_exp:  jsr  PEEK
         cmp  #'E'
         beq  pf_e
         jmp  pf_fin
pf_e:    jsr  GETCH           ; exponent
         ldx  #0              ; X = exponent sign (0 = +)
         jsr  PEEK
         cmp  #'-'
         bne  pf_ep
         ldx  #1
         jsr  GETCH
         jmp  pf_ed
pf_ep:   cmp  #'+'
         bne  pf_ed
         jsr  GETCH
pf_ed:   lda  #0
         sta  DCNT
pf_edl:  jsr  PEEK
         cmp  #'0'
         bcc  pf_eap
         cmp  #'9'+1
         bcs  pf_eap
         jsr  GETCH
         sec
         sbc  #'0'
         pha
         lda  DCNT            ; DCNT = DCNT*10 + digit
         asl  A
         sta  FTMP
         asl  A
         asl  A
         clc
         adc  FTMP
         sta  DCNT
         pla
         clc
         adc  DCNT
         sta  DCNT
         jmp  pf_edl
pf_eap:  txa                  ; apply exponent sign
         bne  pf_eneg
         lda  FEXP
         clc
         adc  DCNT
         sta  FEXP
         jmp  pf_fin
pf_eneg: lda  FEXP
         sec
         sbc  DCNT
         sta  FEXP
pf_fin:  jmp  FNORM

; ---- PFPUT: emit A to PRINT_FAC's current sink (console or STR$ buffer) ----
;  Preserves X (PRINT_FAC keeps loop counters in X across output).
PFPUT:   bit  PFDEST
         bmi  pfp_str
         jmp  PUTCH
pfp_str: jmp  APPEND_CH

; ---- PRINT_FAC: print FAC as a decimal number (via PFPUT sink) ----
PRINT_FAC:
         lda  FSGN
         beq  pfa_pos
         lda  #'-'
         jsr  PFPUT
pfa_pos: jsr  FM_ISZERO
         bne  pfa_nz
         lda  #'0'
         jmp  PFPUT
pfa_nz:  ldy  #6              ; extract the 7 digits d1..d7 into MTMP[0..6]
pfa_ext: jsr  FM_DIV10        ; (FM_DIV10 clobbers X, so index with Y)
         sta  MTMP,y
         dey
         bpl  pfa_ext
         lda  FEXP            ; P = exponent of leading digit = FEXP + 6
         clc
         adc  #6
         sta  FTMP
         bpl  pfa_ppos        ; choose fixed vs scientific
         clc
         adc  #3
         bmi  pfa_scij        ; P < -3 -> scientific
         jmp  pfa_fixed
pfa_ppos:
         cmp  #9
         bcc  pfa_fixed       ; 0..8 -> fixed
pfa_scij: jmp  pfa_sci        ; trampoline (keeps branches in range)
pfa_fixed:
         lda  FTMP
         bmi  pfa_pfrac       ; -3..-1
         ; P >= 0: integer part is P+1 digits
         lda  FTMP
         clc
         adc  #1
         sta  DCNT
         ldx  #0
pfa_il:  cpx  DCNT
         beq  pfa_ifr
         cpx  #7
         bcs  pfa_iz
         lda  MTMP,x
         clc
         adc  #'0'
         jsr  PFPUT
         inx
         jmp  pfa_il
pfa_iz:  lda  #'0'
         jsr  PFPUT
         inx
         jmp  pfa_il
pfa_ifr: lda  DCNT
         cmp  #7
         bcs  pfa_end         ; no fraction
         ldx  #6              ; trim trailing zeros
pfa_ft:  lda  MTMP,x
         bne  pfa_fh
         dex
         cpx  DCNT
         bcs  pfa_ft
         jmp  pfa_end
pfa_fh:  stx  FTMP+1
         lda  #'.'
         jsr  PFPUT
         ldx  DCNT
pfa_fp:  lda  MTMP,x
         clc
         adc  #'0'
         jsr  PFPUT
         cpx  FTMP+1
         beq  pfa_end
         inx
         jmp  pfa_fp
pfa_end: rts

pfa_pfrac:                    ; 0.00..ddd  (P in -3..-1)
         lda  #'0'
         jsr  PFPUT
         lda  #'.'
         jsr  PFPUT
         lda  FTMP            ; leading zeros = -P - 1
         eor  #$FF
         clc
         adc  #1
         sec
         sbc  #1
         sta  DCNT
pfa_lz:  lda  DCNT
         beq  pfa_pd
         lda  #'0'
         jsr  PFPUT
         dec  DCNT
         jmp  pfa_lz
pfa_pd:  ldx  #6              ; trim trailing zeros
pfa_pt:  lda  MTMP,x
         bne  pfa_ph
         dex
         bpl  pfa_pt
         rts
pfa_ph:  stx  FTMP+1
         ldx  #0
pfa_pp:  lda  MTMP,x
         clc
         adc  #'0'
         jsr  PFPUT
         cpx  FTMP+1
         beq  pfa_pend
         inx
         jmp  pfa_pp
pfa_pend: rts

pfa_sci:                     ; d1.d2..d7E(+/-)PP
         lda  MTMP+0
         clc
         adc  #'0'
         jsr  PFPUT
         ldx  #6              ; trim trailing zeros of fraction
pfa_st:  lda  MTMP,x
         bne  pfa_sh
         dex
         cpx  #1
         bcs  pfa_st
         jmp  pfa_snf
pfa_sh:  stx  FTMP+1
         lda  #'.'
         jsr  PFPUT
         ldx  #1
pfa_sfp: lda  MTMP,x
         clc
         adc  #'0'
         jsr  PFPUT
         cpx  FTMP+1
         beq  pfa_snf
         inx
         jmp  pfa_sfp
pfa_snf: lda  #'E'
         jsr  PFPUT
         lda  FTMP
         bpl  pfa_spp
         lda  #'-'
         jsr  PFPUT
         lda  #0
         sec
         sbc  FTMP
         jmp  pfa_spv
pfa_spp: lda  #'+'
         jsr  PFPUT
         lda  FTMP
pfa_spv: ldx  #0              ; print A (<100) as two digits
pfa_stn: cmp  #10
         bcc  pfa_son
         sec
         sbc  #10
         inx
         jmp  pfa_stn
pfa_son: pha
         txa
         clc
         adc  #'0'
         jsr  PFPUT
         pla
         clc
         adc  #'0'
         jsr  PFPUT
         rts

; =============================================================================
;  Floating-point arithmetic:  FAC = ARG (op) FAC
; =============================================================================

; ---- copy helpers (FAC block $91-$98, ARG block $99-$A0 are 8 bytes each) ----
FAC_TO_ARG:
         ldx  #7
fta_lp:  lda  FSGN,x
         sta  ASGN,x
         dex
         bpl  fta_lp
         rts
ARG_TO_FAC:
         ldx  #7
atf_lp:  lda  ASGN,x
         sta  FSGN,x
         dex
         bpl  atf_lp
         rts
FSWAP:
         ldx  #7
fsw_lp:  lda  FSGN,x
         pha
         lda  ASGN,x
         sta  FSGN,x
         pla
         sta  ASGN,x
         dex
         bpl  fsw_lp
         rts

FAC_NEG:
         jsr  FM_ISZERO
         beq  fneg_x
         lda  FSGN
         eor  #$FF
         sta  FSGN
fneg_x:  rts

; ---- 48-bit mantissa primitives (FM, AM, MTMP are 6 bytes) ----
M6_ADD:                       ; FM += AM
         clc
         lda  FM
         adc  AM
         sta  FM
         lda  FM+1
         adc  AM+1
         sta  FM+1
         lda  FM+2
         adc  AM+2
         sta  FM+2
         lda  FM+3
         adc  AM+3
         sta  FM+3
         lda  FM+4
         adc  AM+4
         sta  FM+4
         lda  FM+5
         adc  AM+5
         sta  FM+5
         rts
M6_SUB:                       ; FM -= AM
         sec
         lda  FM
         sbc  AM
         sta  FM
         lda  FM+1
         sbc  AM+1
         sta  FM+1
         lda  FM+2
         sbc  AM+2
         sta  FM+2
         lda  FM+3
         sbc  AM+3
         sta  FM+3
         lda  FM+4
         sbc  AM+4
         sta  FM+4
         lda  FM+5
         sbc  AM+5
         sta  FM+5
         rts
M6_CMP:                       ; carry set if FM >= AM (unsigned 48-bit)
         lda  FM+5
         cmp  AM+5
         bne  m6c_x
         lda  FM+4
         cmp  AM+4
         bne  m6c_x
         lda  FM+3
         cmp  AM+3
         bne  m6c_x
         lda  FM+2
         cmp  AM+2
         bne  m6c_x
         lda  FM+1
         cmp  AM+1
         bne  m6c_x
         lda  FM
         cmp  AM
m6c_x:   rts

; FM += MTMP  (used by the multiply)
MADDT:   clc
         lda  FM
         adc  MTMP
         sta  FM
         lda  FM+1
         adc  MTMP+1
         sta  FM+1
         lda  FM+2
         adc  MTMP+2
         sta  FM+2
         lda  FM+3
         adc  MTMP+3
         sta  FM+3
         lda  FM+4
         adc  MTMP+4
         sta  FM+4
         lda  FM+5
         adc  MTMP+5
         sta  FM+5
         rts

; ---- FADD: FAC = ARG + FAC ----
FADD:    lda  AM               ; ARG zero -> FAC unchanged
         ora  AM+1
         ora  AM+2
         ora  AM+3
         ora  AM+4
         ora  AM+5
         bne  fadd_a
         rts
fadd_a:  jsr  FM_ISZERO        ; FAC zero -> FAC = ARG
         bne  fadd_b
         jmp  ARG_TO_FAC
fadd_b:  lda  FEXP             ; make FEXP <= AEXP (swap if greater)
         cmp  AEXP
         beq  fadd_al
         sec
         sbc  AEXP
         bvc  fadd_v
         eor  #$80
fadd_v:  bmi  fadd_al          ; FEXP < AEXP already
         jsr  FSWAP
fadd_al: lda  AEXP             ; diff = AEXP - FEXP  (>= 0)
         sec
         sbc  FEXP
         sta  DCNT
         cmp  #8               ; FAC negligible?
         bcc  fadd_sc
         jmp  ARG_TO_FAC
fadd_sc: lda  DCNT             ; scale FM down to ARG's exponent
         beq  fadd_cb
fadd_sd: jsr  FM_DIV10
         dec  DCNT
         bne  fadd_sd
fadd_cb: lda  AEXP
         sta  FEXP
         lda  FSGN
         cmp  ASGN
         bne  fadd_df
         jsr  M6_ADD           ; same sign: add magnitudes
         jmp  FNORM
fadd_df: jsr  M6_CMP           ; different signs: big - small
         bcs  fadd_big
         jsr  FSWAP            ; make FM the larger (sign follows)
fadd_big:jsr  M6_SUB
         jmp  FNORM

; ---- FSUB: FAC = ARG - FAC ----
FSUB:    jsr  FAC_NEG
         jmp  FADD

; ---- MUL_2424: FM(24) * AM(24) -> 48-bit in FM ----
MUL_2424:
         ldx  #5               ; MTMP = multiplicand (FM)
m24_cp:  lda  FM,x
         sta  MTMP,x
         dex
         bpl  m24_cp
         lda  #0               ; FM = 0 (accumulator)
         sta  FM
         sta  FM+1
         sta  FM+2
         sta  FM+3
         sta  FM+4
         sta  FM+5
         ldx  #24
m24_lp:  lsr  AM+2             ; multiplier bit -> carry
         ror  AM+1
         ror  AM
         bcc  m24_sk
         jsr  MADDT            ; FM += MTMP
m24_sk:  asl  MTMP             ; MTMP <<= 1
         rol  MTMP+1
         rol  MTMP+2
         rol  MTMP+3
         rol  MTMP+4
         rol  MTMP+5
         dex
         bne  m24_lp
         rts

; ---- FMUL: FAC = ARG * FAC ----
FMUL:    jsr  FM_ISZERO
         beq  fmul_z
         lda  AM
         ora  AM+1
         ora  AM+2
         ora  AM+3
         ora  AM+4
         ora  AM+5
         beq  fmul_z
         lda  FSGN             ; sign = FSGN eor ASGN
         eor  ASGN
         sta  FTMP+1
         lda  FEXP             ; exp = FEXP + AEXP
         clc
         adc  AEXP
         sta  FTMP
         jsr  MUL_2424
         lda  FTMP
         sta  FEXP
         lda  FTMP+1
         sta  FSGN
         jmp  FNORM
fmul_z:  jmp  FAC_ZERO

; ---- DIV_48_24: FM(48) / MTMP2(24) -> quotient in FM ----
DIV_48_24:
         lda  #0               ; remainder in AM (32-bit)
         sta  AM
         sta  AM+1
         sta  AM+2
         sta  AM+3
         ldx  #48
d48_lp:  asl  FM
         rol  FM+1
         rol  FM+2
         rol  FM+3
         rol  FM+4
         rol  FM+5
         rol  AM
         rol  AM+1
         rol  AM+2
         rol  AM+3
         lda  AM+3
         bne  d48_sub
         lda  AM+2
         cmp  MTMP2+2
         bcc  d48_no
         bne  d48_sub
         lda  AM+1
         cmp  MTMP2+1
         bcc  d48_no
         bne  d48_sub
         lda  AM
         cmp  MTMP2
         bcc  d48_no
d48_sub: sec
         lda  AM
         sbc  MTMP2
         sta  AM
         lda  AM+1
         sbc  MTMP2+1
         sta  AM+1
         lda  AM+2
         sbc  MTMP2+2
         sta  AM+2
         lda  AM+3
         sbc  #0
         sta  AM+3
         inc  FM
d48_no:  dex
         bne  d48_lp
         rts

; ---- FDIV: FAC = ARG / FAC  (divisor = FAC, dividend = ARG) ----
FDIV:    jsr  FM_ISZERO        ; divide by zero -> 0
         beq  fdiv_z
         lda  AM
         ora  AM+1
         ora  AM+2
         ora  AM+3
         ora  AM+4
         ora  AM+5
         beq  fdiv_z
         lda  FSGN             ; result sign
         eor  ASGN
         sta  FTMP+1
         lda  AEXP             ; result exp = AEXP - FEXP - 7
         sec
         sbc  FEXP
         sec
         sbc  #7
         sta  FTMP
         ldx  #5               ; MTMP2 = divisor (FM)
fdv_cd:  lda  FM,x
         sta  MTMP2,x
         dex
         bpl  fdv_cd
         ldx  #5               ; FM = dividend (AM)
fdv_cn:  lda  AM,x
         sta  FM,x
         dex
         bpl  fdv_cn
         lda  #7               ; scale dividend up by 10^7
         sta  DCNT
fdv_sc:  jsr  FM_MUL10
         dec  DCNT
         bne  fdv_sc
         jsr  DIV_48_24
         lda  FTMP
         sta  FEXP
         lda  FTMP+1
         sta  FSGN
         jmp  FNORM
fdiv_z:  jmp  FAC_ZERO

; ---- FTRUE: FAC = -1  (boolean true) ----
FTRUE:   lda  #1
         sta  AR
         lda  #0
         sta  AR+1
         jsr  INT_TO_FAC
         lda  #$FF
         sta  FSGN
         rts

; ---- variable slots: 5 packed bytes each at VARS + (letter-'A')*5 ----
VOFF:    sec                  ; A = letter -> X = (letter-'A')*5
         sbc  #'A'
         sta  FTMP
         asl  A
         asl  A
         clc
         adc  FTMP
         tax
         rts
VLOAD:   lda  VARS,x          ; X = slot offset -> FAC
         sta  FSGN
         lda  VARS+1,x
         sta  FEXP
         lda  VARS+2,x
         sta  FM
         lda  VARS+3,x
         sta  FM+1
         lda  VARS+4,x
         sta  FM+2
         lda  #0
         sta  FM+3
         sta  FM+4
         sta  FM+5
         rts
VSTORE:  lda  FSGN            ; X = slot offset <- FAC
         sta  VARS,x
         lda  FEXP
         sta  VARS+1,x
         lda  FM
         sta  VARS+2,x
         lda  FM+1
         sta  VARS+3,x
         lda  FM+2
         sta  VARS+4,x
         rts

; ---- FAC_TO_INT: FAC -> AR (signed 16-bit, truncate toward zero) ----
FAC_TO_INT:
         jsr  FM_ISZERO
         bne  fti_nz
         lda  #0
         sta  AR
         sta  AR+1
         rts
fti_nz:  lda  FEXP             ; DCNT (not FTMP) survives FM_MUL10/FM_DIV10
         sta  DCNT
fti_up:  lda  DCNT
         bmi  fti_dn
         beq  fti_ok
         jsr  FM_MUL10
         dec  DCNT
         jmp  fti_up
fti_dn:  jsr  FM_DIV10
         inc  DCNT
         lda  DCNT
         bne  fti_dn
fti_ok:  lda  FM
         sta  AR
         lda  FM+1
         sta  AR+1
         lda  FSGN
         beq  fti_x
         lda  #0
         sec
         sbc  AR
         sta  AR
         lda  #0
         sbc  AR+1
         sta  AR+1
fti_x:   rts

; ---- FAC_ZERO: set FAC to 0 ----
FAC_ZERO:
         lda  #0
         sta  FM
         sta  FM+1
         sta  FM+2
         sta  FM+3
         sta  FM+4
         sta  FM+5
         sta  FEXP
         sta  FSGN
         rts

; ---- float value stack (FSTACK, 8 entries x 5 bytes; ESTKP = depth) ----
FPUSH:   lda  ESTKP
         asl  A
         asl  A
         clc
         adc  ESTKP           ; ESTKP * 5
         tax
         lda  FSGN
         sta  FSTACK,x
         lda  FEXP
         sta  FSTACK+1,x
         lda  FM
         sta  FSTACK+2,x
         lda  FM+1
         sta  FSTACK+3,x
         lda  FM+2
         sta  FSTACK+4,x
         inc  ESTKP
         rts
FPOP:    dec  ESTKP
         lda  ESTKP
         asl  A
         asl  A
         clc
         adc  ESTKP
         tax
         lda  FSTACK,x
         sta  ASGN
         lda  FSTACK+1,x
         sta  AEXP
         lda  FSTACK+2,x
         sta  AM
         lda  FSTACK+3,x
         sta  AM+1
         lda  FSTACK+4,x
         sta  AM+2
         lda  #0
         sta  AM+3
         sta  AM+4
         sta  AM+5
         rts

; =============================================================================
;  String data
; =============================================================================
s_banner:
         .asc "Float BASIC  (CC0 1.0)"
         .byte 13, 10, 0

s_syntax:
         .asc "?SYNTAX ERROR"
         .byte 13, 10, 0

s_subscr:
         .asc "?BAD SUBSCRIPT"
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

s_ooo:
         .asc "?OUT OF DATA"
         .byte 13, 10, 0

s_help:
         .asc "MS-style BASIC:"
         .byte 13, 10
         .asc "  LET v=e / a(i)=e / a$=str / DIM a(n)"
         .byte 13, 10
         .asc "  PRINT e,e;.. (, tab ; join)  INPUT 'p',v"
         .byte 13, 10
         .asc "  IF e THEN (n | stmt)   ON e GOTO/GOSUB n,.."
         .byte 13, 10
         .asc "  FOR v=a TO b [STEP s]..NEXT  GOSUB n..RETURN"
         .byte 13, 10
         .asc "  DATA n,..  READ v,..  RESTORE"
         .byte 13, 10
         .asc "  num: ABS SGN RND LEN ASC VAL"
         .byte 13, 10
         .asc "  str: CHR$ STR$ LEFT$ RIGHT$ MID$  + joins"
         .byte 13, 10
         .asc "  ops: + - * /  < > = <> <= >=  AND OR NOT"
         .byte 13, 10
         .asc "  ':' joins stmts.  RUN LIST NEW END REM MON"
         .byte 13, 10, 0

; =============================================================================
;  Vectors
; =============================================================================
         .org $FFFA
         .word RESET          ; NMI
         .word RESET          ; RESET
         .word RESET          ; IRQ/BRK
