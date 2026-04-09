#!/usr/bin/env sh
# Bootstrap build. Each stage compiles the next from source using only the
# previous stage's binary. No external tools other than QEMU.
set -e
run() {
	(cat "$2"; printf '\004') | qemu-system-riscv32 \
		-machine virt \
		-cpu rv32i \
		-nographic \
		-bios none \
		-device loader,file="$1",addr=0x80000000 \
		-serial mon:stdio 2>/dev/null
}
run fam0.seed src/fam0.fam0 > bin/fam0
cmp ./bin/fam0 ./fam0.seed || { echo "fam0: binaries don't match!"; exit 1; }
echo "fam0: OK"
run bin/fam0 src/fam1.fam0 > bin/fam1
echo "fam1: OK ($(wc -c < bin/fam1) bytes)"
run bin/fam1 src/fam2.fam1 > bin/fam2
echo "fam2: OK ($(wc -c < bin/fam2) bytes)"

echo "Success!";
