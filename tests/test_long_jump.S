# test_long_jump.S — verify branch relaxation works across large gaps.
#
# Strategy: place a 8KB .fill block between a branch and its target.
# This exceeds the +/-4KB B-type range, so fam3's branch relaxation must
# kick in (inverted branch + JAL trampoline).
#
# On success: prints "OK\n" to UART and poweroffs.
# On failure: prints "FAIL\n" or hangs.

lui     s5, 0x10000                 # UART base

# ---- Test 1: forward beq over 8KB gap ----
li      a0, 42
li      a1, 42
beq     a0, a1, fwd_target

# If the branch didn't fire, we fall through here
j       fail

.fill   2048, 4, 0                  # 8KB gap

fwd_target:

# ---- Test 2: forward bne over 8KB gap ----
li      a0, 1
li      a1, 2
bne     a0, a1, fwd_target2

j       fail

.fill   2048, 4, 0                  # 8KB gap

fwd_target2:

# ---- Test 3: forward beqz over 8KB gap ----
li      a0, 0
beqz    a0, fwd_target3

j       fail

.fill   2048, 4, 0                  # 8KB gap

fwd_target3:

# ---- Test 4: forward bnez over 8KB gap ----
li      a0, 1
bnez    a0, fwd_target4

j       fail

.fill   2048, 4, 0                  # 8KB gap

fwd_target4:

# ---- Test 5: backward branch over 8KB gap ----
j       skip_back_target

back_target:
j       all_pass

.fill   2048, 4, 0                  # 8KB gap

skip_back_target:
li      a0, 7
li      a1, 7
beq     a0, a1, back_target

j       fail

# ---- Test 6: branch NOT taken should skip trampoline correctly ----
li      a0, 1
li      a1, 2
beq     a0, a1, fail_target         # should NOT be taken (1 != 2)
j       not_taken_pass

.fill   2048, 4, 0

fail_target:
j       fail

not_taken_pass:

# ---- All tests passed ----
all_pass:
# Print "OK\n"
li      t0, 79                      # 'O'
jal     ra, wrch
li      t0, 75                      # 'K'
jal     ra, wrch
li      t0, 10                      # '\n'
jal     ra, wrch
j       powoff

fail:
# Print "FAIL\n"
li      t0, 70                      # 'F'
jal     ra, wrch
li      t0, 65                      # 'A'
jal     ra, wrch
li      t0, 73                      # 'I'
jal     ra, wrch
li      t0, 76                      # 'L'
jal     ra, wrch
li      t0, 10                      # '\n'
jal     ra, wrch
j       powoff

wrch:
    lbu     t5, 5(s5)
    andi    t5, t5, 0x20
    beqz    t5, wrch
    sb      t0, 0(s5)
    ret

powoff:
    lui     s5, 0x100
    lui     t0, 5
    addi    t0, t0, 0x555
    sw      t0, 0(s5)
powoff_hang:
    j       powoff_hang
