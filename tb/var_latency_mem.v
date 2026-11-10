`timescale 1ns / 1ps
// =============================================================================
// var_latency_mem.v
// Mô hình Bộ nhớ chính (RAM) có độ trễ biến thiên (Variable Latency Memory).
//   - Sử dụng LFSR 8-bit sinh độ trễ ngẫu nhiên từ BASE_DELAY đến BASE_DELAY+3
//     (mặc định: 2..5 chu kỳ khi VAR_ENABLE = 1).
//   - Tích hợp bộ đếm phân bố độ trễ (lat_hist) để xuất bằng chứng kiểm chứng
//     độ trễ biến thiên ra log mô phỏng.
// =============================================================================
module var_latency_mem #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter MEM_WORDS  = 16384, // 64 KB RAM
    parameter BASE_DELAY = 3'd2,  // Độ trễ cơ sở (mặc định 2 chu kỳ)
    parameter VAR_ENABLE = 1      // 1: Độ trễ biến thiên BASE_DELAY..BASE_DELAY+3, 0: Cố định
)(
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  mem_req,
    input  wire                  mem_we,
    input  wire [3:0]            mem_wstrb,
    input  wire [ADDR_WIDTH-1:0] mem_addr,
    input  wire [DATA_WIDTH-1:0] mem_wdata,
    output reg  [DATA_WIDTH-1:0] mem_rdata,
    output reg                   mem_ready
);

    reg [DATA_WIDTH-1:0] ram [0:MEM_WORDS-1];
    reg [4:0]            delay_cnt;
    reg [4:0]            target_delay;
    reg [7:0]            lfsr;
    reg [ADDR_WIDTH-1:0] prev_addr;
    reg                  busy;

    // Số chu kỳ kìm hãm (backpressure) cộng thêm từ Testbench khi kiểm thử T14/T18 (mặc định = 0)
    integer              backpressure_extra;

    // Bộ đếm thống kê phân bố độ trễ RAM (phục vụ báo cáo kiểm chứng)
    integer              lat_hist [0:31];
    integer              total_xfers;
    integer              total_lat_cycles;

    wire [13:0] word_addr = mem_addr[15:2];

    integer i;
    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1)
            ram[i] = 32'h1000_0000 + i; // Khởi tạo dữ liệu mẫu dễ kiểm tra
        for (i = 0; i < 32; i = i + 1)
            lat_hist[i] = 0;
        backpressure_extra = 0;
        total_xfers        = 0;
        total_lat_cycles   = 0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr             <= 8'hA5;
            delay_cnt        <= 5'd0;
            target_delay     <= {2'b00, BASE_DELAY[2:0]};
            mem_ready        <= 1'b0;
            mem_rdata        <= 32'd0;
            busy             <= 1'b0;
            prev_addr        <= 32'd0;
            total_xfers      <= 0;
            total_lat_cycles <= 0;
            for (i = 0; i < 32; i = i + 1)
                lat_hist[i] <= 0;
        end else begin
            // LFSR sinh số giả ngẫu nhiên cho độ trễ biến thiên
            lfsr      <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
            mem_ready <= 1'b0;

            if (mem_req && !mem_ready) begin
                if (!busy || (mem_addr != prev_addr)) begin
                    busy         <= 1'b1;
                    prev_addr    <= mem_addr;
                    delay_cnt    <= 5'd1;
                    target_delay <= {2'b00, BASE_DELAY[2:0]} +
                                    (VAR_ENABLE ? {3'b000, lfsr[1:0]} : 5'd0) +
                                    backpressure_extra[4:0];
                end else if (delay_cnt < target_delay) begin
                    delay_cnt <= delay_cnt + 1'b1;
                end else begin
                    // Hoàn tất truy cập bộ nhớ
                    mem_ready        <= 1'b1;
                    busy             <= 1'b0;
                    lat_hist[target_delay] <= lat_hist[target_delay] + 1;
                    total_xfers      <= total_xfers + 1;
                    total_lat_cycles <= total_lat_cycles + target_delay;
                    if (mem_we) begin
                        if (mem_wstrb[0]) ram[word_addr][7:0]   <= mem_wdata[7:0];
                        if (mem_wstrb[1]) ram[word_addr][15:8]  <= mem_wdata[15:8];
                        if (mem_wstrb[2]) ram[word_addr][23:16] <= mem_wdata[23:16];
                        if (mem_wstrb[3]) ram[word_addr][31:24] <= mem_wdata[31:24];
                    end else begin
                        mem_rdata <= ram[word_addr];
                    end
                end
            end else begin
                busy <= 1'b0;
            end
        end
    end

endmodule