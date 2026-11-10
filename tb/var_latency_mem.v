`timescale 1ns / 1ps
// =============================================================================
// var_latency_mem.v
// Mô hình Bộ nhớ chính (RAM) & Giải mã Địa chỉ SoC có độ trễ biến thiên.
//   - Sử dụng LFSR 8-bit sinh độ trễ ngẫu nhiên từ BASE_DELAY đến BASE_DELAY+3
//     (mặc định: 2..5 chu kỳ khi VAR_ENABLE = 1).
//   - Bản đồ địa chỉ SoC hoàn chỉnh (Giải quyết Vấn đề C - Không Alias địa chỉ):
//       1. Vùng Cacheable Main RAM (0x0000_0000 .. 0x0000_BFFF, 48 KB):
//          Ánh xạ vật lý vào ram[14'h0000 .. 14'h2FFF] (word 0 .. 12287).
//       2. Vùng Uncached Shared RAM / DMA Buffer (0x8000_0000 .. 0x8000_3FFF, 16 KB):
//          Ánh xạ vật lý vào ram[14'h3000 .. 14'h3FFF] (word 12288 .. 16383).
//          => Tách biệt vật lý hoàn toàn với vùng Cacheable (0x0000_0010 và
//             0x8000_0010 KHÔNG còn trỏ vào cùng một ô nhớ).
//       3. Vùng Uncached MMIO / DMA Registers (0x8001_0000 .. 0x8001_003F, 64 Bytes):
//          Ánh xạ vào tập 16 thanh ghi điều khiển mmio_regs[0:15] (ví dụ: DMA_SRC,
//          DMA_DST, DMA_LEN, DMA_CTRL/STATUS).
//       4. Địa chỉ không hợp lệ (Ngoài 3 vùng trên):
//          Bật cờ addr_error = 1, tăng bộ đếm addr_err_cnt, chặn ghi bộ nhớ và
//          trả về mã lỗi 32'hDEAD_BAD0 khi đọc.
// =============================================================================
module var_latency_mem #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter MEM_WORDS  = 16384, // 64 KB tổng cộng (48 KB Cached RAM + 16 KB Uncached RAM)
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
    output reg                   mem_ready,
    output reg                   addr_error
);

    reg [DATA_WIDTH-1:0] ram       [0:MEM_WORDS-1];
    reg [DATA_WIDTH-1:0] mmio_regs [0:15];
    reg [4:0]            delay_cnt;
    reg [4:0]            target_delay;
    reg [7:0]            lfsr;
    reg [ADDR_WIDTH-1:0] prev_addr;
    reg                  busy;

    // Số chu kỳ kìm hãm (backpressure) cộng thêm từ Testbench khi kiểm thử T14/T18 (mặc định = 0)
    integer              backpressure_extra;

    // Bộ đếm thống kê phân bố độ trễ RAM & lỗi địa chỉ (phục vụ báo cáo kiểm chứng)
    integer              lat_hist [0:31];
    integer              total_xfers;
    integer              total_lat_cycles;
    integer              addr_err_cnt;

    // -------------------------------------------------------------------------
    // Bộ giải mã địa chỉ SoC (SoC Address Decoder - Không Alias)
    // -------------------------------------------------------------------------
    // 1. Cacheable Main RAM: 0x0000_0000 .. 0x0000_BFFF (48 KB = 12,288 words)
    wire is_cached_ram   = (mem_addr[31:16] == 16'h0000) && (mem_addr[15:14] != 2'b11);

    // 2. Uncached Shared RAM / DMA Buffer: 0x8000_0000 .. 0x8000_3FFF (16 KB = 4,096 words)
    wire is_uncached_ram = (mem_addr[31:14] == 18'h20000);

    // 3. Uncached MMIO / DMA Control Registers: 0x8001_0000 .. 0x8001_003F (16 words)
    wire is_mmio_reg     = (mem_addr[31:6]  == 26'h2000400);

    // 4. Địa chỉ không hợp lệ (Unmapped / Invalid Address)
    wire is_invalid_addr = !(is_cached_ram || is_uncached_ram || is_mmio_reg);

    // Ánh xạ chỉ số word vật lý trong mảng ram[0:16383]:
    //   - Cached RAM   -> 14'h0000 .. 14'h2FFF (mem_addr[15:2])
    //   - Uncached RAM -> 14'h3000 .. 14'h3FFF ({2'b11, mem_addr[13:2]})
    wire [13:0] ram_word_addr = is_uncached_ram ? {2'b11, mem_addr[13:2]} : mem_addr[15:2];
    wire [3:0]  mmio_reg_idx  = mem_addr[5:2];

    integer i;
    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1)
            ram[i] = 32'h1000_0000 + i; // Khởi tạo dữ liệu mẫu dễ kiểm tra
        for (i = 0; i < 16; i = i + 1)
            mmio_regs[i] = 32'd0;
        for (i = 0; i < 32; i = i + 1)
            lat_hist[i] = 0;
        backpressure_extra = 0;
        total_xfers        = 0;
        total_lat_cycles   = 0;
        addr_err_cnt       = 0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lfsr             <= 8'hA5;
            delay_cnt        <= 5'd0;
            target_delay     <= {2'b00, BASE_DELAY[2:0]};
            mem_ready        <= 1'b0;
            mem_rdata        <= 32'd0;
            addr_error       <= 1'b0;
            busy             <= 1'b0;
            prev_addr        <= 32'd0;
            total_xfers      <= 0;
            total_lat_cycles <= 0;
            addr_err_cnt     <= 0;
            for (i = 0; i < 16; i = i + 1)
                mmio_regs[i] <= 32'd0;
            for (i = 0; i < 32; i = i + 1)
                lat_hist[i] <= 0;
        end else begin
            // LFSR sinh số giả ngẫu nhiên cho độ trễ biến thiên
            lfsr       <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};
            mem_ready  <= 1'b0;
            addr_error <= 1'b0;

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
                    mem_ready              <= 1'b1;
                    busy                   <= 1'b0;
                    lat_hist[target_delay] <= lat_hist[target_delay] + 1;
                    total_xfers            <= total_xfers + 1;
                    total_lat_cycles       <= total_lat_cycles + target_delay;

                    if (is_invalid_addr) begin
                        addr_error   <= 1'b1;
                        addr_err_cnt <= addr_err_cnt + 1;
                        if (!mem_we)
                            mem_rdata <= 32'hDEAD_BAD0;
                    end else if (is_mmio_reg) begin
                        if (mem_we) begin
                            if (mem_wstrb[0]) mmio_regs[mmio_reg_idx][7:0]   <= mem_wdata[7:0];
                            if (mem_wstrb[1]) mmio_regs[mmio_reg_idx][15:8]  <= mem_wdata[15:8];
                            if (mem_wstrb[2]) mmio_regs[mmio_reg_idx][23:16] <= mem_wdata[23:16];
                            if (mem_wstrb[3]) mmio_regs[mmio_reg_idx][31:24] <= mem_wdata[31:24];
                        end else begin
                            mem_rdata <= mmio_regs[mmio_reg_idx];
                        end
                    end else begin
                        // Truy cập Cached RAM (0x0000_xxxx) hoặc Uncached RAM (0x8000_xxxx)
                        if (mem_we) begin
                            if (mem_wstrb[0]) ram[ram_word_addr][7:0]   <= mem_wdata[7:0];
                            if (mem_wstrb[1]) ram[ram_word_addr][15:8]  <= mem_wdata[15:8];
                            if (mem_wstrb[2]) ram[ram_word_addr][23:16] <= mem_wdata[23:16];
                            if (mem_wstrb[3]) ram[ram_word_addr][31:24] <= mem_wdata[31:24];
                        end else begin
                            mem_rdata <= ram[ram_word_addr];
                        end
                    end
                end
            end else begin
                busy <= 1'b0;
            end
        end
    end

endmodule
