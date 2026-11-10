#!/usr/bin/env bash
# Chạy mô phỏng D-Cache bằng Icarus Verilog.
#   ./sim/run.sh         -> biên dịch + mô phỏng D-Cache standalone
#   ./sim/run.sh soc     -> biên dịch + mô phỏng SoC RISC-V + D-Cache chạy C (ĐA2)
#   ./sim/run.sh wave    -> biên dịch + mô phỏng + mở GTKWave
set -e
cd "$(dirname "$0")/.."

if [ "$1" = "soc" ]; then
    iverilog -g2012 -o sim/tb_soc.vvp -s tb_riscv_cache_soc -c sim/files_soc.f
    vvp sim/tb_soc.vvp
    exit 0
fi

iverilog -g2012 -o sim/tb.vvp -s tb_riscv_dcache_2way -s dump_wave -c sim/files.f
vvp sim/tb.vvp

if [ "$1" = "wave" ]; then
    gtkwave sim/tb_riscv_dcache_2way.vcd sim/wave.gtkw >/dev/null 2>&1 &
fi
