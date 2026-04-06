#!/bin/sh

  (cat tests/test_long_jump.fam3; printf '\004') | \
    qemu-system-riscv32 -machine virt -cpu rv32i -nographic -bios none \
      -device loader,file=bin/fam3,addr=0x80000000 -serial mon:stdio 2>/dev/null > /tmp/test.bin
  qemu-system-riscv32 -machine virt -cpu rv32i -nographic -bios none \
    -device loader,file=/tmp/test.bin,addr=0x80000000 -serial mon:stdio 2>/dev/null 
