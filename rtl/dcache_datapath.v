`timescale 1ns / 1ps
// =============================================================================
// dcache_datapath.v
// Đường dữ liệu của D-Cache 2-way set-associative.
//   - Chứa Tag / Valid / Dirty / Data array, bit LRU và Write Buffer.
//   - Tra cứu Hit/Miss song song 2 way, chọn Victim way.
//   - Tạo thanh ghi cpu_rdata, mem_addr, mem_wdata.
//   - Mọi thao tác ghi đều do strobe từ dcache_controller ra lệnh.
// =============================================================================
module dcache_datapath #(
    parameter ADDR_WIDTH     = 32,
    parameter DATA_WIDTH     = 32,
    parameter NUM_SETS       = 64,
    parameter WAYS           = 2,
    parameter WORDS_PER_LINE = 4,
    parameter OFFSET_BITS    = 4,
    parameter WORD_BITS      = 2,
    parameter INDEX_BITS     = 6,
    parameter TAG_BITS       = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // --- Dữ liệu từ CPU ---
    input  wire                  cpu_we,
    input  wire [3:0]            cpu_wstrb,
    input  wire [ADDR_WIDTH-1:0] cpu_addr,
    input  wire [DATA_WIDTH-1:0] cpu_wdata,
    output reg  [DATA_WIDTH-1:0] cpu_rdata,

    // --- Dữ liệu bộ nhớ ---
    output reg  [ADDR_WIDTH-1:0] mem_addr,
    output reg  [DATA_WIDTH-1:0] mem_wdata,
    output reg  [3:0]            mem_wstrb,
    input  wire [DATA_WIDTH-1:0] mem_rdata,

    // --- Con trỏ từ Controller ---
    input  wire [1:0]            word_cnt,
    input  wire                  saved_victim_way,
    input  wire [INDEX_BITS-1:0] flush_set,
    input  wire                  flush_way,

    // --- Strobe từ Controller ---
    input  wire                  dp_req_latch,
    input  wire                  dp_use_latched,
    input  wire                  dp_inval_all,
    input  wire                  dp_hit_rd,
    input  wire                  dp_hit_wr,
    input  wire                  dp_wb_load,
    input  wire                  dp_wb_clear,
    input  wire                  dp_refill_we,
    input  wire                  dp_refill_done,
    input  wire                  dp_unc_rdata,
    input  wire                  dp_flush_clean,
    input  wire                  dp_mem_ld,
    input  wire [1:0]            dp_mem_sel,
    input  wire [1:0]            dp_mem_word,

    // --- Trạng thái gửi về Controller ---
    output wire                  is_uncached,
    output wire                  cache_hit,
    output wire                  hit_way0,
    output wire                  hit_way1,
    output wire                  victim_way,
    output wire                  victim_dirty,
    output reg                   wb_valid,
    output reg  [ADDR_WIDTH-1:0] wb_base_addr,
    output wire                  flush_line_dirty
);

    localparam MS_UNCACHED = 2'd0;
    localparam MS_REFILL   = 2'd1;
    localparam MS_WB       = 2'd2;
    localparam MS_FLUSH    = 2'd3;

    // -------------------------------------------------------------------------
    // Thanh ghi chốt yêu cầu CPU (Bảo đảm hợp đồng giao tiếp ổn định suốt Miss/Uncached)
    // -------------------------------------------------------------------------
    reg                  req_we_q;
    reg [3:0]            req_wstrb_q;
    reg [ADDR_WIDTH-1:0] req_addr_q;
    reg [DATA_WIDTH-1:0] req_wdata_q;

    wire                  eff_we    = dp_use_latched ? req_we_q    : cpu_we;
    wire [3:0]            eff_wstrb = dp_use_latched ? req_wstrb_q : cpu_wstrb;
    wire [ADDR_WIDTH-1:0] eff_addr  = dp_use_latched ? req_addr_q  : cpu_addr;
    wire [DATA_WIDTH-1:0] eff_wdata = dp_use_latched ? req_wdata_q : cpu_wdata;

    // -------------------------------------------------------------------------
    // Phân rã địa chỉ (Mặc định 64 sets: [31:10] Tag | [9:4] Index | [3:2] Word | [1:0] Byte)
    // Bản đồ địa chỉ SoC (SoC Address Map - Không Alias):
    //   - 0x0000_0000 .. 0x0000_BFFF (bit 31 = 0): Cacheable Main RAM (48 KB, word 0x0000..0x2FFF)
    //   - 0x8000_0000 .. 0x8000_3FFF (bit 31 = 1): Uncached Shared RAM / DMA Buffer (16 KB, word 0x3000..0x3FFF)
    //   - 0x8001_0000 .. 0x8001_003F (bit 31 = 1): Uncached MMIO / DMA Control Registers (16 regs)
    //   - Địa chỉ ngoài các vùng trên             : Invalid Address (báo addr_error = 1)
    // -------------------------------------------------------------------------
    wire [TAG_BITS-1:0]   req_tag   = eff_addr[ADDR_WIDTH-1 : INDEX_BITS+OFFSET_BITS];
    wire [INDEX_BITS-1:0] req_index = eff_addr[INDEX_BITS+OFFSET_BITS-1 : OFFSET_BITS];
    wire [WORD_BITS-1:0]  req_word  = eff_addr[OFFSET_BITS-1 : 2];
    assign is_uncached = eff_addr[31]; // bit 31 = 1: Bypass Cache (Uncached RAM & MMIO/DMA)

    // -------------------------------------------------------------------------
    // Mảng lưu trữ
    // -------------------------------------------------------------------------
    reg [TAG_BITS-1:0]   tag_array   [0:NUM_SETS-1][0:WAYS-1];
    reg [DATA_WIDTH-1:0] data_array  [0:NUM_SETS-1][0:WAYS-1][0:WORDS_PER_LINE-1];
    reg                  valid_array [0:NUM_SETS-1][0:WAYS-1];
    reg                  dirty_array [0:NUM_SETS-1][0:WAYS-1];
    reg                  lru_bit     [0:NUM_SETS-1]; // 0: Way 0 là LRU, 1: Way 1 là LRU

    // Write Buffer (Eviction Buffer 1 dòng)
    reg [DATA_WIDTH-1:0] wb_data [0:WORDS_PER_LINE-1];

    // -------------------------------------------------------------------------
    // Hợp nhất Đường truy cập Đọc/Ghi cho Tag Array & Data Array (Giải quyết Mục 3.1
    // khi tổng hợp trên FPGA DE10-Standard):
    //   - Các thao tác đọc Data Array (Hit Read, Load Write Buffer, Refill Bypass,
    //     và Flush Read) hoàn toàn loại trừ nhau theo thời gian (mutually exclusive).
    //   - Do đó, toàn bộ các đường đọc được dồn kênh (multiplex) về DUY NHẤT 1 địa chỉ
    //     đọc (rd_set, rd_way) trên 4 word của dòng Cache, và toàn bộ các đường ghi
    //     (Hit Write, Refill Word Write, Refill CPU Write) được dồn về DUY NHẤT 1 địa
    //     chỉ ghi (req_index, wr_way), giúp giảm mạnh số bộ dồn kênh (MUX) và ALM.
    // -------------------------------------------------------------------------
    localparam WAY1_IDX = (WAYS > 1) ? 1 : 0;

    // Tra cứu Tag trực tiếp theo req_index (tránh vòng lặp tổ hợp từ strobe của Controller)
    assign hit_way0  = valid_array[req_index][0] && (tag_array[req_index][0] == req_tag) && !is_uncached;
    assign hit_way1  = (WAYS > 1) ? (valid_array[req_index][WAY1_IDX] &&
                                     (tag_array[req_index][WAY1_IDX] == req_tag) && !is_uncached)
                                  : 1'b0;
    assign cache_hit = hit_way0 || hit_way1;
    wire   hit_way   = hit_way1;

    // Chọn Victim: nếu Direct-Mapped (WAYS=1) luôn chọn way 0; nếu 2-Way ưu tiên way trống rồi theo LRU
    assign victim_way   = (WAYS == 1)                        ? 1'b0 :
                          (!valid_array[req_index][0])       ? 1'b0 :
                          (!valid_array[req_index][WAY1_IDX]) ? 1'b1 :
                          lru_bit[req_index];
    assign victim_dirty = valid_array[req_index][victim_way] && dirty_array[req_index][victim_way];

    // Dòng tại con trỏ Flush
    assign flush_line_dirty = valid_array[flush_set][flush_way] && dirty_array[flush_set][flush_way];

    // Chọn Set, Way và Word duy nhất cho cổng đọc hợp nhất của Data Array
    wire                  is_flush_rd = dp_mem_ld && (dp_mem_sel == MS_FLUSH);
    wire [INDEX_BITS-1:0] rd_set      = is_flush_rd    ? flush_set        : req_index;
    wire                  rd_way      = is_flush_rd    ? flush_way        :
                                        dp_refill_done ? saved_victim_way :
                                        dp_wb_load     ? victim_way       : hit_way;
    wire [1:0]            rd_word     = is_flush_rd    ? dp_mem_word      : req_word;
    wire [TAG_BITS-1:0]   rd_tag_sel  = tag_array[rd_set][rd_way];

    wire [DATA_WIDTH-1:0] rd_line_w0  = data_array[rd_set][rd_way][0];
    wire [DATA_WIDTH-1:0] rd_line_w1  = data_array[rd_set][rd_way][1];
    wire [DATA_WIDTH-1:0] rd_line_w2  = data_array[rd_set][rd_way][2];
    wire [DATA_WIDTH-1:0] rd_line_w3  = data_array[rd_set][rd_way][3];

    wire [DATA_WIDTH-1:0] rd_word_mux = (rd_word == 2'd0) ? rd_line_w0 :
                                        (rd_word == 2'd1) ? rd_line_w1 :
                                        (rd_word == 2'd2) ? rd_line_w2 :
                                                            rd_line_w3;

    // Ghi theo Byte Mask (hỗ trợ SB/SH/SW)
    function [DATA_WIDTH-1:0] apply_wstrb(
        input [DATA_WIDTH-1:0] old_word,
        input [DATA_WIDTH-1:0] new_word,
        input [3:0]            wstrb
    );
        begin
            apply_wstrb[7:0]   = wstrb[0] ? new_word[7:0]   : old_word[7:0];
            apply_wstrb[15:8]  = wstrb[1] ? new_word[15:8]  : old_word[15:8];
            apply_wstrb[23:16] = wstrb[2] ? new_word[23:16] : old_word[23:16];
            apply_wstrb[31:24] = wstrb[3] ? new_word[31:24] : old_word[31:24];
        end
    endfunction

    // Word CPU yêu cầu trong lúc kết thúc Refill: word cuối vừa về chưa nằm trong array
    wire [DATA_WIDTH-1:0] refill_req_word =
        (req_word == WORDS_PER_LINE-1) ? mem_rdata : rd_word_mux;

    integer s, w, k;

    // -------------------------------------------------------------------------
    // Cập nhật Metadata (Valid, Dirty, LRU, Write Buffer status) + cpu_rdata
    // Hợp đồng phần cứng khi Reset cứng (Hard Reset: rst_n = 0):
    //   - Khi rst_n = 0, wb_valid cùng toàn bộ valid_array và dirty_array bị xóa về 0
    //     để đưa Cache về trạng thái khởi đầu sạch.
    //   - Mọi word của Write Buffer ĐÃ hoàn tất bắt tay ghi xuống RAM (mem_req && mem_we
    //     && mem_ready == 1) trước thời điểm rst_n = 0 đều đã nằm an toàn trong RAM.
    //   - Các word chưa kịp bắt tay trong Write Buffer (wb_valid == 1) hoặc các dòng
    //     Dirty còn nằm trong Cache (dirty_array == 1) sẽ bị hủy (aborted) khi Hard Reset.
    //   - Để bảo toàn 100% dữ liệu bẩn trước khi khởi động lại mềm (Warm Reset), phần mềm
    //     phải thực thi lệnh CLEAN (cache_flush = 1) và chờ maint_done == 1 trước khi Reset.
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        s = 0;
        w = 0;
        if (!rst_n) begin
            cpu_rdata    <= {DATA_WIDTH{1'b0}};
            wb_valid     <= 1'b0;
            wb_base_addr <= {ADDR_WIDTH{1'b0}};
            req_we_q     <= 1'b0;
            req_wstrb_q  <= 4'b0000;
            req_addr_q   <= {ADDR_WIDTH{1'b0}};
            req_wdata_q  <= {DATA_WIDTH{1'b0}};
            for (s = 0; s < NUM_SETS; s = s + 1) begin
                lru_bit[s] <= 1'b0;
                for (w = 0; w < WAYS; w = w + 1) begin
                    valid_array[s][w] <= 1'b0;
                    dirty_array[s][w] <= 1'b0;
                end
            end
        end else begin
            // --- Chốt yêu cầu CPU khi bắt đầu giao dịch nhiều chu kỳ (Miss / Uncached) ---
            if (dp_req_latch) begin
                req_we_q    <= cpu_we;
                req_wstrb_q <= cpu_wstrb;
                req_addr_q  <= cpu_addr;
                req_wdata_q <= cpu_wdata;
            end

            // --- Invalidate có điều kiện: chỉ xóa Valid của các dòng Clean (!Dirty) ---
            // Bảo vệ dữ liệu Dirty chưa ghi trả không bị mất vô tình. Khi thực hiện
            // CLEAN_INVALIDATE, S_FLUSH đã ghi trả và xóa hết Dirty trước đó nên
            // bước này sẽ xóa Valid toàn bộ Cache.
            if (dp_inval_all) begin
                for (s = 0; s < NUM_SETS; s = s + 1) begin
                    for (w = 0; w < WAYS; w = w + 1) begin
                        if (!dirty_array[s][w]) begin
                            valid_array[s][w] <= 1'b0;
                        end
                    end
                end
            end

            // --- Hit: cập nhật LRU (way còn lại thành LRU) ---
            if (dp_hit_rd || dp_hit_wr)
                lru_bit[req_index] <= ~hit_way;

            if (dp_hit_rd)
                cpu_rdata <= rd_word_mux;

            if (dp_hit_wr)
                dirty_array[req_index][hit_way] <= 1'b1;

            // --- Đẩy dòng victim Dirty vào Write Buffer ---
            if (dp_wb_load) begin
                wb_valid     <= 1'b1;
                wb_base_addr <= {rd_tag_sel, req_index, {OFFSET_BITS{1'b0}}};
                dirty_array[req_index][victim_way] <= 1'b0;
            end

            if (dp_wb_clear)
                wb_valid <= 1'b0;

            // --- Refill xong: cập nhật metadata + trả dữ liệu cho CPU ---
            if (dp_refill_done) begin
                valid_array[req_index][saved_victim_way] <= 1'b1;
                lru_bit[req_index]                       <= ~saved_victim_way;
                if (eff_we) begin
                    dirty_array[req_index][saved_victim_way] <= 1'b1;
                end else begin
                    cpu_rdata <= refill_req_word;
                    dirty_array[req_index][saved_victim_way] <= 1'b0;
                end
            end

            // --- Uncached: trả dữ liệu từ bộ nhớ ---
            if (dp_unc_rdata)
                cpu_rdata <= mem_rdata;

            // --- Flush: dòng đã ghi trả xong ---
            if (dp_flush_clean)
                dirty_array[flush_set][flush_way] <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Cập nhật mảng Tag / Data / Write Buffer Data (Đồng bộ thuần theo clk,
    // hợp nhất 1 địa chỉ ghi (req_index, wr_way) để tối ưu tài nguyên FPGA)
    // -------------------------------------------------------------------------
    wire                  wr_way        = dp_hit_wr ? hit_way : saved_victim_way;
    wire [DATA_WIDTH-1:0] hit_wr_merged = apply_wstrb(rd_word_mux, cpu_wdata, cpu_wstrb);
    wire [DATA_WIDTH-1:0] ref_wr_merged = apply_wstrb(refill_req_word, eff_wdata, eff_wstrb);

    always @(posedge clk) begin
        k = 0;
        if (dp_wb_load) begin
            wb_data[0] <= rd_line_w0;
            wb_data[1] <= rd_line_w1;
            wb_data[2] <= rd_line_w2;
            wb_data[3] <= rd_line_w3;
        end

        if (dp_refill_done)
            tag_array[req_index][saved_victim_way] <= req_tag;

        // Cổng ghi hợp nhất trên từng word k của dòng (req_index, wr_way)
        for (k = 0; k < WORDS_PER_LINE; k = k + 1) begin
            if (dp_hit_wr && (req_word == k[1:0])) begin
                data_array[req_index][wr_way][k] <= hit_wr_merged;
            end else if (dp_refill_done && eff_we && (req_word == k[1:0])) begin
                data_array[req_index][wr_way][k] <= ref_wr_merged;
            end else if (dp_refill_we && (word_cnt == k[1:0])) begin
                data_array[req_index][wr_way][k] <= mem_rdata;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Thanh ghi địa chỉ / dữ liệu / byte-enable ghi xuống bộ nhớ
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        s = 0;
        w = 0;
        if (!rst_n) begin
            mem_addr  <= {ADDR_WIDTH{1'b0}};
            mem_wdata <= {DATA_WIDTH{1'b0}};
            mem_wstrb <= 4'b0000;
        end else if (dp_mem_ld) begin
            case (dp_mem_sel)
                MS_UNCACHED: begin
                    mem_addr  <= {eff_addr[ADDR_WIDTH-1:2], 2'b00};
                    mem_wdata <= eff_wdata;
                    mem_wstrb <= eff_wstrb;
                end
                MS_REFILL: begin
                    mem_addr  <= {req_tag, req_index, dp_mem_word, 2'b00};
                    mem_wstrb <= 4'b0000;
                end
                MS_WB: begin
                    mem_addr  <= wb_base_addr + {dp_mem_word, 2'b00};
                    mem_wdata <= wb_data[dp_mem_word];
                    mem_wstrb <= 4'b1111;
                end
                MS_FLUSH: begin
                    mem_addr  <= {rd_tag_sel, flush_set, dp_mem_word, 2'b00};
                    mem_wdata <= rd_word_mux;
                    mem_wstrb <= 4'b1111;
                end
            endcase
        end
    end

endmodule
