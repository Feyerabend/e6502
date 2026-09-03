-m mod -x "ei 0800 A9 41 8D 01 F0 AD 00 20 20 10 08 8D FF F0; ei 0810 60; zero; g 800; stats; q"
# Census of bus access kinds for a hand-assembled six-instruction program:
#   $0800  LDA #$41      1 opcode + 1 operand byte
#   $0802  STA $F001     1 opcode + 2 operand + 1 uncached store
#   $0805  LDA $2000     1 opcode + 2 operand + 1 data load
#   $0808  JSR $0810     1 opcode + 2 operand + 2 stack pushes
#   $0810  RTS           1 opcode           + 2 stack pulls
#   $080B  STA $F0FF     1 opcode + 2 operand + 1 uncached store (halt)
# Expect OPCODE=6 OPERAND=9 DATA=3 PTR=0 STACK=4 VECTOR=0, and 15 of the 18
# accesses on the instruction side.
