# fam1.S — second-stage bootstrap assembler
#
# Input grammar (read from UART, terminated by EOT = 0x04):
#   XX              emit one hex byte (pairs of adjacent hex digits)
#   # ... \n        comment, skipped
#   whitespace      ignored
#   :NAME           define 4-char label NAME at current output offset
#   @NAME           fix up previous 4 bytes: patch the B-type (0x63) or
#                   J-type (0x6F) immediate to point to NAME
#
# Labels are exactly 4 ASCII chars (the four bytes after : or @ are taken
# literally from the stream, so no whitespace between : / @ and the name).
#
# Output: resolved binary stream to UART, then QEMU poweroff.
#
# Register convention:
#   s5 = UART base (0x10000000)     s6 = 10 ('\n')
#   s1 = output buffer base         s2 = output write ptr
#   s3 = symbol table base          s4 = symbol write ptr
#   s7 = fixup table base           s8 = fixup write ptr
#   s9 = comment flag
#   t1 = current input char         (other t/a regs = scratch)

# ---- Init ----
    li      s6, 10
    lui     s5, 0x10000
    auipc   t0, 0
    lui     t2, 1
    add     s1, t0, t2                  # output buf base  = PC+0x1000
    mv      s2, s1
    lui     t2, 3
    add     s3, t0, t2                  # symbol tbl base  = PC+0x3000
    mv      s4, s3
    lui     t2, 5
    add     s7, t0, t2                  # fixup tbl base   = PC+0x5000
    mv      s8, s7
    li      s9, 0                       # comment flag

# ---- Main read loop ----
main:
    jal     ra, rdch
    li      t3, 4                       # EOT?
    beq     t1, t3, finish

    beqz    s9, notcmt                  # if in comment, look for '\n'
    bne     t1, s6, main
    li      s9, 0
    j       main
notcmt:
    li      t3, 0x23                    # '#'
    bne     t1, t3, nothash
    li      s9, 1
    j       main
nothash:
    li      t3, 0x3A                    # ':'
    bne     t1, t3, notcolon
    # Read 4-byte label name, write to symbol table entry
    jal     ra, rdch
    sb      t1, 0(s4)
    jal     ra, rdch
    sb      t1, 1(s4)
    jal     ra, rdch
    sb      t1, 2(s4)
    jal     ra, rdch
    sb      t1, 3(s4)
    sub     t2, s2, s1
    sw      t2, 4(s4)
    addi    s4, s4, 8
    j       main
notcolon:
    li      t3, 0x40                    # '@'
    bne     t1, t3, notat
    # Read 4-byte label name, write to fixup table entry
    jal     ra, rdch
    sb      t1, 0(s8)
    jal     ra, rdch
    sb      t1, 1(s8)
    jal     ra, rdch
    sb      t1, 2(s8)
    jal     ra, rdch
    sb      t1, 3(s8)
    sub     t2, s2, s1
    addi    t2, t2, -4                  # patch previous 4-byte word
    sw      t2, 4(s8)
    addi    s8, s8, 8
    j       main
notat:
    li      t3, 33
    blt     t1, t3, main                # whitespace/control: ignore

    # Hex digit (high nibble)
    addi    t1, t1, -48
    bltu    t1, s6, hi_ok
    addi    t1, t1, -7
    li      t3, 16
    bltu    t1, t3, hi_ok
    j       main                        # invalid: skip
hi_ok:
    slli    t4, t1, 4
    jal     ra, rdch
    addi    t1, t1, -48
    bltu    t1, s6, lo_ok
    addi    t1, t1, -7
    li      t3, 16
    bltu    t1, t3, lo_ok
    j       main                        # invalid low: drop byte
lo_ok:
    or      t4, t4, t1
    sb      t4, 0(s2)
    addi    s2, s2, 1
    j       main

# ---- Read one char from UART (returns in t1) ----
rdch:
    lbu     t5, 5(s5)
    andi    t5, t5, 1
    beqz    t5, rdch
    lbu     t1, 0(s5)
    jalr    x0, 0(ra)

# ---- Finish: resolve all fixups, then dump output ----
finish:
    mv      t0, s7
fixup_lp:
    beq     t0, s8, dump
    lw      a4, 0(t0)                   # fixup label name (as word)
    lw      a5, 4(t0)                   # patch offset
    # Linear-scan symbol table
    mv      a6, s3
sym_lp:
    beq     a6, s4, fx_next             # not found -> skip
    lw      a7, 0(a6)
    beq     a7, a4, sym_hit
    addi    a6, a6, 8
    j       sym_lp
sym_hit:
    lw      t1, 4(a6)                   # label's output offset
    sub     t1, t1, a5                  # imm = label_off - patch_off
    # Load 4-byte instruction at output[patch_off]
    add     a3, s1, a5
    lw      t2, 0(a3)
    andi    t3, t2, 0x7F                # opcode
    li      t6, 0x6F
    beq     t3, t6, enc_j
    li      t6, 0x63
    beq     t3, t6, enc_b
    j       fx_next                     # unknown opcode: skip

# ---- B-type re-encoding: clear imm bits, OR in new layout ----
enc_b:
    # keep mask = 0x01FFF07F  (clear bits 31, 30:25, 11:8, 7)
    lui     t4, 0x01FFF
    addi    t4, t4, 0x07F
    and     t2, t2, t4
    # imm[12] -> inst[31]
    srli    t5, t1, 12
    andi    t5, t5, 1
    slli    t5, t5, 31
    or      t2, t2, t5
    # imm[10:5] -> inst[30:25]
    srli    t5, t1, 5
    andi    t5, t5, 0x3F
    slli    t5, t5, 25
    or      t2, t2, t5
    # imm[4:1] -> inst[11:8]
    srli    t5, t1, 1
    andi    t5, t5, 0xF
    slli    t5, t5, 8
    or      t2, t2, t5
    # imm[11] -> inst[7]
    srli    t5, t1, 11
    andi    t5, t5, 1
    slli    t5, t5, 7
    or      t2, t2, t5
    sw      t2, 0(a3)
    j       fx_next

# ---- J-type re-encoding ----
enc_j:
    # keep mask = 0x00000FFF  (clear bits 31:12)
    lui     t4, 1
    addi    t4, t4, -1
    and     t2, t2, t4
    # imm[20] -> inst[31]
    srli    t5, t1, 20
    andi    t5, t5, 1
    slli    t5, t5, 31
    or      t2, t2, t5
    # imm[10:1] -> inst[30:21]
    srli    t5, t1, 1
    li      t6, 0x3FF
    and     t5, t5, t6
    slli    t5, t5, 21
    or      t2, t2, t5
    # imm[11] -> inst[20]
    srli    t5, t1, 11
    andi    t5, t5, 1
    slli    t5, t5, 20
    or      t2, t2, t5
    # imm[19:12] -> inst[19:12]
    srli    t5, t1, 12
    andi    t5, t5, 0xFF
    slli    t5, t5, 12
    or      t2, t2, t5
    sw      t2, 0(a3)
    j       fx_next

fx_next:
    addi    t0, t0, 8
    j       fixup_lp

# ---- Dump output buffer to UART ----
dump:
    mv      a0, s1
dump_lp:
    beq     a0, s2, powoff
    lbu     t3, 0(a0)
    addi    a0, a0, 1
tx_wt:
    lbu     t1, 5(s5)
    andi    t1, t1, 32
    beqz    t1, tx_wt
    sb      t3, 0(s5)
    j       dump_lp

# ---- QEMU virt poweroff ----
powoff:
    lui     s5, 0x100
    lui     t1, 5
    addi    t1, t1, 0x555
    sw      t1, 0(s5)
