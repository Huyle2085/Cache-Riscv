`timescale 1ns / 1ps
// =============================================================================
// minimal/tb/tb_tc3_thrashing.v
// TESTBENCH NHỎ 3 (CHẠY RIÊNG TC3): KIỂM TRA WRITE-ALLOCATE & PING-PONG THRASHING
// Chạy lệnh: .\minimal\run_minimal.bat tc3
// =============================================================================
module tb_tc3_thrashing;

    `include "minimal/tb/tb_min_base.vh"
    `include "minimal/tb/tc3_thrashing.vh"

    initial begin
        $dumpfile("minimal/wave_tc3_thrashing.vcd");
        $dumpvars(0, tb_tc3_thrashing);

        tb_init_reset();
        run_tc3_thrashing();
        print_da1_report("TC3 - WRITE-ALLOCATE & THRASHING");
        $finish;
    end

endmodule
