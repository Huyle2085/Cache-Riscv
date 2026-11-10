`timescale 1ns / 1ps
// =============================================================================
// dcache_perf_counters.v
// Bộ đếm hiệu năng của D-Cache (phục vụ báo cáo Miss Rate, AMAT, Traffic...).
// Chỉ đếm sự kiện do dcache_controller báo, không ảnh hưởng chức năng Cache.
// =============================================================================
module dcache_perf_counters (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        ev_access,    // 1 truy cập Cached (hit hoặc miss)
    input  wire        ev_miss,      // 1 lần Miss
    input  wire        ev_stall,     // CPU bị dừng trong chu kỳ này
    input  wire        ev_mem_xfer,  // 1 word truyền qua bus bộ nhớ
    input  wire        ev_coherence, // 1 chu kỳ dành cho Flush/Invalidate

    output reg  [31:0] cnt_accesses,
    output reg  [31:0] cnt_misses,
    output reg  [31:0] cnt_stall_cycles,
    output reg  [31:0] cnt_mem_traffic,
    output reg  [31:0] cnt_coherence_cyc
);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt_accesses      <= 32'd0;
            cnt_misses        <= 32'd0;
            cnt_stall_cycles  <= 32'd0;
            cnt_mem_traffic   <= 32'd0;
            cnt_coherence_cyc <= 32'd0;
        end else begin
            if (ev_access)    cnt_accesses      <= cnt_accesses      + 1'b1;
            if (ev_miss)      cnt_misses        <= cnt_misses        + 1'b1;
            if (ev_stall)     cnt_stall_cycles  <= cnt_stall_cycles  + 1'b1;
            if (ev_mem_xfer)  cnt_mem_traffic   <= cnt_mem_traffic   + 1'b1;
            if (ev_coherence) cnt_coherence_cyc <= cnt_coherence_cyc + 1'b1;
        end
    end

endmodule
