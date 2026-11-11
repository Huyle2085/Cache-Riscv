#!/usr/bin/env bash
# =============================================================================
# sw/build_sw.sh
# Quy trình biên dịch tự động C -> ELF -> BIN -> HEX bằng RISC-V GCC
# cho Lõi vi xử lý RISC-V RV32I Pipeline 5 tầng (ĐA2):
#   1. sw/benchmark_da2.c -> sw/benchmark_da2.elf -> sw/program.hex
#   2. sw/benchmark_seq.c -> sw/benchmark_seq.elf -> sw/program_seq.hex
# =============================================================================
set -euo pipefail

CC=riscv64-unknown-elf-gcc
OBJCOPY=riscv64-unknown-elf-objcopy
OBJDUMP=riscv64-unknown-elf-objdump
CFLAGS="-march=rv32i -mabi=ilp32 -O2 -fno-unroll-loops -fno-tree-loop-distribute-patterns -ffreestanding -nostdlib -Wall -Wextra"
LDFLAGS="-T sw/link.ld -Wl,--no-relax"

echo "=== [1/2] Compiling Benchmark 1 (Conflict/Thrashing): sw/benchmark_da2.c ==="
$CC $CFLAGS $LDFLAGS sw/start.S sw/benchmark_da2.c -o sw/benchmark_da2.elf
$OBJDUMP -d -M no-aliases sw/benchmark_da2.elf > sw/benchmark_da2.dump
$OBJCOPY -O binary sw/benchmark_da2.elf sw/benchmark_da2.bin
python3 sw/bin2hex.py sw/benchmark_da2.bin sw/program.hex

echo "=== [2/2] Compiling Benchmark 2 (Sequential/Low-Conflict): sw/benchmark_seq.c ==="
$CC $CFLAGS $LDFLAGS sw/start.S sw/benchmark_seq.c -o sw/benchmark_seq.elf
$OBJDUMP -d -M no-aliases sw/benchmark_seq.elf > sw/benchmark_seq.dump
$OBJCOPY -O binary sw/benchmark_seq.elf sw/benchmark_seq.bin
python3 sw/bin2hex.py sw/benchmark_seq.bin sw/program_seq.hex

echo "=== Build Complete ==="
