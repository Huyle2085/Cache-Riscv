`timescale 1ns / 1ps
// =============================================================================
// minimal/dcache_min_perf_counters.v
// KHỐI ĐẾM HIỆU NĂNG (PERFORMANCE COUNTERS) CỦA D-CACHE SƠ KHAI
// -----------------------------------------------------------------------------
// Vai trò:
//   - Độc lập hoàn toàn với logic điều khiển và dữ liệu của Cache.
//   - Chỉ lắng nghe các xung sự kiện (ev_*) từ dcache_min_controller để đếm
//     chính xác các thông số về tốc độ xử lý, tỷ lệ Hit/Miss, số lần Write-Back,
//     số chu kỳ dừng CPU (Stall Cycles) và lưu lượng truyền RAM (Memory Traffic).
// =============================================================================
module dcache_min_perf_counters (
    input  wire        clk,
    input  wire        rst_n,

    // --- Loại giao dịch hiện tại của CPU (0: Đọc, 1: Ghi) ---
    input  wire        cpu_we,

    // --- Các xung sự kiện (1 chu kỳ) báo từ Controller ---
    input  wire        ev_access,        // Bắt đầu 1 truy cập từ CPU
    input  wire        ev_hit,           // Truy cập trúng Cache (Hit)
    input  wire        ev_miss,          // Truy cập trượt Cache (Miss)
    input  wire        ev_writeback,     // Phải đẩy dòng bẩn xuống RAM (Dirty Eviction)
    input  wire        ev_stall,         // CPU bị dừng trong chu kỳ hiện tại
    input  wire        ev_mem_xfer,      // 1 word vừa truyền qua bus RAM

    // --- Các thanh ghi bộ đếm xuất ra ngoài ---
    output reg  [31:0] cnt_accesses,     // Tổng số lần truy cập (= Hits + Misses)
    output reg  [31:0] cnt_hits,         // Tổng số lần Cache Hit
    output reg  [31:0] cnt_read_hits,    // Số lần Read Hit
    output reg  [31:0] cnt_write_hits,   // Số lần Write Hit
    output reg  [31:0] cnt_misses,       // Tổng số lần Cache Miss
    output reg  [31:0] cnt_read_misses,  // Số lần Read Miss
    output reg  [31:0] cnt_write_misses, // Số lần Write Miss
    output reg  [31:0] cnt_writebacks,   // Số lần Write-Back dòng Dirty
    output reg  [31:0] cnt_stall_cycles, // Tổng số chu kỳ dừng CPU
    output reg  [31:0] cnt_mem_traffic   // Tổng số word đọc/ghi trên bus RAM
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_accesses     <= 32'd0;
            cnt_hits         <= 32'd0;
            cnt_read_hits    <= 32'd0;
            cnt_write_hits   <= 32'd0;
            cnt_misses       <= 32'd0;
            cnt_read_misses  <= 32'd0;
            cnt_write_misses <= 32'd0;
            cnt_writebacks   <= 32'd0;
            cnt_stall_cycles <= 32'd0;
            cnt_mem_traffic  <= 32'd0;
        end else begin
            // 1. Đếm tổng số lần CPU truy cập
            if (ev_access)
                cnt_accesses <= cnt_accesses + 1'b1;

            // 2. Đếm số lần Cache Hit (tách rõ Read Hit và Write Hit)
            if (ev_hit) begin
                cnt_hits <= cnt_hits + 1'b1;
                if (cpu_we) cnt_write_hits <= cnt_write_hits + 1'b1;
                else        cnt_read_hits  <= cnt_read_hits  + 1'b1;
            end

            // 3. Đếm số lần Cache Miss (tách rõ Read Miss và Write Miss)
            if (ev_miss) begin
                cnt_misses <= cnt_misses + 1'b1;
                if (cpu_we) cnt_write_misses <= cnt_write_misses + 1'b1;
                else        cnt_read_misses  <= cnt_read_misses  + 1'b1;
            end

            // 4. Đếm số lần phải Write-Back dòng Dirty về RAM
            if (ev_writeback)
                cnt_writebacks <= cnt_writebacks + 1'b1;

            // 5. Đếm số chu kỳ CPU bị dừng (Stall Cycles)
            if (ev_stall)
                cnt_stall_cycles <= cnt_stall_cycles + 1'b1;

            // 6. Đếm lưu lượng dữ liệu truyền trên bus RAM (tính theo word)
            if (ev_mem_xfer)
                cnt_mem_traffic <= cnt_mem_traffic + 1'b1;
        end
    end

endmodule
