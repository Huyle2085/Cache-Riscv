`timescale 1ns / 1ps
// =============================================================================
// minimal/dcache_minimal.v  (TOP MODULE)
// MÔ HÌNH D-CACHE SƠ KHAI (ĐÃ CHIA TÁCH THÀNH 3 KHỐI NHỎ RÕ RÀNG)
// -----------------------------------------------------------------------------
// Cấu trúc phân cấp (giống hệt cấu trúc của mô hình hoàn chỉnh ở rtl/, nhưng ở
// mức tối giản nhất để dễ hiểu, dễ quản lý và dễ debug):
//
//   dcache_minimal (TOP)
//   ├── u_ctrl : dcache_min_controller    (FSM 3 trạng thái + xung điều khiển)
//   ├── u_dp   : dcache_min_datapath      (Bảng Valid/Dirty/Tag/Data + so sánh Hit)
//   └── u_perf : dcache_min_perf_counters (Bộ đếm Hit/Miss/Writeback/Stall/Traffic)
//
// Đặc điểm kiến trúc sơ khai (Step 0):
//   - Direct-Mapped (1-Way), 1 Word/Line (4 Bytes), Write-Back + Write-Allocate.
//   - Chưa có Write Buffer, chưa có LRU, chưa có Byte-strobe hay Flush/Uncached.
// =============================================================================
module dcache_minimal #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter NUM_SETS   = 64,              // 64 dòng x 4 Bytes = 256 Bytes
    parameter INDEX_BITS = 6                // log2(64) = 6 bits
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // --- Giao tiếp phía CPU ---
    input  wire                   cpu_req,      // 1: CPU yêu cầu truy cập bộ nhớ
    input  wire                   cpu_we,       // 0: Đọc (Load), 1: Ghi (Store)
    input  wire [3:0]             cpu_wstrb,    // Byte strobe (dự phòng cho bước nâng cấp)
    input  wire [ADDR_WIDTH-1:0]  cpu_addr,     // Địa chỉ 32-bit từ CPU
    input  wire [DATA_WIDTH-1:0]  cpu_wdata,    // Dữ liệu ghi từ CPU
    output wire [DATA_WIDTH-1:0]  cpu_rdata,    // Dữ liệu đọc trả về CPU
    output wire                   cpu_stall,    // 1: Báo CPU dừng đợi Cache
    output wire                   cpu_ready,    // 1: Báo hoàn tất giao dịch trong chu kỳ này

    // --- Giao tiếp phía Bộ nhớ chính (RAM) ---
    output wire                   mem_req,      // 1: Yêu cầu đọc/ghi RAM
    output wire                   mem_we,       // 0: Đọc RAM, 1: Ghi RAM
    output wire [ADDR_WIDTH-1:0]  mem_addr,     // Địa chỉ gửi xuống RAM
    output wire [DATA_WIDTH-1:0]  mem_wdata,    // Dữ liệu ghi xuống RAM (khi Write-Back)
    input  wire [DATA_WIDTH-1:0]  mem_rdata,    // Dữ liệu đọc từ RAM (khi Allocate)
    input  wire                   mem_ready,    // 1: RAM báo hoàn tất truyền 1 word

    // --- Các bộ đếm thu thập thông số Hiệu năng & Tốc độ xử lý ---
    output wire [31:0]            cnt_accesses,     // Tổng số lần CPU truy cập
    output wire [31:0]            cnt_hits,         // Tổng số lần Cache Hit
    output wire [31:0]            cnt_read_hits,    // Số lần Read Hit
    output wire [31:0]            cnt_write_hits,   // Số lần Write Hit
    output wire [31:0]            cnt_misses,       // Tổng số lần Cache Miss
    output wire [31:0]            cnt_read_misses,  // Số lần Read Miss
    output wire [31:0]            cnt_write_misses, // Số lần Write Miss
    output wire [31:0]            cnt_writebacks,   // Số lần Write-Back dòng Dirty
    output wire [31:0]            cnt_stall_cycles, // Tổng số chu kỳ CPU bị dừng (Stall)
    output wire [31:0]            cnt_mem_traffic,  // Tổng số word truyền trên bus RAM

    // --- Tín hiệu quan sát trực tiếp (hỗ trợ Debug / Testbench / Waveform) ---
    output wire [1:0]             dbg_state,        // Trạng thái FSM hiện tại (0:IDLE, 1:WB, 2:ALLOC)
    output wire                   dbg_cache_hit,    // Tín hiệu báo Hit tổ hợp
    output wire                   dbg_victim_dirty  // Báo dòng hiện tại ở Set đang bẩn
);

    localparam OFFSET_BITS = 2;                                      // 1 word = 4 bytes
    localparam TAG_BITS    = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;  // 24 bits

    // -------------------------------------------------------------------------
    // Dây kết nối nội bộ giữa 3 khối (Controller <-> Datapath <-> Perf Counters)
    // -------------------------------------------------------------------------
    // 1. Trạng thái từ Datapath báo về Controller
    wire cache_hit;
    wire victim_dirty;

    // 2. Xung điều khiển (Strobe) từ Controller ra lệnh cho Datapath
    wire dp_hit_read;
    wire dp_hit_write;
    wire dp_wb_start;
    wire dp_alloc_start;
    wire dp_alloc_done;

    // 3. Xung sự kiện (Event) từ Controller báo sang Bộ đếm Hiệu năng
    wire ev_access;
    wire ev_hit;
    wire ev_miss;
    wire ev_writeback;
    wire ev_stall;
    wire ev_mem_xfer;

    assign dbg_cache_hit    = cache_hit;
    assign dbg_victim_dirty = victim_dirty;

    // =========================================================================
    // KHỐI 1: BỘ ĐIỀU KHIỂN (CONTROLLER - FSM 3 TRẠNG THÁI)
    // =========================================================================
    dcache_min_controller u_ctrl (
        .clk            (clk),
        .rst_n          (rst_n),
        .cpu_req        (cpu_req),
        .cpu_we         (cpu_we),
        .cpu_ready      (cpu_ready),
        .cpu_stall      (cpu_stall),
        .mem_req        (mem_req),
        .mem_we         (mem_we),
        .mem_ready      (mem_ready),
        .cache_hit      (cache_hit),
        .victim_dirty   (victim_dirty),
        .dp_hit_read    (dp_hit_read),
        .dp_hit_write   (dp_hit_write),
        .dp_wb_start    (dp_wb_start),
        .dp_alloc_start (dp_alloc_start),
        .dp_alloc_done  (dp_alloc_done),
        .ev_access      (ev_access),
        .ev_hit         (ev_hit),
        .ev_miss        (ev_miss),
        .ev_writeback   (ev_writeback),
        .ev_stall       (ev_stall),
        .ev_mem_xfer    (ev_mem_xfer),
        .state          (dbg_state)
    );

    // =========================================================================
    // KHỐI 2: ĐƯỜNG DỮ LIỆU (DATAPATH - BẢNG CACHE & SO SÁNH TAG)
    // =========================================================================
    dcache_min_datapath #(
        .ADDR_WIDTH  (ADDR_WIDTH),
        .DATA_WIDTH  (DATA_WIDTH),
        .NUM_SETS    (NUM_SETS),
        .INDEX_BITS  (INDEX_BITS),
        .OFFSET_BITS (OFFSET_BITS),
        .TAG_BITS    (TAG_BITS)
    ) u_dp (
        .clk            (clk),
        .rst_n          (rst_n),
        .cpu_we         (cpu_we),
        .cpu_wstrb      (cpu_wstrb),
        .cpu_addr       (cpu_addr),
        .cpu_wdata      (cpu_wdata),
        .cpu_rdata      (cpu_rdata),
        .mem_addr       (mem_addr),
        .mem_wdata      (mem_wdata),
        .mem_rdata      (mem_rdata),
        .dp_hit_read    (dp_hit_read),
        .dp_hit_write   (dp_hit_write),
        .dp_wb_start    (dp_wb_start),
        .dp_alloc_start (dp_alloc_start),
        .dp_alloc_done  (dp_alloc_done),
        .cache_hit      (cache_hit),
        .victim_dirty   (victim_dirty)
    );

    // =========================================================================
    // KHỐI 3: BỘ ĐẾM HIỆU NĂNG (PERFORMANCE COUNTERS)
    // =========================================================================
    dcache_min_perf_counters u_perf (
        .clk              (clk),
        .rst_n            (rst_n),
        .cpu_we           (cpu_we),
        .ev_access        (ev_access),
        .ev_hit           (ev_hit),
        .ev_miss          (ev_miss),
        .ev_writeback     (ev_writeback),
        .ev_stall         (ev_stall),
        .ev_mem_xfer      (ev_mem_xfer),
        .cnt_accesses     (cnt_accesses),
        .cnt_hits         (cnt_hits),
        .cnt_read_hits    (cnt_read_hits),
        .cnt_write_hits   (cnt_write_hits),
        .cnt_misses       (cnt_misses),
        .cnt_read_misses  (cnt_read_misses),
        .cnt_write_misses (cnt_write_misses),
        .cnt_writebacks   (cnt_writebacks),
        .cnt_stall_cycles (cnt_stall_cycles),
        .cnt_mem_traffic  (cnt_mem_traffic)
    );

endmodule
