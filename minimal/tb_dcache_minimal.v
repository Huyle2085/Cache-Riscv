`timescale 1ns / 1ps
// =============================================================================
// minimal/tb_dcache_minimal.v
// TESTBENCH TỔNG HỢP ĐA1 (GỌI LẦN LƯỢT CẢ 3 TEST CASE NHỎ: TC1 + TC2 + TC3)
// -----------------------------------------------------------------------------
// Cấu trúc đã được chia tách thành các file nhỏ trong minimal/tb/:
//   - minimal/tb/tb_min_base.vh    : Khai báo dây nối & khởi tạo DUT + RAM
//   - minimal/tb/tb_min_tasks.vh   : Các task trace_load, trace_store, print_da1_report
//   - minimal/tb/tc1_hit_miss.vh   : Kịch bản 1 - Cold Miss, Read Hit, Write Hit
//   - minimal/tb/tc2_writeback.vh  : Kịch bản 2 - Clean Conflict vs. Dirty Write-Back
//   - minimal/tb/tc3_thrashing.vh  : Kịch bản 3 - Write-Allocate & Ping-Pong Thrashing
//
// Bạn có thể chạy riêng từng file nhỏ hoặc chạy tổng hợp bằng minimal\run_minimal.bat
// =============================================================================
module tb_dcache_minimal;

    `include "minimal/tb/tb_min_base.vh"
    `include "minimal/tb/tc1_hit_miss.vh"
    `include "minimal/tb/tc2_writeback.vh"
    `include "minimal/tb/tc3_thrashing.vh"

    initial begin
        $dumpfile("minimal/wave_minimal.vcd");
        $dumpvars(0, tb_dcache_minimal);

        tb_init_reset();

        $display("=========================================================================================================================");
        $display(" KIEM CHUNG TONG HOP MO HINH D-CACHE SO KHAI (DA1: CHAY LAN LUOT TC1 + TC2 + TC3)");
        $display("=========================================================================================================================");

        // Chạy lần lượt 3 nhóm kịch bản độc lập (Set 4, Set 8, Set 12)
        run_tc1_hit_miss();
        run_tc2_writeback();
        run_tc3_thrashing();

        // In báo cáo hiệu năng & phân bố độ trễ RAM biến thiên
        print_da1_report("TONG HOP DA1 (TC1 + TC2 + TC3)");
        $finish;
    end

endmodule
