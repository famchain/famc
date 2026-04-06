# MIT License
#
# Copyright (c) 2026 Christopher Gilliard
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# fam2.S — RV32I mnemonic assembler (third-stage bootstrap).
#
# Reads text from UART (terminated by EOT = 0x04), emits a RISC-V binary
# back over UART, then poweroffs.
#
# Grammar:
#   # ... \n                    comment (to end of line)
#   whitespace / comma          token separators (interchangeable)
#   name:                       label definition (name <= 16 ASCII chars,
#                               [A-Za-z_][A-Za-z0-9_]*)
#   XX                          passthrough hex byte (exactly two hex digits)
#   mnemonic operands           RV32I instruction or pseudo
#
# Supported mnemonics (RV32I base):
#   add sub and or xor sll srl sra slt sltu
#   addi andi ori xori slti sltiu slli srli srai
#   lb lh lw lbu lhu
#   sb sh sw
#   beq bne blt bge bltu bgeu
#   jal jalr lui auipc
# Pseudos:
#   li mv j ret beqz bnez
#
# Operands:
#   registers:   x0..x31 or ABI (zero, ra, sp, gp, tp, t0-t6, s0-s11, fp, a0-a7)
#   immediates:  decimal (-42) or 0xHEX
#   memory:      imm(rs)
#   branch tgt:  label name OR numeric offset
#
# Fixups: label references are only valid in B-type and J-type target slots.
# They are recorded in a fixup table and resolved after EOT (same mechanism
# as fam1). Labels may be defined before or after first reference.
#
# Register convention:
#   s0  = token length          s1  = output buf base
#   s2  = output write ptr      s3  = symtab base
#   s4  = symtab write ptr      s5  = UART base (0x10000000)
#   s6  = 10 (constant)         s7  = fixup base
#   s8  = fixup write ptr       s9  = mnem_table base
#   s10 = token buf base        s11 = reg_table base
#   sp  = descending stack      t0-t6, a0-a7, ra = scratch
#
# Memory layout (relative to auipc at init):
#   +0x01000   output buffer (60 KB headroom)
#   +0x10000   symtab (20-byte entries: 16-byte padded name + 4-byte offset)
#   +0x20000   fixup tab (same layout)
#   +0x30000   token buffer (32 bytes, zero-padded)
#   +0x40000   stack top
#
# Calling convention inside this program:
#   - args in a0..a7, returns in a0 (and a1 for two-value returns)
#   - s-regs are global invariants; subroutines must not clobber them
#   - nested-call functions save/restore ra on stack

# ============================================================================
# Entry + static tables
# ============================================================================

_start:
    jal     t0, after_mnem_tab          # t0 = &mnem_table (byte after jal)
mnem_table:
    # Each entry: 8-byte padded name + class[1] + f3[1] + f7[1] + pad[1] = 12B
    # Classes: 1=R, 2=I_arith, 3=I_shift, 4=I_load, 5=S, 6=B,
    #          7=U_lui, 8=U_auipc, 9=J_jal, 10=I_jalr,
    #          11=ps_li, 12=ps_mv, 13=ps_j, 14=ps_ret, 15=ps_beqz, 16=ps_bnez
    .ascii "add";    .zero 5;  .byte 1, 0, 0x00, 0
    .ascii "sub";    .zero 5;  .byte 1, 0, 0x20, 0
    .ascii "sll";    .zero 5;  .byte 1, 1, 0x00, 0
    .ascii "slt";    .zero 5;  .byte 1, 2, 0x00, 0
    .ascii "sltu";   .zero 4;  .byte 1, 3, 0x00, 0
    .ascii "xor";    .zero 5;  .byte 1, 4, 0x00, 0
    .ascii "srl";    .zero 5;  .byte 1, 5, 0x00, 0
    .ascii "sra";    .zero 5;  .byte 1, 5, 0x20, 0
    .ascii "or";     .zero 6;  .byte 1, 6, 0x00, 0
    .ascii "and";    .zero 5;  .byte 1, 7, 0x00, 0
    .ascii "addi";   .zero 4;  .byte 2, 0, 0, 0
    .ascii "slti";   .zero 4;  .byte 2, 2, 0, 0
    .ascii "sltiu";  .zero 3;  .byte 2, 3, 0, 0
    .ascii "xori";   .zero 4;  .byte 2, 4, 0, 0
    .ascii "ori";    .zero 5;  .byte 2, 6, 0, 0
    .ascii "andi";   .zero 4;  .byte 2, 7, 0, 0
    .ascii "slli";   .zero 4;  .byte 3, 1, 0x00, 0
    .ascii "srli";   .zero 4;  .byte 3, 5, 0x00, 0
    .ascii "srai";   .zero 4;  .byte 3, 5, 0x20, 0
    .ascii "lb";     .zero 6;  .byte 4, 0, 0, 0
    .ascii "lh";     .zero 6;  .byte 4, 1, 0, 0
    .ascii "lw";     .zero 6;  .byte 4, 2, 0, 0
    .ascii "lbu";    .zero 5;  .byte 4, 4, 0, 0
    .ascii "lhu";    .zero 5;  .byte 4, 5, 0, 0
    .ascii "sb";     .zero 6;  .byte 5, 0, 0, 0
    .ascii "sh";     .zero 6;  .byte 5, 1, 0, 0
    .ascii "sw";     .zero 6;  .byte 5, 2, 0, 0
    .ascii "beq";    .zero 5;  .byte 6, 0, 0, 0
    .ascii "bne";    .zero 5;  .byte 6, 1, 0, 0
    .ascii "blt";    .zero 5;  .byte 6, 4, 0, 0
    .ascii "bge";    .zero 5;  .byte 6, 5, 0, 0
    .ascii "bltu";   .zero 4;  .byte 6, 6, 0, 0
    .ascii "bgeu";   .zero 4;  .byte 6, 7, 0, 0
    .ascii "lui";    .zero 5;  .byte 7, 0, 0, 0
    .ascii "auipc";  .zero 3;  .byte 8, 0, 0, 0
    .ascii "jal";    .zero 5;  .byte 9, 0, 0, 0
    .ascii "jalr";   .zero 4;  .byte 10, 0, 0, 0
    .ascii "li";     .zero 6;  .byte 11, 0, 0, 0
    .ascii "mv";     .zero 6;  .byte 12, 0, 0, 0
    .ascii "j";      .zero 7;  .byte 13, 0, 0, 0
    .ascii "ret";    .zero 5;  .byte 14, 0, 0, 0
    .ascii "beqz";   .zero 4;  .byte 15, 0, 0, 0
    .ascii "bnez";   .zero 4;  .byte 16, 0, 0, 0
    .zero 12                                 # terminator (name starts with 0)
after_mnem_tab:

    jal     t1, after_reg_tab           # t1 = &reg_table
reg_table:
    # Each entry: 4-byte padded name + 4-byte reg number (LE) = 8 bytes
    .ascii "zero";            .byte 0, 0, 0, 0
    .ascii "ra";   .zero 2;   .byte 1, 0, 0, 0
    .ascii "sp";   .zero 2;   .byte 2, 0, 0, 0
    .ascii "gp";   .zero 2;   .byte 3, 0, 0, 0
    .ascii "tp";   .zero 2;   .byte 4, 0, 0, 0
    .ascii "t0";   .zero 2;   .byte 5, 0, 0, 0
    .ascii "t1";   .zero 2;   .byte 6, 0, 0, 0
    .ascii "t2";   .zero 2;   .byte 7, 0, 0, 0
    .ascii "s0";   .zero 2;   .byte 8, 0, 0, 0
    .ascii "fp";   .zero 2;   .byte 8, 0, 0, 0
    .ascii "s1";   .zero 2;   .byte 9, 0, 0, 0
    .ascii "a0";   .zero 2;   .byte 10, 0, 0, 0
    .ascii "a1";   .zero 2;   .byte 11, 0, 0, 0
    .ascii "a2";   .zero 2;   .byte 12, 0, 0, 0
    .ascii "a3";   .zero 2;   .byte 13, 0, 0, 0
    .ascii "a4";   .zero 2;   .byte 14, 0, 0, 0
    .ascii "a5";   .zero 2;   .byte 15, 0, 0, 0
    .ascii "a6";   .zero 2;   .byte 16, 0, 0, 0
    .ascii "a7";   .zero 2;   .byte 17, 0, 0, 0
    .ascii "s2";   .zero 2;   .byte 18, 0, 0, 0
    .ascii "s3";   .zero 2;   .byte 19, 0, 0, 0
    .ascii "s4";   .zero 2;   .byte 20, 0, 0, 0
    .ascii "s5";   .zero 2;   .byte 21, 0, 0, 0
    .ascii "s6";   .zero 2;   .byte 22, 0, 0, 0
    .ascii "s7";   .zero 2;   .byte 23, 0, 0, 0
    .ascii "s8";   .zero 2;   .byte 24, 0, 0, 0
    .ascii "s9";   .zero 2;   .byte 25, 0, 0, 0
    .ascii "s10";  .zero 1;   .byte 26, 0, 0, 0
    .ascii "s11";  .zero 1;   .byte 27, 0, 0, 0
    .ascii "t3";   .zero 2;   .byte 28, 0, 0, 0
    .ascii "t4";   .zero 2;   .byte 29, 0, 0, 0
    .ascii "t5";   .zero 2;   .byte 30, 0, 0, 0
    .ascii "t6";   .zero 2;   .byte 31, 0, 0, 0
    .zero 8                                 # terminator
after_reg_tab:

# ============================================================================
# Init
# ============================================================================

    mv      s9, t0                      # mnem_table base
    mv      s11, t1                     # reg_table base
    li      s6, 10
    lui     s5, 0x10000                 # UART base
    auipc   a0, 0                       # a0 = PC base for data regions
    lui     t2, 1
    add     s1, a0, t2                  # output buf  = PC + 0x1000
    mv      s2, s1
    lui     t2, 0x10
    add     s3, a0, t2                  # symtab      = PC + 0x10000
    mv      s4, s3
    lui     t2, 0x20
    add     s7, a0, t2                  # fixup tab   = PC + 0x20000
    mv      s8, s7
    lui     t2, 0x30
    add     s10, a0, t2                 # token buf   = PC + 0x30000
    sb      x0, 32(s10)                 # sticky EOT flag at token_buf+32
    lui     t2, 0x40
    add     sp, a0, t2                  # stack top   = PC + 0x40000
    j       main_loop

# ============================================================================
# Main loop
# ============================================================================

main_loop:
    jal     ra, read_token
    # s0 = token length. Sticky EOT flag at 32(s10) (set by read_token).
    beqz    s0, ml_post

    # Check if last char is ':' → label definition
    add     t0, s10, s0
    lbu     t1, -1(t0)
    li      t2, 0x3A
    beq     t1, t2, ml_label

    # Check passthrough hex: len==2 AND both chars hex
    li      t2, 2
    bne     s0, t2, ml_mnem
    lbu     t1, 0(s10)
    jal     ra, hex_val
    li      t2, -1
    beq     a0, t2, ml_mnem
    mv      t3, a0                      # hi nibble
    lbu     t1, 1(s10)
    jal     ra, hex_val
    li      t2, -1
    beq     a0, t2, ml_mnem
    slli    t3, t3, 4
    or      t3, t3, a0
    sb      t3, 0(s2)
    addi    s2, s2, 1
    j       ml_post

ml_label:
    jal     ra, define_label
    j       ml_post

ml_mnem:
    jal     ra, find_mnem
    li      t0, -1
    beq     a0, t0, halt_err
    jal     ra, dispatch

ml_post:
    lbu     t0, 32(s10)
    bnez    t0, finish_all
    j       main_loop

# ============================================================================
# Finish: fixup pass + dump + poweroff
# ============================================================================

finish_all:
    jal     ra, fixup_pass
    jal     ra, dump_output
    # fall through to powoff
powoff:
    lui     s5, 0x100
    lui     t0, 5
    addi    t0, t0, 0x555
    sw      t0, 0(s5)
powoff_hang:
    j       powoff_hang

halt_err:
    lui     s5, 0x100
    lui     t0, 5
    addi    t0, t0, 0x555
    sw      t0, 0(s5)
halt_err_hang:
    j       halt_err_hang

# ============================================================================
# UART primitives
# ============================================================================

rdch:
    # No saves. Reads one char into t1.
    lbu     t5, 5(s5)
    andi    t5, t5, 1
    beqz    t5, rdch
    lbu     t1, 0(s5)
    ret

wrch:
    # Input: t0 = byte. No saves.
    lbu     t5, 5(s5)
    andi    t5, t5, 0x20
    beqz    t5, wrch
    sb      t0, 0(s5)
    ret

# ============================================================================
# read_token: reads the next whitespace/comma-delimited token.
# On entry: nothing.
# On exit: s0 = token length (0..31), a0 = 1 if EOT seen else 0.
# Token bytes in buffer at s10, zero-padded to 32 bytes.
# Halts if token length would exceed 31.
# ============================================================================

read_token:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    li      s0, 0
    # Zero token buffer
    mv      t0, s10
    addi    t2, s10, 32
rt_zero:
    sb      x0, 0(t0)
    addi    t0, t0, 1
    bne     t0, t2, rt_zero
rt_skip:
    jal     ra, rdch
    li      t0, 4
    beq     t1, t0, rt_eot
    li      t0, 0x23                    # '#'
    bne     t1, t0, rt_skip_not_hash
rt_com:
    jal     ra, rdch
    li      t0, 4
    beq     t1, t0, rt_eot
    bne     t1, s6, rt_com
    j       rt_skip
rt_skip_not_hash:
    li      t0, 0x2C                    # ','
    beq     t1, t0, rt_skip
    li      t0, 33
    blt     t1, t0, rt_skip             # whitespace/control
rt_collect:
    add     t0, s10, s0
    sb      t1, 0(t0)
    addi    s0, s0, 1
    li      t0, 32
    bge     s0, t0, halt_err
    jal     ra, rdch
    li      t0, 4
    beq     t1, t0, rt_eot
    li      t0, 0x23
    beq     t1, t0, rt_com_post
    li      t0, 0x2C
    beq     t1, t0, rt_done
    li      t0, 33
    blt     t1, t0, rt_done
    j       rt_collect
rt_com_post:
    jal     ra, rdch
    li      t0, 4
    beq     t1, t0, rt_eot
    bne     t1, s6, rt_com_post
    j       rt_done
rt_eot:
    li      t0, 1
    sb      t0, 32(s10)                 # set sticky EOT flag
rt_done:
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

# ============================================================================
# hex_val: t1 = char → a0 = 0..15 or -1
# ============================================================================

hex_val:
    li      t0, 48                      # '0'
    blt     t1, t0, hv_bad
    li      t0, 58                      # '9'+1
    blt     t1, t0, hv_dig
    li      t0, 65                      # 'A'
    blt     t1, t0, hv_bad
    li      t0, 71                      # 'F'+1
    blt     t1, t0, hv_upr
    li      t0, 97                      # 'a'
    blt     t1, t0, hv_bad
    li      t0, 103                     # 'f'+1
    blt     t1, t0, hv_lwr
hv_bad:
    li      a0, -1
    ret
hv_dig:
    addi    a0, t1, -48
    ret
hv_upr:
    addi    a0, t1, -55
    ret
hv_lwr:
    addi    a0, t1, -87
    ret

# ============================================================================
# find_mnem: token in buf at s10 (zero-padded).
# Returns: a0 = class, a1 = f3, a2 = f7, or a0 = -1 if not found.
# ============================================================================

find_mnem:
    mv      t0, s9
fm_next:
    lbu     t1, 0(t0)
    beqz    t1, fm_notfound
    mv      t2, s10
    mv      t3, t0
    li      t4, 8
fm_cmp:
    lbu     t5, 0(t2)
    lbu     t6, 0(t3)
    bne     t5, t6, fm_skip
    addi    t2, t2, 1
    addi    t3, t3, 1
    addi    t4, t4, -1
    bnez    t4, fm_cmp
    lbu     a0, 8(t0)
    lbu     a1, 9(t0)
    lbu     a2, 10(t0)
    ret
fm_skip:
    addi    t0, t0, 12
    j       fm_next
fm_notfound:
    li      a0, -1
    ret

# ============================================================================
# parse_reg: a0 = ptr, a1 = len → a0 = reg num (0..31) or -1
# ============================================================================

parse_reg:
    mv      t0, a0
    mv      t1, a1
    beqz    t1, pr_bad
    lbu     t2, 0(t0)
    li      t3, 120                     # 'x'
    bne     t2, t3, pr_abi
    # xN form: length 2 or 3
    li      t3, 2
    beq     t1, t3, pr_x1
    li      t3, 3
    beq     t1, t3, pr_x2
    j       pr_bad
pr_x1:
    lbu     t2, 1(t0)
    addi    t2, t2, -48
    bltz    t2, pr_bad
    li      t3, 10
    bge     t2, t3, pr_bad
    mv      a0, t2
    ret
pr_x2:
    lbu     t2, 1(t0)
    addi    t2, t2, -48
    bltz    t2, pr_bad
    li      t3, 10
    bge     t2, t3, pr_bad
    lbu     t4, 2(t0)
    addi    t4, t4, -48
    bltz    t4, pr_bad
    bge     t4, t3, pr_bad
    slli    t5, t2, 3
    slli    t6, t2, 1
    add     t5, t5, t6
    add     a0, t5, t4
    li      t3, 32
    bge     a0, t3, pr_bad
    ret
pr_abi:
    # ABI names are 2-4 chars. Longer input can't match.
    li      t2, 5
    bge     t1, t2, pr_bad
    beqz    t1, pr_bad
    mv      t2, s11
pr_a_next:
    lbu     t3, 0(t2)
    beqz    t3, pr_bad
    mv      t4, t0
    mv      t5, t2
    mv      t6, t1                      # remaining len
pr_a_cmp:
    lbu     a0, 0(t4)
    lbu     a2, 0(t5)
    bne     a0, a2, pr_a_skip
    addi    t4, t4, 1
    addi    t5, t5, 1
    addi    t6, t6, -1
    bnez    t6, pr_a_cmp
    # Matched first `t1` bytes. Now ensure entry bytes at positions t1..3 are null.
    li      t6, 4
    sub     t6, t6, t1
    beqz    t6, pr_a_found
pr_a_padchk:
    lbu     a0, 0(t5)
    bnez    a0, pr_a_skip
    addi    t5, t5, 1
    addi    t6, t6, -1
    bnez    t6, pr_a_padchk
pr_a_found:
    lbu     a0, 4(t2)
    ret
pr_a_skip:
    addi    t2, t2, 8
    j       pr_a_next
pr_bad:
    li      a0, -1
    ret

# ============================================================================
# parse_imm: a0 = ptr, a1 = len → a0 = value, halts on error
# ============================================================================

parse_imm:
    mv      t0, a0
    mv      t1, a1
    li      t2, 1                       # sign
    beqz    t1, pi_bad
    lbu     t3, 0(t0)
    li      t4, 45                      # '-'
    bne     t3, t4, pi_maybe_plus
    li      t2, -1
    addi    t0, t0, 1
    addi    t1, t1, -1
    j       pi_after_sign
pi_maybe_plus:
    li      t4, 43                      # '+'
    bne     t3, t4, pi_after_sign
    addi    t0, t0, 1
    addi    t1, t1, -1
pi_after_sign:
    beqz    t1, pi_bad
    li      t4, 2
    blt     t1, t4, pi_decimal
    lbu     t3, 0(t0)
    li      t4, 48                      # '0'
    bne     t3, t4, pi_decimal
    lbu     t3, 1(t0)
    li      t4, 120                     # 'x'
    beq     t3, t4, pi_hex_begin
    li      t4, 88                      # 'X'
    bne     t3, t4, pi_decimal
pi_hex_begin:
    addi    t0, t0, 2
    addi    t1, t1, -2
    beqz    t1, pi_bad
    li      a0, 0
pi_hex_lp:
    beqz    t1, pi_done
    lbu     t3, 0(t0)
    addi    t4, t3, -48                 # try 0-9
    li      t5, 10
    blt     t4, t5, pi_h_ok
    addi    t4, t3, -55                 # try A-F
    li      t5, 10
    blt     t4, t5, pi_bad
    li      t5, 16
    blt     t4, t5, pi_h_ok
    addi    t4, t3, -87                 # try a-f
    li      t5, 10
    blt     t4, t5, pi_bad
    li      t5, 16
    blt     t4, t5, pi_h_ok
    j       pi_bad
pi_h_ok:
    slli    a0, a0, 4
    or      a0, a0, t4
    addi    t0, t0, 1
    addi    t1, t1, -1
    j       pi_hex_lp
pi_decimal:
    li      a0, 0
    beqz    t1, pi_bad
pi_dec_lp:
    beqz    t1, pi_done
    lbu     t3, 0(t0)
    addi    t3, t3, -48
    bltz    t3, pi_bad
    li      t4, 10
    bge     t3, t4, pi_bad
    slli    t4, a0, 3
    slli    t5, a0, 1
    add     t4, t4, t5
    add     a0, t4, t3
    addi    t0, t0, 1
    addi    t1, t1, -1
    j       pi_dec_lp
pi_done:
    li      t3, 1
    beq     t2, t3, pi_ret
    sub     a0, x0, a0
pi_ret:
    ret
pi_bad:
    j       halt_err

# ============================================================================
# parse_mem: a0 = ptr, a1 = len → a0 = imm, a1 = reg. Halts on error.
# Expects token of form imm(rs).
# ============================================================================

parse_mem:
    addi    sp, sp, -20
    sw      ra, 0(sp)
    sw      a0, 4(sp)
    sw      a1, 8(sp)
    mv      t0, a0
    mv      t1, a1
    li      t2, 0
    li      t3, 40                      # '('
pm_scan:
    bge     t2, t1, pm_bad
    add     t4, t0, t2
    lbu     t5, 0(t4)
    beq     t5, t3, pm_found
    addi    t2, t2, 1
    j       pm_scan
pm_found:
    sw      t2, 12(sp)
    mv      a0, t0
    mv      a1, t2
    jal     ra, parse_imm
    sw      a0, 16(sp)
    lw      t0, 4(sp)
    lw      t1, 8(sp)
    lw      t2, 12(sp)
    addi    t3, t1, -1
    add     t4, t0, t3
    lbu     t5, 0(t4)
    li      t6, 41                      # ')'
    bne     t5, t6, pm_bad
    add     a0, t0, t2
    addi    a0, a0, 1
    sub     a1, t1, t2
    addi    a1, a1, -2
    jal     ra, parse_reg
    li      t3, -1
    beq     a0, t3, pm_bad
    mv      a1, a0
    lw      a0, 16(sp)
    lw      ra, 0(sp)
    addi    sp, sp, 20
    ret
pm_bad:
    j       halt_err

# ============================================================================
# Operand readers: call read_token then parse
# ============================================================================

read_reg_op:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    jal     ra, read_token
    mv      a0, s10
    mv      a1, s0
    jal     ra, parse_reg
    li      t0, -1
    beq     a0, t0, halt_err
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

read_imm_op:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    jal     ra, read_token
    mv      a0, s10
    mv      a1, s0
    jal     ra, parse_imm
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

read_mem_op:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    jal     ra, read_token
    mv      a0, s10
    mv      a1, s0
    jal     ra, parse_mem
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

# read_br_target: read next token. If first char is letter/underscore, treat
# as label (record fixup at CURRENT output offset, return 0). Else parse as
# immediate. Returns offset in a0.
read_br_target:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    jal     ra, read_token
    lbu     t0, 0(s10)
    # Letter or underscore → label
    li      t1, 65                      # 'A'
    blt     t0, t1, rbt_imm
    li      t1, 91                      # 'Z'+1
    blt     t0, t1, rbt_label
    li      t1, 95                      # '_'
    beq     t0, t1, rbt_label
    li      t1, 97                      # 'a'
    blt     t0, t1, rbt_imm
    li      t1, 123                     # 'z'+1
    blt     t0, t1, rbt_label
rbt_imm:
    mv      a0, s10
    mv      a1, s0
    jal     ra, parse_imm
    j       rbt_done
rbt_label:
    # Length check (label name must fit in 16 bytes)
    li      t0, 17
    bge     s0, t0, halt_err
    sub     a0, s2, s1                  # patch_offset
    jal     ra, record_fixup
    li      a0, 0
rbt_done:
    lw      ra, 0(sp)
    addi    sp, sp, 4
    ret

# ============================================================================
# define_label: token "name:" in buf (length s0). Strip colon, check length,
# copy 16 bytes to symtab, append current output offset.
# ============================================================================

define_label:
    li      t0, 18                      # name len = s0-1, must be <= 16 → s0 <= 17
    bge     s0, t0, halt_err
    addi    t0, s0, -1                  # position of ':'
    add     t1, s10, t0
    sb      x0, 0(t1)                   # zero out the colon
    mv      t2, s10
    mv      t3, s4
    li      t4, 16
dl_cp:
    lbu     t5, 0(t2)
    sb      t5, 0(t3)
    addi    t2, t2, 1
    addi    t3, t3, 1
    addi    t4, t4, -1
    bnez    t4, dl_cp
    sub     t5, s2, s1
    sw      t5, 16(s4)
    addi    s4, s4, 20
    ret

# ============================================================================
# record_fixup: a0 = patch_offset. Copies 16-byte padded name from token buf
# (must already hold the label name) into fixup entry, appends patch_offset.
# ============================================================================

record_fixup:
    li      t0, 17
    bge     s0, t0, halt_err
    mv      t2, s10
    mv      t3, s8
    li      t4, 16
rf_cp:
    lbu     t5, 0(t2)
    sb      t5, 0(t3)
    addi    t2, t2, 1
    addi    t3, t3, 1
    addi    t4, t4, -1
    bnez    t4, rf_cp
    sw      a0, 16(s8)
    addi    s8, s8, 20
    ret

# ============================================================================
# emit_word: a0 = 32-bit word. Writes 4 bytes LE to output, advances s2.
# ============================================================================

emit_word:
    sb      a0, 0(s2)
    srli    a0, a0, 8
    sb      a0, 1(s2)
    srli    a0, a0, 8
    sb      a0, 2(s2)
    srli    a0, a0, 8
    sb      a0, 3(s2)
    addi    s2, s2, 4
    ret

# ============================================================================
# dispatch: a0 = class, a1 = f3, a2 = f7. Tail-calls appropriate handler.
# ============================================================================

dispatch:
    li      t0, 1
    beq     a0, t0, do_r
    li      t0, 2
    beq     a0, t0, do_i_arith
    li      t0, 3
    beq     a0, t0, do_i_shift
    li      t0, 4
    beq     a0, t0, do_i_load
    li      t0, 5
    beq     a0, t0, do_s
    li      t0, 6
    beq     a0, t0, do_b
    li      t0, 7
    beq     a0, t0, do_u_lui
    li      t0, 8
    beq     a0, t0, do_u_auipc
    li      t0, 9
    beq     a0, t0, do_j_jal
    li      t0, 10
    beq     a0, t0, do_i_jalr
    li      t0, 11
    beq     a0, t0, do_ps_li
    li      t0, 12
    beq     a0, t0, do_ps_mv
    li      t0, 13
    beq     a0, t0, do_ps_j
    li      t0, 14
    beq     a0, t0, do_ps_ret
    li      t0, 15
    beq     a0, t0, do_ps_beqz
    li      t0, 16
    beq     a0, t0, do_ps_bnez
    j       halt_err

# ============================================================================
# Encoder handlers.
# Each handler enters with a1=f3, a2=f7 (if relevant), ra = dispatch's caller.
# Each handler saves ra, reads operands, composes word, restores ra, then
# tail-calls emit_word which returns to dispatch's caller.
# ============================================================================

# do_r: rd, rs1, rs2 → (f7<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(rd<<7)|0x33
do_r:
    addi    sp, sp, -20
    sw      ra, 0(sp)
    sw      a1, 4(sp)                   # f3
    sw      a2, 8(sp)                   # f7
    jal     ra, read_reg_op
    sw      a0, 12(sp)                  # rd
    jal     ra, read_reg_op
    sw      a0, 16(sp)                  # rs1
    jal     ra, read_reg_op
    mv      t0, a0                      # rs2
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    lw      a2, 8(sp)
    lw      a3, 12(sp)
    lw      a4, 16(sp)
    addi    sp, sp, 20
    andi    a2, a2, 0x7F
    slli    t1, a2, 25
    andi    t0, t0, 0x1F
    slli    t2, t0, 20
    or      t1, t1, t2
    andi    a4, a4, 0x1F
    slli    t2, a4, 15
    or      t1, t1, t2
    andi    a1, a1, 7
    slli    t2, a1, 12
    or      t1, t1, t2
    andi    a3, a3, 0x1F
    slli    t2, a3, 7
    or      t1, t1, t2
    ori     t1, t1, 0x33
    mv      a0, t1
    j       emit_word

# do_i_arith: rd, rs1, imm → opcode 0x13
do_i_arith:
    addi    sp, sp, -16
    sw      ra, 0(sp)
    sw      a1, 4(sp)                   # f3
    jal     ra, read_reg_op
    sw      a0, 8(sp)                   # rd
    jal     ra, read_reg_op
    sw      a0, 12(sp)                  # rs1
    jal     ra, read_imm_op
    mv      t0, a0                      # imm
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    lw      a2, 8(sp)                   # rd
    lw      a3, 12(sp)                  # rs1
    addi    sp, sp, 16
    slli    t1, t0, 20                  # imm[11:0] → bits 31:20
    andi    a3, a3, 0x1F
    slli    t2, a3, 15
    or      t1, t1, t2
    andi    a1, a1, 7
    slli    t2, a1, 12
    or      t1, t1, t2
    andi    a2, a2, 0x1F
    slli    t2, a2, 7
    or      t1, t1, t2
    ori     t1, t1, 0x13
    mv      a0, t1
    j       emit_word

# do_i_shift: rd, rs1, shamt → opcode 0x13, imm = (f7<<5)|(shamt&0x1F)
do_i_shift:
    addi    sp, sp, -20
    sw      ra, 0(sp)
    sw      a1, 4(sp)                   # f3
    sw      a2, 8(sp)                   # f7
    jal     ra, read_reg_op
    sw      a0, 12(sp)                  # rd
    jal     ra, read_reg_op
    sw      a0, 16(sp)                  # rs1
    jal     ra, read_imm_op
    mv      t0, a0                      # shamt
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    lw      a2, 8(sp)
    lw      a3, 12(sp)
    lw      a4, 16(sp)
    addi    sp, sp, 20
    andi    t0, t0, 0x1F
    andi    a2, a2, 0x7F
    slli    t1, a2, 5
    or      t0, t0, t1                  # imm = (f7<<5) | shamt
    slli    t1, t0, 20
    andi    a4, a4, 0x1F
    slli    t2, a4, 15
    or      t1, t1, t2
    andi    a1, a1, 7
    slli    t2, a1, 12
    or      t1, t1, t2
    andi    a3, a3, 0x1F
    slli    t2, a3, 7
    or      t1, t1, t2
    ori     t1, t1, 0x13
    mv      a0, t1
    j       emit_word

# do_i_load: rd, imm(rs) → opcode 0x03
do_i_load:
    addi    sp, sp, -12
    sw      ra, 0(sp)
    sw      a1, 4(sp)                   # f3
    jal     ra, read_reg_op
    sw      a0, 8(sp)                   # rd
    jal     ra, read_mem_op
    # a0 = imm, a1 = rs1
    mv      t0, a0                      # imm
    mv      t3, a1                      # rs1
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    lw      a2, 8(sp)                   # rd
    addi    sp, sp, 12
    slli    t1, t0, 20
    andi    t3, t3, 0x1F
    slli    t2, t3, 15
    or      t1, t1, t2
    andi    a1, a1, 7
    slli    t2, a1, 12
    or      t1, t1, t2
    andi    a2, a2, 0x1F
    slli    t2, a2, 7
    or      t1, t1, t2
    ori     t1, t1, 0x03
    mv      a0, t1
    j       emit_word

# do_s: rs2, imm(rs1) → opcode 0x23
do_s:
    addi    sp, sp, -12
    sw      ra, 0(sp)
    sw      a1, 4(sp)                   # f3
    jal     ra, read_reg_op
    sw      a0, 8(sp)                   # rs2
    jal     ra, read_mem_op
    mv      t0, a0                      # imm
    mv      t3, a1                      # rs1
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    lw      a2, 8(sp)                   # rs2
    addi    sp, sp, 12
    # imm[11:5] → bits 31:25 ; imm[4:0] → bits 11:7
    srli    t1, t0, 5
    andi    t1, t1, 0x7F
    slli    t1, t1, 25
    andi    a2, a2, 0x1F
    slli    t2, a2, 20
    or      t1, t1, t2
    andi    t3, t3, 0x1F
    slli    t2, t3, 15
    or      t1, t1, t2
    andi    a1, a1, 7
    slli    t2, a1, 12
    or      t1, t1, t2
    andi    t2, t0, 0x1F
    slli    t2, t2, 7
    or      t1, t1, t2
    ori     t1, t1, 0x23
    mv      a0, t1
    j       emit_word

# do_b: rs1, rs2, target → opcode 0x63; B-type imm encoding.
# target may be label (records fixup, imm=0) or numeric offset.
do_b:
    addi    sp, sp, -16
    sw      ra, 0(sp)
    sw      a1, 4(sp)                   # f3
    jal     ra, read_reg_op
    sw      a0, 8(sp)                   # rs1
    jal     ra, read_reg_op
    sw      a0, 12(sp)                  # rs2
    jal     ra, read_br_target
    mv      t0, a0                      # off
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    lw      a2, 8(sp)
    lw      a3, 12(sp)
    addi    sp, sp, 16
    # Compose B-type
    li      t1, 0
    srli    t2, t0, 12
    andi    t2, t2, 1
    slli    t2, t2, 31
    or      t1, t1, t2
    srli    t2, t0, 5
    andi    t2, t2, 0x3F
    slli    t2, t2, 25
    or      t1, t1, t2
    andi    a3, a3, 0x1F
    slli    t2, a3, 20
    or      t1, t1, t2
    andi    a2, a2, 0x1F
    slli    t2, a2, 15
    or      t1, t1, t2
    andi    a1, a1, 7
    slli    t2, a1, 12
    or      t1, t1, t2
    srli    t2, t0, 1
    andi    t2, t2, 0xF
    slli    t2, t2, 8
    or      t1, t1, t2
    srli    t2, t0, 11
    andi    t2, t2, 1
    slli    t2, t2, 7
    or      t1, t1, t2
    ori     t1, t1, 0x63
    mv      a0, t1
    j       emit_word

# do_u_lui: rd, imm → (imm<<12)|(rd<<7)|0x37
do_u_lui:
    addi    sp, sp, -8
    sw      ra, 0(sp)
    jal     ra, read_reg_op
    sw      a0, 4(sp)                   # rd
    jal     ra, read_imm_op
    mv      t0, a0                      # imm
    lw      ra, 0(sp)
    lw      a1, 4(sp)                   # rd
    addi    sp, sp, 8
    slli    t1, t0, 12
    andi    a1, a1, 0x1F
    slli    t2, a1, 7
    or      t1, t1, t2
    ori     t1, t1, 0x37
    mv      a0, t1
    j       emit_word

# do_u_auipc: rd, imm → (imm<<12)|(rd<<7)|0x17
do_u_auipc:
    addi    sp, sp, -8
    sw      ra, 0(sp)
    jal     ra, read_reg_op
    sw      a0, 4(sp)
    jal     ra, read_imm_op
    mv      t0, a0
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    addi    sp, sp, 8
    slli    t1, t0, 12
    andi    a1, a1, 0x1F
    slli    t2, a1, 7
    or      t1, t1, t2
    ori     t1, t1, 0x17
    mv      a0, t1
    j       emit_word

# do_j_jal: rd, target → J-type, opcode 0x6F
do_j_jal:
    addi    sp, sp, -8
    sw      ra, 0(sp)
    jal     ra, read_reg_op
    sw      a0, 4(sp)                   # rd
    jal     ra, read_br_target
    mv      t0, a0                      # off
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    addi    sp, sp, 8
    # J-type encode
    li      t1, 0
    srli    t2, t0, 20
    andi    t2, t2, 1
    slli    t2, t2, 31
    or      t1, t1, t2
    srli    t2, t0, 1
    li      t3, 0x3FF
    and     t2, t2, t3
    slli    t2, t2, 21
    or      t1, t1, t2
    srli    t2, t0, 11
    andi    t2, t2, 1
    slli    t2, t2, 20
    or      t1, t1, t2
    srli    t2, t0, 12
    andi    t2, t2, 0xFF
    slli    t2, t2, 12
    or      t1, t1, t2
    andi    a1, a1, 0x1F
    slli    t2, a1, 7
    or      t1, t1, t2
    ori     t1, t1, 0x6F
    mv      a0, t1
    j       emit_word

# do_i_jalr: rd, imm(rs) → I-type, opcode 0x67, f3=0
do_i_jalr:
    addi    sp, sp, -8
    sw      ra, 0(sp)
    jal     ra, read_reg_op
    sw      a0, 4(sp)                   # rd
    jal     ra, read_mem_op
    mv      t0, a0                      # imm
    mv      t3, a1                      # rs
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    addi    sp, sp, 8
    slli    t1, t0, 20
    andi    t3, t3, 0x1F
    slli    t2, t3, 15
    or      t1, t1, t2
    andi    a1, a1, 0x1F
    slli    t2, a1, 7
    or      t1, t1, t2
    ori     t1, t1, 0x67
    mv      a0, t1
    j       emit_word

# do_ps_li: rd, imm → addi rd, x0, imm (I-type 0x13, f3=0, rs1=0)
do_ps_li:
    addi    sp, sp, -8
    sw      ra, 0(sp)
    jal     ra, read_reg_op
    sw      a0, 4(sp)
    jal     ra, read_imm_op
    mv      t0, a0
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    addi    sp, sp, 8
    slli    t1, t0, 20
    andi    a1, a1, 0x1F
    slli    t2, a1, 7
    or      t1, t1, t2
    ori     t1, t1, 0x13
    mv      a0, t1
    j       emit_word

# do_ps_mv: rd, rs → addi rd, rs, 0
do_ps_mv:
    addi    sp, sp, -8
    sw      ra, 0(sp)
    jal     ra, read_reg_op
    sw      a0, 4(sp)
    jal     ra, read_reg_op
    mv      t3, a0
    lw      ra, 0(sp)
    lw      a1, 4(sp)
    addi    sp, sp, 8
    # imm=0, rs1=t3, rd=a1, f3=0, opcode=0x13
    andi    t3, t3, 0x1F
    slli    t1, t3, 15
    andi    a1, a1, 0x1F
    slli    t2, a1, 7
    or      t1, t1, t2
    ori     t1, t1, 0x13
    mv      a0, t1
    j       emit_word

# do_ps_j: target → jal x0, target
do_ps_j:
    addi    sp, sp, -4
    sw      ra, 0(sp)
    jal     ra, read_br_target
    mv      t0, a0                      # off
    lw      ra, 0(sp)
    addi    sp, sp, 4
    li      t1, 0
    srli    t2, t0, 20
    andi    t2, t2, 1
    slli    t2, t2, 31
    or      t1, t1, t2
    srli    t2, t0, 1
    li      t3, 0x3FF
    and     t2, t2, t3
    slli    t2, t2, 21
    or      t1, t1, t2
    srli    t2, t0, 11
    andi    t2, t2, 1
    slli    t2, t2, 20
    or      t1, t1, t2
    srli    t2, t0, 12
    andi    t2, t2, 0xFF
    slli    t2, t2, 12
    or      t1, t1, t2
    ori     t1, t1, 0x6F
    mv      a0, t1
    j       emit_word

# do_ps_ret: → jalr x0, 0(ra) = 0x00008067
do_ps_ret:
    lui     t0, 8
    addi    t0, t0, 0x067
    mv      a0, t0
    j       emit_word

# do_ps_beqz: rs, target → beq rs, x0, target (f3=0)
do_ps_beqz:
    addi    sp, sp, -8
    sw      ra, 0(sp)
    jal     ra, read_reg_op
    sw      a0, 4(sp)                   # rs
    jal     ra, read_br_target
    mv      t0, a0                      # off
    lw      ra, 0(sp)
    lw      a2, 4(sp)                   # rs
    addi    sp, sp, 8
    # B-type with rs1=a2, rs2=0, f3=0
    li      t1, 0
    srli    t2, t0, 12
    andi    t2, t2, 1
    slli    t2, t2, 31
    or      t1, t1, t2
    srli    t2, t0, 5
    andi    t2, t2, 0x3F
    slli    t2, t2, 25
    or      t1, t1, t2
    andi    a2, a2, 0x1F
    slli    t2, a2, 15
    or      t1, t1, t2
    srli    t2, t0, 1
    andi    t2, t2, 0xF
    slli    t2, t2, 8
    or      t1, t1, t2
    srli    t2, t0, 11
    andi    t2, t2, 1
    slli    t2, t2, 7
    or      t1, t1, t2
    ori     t1, t1, 0x63
    mv      a0, t1
    j       emit_word

# do_ps_bnez: rs, target → bne rs, x0, target (f3=1)
do_ps_bnez:
    addi    sp, sp, -8
    sw      ra, 0(sp)
    jal     ra, read_reg_op
    sw      a0, 4(sp)
    jal     ra, read_br_target
    mv      t0, a0
    lw      ra, 0(sp)
    lw      a2, 4(sp)
    addi    sp, sp, 8
    li      t1, 0
    srli    t2, t0, 12
    andi    t2, t2, 1
    slli    t2, t2, 31
    or      t1, t1, t2
    srli    t2, t0, 5
    andi    t2, t2, 0x3F
    slli    t2, t2, 25
    or      t1, t1, t2
    andi    a2, a2, 0x1F
    slli    t2, a2, 15
    or      t1, t1, t2
    lui     t2, 1                       # 0x1000 = f3=1 at bit 12
    or      t1, t1, t2
    srli    t2, t0, 1
    andi    t2, t2, 0xF
    slli    t2, t2, 8
    or      t1, t1, t2
    srli    t2, t0, 11
    andi    t2, t2, 1
    slli    t2, t2, 7
    or      t1, t1, t2
    ori     t1, t1, 0x63
    mv      a0, t1
    j       emit_word

# ============================================================================
# fixup_pass: scan fixup table, resolve each against symtab, patch B/J imm.
# ============================================================================

fixup_pass:
    mv      t0, s7
fp_lp:
    beq     t0, s8, fp_ret
    mv      a6, s3
fp_sym:
    beq     a6, s4, fp_noresolve
    mv      t1, t0
    mv      t2, a6
    li      t3, 16
fp_cmp:
    lbu     t4, 0(t1)
    lbu     t5, 0(t2)
    bne     t4, t5, fp_skip
    addi    t1, t1, 1
    addi    t2, t2, 1
    addi    t3, t3, -1
    bnez    t3, fp_cmp
    lw      t5, 16(a6)                  # symbol offset
    lw      t6, 16(t0)                  # patch offset
    sub     t5, t5, t6                  # imm
    add     t2, s1, t6
    lw      t3, 0(t2)
    andi    t4, t3, 0x7F
    li      a7, 0x6F
    beq     t4, a7, fp_enc_j
    li      a7, 0x63
    beq     t4, a7, fp_enc_b
    j       fp_next
fp_skip:
    addi    a6, a6, 20
    j       fp_sym
fp_noresolve:
    j       halt_err
fp_enc_b:
    lui     t4, 0x01FFF
    addi    t4, t4, 0x07F
    and     t3, t3, t4
    srli    t4, t5, 12
    andi    t4, t4, 1
    slli    t4, t4, 31
    or      t3, t3, t4
    srli    t4, t5, 5
    andi    t4, t4, 0x3F
    slli    t4, t4, 25
    or      t3, t3, t4
    srli    t4, t5, 1
    andi    t4, t4, 0xF
    slli    t4, t4, 8
    or      t3, t3, t4
    srli    t4, t5, 11
    andi    t4, t4, 1
    slli    t4, t4, 7
    or      t3, t3, t4
    sw      t3, 0(t2)
    j       fp_next
fp_enc_j:
    lui     t4, 1
    addi    t4, t4, -1
    and     t3, t3, t4
    srli    t4, t5, 20
    andi    t4, t4, 1
    slli    t4, t4, 31
    or      t3, t3, t4
    srli    t4, t5, 1
    li      a7, 0x3FF
    and     t4, t4, a7
    slli    t4, t4, 21
    or      t3, t3, t4
    srli    t4, t5, 11
    andi    t4, t4, 1
    slli    t4, t4, 20
    or      t3, t3, t4
    srli    t4, t5, 12
    andi    t4, t4, 0xFF
    slli    t4, t4, 12
    or      t3, t3, t4
    sw      t3, 0(t2)
    j       fp_next
fp_next:
    addi    t0, t0, 20
    j       fp_lp
fp_ret:
    ret

# ============================================================================
# dump_output: write s1..s2 to UART
# ============================================================================

dump_output:
    mv      a0, s1
do_lp:
    beq     a0, s2, do_ret
    lbu     t3, 0(a0)
    addi    a0, a0, 1
do_wait:
    lbu     t1, 5(s5)
    andi    t1, t1, 0x20
    beqz    t1, do_wait
    sb      t3, 0(s5)
    j       do_lp
do_ret:
    ret
