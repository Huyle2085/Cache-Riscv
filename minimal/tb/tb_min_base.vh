// =============================================================================
// minimal/tb/tb_min_base.vh
// KHUNG KẾT NỐI PHẦN CỨNG CHUNG (DUT dcache_minimal + RAM var_latency_mem)
// -----------------------------------------------------------------------------
// Dùng chung cho tất cả các file Testbench nhỏ (tc1, tc2, tc3, tổng hợp) để
// tránh lặp lại khai báo dây nối.
// =============================================================================

    reg clk;
    reg rst_n;

    // Xung nhịp 100 MHz (1 chu kỳ = 10 ns)
    always #5 clk = ~clk;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer tx_id    = 0;

    // --- Dây kết nối CPU <-> D-Cache Minimal ---
    reg         cpu_req, cpu_we;
    reg  [3:0]  cpu_wstrb;
    reg  [31:0] cpu_addr, cpu_wdata;
    wire [31:0] cpu_rdata;
    wire        cpu_stall, cpu_ready;

    // --- Dây kết nối D-Cache Minimal <-> RAM ---
    wire        mem_req, mem_we, mem_ready;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;

    // --- Dây bộ đếm hiệu năng & tín hiệu quan sát ---
    wire [31:0] cnt_acc, cnt_hits, cnt_rhit, cnt_whit;
    wire [31:0] cnt_miss, cnt_rmiss, cnt_wmiss, cnt_wb;
    wire [31:0] cnt_stall, cnt_traf;
    wire [1:0]  dbg_state;
    wire        dbg_hit, dbg_dirty;

    // Khởi tạo D-Cache Direct-Mapped Sơ khai (DUT)
    dcache_minimal #(
        .NUM_SETS   (64),
        .INDEX_BITS (6)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .cpu_req          (cpu_req),
        .cpu_we           (cpu_we),
        .cpu_wstrb        (cpu_wstrb),
        .cpu_addr         (cpu_addr),
        .cpu_wdata        (cpu_wdata),
        .cpu_rdata        (cpu_rdata),
        .cpu_stall        (cpu_stall),
        .cpu_ready        (cpu_ready),
        .mem_req          (mem_req),
        .mem_we           (mem_we),
        .mem_addr         (mem_addr),
        .mem_wdata        (mem_wdata),
        .mem_rdata        (mem_rdata),
        .mem_ready        (mem_ready),
        .cnt_accesses     (cnt_acc),
        .cnt_hits         (cnt_hits),
        .cnt_read_hits    (cnt_rhit),
        .cnt_write_hits   (cnt_whit),
        .cnt_misses       (cnt_miss),
        .cnt_read_misses  (cnt_rmiss),
        .cnt_write_misses (cnt_wmiss),
        .cnt_writebacks   (cnt_wb),
        .cnt_stall_cycles (cnt_stall),
        .cnt_mem_traffic  (cnt_traf),
        .dbg_state        (dbg_state),
        .dbg_cache_hit    (dbg_hit),
        .dbg_victim_dirty (dbg_dirty)
    );

    // Khởi tạo Bộ nhớ RAM có độ trễ biến thiên (2..5 chu kỳ)
    var_latency_mem #(
        .BASE_DELAY (3'd2),
        .VAR_ENABLE (1)
    ) u_mem (
        .clk       (clk),
        .rst_n     (rst_n),
        .mem_req   (mem_req),
        .mem_we    (mem_we),
        .mem_wstrb (4'b1111),
        .mem_addr  (mem_addr),
        .mem_wdata (mem_wdata),
        .mem_rdata (mem_rdata),
        .mem_ready (mem_ready)
    );

    // Task khởi tạo tín hiệu đầu buổi mô phỏng
    task tb_init_reset;
        begin
            clk       = 1'b0;
            rst_n     = 1'b0;
            cpu_req   = 1'b0;
            cpu_we    = 1'b0;
            cpu_wstrb = 4'b1111;
            cpu_addr  = 32'd0;
            cpu_wdata = 32'd0;
            #25 rst_n = 1'b1;
        end
    endtask

    // Nhúng các hàm trace_load, trace_store, print_da1_report
    `include "minimal/tb/tb_min_tasks.vh"
