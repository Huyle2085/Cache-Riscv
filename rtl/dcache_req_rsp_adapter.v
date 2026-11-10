`timescale 1ns / 1ps
// =============================================================================
// dcache_req_rsp_adapter.v
// Bộ chuyển đổi (Adapter) chuẩn hóa giao thức 2 pha độc lập (Request / Response)
// cho D-Cache 2-Way (Giải quyết Vấn đề B khi mở rộng SoC với các Master tổng quát):
//   - Pha Request : req_valid & req_ready (Xác nhận nhận yêu cầu khi cả hai bằng 1).
//                   Sau chu kỳ bắt tay req_valid && req_ready == 1, Master có thể hạ
//                   ngay req_valid = 0 hoặc phát tiếp yêu cầu mới mà giao dịch đã nhận
//                   vẫn được xử lý đến hết.
//   - Pha Response: rsp_valid & rsp_rdata (Báo giao dịch đã hoàn thành và trả dữ liệu).
//   - Hỗ trợ nhận yêu cầu mới (Back-to-Back 0-bubble) ngay trong đúng chu kỳ
//     rsp_valid == 1 (cpu_ready == 1) nhờ thanh ghi đệm 1 mục (Skid Buffer).
// =============================================================================
module dcache_req_rsp_adapter #(
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // --- Giao diện Master tổng quát 2 pha (Decoupled Request / Response) ---
    input  wire                  req_valid,
    output wire                  req_ready,
    input  wire                  req_we,
    input  wire [3:0]            req_wstrb,
    input  wire [ADDR_WIDTH-1:0] req_addr,
    input  wire [DATA_WIDTH-1:0] req_wdata,

    output wire                  rsp_valid,
    output wire [DATA_WIDTH-1:0] rsp_rdata,

    // --- Giao diện nối tới riscv_dcache_2way ---
    output wire                  cpu_req,
    input  wire                  cpu_req_ready,
    output wire                  cpu_we,
    output wire [3:0]            cpu_wstrb,
    output wire [ADDR_WIDTH-1:0] cpu_addr,
    output wire [DATA_WIDTH-1:0] cpu_wdata,
    input  wire [DATA_WIDTH-1:0] cpu_rdata,
    input  wire                  cpu_ready
);

    // Thanh ghi đệm (Skid Buffer 1 mục) lưu yêu cầu mới khi Master phát req_valid
    // ngay trong chu kỳ cpu_ready == 1 (lúc Cache vừa trả kết quả của giao dịch trước).
    reg                  buf_valid;
    reg                  buf_we;
    reg [3:0]            buf_wstrb;
    reg [ADDR_WIDTH-1:0] buf_addr;
    reg [DATA_WIDTH-1:0] buf_wdata;

    // Adapter sẵn sàng nhận yêu cầu mới khi:
    //   1. Skid Buffer đang trống (!buf_valid), VÀ
    //   2. Cache đang sẵn sàng nhận trực tiếp (cpu_req_ready == 1) HOẶC Cache vừa hoàn tất
    //      giao dịch trước trong chu kỳ này (cpu_ready == 1, sẽ chốt vào Skid Buffer).
    assign req_ready = !buf_valid && (cpu_req_ready || cpu_ready);

    // Đường điều khiển và dữ liệu sang D-Cache:
    //   - Nếu có yêu cầu đang giữ trong Skid Buffer (buf_valid == 1), phát yêu cầu đó.
    //   - Ngược lại, chuyển trực tiếp yêu cầu từ Master sang D-Cache (khi !cpu_ready).
    assign cpu_req   = buf_valid ? 1'b1      : (req_valid && !cpu_ready);
    assign cpu_we    = buf_valid ? buf_we    : req_we;
    assign cpu_wstrb = buf_valid ? buf_wstrb : req_wstrb;
    assign cpu_addr  = buf_valid ? buf_addr  : req_addr;
    assign cpu_wdata = buf_valid ? buf_wdata : req_wdata;

    // Pha Response trả về Master
    assign rsp_valid = cpu_ready;
    assign rsp_rdata = cpu_rdata;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_valid <= 1'b0;
            buf_we    <= 1'b0;
            buf_wstrb <= 4'b0000;
            buf_addr  <= {ADDR_WIDTH{1'b0}};
            buf_wdata <= {DATA_WIDTH{1'b0}};
        end else begin
            if (buf_valid) begin
                // Khi D-Cache đã nhận yêu cầu từ Skid Buffer (cpu_req_ready == 1),
                // giải phóng Skid Buffer.
                if (cpu_req_ready)
                    buf_valid <= 1'b0;
            end else if (req_valid && cpu_ready) begin
                // Master phát yêu cầu mới ngay trong chu kỳ cpu_ready == 1:
                // Chốt vào Skid Buffer để chuyển giao cho D-Cache ở chu kỳ kế tiếp.
                buf_valid <= 1'b1;
                buf_we    <= req_we;
                buf_wstrb <= req_wstrb;
                buf_addr  <= req_addr;
                buf_wdata <= req_wdata;
            end
        end
    end

endmodule
