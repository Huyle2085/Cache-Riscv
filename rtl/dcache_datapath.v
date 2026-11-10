`timescale 1ns / 1ps
// =============================================================================
// dcache_datapath.v
// Đường dữ liệu của D-Cache 2-way set-associative (Kiến trúc Data Array đồng bộ M10K).
//   - Tag / Valid / Dirty / LRU array dùng cho tra cứu Hit/Miss nhanh trong S_IDLE.
//   - Data Array được thiết kế theo chuẩn bộ nhớ đồng bộ (Synchronous Dual-Port RAM
//     với Byte-Enable theo 4 byte-lane 1D array mỗi word/way) để Quartus II suy diễn
//     trực tiếp thành các khối phần cứng M10K Block RAM trên FPGA DE10-Standard.
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
    output wire [DATA_WIDTH-1:0] cpu_rdata,

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
    localparam WAY1_IDX    = (WAYS > 1) ? 1 : 0;

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
    // Mảng Metadata (Tag / Valid / Dirty / LRU) và Write Buffer
    // -------------------------------------------------------------------------
    reg [TAG_BITS-1:0]   tag_array   [0:NUM_SETS-1][0:WAYS-1];
    reg                  valid_array [0:NUM_SETS-1][0:WAYS-1];
    reg                  dirty_array [0:NUM_SETS-1][0:WAYS-1];
    reg                  lru_bit     [0:NUM_SETS-1]; // 0: Way 0 là LRU, 1: Way 1 là LRU

    // Write Buffer (Eviction Buffer 1 dòng = 4 words)
    reg [DATA_WIDTH-1:0] wb_data [0:WORDS_PER_LINE-1];
    reg                  wb_load_d1; // Trễ 1 nhịp sau dp_wb_load để bắt dữ liệu đọc đồng bộ từ M10K

    // Thanh ghi giữ dữ liệu trả về CPU & cờ định tuyến đầu ra đồng bộ M10K khi Read-Hit
    reg [DATA_WIDTH-1:0] cpu_rdata_q;
    reg                  hit_rd_valid_q;
    reg                  hit_way_q;
    reg [1:0]            hit_word_q;

    // -------------------------------------------------------------------------
    // Tra cứu Hit/Miss song song trên Metadata
    // -------------------------------------------------------------------------
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

    // Ghi theo Byte Mask (hỗ trợ SB/SH/SW khi trộn dữ liệu Refill Write-Miss)
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

    // -------------------------------------------------------------------------
    // KIẾN TRÚC DATA ARRAY ĐỒNG BỘ SUY DIỄN M10K BLOCK RAM (Mục 3.1 - DE10-Standard)
    //   - Mỗi (way, word) được tổ chức thành 4 mảng 1 chiều 8-bit (bank_b0..bank_b3)
    //     có chỉ dẫn (* ramstyle = "M10K, no_rw_check" *).
    //   - Cổng Ghi đồng bộ (wr_set = req_index):
    //       + Khi Write-Hit (dp_hit_wr): ghi trực tiếp theo Byte-Enable cpu_wstrb[3:0]
    //         mà KHÔNG cần đọc tổ hợp dữ liệu cũ.
    //       + Khi Refill (dp_refill_we): nếu là Write-Miss tại đúng word CPU yêu cầu
    //         (eff_we && word_cnt == req_word), trộn luôn eff_wdata với mem_rdata theo
    //         eff_wstrb và ghi 1 lần duy nhất vào M10K.
    //   - Cổng Đọc đồng bộ (rd_set = is_flush_mode ? flush_set : req_index):
    //       + Dữ liệu đọc luôn chốt qua thanh ghi rdata_q tại sườn lên clk, đúng mẫu
    //         suy diễn Simple Dual-Port Synchronous RAM (altsyncram / M10K) của Quartus.
    // -------------------------------------------------------------------------
    wire                  is_flush_mode = (dp_mem_sel == MS_FLUSH);
    wire [INDEX_BITS-1:0] rd_set        = is_flush_mode ? flush_set : req_index;
    wire [INDEX_BITS-1:0] wr_set        = req_index;

    wire [DATA_WIDTH-1:0] refill_wdata_merged =
        (eff_we && (word_cnt == req_word)) ? apply_wstrb(mem_rdata, eff_wdata, eff_wstrb)
                                           : mem_rdata;

    wire [DATA_WIDTH-1:0] ram_rdata [0:WAYS-1][0:WORDS_PER_LINE-1];

    genvar gw, gk;
    generate
        for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_way
            for (gk = 0; gk < WORDS_PER_LINE; gk = gk + 1) begin : gen_word
                (* ramstyle = "M10K, no_rw_check" *) reg [7:0] bank_b0 [0:NUM_SETS-1];
                (* ramstyle = "M10K, no_rw_check" *) reg [7:0] bank_b1 [0:NUM_SETS-1];
                (* ramstyle = "M10K, no_rw_check" *) reg [7:0] bank_b2 [0:NUM_SETS-1];
                (* ramstyle = "M10K, no_rw_check" *) reg [7:0] bank_b3 [0:NUM_SETS-1];
                reg [DATA_WIDTH-1:0] rdata_q;

                wire hit_we_here    = dp_hit_wr    && (hit_way == gw[0])          && (req_word == gk[1:0]);
                wire refill_we_here = dp_refill_we && (saved_victim_way == gw[0]) && (word_cnt == gk[1:0]);
                wire bank_we        = hit_we_here || refill_we_here;
                wire [3:0] bank_be  = hit_we_here ? cpu_wstrb : 4'b1111;
                wire [DATA_WIDTH-1:0] bank_wdata = hit_we_here ? cpu_wdata : refill_wdata_merged;

                always @(posedge clk) begin
                    if (bank_we && bank_be[0]) bank_b0[wr_set] <= bank_wdata[7:0];
                    if (bank_we && bank_be[1]) bank_b1[wr_set] <= bank_wdata[15:8];
                    if (bank_we && bank_be[2]) bank_b2[wr_set] <= bank_wdata[23:16];
                    if (bank_we && bank_be[3]) bank_b3[wr_set] <= bank_wdata[31:24];

                    rdata_q[7:0]   <= bank_b0[rd_set];
                    rdata_q[15:8]  <= bank_b1[rd_set];
                    rdata_q[23:16] <= bank_b2[rd_set];
                    rdata_q[31:24] <= bank_b3[rd_set];
                end

                assign ram_rdata[gw][gk] = rdata_q;
            end
        end
    endgenerate

    // Chọn dữ liệu từ đầu ra đồng bộ M10K cho Read-Hit và Flush
    wire [DATA_WIDTH-1:0] hit_rdata_mux =
        (hit_way_q && (WAYS > 1)) ? ram_rdata[WAY1_IDX][hit_word_q]
                                  : ram_rdata[0][hit_word_q];

    wire [DATA_WIDTH-1:0] flush_rdata_mux =
        (flush_way && (WAYS > 1)) ? ram_rdata[WAY1_IDX][dp_mem_word]
                                  : ram_rdata[0][dp_mem_word];

    // Ngõ ra cpu_rdata: Trong chu kỳ ngay sau dp_hit_rd (hit_rd_valid_q == 1), lấy trực tiếp
    // từ thanh ghi đồng bộ rdata_q của M10K; các chu kỳ sau giữ ổn định trong cpu_rdata_q.
    assign cpu_rdata = hit_rd_valid_q ? hit_rdata_mux : cpu_rdata_q;

    integer s, w, k;

    // -------------------------------------------------------------------------
    // Cập nhật Metadata (Valid, Dirty, LRU, Write Buffer status) + cpu_rdata_q
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
            cpu_rdata_q    <= {DATA_WIDTH{1'b0}};
            hit_rd_valid_q <= 1'b0;
            hit_way_q      <= 1'b0;
            hit_word_q     <= 2'd0;
            wb_valid       <= 1'b0;
            wb_load_d1     <= 1'b0;
            wb_base_addr   <= {ADDR_WIDTH{1'b0}};
            req_we_q       <= 1'b0;
            req_wstrb_q    <= 4'b0000;
            req_addr_q     <= {ADDR_WIDTH{1'b0}};
            req_wdata_q    <= {DATA_WIDTH{1'b0}};
            for (s = 0; s < NUM_SETS; s = s + 1) begin
                lru_bit[s] <= 1'b0;
                for (w = 0; w < WAYS; w = w + 1) begin
                    valid_array[s][w] <= 1'b0;
                    dirty_array[s][w] <= 1'b0;
                end
            end
        end else begin
            // Chốt lại dữ liệu Read-Hit từ M10K vào cpu_rdata_q để giữ ổn định ở các chu kỳ sau
            if (hit_rd_valid_q)
                cpu_rdata_q <= hit_rdata_mux;

            hit_rd_valid_q <= dp_hit_rd;
            if (dp_hit_rd) begin
                hit_way_q  <= hit_way;
                hit_word_q <= req_word;
            end

            // Trễ 1 nhịp cho dp_wb_load để đợi đầu ra đồng bộ rdata_q của M10K sẵn sàng
            wb_load_d1 <= dp_wb_load;

            // --- Chốt yêu cầu CPU khi bắt đầu giao dịch nhiều chu kỳ (Miss / Uncached) ---
            if (dp_req_latch) begin
                req_we_q    <= cpu_we;
                req_wstrb_q <= cpu_wstrb;
                req_addr_q  <= cpu_addr;
                req_wdata_q <= cpu_wdata;
            end

            // --- Invalidate có điều kiện: chỉ xóa Valid của các dòng Clean (!Dirty) ---
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

            if (dp_hit_wr)
                dirty_array[req_index][hit_way] <= 1'b1;

            // --- Đẩy dòng victim Dirty vào Write Buffer (Metadata chốt ngay, Data chốt ở wb_load_d1) ---
            if (dp_wb_load) begin
                wb_valid     <= 1'b1;
                wb_base_addr <= {tag_array[req_index][victim_way], req_index, {OFFSET_BITS{1'b0}}};
                dirty_array[req_index][victim_way] <= 1'b0;
            end

            if (dp_wb_clear)
                wb_valid <= 1'b0;

            // --- Trong quá trình Refill: bắt trực tiếp word đọc mà CPU yêu cầu khi từ RAM trả về ---
            if (dp_refill_we && !eff_we && (word_cnt == req_word))
                cpu_rdata_q <= mem_rdata;

            // --- Refill xong: cập nhật metadata ---
            if (dp_refill_done) begin
                valid_array[req_index][saved_victim_way] <= 1'b1;
                lru_bit[req_index]                       <= ~saved_victim_way;
                dirty_array[req_index][saved_victim_way] <= eff_we;
            end

            // --- Uncached: trả dữ liệu từ bộ nhớ ---
            if (dp_unc_rdata)
                cpu_rdata_q <= mem_rdata;

            // --- Flush: dòng đã ghi trả xong ---
            if (dp_flush_clean)
                dirty_array[flush_set][flush_way] <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Cập nhật mảng Tag và Write Buffer Data (Đồng bộ thuần theo clk)
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        k = 0;
        // Sau 1 chu kỳ kể từ dp_wb_load (khi wb_load_d1 == 1), thanh ghi rdata_q của M10K
        // đã giữ toàn bộ 4 words của dòng victim tại req_index -> nạp vào wb_data[0..3].
        if (wb_load_d1) begin
            for (k = 0; k < WORDS_PER_LINE; k = k + 1) begin
                wb_data[k] <= (saved_victim_way && (WAYS > 1)) ? ram_rdata[WAY1_IDX][k]
                                                               : ram_rdata[0][k];
            end
        end

        if (dp_refill_done) begin
            tag_array[req_index][saved_victim_way] <= req_tag;
        end
    end

    // -------------------------------------------------------------------------
    // Thanh ghi địa chỉ / dữ liệu / byte-enable ghi xuống bộ nhớ
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
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
                    mem_addr  <= {tag_array[flush_set][flush_way], flush_set, dp_mem_word, 2'b00};
                    mem_wdata <= flush_rdata_mux;
                    mem_wstrb <= 4'b1111;
                end
            endcase
        end
    end

endmodule
