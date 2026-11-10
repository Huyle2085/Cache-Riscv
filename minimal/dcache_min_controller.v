`timescale 1ns / 1ps
// =============================================================================
// minimal/dcache_min_controller.v
// KHỐI ĐIỀU KHIỂN (CONTROLLER / FSM) CỦA D-CACHE SƠ KHAI
// -----------------------------------------------------------------------------
// Vai trò:
//   - Là "bộ não" của Cache: Nhận tín hiệu trạng thái (cache_hit, victim_dirty)
//     từ Datapath, quyết định trạng thái kế tiếp của FSM (3 trạng thái) và
//     phát các xung điều khiển (strobe) sang Datapath + sự kiện sang Perf Counters.
//   - Không chứa mảng dữ liệu RAM/Cache để tách bạch hoàn toàn phần Điều khiển
//     và phần Dữ liệu (giúp dễ hiểu, dễ quản lý và dễ đặt breakpoint debug).
//
// Máy trạng thái 3 trạng thái:
//   - S_IDLE      (2'd0): Kiểm tra Hit/Miss ngay trong 1 chu kỳ.
//   - S_WRITEBACK (2'd1): Đợi RAM ghi xong dòng cũ đang bẩn (Dirty = 1).
//   - S_ALLOCATE  (2'd2): Đợi RAM đọc xong dòng mới nạp lên Cache.
// =============================================================================
module dcache_min_controller (
    input  wire       clk,
    input  wire       rst_n,

    // --- Giao tiếp điều khiển với CPU ---
    input  wire       cpu_req,          // 1: CPU yêu cầu đọc/ghi
    input  wire       cpu_we,           // 0: Load (Read), 1: Store (Write)
    output reg        cpu_ready,        // 1: Báo cho CPU giao dịch đã xong
    output wire       cpu_stall,        // 1: Báo CPU dừng chờ Cache xử lý Miss

    // --- Giao tiếp điều khiển với RAM ---
    output reg        mem_req,          // 1: Yêu cầu giao dịch với RAM
    output reg        mem_we,           // 0: Đọc RAM (Allocate), 1: Ghi RAM (Write-Back)
    input  wire       mem_ready,        // 1: RAM báo đã truyền xong 1 word

    // --- Trạng thái nhận từ Datapath ---
    input  wire       cache_hit,        // 1: Valid == 1 và Tag khớp
    input  wire       victim_dirty,     // 1: Dòng hiện tại ở Set có Valid == 1 và Dirty == 1

    // --- Xung điều khiển (Strobe) gửi sang Datapath ---
    output reg        dp_hit_read,      // Lệnh: Đọc dữ liệu từ Cache trả về CPU (Read Hit)
    output reg        dp_hit_write,     // Lệnh: Ghi dữ liệu CPU vào Cache & bật Dirty (Write Hit)
    output reg        dp_wb_start,      // Lệnh: Xuất địa chỉ/dữ liệu dòng bẩn ra bus RAM để Write-Back
    output reg        dp_alloc_start,   // Lệnh: Xuất địa chỉ dòng mới ra bus RAM để Allocate
    output reg        dp_alloc_done,    // Lệnh: Chốt dữ liệu từ RAM vào Cache & cập nhật Tag/Valid

    // --- Xung sự kiện (Event) gửi sang Bộ đếm Hiệu năng (Perf Counters) ---
    output reg        ev_access,        // Có 1 yêu cầu mới từ CPU được tiếp nhận
    output reg        ev_hit,           // Giao dịch là Cache Hit
    output reg        ev_miss,          // Giao dịch là Cache Miss
    output reg        ev_writeback,     // Phải thực hiện Write-Back dòng bẩn
    output wire       ev_stall,         // Chu kỳ hiện tại CPU bị dừng (Stall)
    output wire       ev_mem_xfer,      // Có 1 word vừa truyền xong qua bus RAM

    // --- Ngõ ra quan sát trạng thái (phục vụ Debug / Waveform) ---
    output reg  [1:0] state
);

    // -------------------------------------------------------------------------
    // Định nghĩa mã trạng thái FSM
    // -------------------------------------------------------------------------
    localparam S_IDLE      = 2'd0;
    localparam S_WRITEBACK = 2'd1;
    localparam S_ALLOCATE  = 2'd2;

    // Yêu cầu từ CPU đang chờ phục vụ khi cpu_req = 1 và chưa báo cpu_ready
    wire cpu_pending = cpu_req && !cpu_ready;

    // Các biến trạng thái kế tiếp (tính trong mạch tổ hợp)
    reg [1:0] state_nxt;
    reg       cpu_ready_nxt;
    reg       mem_req_nxt;
    reg       mem_we_nxt;

    // CPU bị dừng (Stall) khi đang có yêu cầu nhưng chưa hoàn tất trong chu kỳ này
    assign cpu_stall   = cpu_pending && !cpu_ready_nxt;
    assign ev_stall    = cpu_stall;
    assign ev_mem_xfer = mem_req && mem_ready;

    // =========================================================================
    // PROCESS 1 (MẠCH TỔ HỢP): Tính trạng thái kế tiếp & Phát xung điều khiển
    // =========================================================================
    always @(*) begin
        // Giá trị mặc định: Giữ nguyên trạng thái, tắt các xung strobe (1 chu kỳ)
        state_nxt      = state;
        cpu_ready_nxt  = 1'b0;
        mem_req_nxt    = mem_req;
        mem_we_nxt     = mem_we;

        dp_hit_read    = 1'b0;
        dp_hit_write   = 1'b0;
        dp_wb_start    = 1'b0;
        dp_alloc_start = 1'b0;
        dp_alloc_done  = 1'b0;

        ev_access      = 1'b0;
        ev_hit         = 1'b0;
        ev_miss        = 1'b0;
        ev_writeback   = 1'b0;

        case (state)
            // -----------------------------------------------------------------
            // 1. S_IDLE: Đợi yêu cầu từ CPU và kiểm tra Hit / Miss
            // -----------------------------------------------------------------
            S_IDLE: begin
                if (cpu_pending) begin
                    ev_access = 1'b1;

                    if (cache_hit) begin
                        // === CACHE HIT: Hoàn tất ngay trong 1 chu kỳ (0 Stall) ===
                        ev_hit        = 1'b1;
                        cpu_ready_nxt = 1'b1;
                        dp_hit_write  = cpu_we;
                        dp_hit_read   = !cpu_we;
                    end else begin
                        // === CACHE MISS: Phải truy cập xuống RAM ===
                        ev_miss = 1'b1;

                        if (victim_dirty) begin
                            // Dòng hiện tại ở Set đang bẩn (Dirty = 1) -> Ghi trả về RAM trước
                            ev_writeback = 1'b1;
                            dp_wb_start  = 1'b1;
                            mem_req_nxt  = 1'b1;
                            mem_we_nxt   = 1'b1;
                            state_nxt    = S_WRITEBACK;
                        end else begin
                            // Dòng hiện tại trống hoặc sạch (Dirty = 0) -> Đọc dòng mới ngay
                            dp_alloc_start = 1'b1;
                            mem_req_nxt    = 1'b1;
                            mem_we_nxt     = 1'b0;
                            state_nxt      = S_ALLOCATE;
                        end
                    end
                end
            end

            // -----------------------------------------------------------------
            // 2. S_WRITEBACK: Đợi RAM ghi xong dòng bẩn cũ
            // -----------------------------------------------------------------
            S_WRITEBACK: begin
                if (mem_ready) begin
                    // Ghi trả xong -> Chuyển ngay sang phát lệnh đọc dòng mới (Allocate)
                    dp_alloc_start = 1'b1;
                    mem_req_nxt    = 1'b1;
                    mem_we_nxt     = 1'b0;
                    state_nxt      = S_ALLOCATE;
                end
            end

            // -----------------------------------------------------------------
            // 3. S_ALLOCATE: Đợi RAM trả dữ liệu dòng mới về Cache
            // -----------------------------------------------------------------
            S_ALLOCATE: begin
                if (mem_ready) begin
                    // Đã nhận được word từ RAM -> Cập nhật Cache, báo cpu_ready và về IDLE
                    dp_alloc_done = 1'b1;
                    mem_req_nxt   = 1'b0;
                    mem_we_nxt    = 1'b0;
                    cpu_ready_nxt = 1'b1;
                    state_nxt     = S_IDLE;
                end
            end

            default: state_nxt = S_IDLE;
        endcase
    end

    // =========================================================================
    // PROCESS 2 (MẠCH TUẦN TỰ): Cập nhật thanh ghi trạng thái theo xung nhịp
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            cpu_ready <= 1'b0;
            mem_req   <= 1'b0;
            mem_we    <= 1'b0;
        end else begin
            state     <= state_nxt;
            cpu_ready <= cpu_ready_nxt;
            mem_req   <= mem_req_nxt;
            mem_we    <= mem_we_nxt;
        end
    end

endmodule
