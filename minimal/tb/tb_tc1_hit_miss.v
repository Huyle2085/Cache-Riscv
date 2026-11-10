`timescale 1ns / 1ps
// =============================================================================
// minimal/tb/tb_tc1_hit_miss.v
// TESTBENCH NHỎ 1 (CHẠY RIÊNG TC1): KIỂM TRA COLD MISS (REFILL) & READ/WRITE HIT
// Chạy lệnh: .\minimal\run_minimal.bat tc1
// =============================================================================
module tb_tc1_hit_miss;

    `include "minimal/tb/tb_min_base.vh"
    `include "minimal/tb/tc1_hit_miss.vh"

    initial begin
        $dumpfile("minimal/wave_tc1_hit_miss.vcd");
        $dumpvars(0, tb_tc1_hit_miss);

        tb_init_reset();
        run_tc1_hit_miss();
        print_da1_report("TC1 - COLD MISS & READ/WRITE HIT");
        $finish;
    end

endmodule
