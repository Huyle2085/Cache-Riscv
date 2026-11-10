`timescale 1ns / 1ps
// =============================================================================
// minimal/tb/tb_tc2_writeback.v
// TESTBENCH NHỎ 2 (CHẠY RIÊNG TC2): KIỂM TRA CONFLICT MISS & DIRTY WRITE-BACK
// Chạy lệnh: .\minimal\run_minimal.bat tc2
// =============================================================================
module tb_tc2_writeback;

    `include "minimal/tb/tb_min_base.vh"
    `include "minimal/tb/tc2_writeback.vh"

    initial begin
        $dumpfile("minimal/wave_tc2_writeback.vcd");
        $dumpvars(0, tb_tc2_writeback);

        tb_init_reset();
        run_tc2_writeback();
        print_da1_report("TC2 - CONFLICT MISS & DIRTY WRITE-BACK");
        $finish;
    end

endmodule
