`timescale 1ns / 1ps
// =============================================================================
// minimal/dcache_min_datapath.v
// ĐƯỜNG DỮ LIỆU (DATAPATH) CỦA D-CACHE SƠ KHAI
// -----------------------------------------------------------------------------
// Vai trò:
//   - Phân rã địa chỉ 32-bit thành Tag và Set Index.
//   - Chứa 4 bảng lưu trữ 1 chiều (Direct-Mapped, 1 Word/Line):
//       + valid_array [0:NUM_SETS-1]
//       + dirty_array [0:NUM_SETS-1]
//       + tag_array   [0:NUM_SETS-1]
//       + data_array  [0:NUM_SETS-1]
//   - Thực hiện so sánh Tag tổ hợp để báo `cache_hit` và `victim_dirty` về
//     cho khối Controller.
//   - Cập nhật dữ liệu/metadata và xuất `cpu_rdata`, `mem_addr`, `mem_wdata`
//     hoàn toàn theo các xung lệnh (strobe) từ Controller.
// =============================================================================
module dcache_min_datapath #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 32,
    parameter NUM_SETS    = 64,
    parameter INDEX_BITS  = 6,
    parameter OFFSET_BITS = 2,
    parameter TAG_BITS    = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // --- Dữ liệu / Địa chỉ phía CPU ---
    input  wire                  cpu_we,
    input  wire [3:0]            cpu_wstrb,
    input  wire [ADDR_WIDTH-1:0] cpu_addr,
    input  wire [DATA_WIDTH-1:0] cpu_wdata,
    output reg  [DATA_WIDTH-1:0] cpu_rdata,

    // --- Dữ liệu / Địa chỉ phía RAM ---
    output reg  [ADDR_WIDTH-1:0] mem_addr,
    output reg  [DATA_WIDTH-1:0] mem_wdata,
    input  wire [DATA_WIDTH-1:0] mem_rdata,

    // --- Các xung điều khiển (Strobe) nhận từ Controller ---
    input  wire                  dp_hit_read,      // Đọc dữ liệu khi Read Hit
    input  wire                  dp_hit_write,     // Ghi dữ liệu & bật Dirty khi Write Hit
    input  wire                  dp_wb_start,      // Nạp địa chỉ/dữ liệu victim để Write-Back
    input  wire                  dp_alloc_start,   // Nạp địa chỉ dòng mới để Allocate (và xóa Dirty cũ)
    input  wire                  dp_alloc_done,    // Ghi dòng mới từ RAM vào Cache & trả cho CPU

    // --- Trạng thái báo về Controller ---
    output wire                  cache_hit,        // 1: Trúng Cache
    output wire                  victim_dirty      // 1: Dòng hiện tại hợp lệ và đang bẩn (Dirty)
);

    // =========================================================================
    // 1. PHÂN RÃ ĐỊA CHỈ (ADDRESS BREAKDOWN)
    //   +-------------------+--------------------+------------------+
    //   |   TAG (24 bits)   |  INDEX (6 bits)    | BYTE OFFSET (2b) |
    //   |     [31 : 8]      |     [7 : 2]        |     [1 : 0]      |
    //   +-------------------+--------------------+------------------+
    // =========================================================================
    wire [TAG_BITS-1:0]   req_tag   = cpu_addr[ADDR_WIDTH-1 : INDEX_BITS+OFFSET_BITS];
    wire [INDEX_BITS-1:0] req_index = cpu_addr[INDEX_BITS+OFFSET_BITS-1 : OFFSET_BITS];

    // =========================================================================
    // 2. CÁC BẢNG LƯU TRỮ (STORAGE ARRAYS - 1 CHIỀU)
    // =========================================================================
    reg                  valid_array [0:NUM_SETS-1];
    reg                  dirty_array [0:NUM_SETS-1];
    reg [TAG_BITS-1:0]   tag_array   [0:NUM_SETS-1];
    reg [DATA_WIDTH-1:0] data_array  [0:NUM_SETS-1];

    // =========================================================================
    // 3. KIỂM TRA HIT / MISS & ĐỊA CHỈ RAM (MẠCH TỔ HỢP)
    // =========================================================================
    assign cache_hit    = valid_array[req_index] && (tag_array[req_index] == req_tag);
    assign victim_dirty = valid_array[req_index] && dirty_array[req_index];

    // Địa chỉ của dòng cũ đang nằm trong Cache (dùng khi phải Write-Back về RAM)
    wire [ADDR_WIDTH-1:0] victim_addr = {tag_array[req_index], req_index, 2'b00};
    // Địa chỉ của dòng mới mà CPU đang yêu cầu (dùng khi Allocate từ RAM)
    wire [ADDR_WIDTH-1:0] refill_addr = {req_tag, req_index, 2'b00};

    integer i;

    // =========================================================================
    // 4. CẬP NHẬT BẢNG CACHE & THANH GHI NGÕ RA THEO STROBE ĐIỀU KHIỂN
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cpu_rdata <= {DATA_WIDTH{1'b0}};
            mem_addr  <= {ADDR_WIDTH{1'b0}};
            mem_wdata <= {DATA_WIDTH{1'b0}};

            for (i = 0; i < NUM_SETS; i = i + 1) begin
                valid_array[i] <= 1'b0;
                dirty_array[i] <= 1'b0;
                tag_array[i]   <= {TAG_BITS{1'b0}};
                data_array[i]  <= {DATA_WIDTH{1'b0}};
            end
        end else begin
            // --- (A) Khi Read Hit: Đọc từ mảng Data trả về cho CPU ---
            if (dp_hit_read) begin
                cpu_rdata <= data_array[req_index];
            end

            // --- (B) Khi Write Hit: Ghi đè vào mảng Data và bật cờ Dirty = 1 ---
            if (dp_hit_write) begin
                data_array[req_index]  <= cpu_wdata;
                dirty_array[req_index] <= 1'b1;
            end

            // --- (C) Khi bắt đầu Write-Back: Đưa địa chỉ & dữ liệu dòng bẩn ra RAM ---
            if (dp_wb_start) begin
                mem_addr  <= victim_addr;
                mem_wdata <= data_array[req_index];
            end

            // --- (D) Khi bắt đầu Allocate: Đưa địa chỉ dòng mới ra RAM ---
            if (dp_alloc_start) begin
                dirty_array[req_index] <= 1'b0;
                mem_addr               <= refill_addr;
            end

            // --- (E) Khi hoàn tất Allocate: Nạp dòng mới vào Cache & phục vụ CPU ---
            if (dp_alloc_done) begin
                valid_array[req_index] <= 1'b1;
                tag_array[req_index]   <= req_tag;

                if (cpu_we) begin
                    // Write Miss (Write-Allocate): Ghi đè dữ liệu CPU và bật Dirty = 1
                    data_array[req_index]  <= cpu_wdata;
                    dirty_array[req_index] <= 1'b1;
                end else begin
                    // Read Miss: Lưu dữ liệu RAM vào Cache, đặt Dirty = 0 và trả cho CPU
                    data_array[req_index]  <= mem_rdata;
                    dirty_array[req_index] <= 1'b0;
                    cpu_rdata              <= mem_rdata;
                end
            end
        end
    end

endmodule
