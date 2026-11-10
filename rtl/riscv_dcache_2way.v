`timescale 1ns / 1ps
// =============================================================================
// riscv_dcache_2way.v  (TOP)
// D-Cache 2-way set-associative cho lõi RISC-V.
//   Cấu hình mặc định: 64 sets x 2 ways x 16 bytes = 2 KB
//   Chính sách: LRU, Write-back + Write-allocate, Write Buffer 1 dòng,
//               Flush/Invalidate cho CPU-DMA coherence, vùng Uncached (bit 31).
//
// Cấu trúc:
//   riscv_dcache_2way
//   ├── u_ctrl : dcache_controller     (FSM + strobe điều khiển)
//   ├── u_dp   : dcache_datapath       (Tag/Data/Valid/Dirty/LRU + Write Buffer)
//   └── u_perf : dcache_perf_counters  (bộ đếm hiệu năng)
// =============================================================================
module riscv_dcache_2way #(
    parameter ADDR_WIDTH     = 32,
    parameter DATA_WIDTH     = 32,
    parameter NUM_SETS       = 64,              // S = 64 sets (s = 6 bits)
    parameter WAYS           = 2,               // E = 2 ways (2-way set-associative)
    parameter WORDS_PER_LINE = 4                // B = 16 bytes = 4 words (b = 4 bits)
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // --- Giao tiếp phía Lõi RISC-V (CPU Load/Store Unit Interface) ---
    input  wire                   cpu_req,       // Pha Request: Yêu cầu đọc/ghi từ Master/CPU
    output wire                   cpu_req_ready, // Pha Request: Cache sẵn sàng nhận yêu cầu mới
    input  wire                   cpu_we,        // 0: Load (Read), 1: Store (Write)
    input  wire [3:0]             cpu_wstrb,     // Byte enable (hỗ trợ SB, SH, SW)
    input  wire [ADDR_WIDTH-1:0]  cpu_addr,      // Địa chỉ 32-bit
    input  wire [DATA_WIDTH-1:0]  cpu_wdata,     // Dữ liệu ghi từ CPU
    output wire [DATA_WIDTH-1:0]  cpu_rdata,     // Pha Response: Dữ liệu đọc trả về CPU
    output wire                   cpu_stall,     // Giữ pipeline CPU khi Cache bận
    output wire                   cpu_ready,     // Pha Response: Báo hoàn tất giao dịch (rsp_valid)

    // --- Giao tiếp Điều khiển Nhất quán Dữ liệu (Dành cho ĐATN: CPU-DMA) ---
    input  wire                   cache_flush,      // Đẩy toàn bộ dòng Dirty xuống RAM
    input  wire                   cache_invalidate, // Xóa Valid toàn bộ Cache
    output wire                   maint_done,       // Báo hoàn tất Flush/Invalidate

    // --- Giao tiếp Bộ nhớ chính ---
    output wire                   mem_req,
    output wire                   mem_we,
    output wire [3:0]             mem_wstrb,
    output wire [ADDR_WIDTH-1:0]  mem_addr,
    output wire [DATA_WIDTH-1:0]  mem_wdata,
    input  wire [DATA_WIDTH-1:0]  mem_rdata,
    input  wire                   mem_ready,

    // --- Bộ đếm Hiệu năng ---
    output wire [31:0]            cnt_accesses,     // Tổng số lần CPU truy cập Cache
    output wire [31:0]            cnt_misses,       // Tổng số lần Cache Miss
    output wire [31:0]            cnt_stall_cycles, // Tổng số chu kỳ dừng CPU
    output wire [31:0]            cnt_mem_traffic,  // Tổng số word truyền qua bus bộ nhớ
    output wire [31:0]            cnt_coherence_cyc // Overhead chu kỳ Flush/Invalidate
);

    localparam OFFSET_BITS = 4;                                  // 16 bytes/line
    localparam WORD_BITS   = 2;                                  // 4 words/line
    localparam INDEX_BITS  = (NUM_SETS <= 2)   ? 1 :
                             (NUM_SETS <= 4)   ? 2 :
                             (NUM_SETS <= 8)   ? 3 :
                             (NUM_SETS <= 16)  ? 4 :
                             (NUM_SETS <= 32)  ? 5 :
                             (NUM_SETS <= 64)  ? 6 :
                             (NUM_SETS <= 128) ? 7 :
                             (NUM_SETS <= 256) ? 8 : 9;          // Tự động theo NUM_SETS
    localparam TAG_BITS    = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;

    // -------------------------------------------------------------------------
    // Tín hiệu nội bộ giữa các khối
    // -------------------------------------------------------------------------
    // Datapath -> Controller (trạng thái)
    wire                  is_uncached;
    wire                  cache_hit;
    wire                  hit_way0;
    wire                  hit_way1;
    wire                  victim_way;
    wire                  victim_dirty;
    wire                  wb_valid;
    wire [ADDR_WIDTH-1:0] wb_base_addr;
    wire                  flush_line_dirty;

    // Controller -> Datapath (con trỏ)
    wire [2:0]            state;
    wire [1:0]            word_cnt;
    wire                  saved_victim_way;
    wire [INDEX_BITS-1:0] flush_set;
    wire                  flush_way;

    // Controller -> Datapath (strobe)
    wire                  dp_req_latch;
    wire                  dp_use_latched;
    wire                  dp_inval_all;
    wire                  dp_hit_rd;
    wire                  dp_hit_wr;
    wire                  dp_wb_load;
    wire                  dp_wb_clear;
    wire                  dp_refill_we;
    wire                  dp_refill_done;
    wire                  dp_unc_rdata;
    wire                  dp_flush_clean;
    wire                  dp_mem_ld;
    wire [1:0]            dp_mem_sel;
    wire [1:0]            dp_mem_word;

    // Controller -> Perf Counters (sự kiện)
    wire                  ev_access;
    wire                  ev_miss;
    wire                  ev_stall;
    wire                  ev_mem_xfer;
    wire                  ev_coherence;

    // -------------------------------------------------------------------------
    // Bộ điều khiển
    // -------------------------------------------------------------------------
    dcache_controller #(
        .NUM_SETS       (NUM_SETS),
        .WAYS           (WAYS),
        .WORDS_PER_LINE (WORDS_PER_LINE),
        .INDEX_BITS     (INDEX_BITS)
    ) u_ctrl (
        .clk              (clk),
        .rst_n            (rst_n),
        .cpu_req          (cpu_req),
        .cpu_we           (cpu_we),
        .cpu_req_ready    (cpu_req_ready),
        .cpu_ready        (cpu_ready),
        .cpu_stall        (cpu_stall),
        .cache_flush      (cache_flush),
        .cache_invalidate (cache_invalidate),
        .maint_done       (maint_done),
        .mem_req          (mem_req),
        .mem_we           (mem_we),
        .mem_ready        (mem_ready),
        .is_uncached      (is_uncached),
        .cache_hit        (cache_hit),
        .victim_way       (victim_way),
        .victim_dirty     (victim_dirty),
        .wb_valid         (wb_valid),
        .flush_line_dirty (flush_line_dirty),
        .word_cnt         (word_cnt),
        .saved_victim_way (saved_victim_way),
        .flush_set        (flush_set),
        .flush_way        (flush_way),
        .dp_req_latch     (dp_req_latch),
        .dp_use_latched   (dp_use_latched),
        .dp_inval_all     (dp_inval_all),
        .dp_hit_rd        (dp_hit_rd),
        .dp_hit_wr        (dp_hit_wr),
        .dp_wb_load       (dp_wb_load),
        .dp_wb_clear      (dp_wb_clear),
        .dp_refill_we     (dp_refill_we),
        .dp_refill_done   (dp_refill_done),
        .dp_unc_rdata     (dp_unc_rdata),
        .dp_flush_clean   (dp_flush_clean),
        .dp_mem_ld        (dp_mem_ld),
        .dp_mem_sel       (dp_mem_sel),
        .dp_mem_word      (dp_mem_word),
        .ev_access        (ev_access),
        .ev_miss          (ev_miss),
        .ev_stall         (ev_stall),
        .ev_mem_xfer      (ev_mem_xfer),
        .ev_coherence     (ev_coherence),
        .state            (state)
    );

    // -------------------------------------------------------------------------
    // Đường dữ liệu
    // -------------------------------------------------------------------------
    dcache_datapath #(
        .ADDR_WIDTH     (ADDR_WIDTH),
        .DATA_WIDTH     (DATA_WIDTH),
        .NUM_SETS       (NUM_SETS),
        .WAYS           (WAYS),
        .WORDS_PER_LINE (WORDS_PER_LINE),
        .OFFSET_BITS    (OFFSET_BITS),
        .WORD_BITS      (WORD_BITS),
        .INDEX_BITS     (INDEX_BITS),
        .TAG_BITS       (TAG_BITS)
    ) u_dp (
        .clk              (clk),
        .rst_n            (rst_n),
        .cpu_we           (cpu_we),
        .cpu_wstrb        (cpu_wstrb),
        .cpu_addr         (cpu_addr),
        .cpu_wdata        (cpu_wdata),
        .cpu_rdata        (cpu_rdata),
        .mem_addr         (mem_addr),
        .mem_wdata        (mem_wdata),
        .mem_wstrb        (mem_wstrb),
        .mem_rdata        (mem_rdata),
        .word_cnt         (word_cnt),
        .saved_victim_way (saved_victim_way),
        .flush_set        (flush_set),
        .flush_way        (flush_way),
        .dp_req_latch     (dp_req_latch),
        .dp_use_latched   (dp_use_latched),
        .dp_inval_all     (dp_inval_all),
        .dp_hit_rd        (dp_hit_rd),
        .dp_hit_wr        (dp_hit_wr),
        .dp_wb_load       (dp_wb_load),
        .dp_wb_clear      (dp_wb_clear),
        .dp_refill_we     (dp_refill_we),
        .dp_refill_done   (dp_refill_done),
        .dp_unc_rdata     (dp_unc_rdata),
        .dp_flush_clean   (dp_flush_clean),
        .dp_mem_ld        (dp_mem_ld),
        .dp_mem_sel       (dp_mem_sel),
        .dp_mem_word      (dp_mem_word),
        .is_uncached      (is_uncached),
        .cache_hit        (cache_hit),
        .hit_way0         (hit_way0),
        .hit_way1         (hit_way1),
        .victim_way       (victim_way),
        .victim_dirty     (victim_dirty),
        .wb_valid         (wb_valid),
        .wb_base_addr     (wb_base_addr),
        .flush_line_dirty (flush_line_dirty)
    );

    // -------------------------------------------------------------------------
    // Bộ đếm hiệu năng
    // -------------------------------------------------------------------------
    dcache_perf_counters u_perf (
        .clk               (clk),
        .rst_n             (rst_n),
        .ev_access         (ev_access),
        .ev_miss           (ev_miss),
        .ev_stall          (ev_stall),
        .ev_mem_xfer       (ev_mem_xfer),
        .ev_coherence      (ev_coherence),
        .cnt_accesses      (cnt_accesses),
        .cnt_misses        (cnt_misses),
        .cnt_stall_cycles  (cnt_stall_cycles),
        .cnt_mem_traffic   (cnt_mem_traffic),
        .cnt_coherence_cyc (cnt_coherence_cyc)
    );

endmodule
