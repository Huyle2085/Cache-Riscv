`timescale 1ns / 1ps
// =============================================================================
// dcache_controller.v
// Bộ điều khiển (FSM) của D-Cache 2-way.
//   - Viết theo kiểu 2 process: 1 khối tổ hợp tính trạng thái kế tiếp + các
//     tín hiệu điều khiển (strobe), 1 khối tuần tự cập nhật thanh ghi.
//   - KHÔNG chứa mảng dữ liệu; chỉ ra lệnh cho dcache_datapath qua các strobe
//     và báo sự kiện cho dcache_perf_counters.
// =============================================================================
module dcache_controller #(
    parameter NUM_SETS       = 64,
    parameter WAYS           = 2,
    parameter WORDS_PER_LINE = 4,
    parameter INDEX_BITS     = 6
)(
    input  wire                  clk,
    input  wire                  rst_n,

    // --- Yêu cầu từ CPU ---
    input  wire                  cpu_req,
    input  wire                  cpu_we,
    output reg                   cpu_ready,
    output wire                  cpu_stall,

    // --- Lệnh bảo trì (CPU-DMA coherence) ---
    input  wire                  cache_flush,
    input  wire                  cache_invalidate,
    output reg                   maint_done,

    // --- Handshake bộ nhớ ---
    output reg                   mem_req,
    output reg                   mem_we,
    input  wire                  mem_ready,

    // --- Trạng thái từ Datapath ---
    input  wire                  is_uncached,
    input  wire                  cache_hit,
    input  wire                  victim_way,
    input  wire                  victim_dirty,     // victim valid && dirty
    input  wire                  wb_valid,
    input  wire                  flush_line_dirty, // dòng tại con trỏ flush valid && dirty

    // --- Con trỏ / bộ đếm gửi sang Datapath ---
    output reg  [1:0]            word_cnt,
    output reg                   saved_victim_way,
    output wire [INDEX_BITS-1:0] flush_set,
    output reg                   flush_way,

    // --- Strobe điều khiển Datapath (tích cực trong chu kỳ thực hiện) ---
    output reg                   dp_req_latch,     // chốt yêu cầu CPU khi bắt đầu Miss/Uncached
    output wire                  dp_use_latched,   // 1: dùng yêu cầu đã chốt trong S_REFILL/S_UNCACHED
    output reg                   dp_inval_all,     // xóa Valid các dòng Clean (sau CLEAN thì xóa toàn bộ)
    output reg                   dp_hit_rd,        // Read-Hit: cpu_rdata <= data
    output reg                   dp_hit_wr,        // Write-Hit: ghi data + set Dirty
    output reg                   dp_wb_load,       // chép dòng victim Dirty vào Write Buffer
    output reg                   dp_wb_clear,      // Write Buffer đã xả xong
    output reg                   dp_refill_we,     // ghi 1 word refill vào data array
    output reg                   dp_refill_done,   // cập nhật tag/valid/LRU + thực hiện lệnh CPU
    output reg                   dp_unc_rdata,     // cpu_rdata <= mem_rdata (uncached)
    output reg                   dp_flush_clean,   // xóa Dirty dòng vừa flush xong
    output reg                   dp_mem_ld,        // nạp mem_addr / mem_wdata / mem_wstrb
    output reg  [1:0]            dp_mem_sel,       // nguồn địa chỉ (xem MS_*)
    output reg  [1:0]            dp_mem_word,      // word offset dùng cho địa chỉ

    // --- Sự kiện cho Performance Counters ---
    output reg                   ev_access,
    output reg                   ev_miss,
    output reg                   ev_stall,
    output reg                   ev_mem_xfer,
    output reg                   ev_coherence,

    // --- Quan sát (debug / waveform) ---
    output reg  [2:0]            state
);

    // -------------------------------------------------------------------------
    // Mã trạng thái
    // -------------------------------------------------------------------------
    localparam S_IDLE     = 3'd0;
    localparam S_REFILL   = 3'd1; // Nạp dòng mới gồm 4 words từ bộ nhớ chính
    localparam S_WB_DRAIN = 3'd2; // Đẩy dòng Dirty từ Write Buffer xuống bộ nhớ
    localparam S_UNCACHED = 3'd3; // Truy cập trực tiếp bỏ qua Cache
    localparam S_FLUSH    = 3'd4; // Quét và ghi trả toàn bộ dòng Dirty

    // Nguồn địa chỉ bộ nhớ (phải khớp với dcache_datapath)
    localparam MS_UNCACHED = 2'd0;
    localparam MS_REFILL   = 2'd1;
    localparam MS_WB       = 2'd2;
    localparam MS_FLUSH    = 2'd3;

    localparam [1:0] LAST_WORD = WORDS_PER_LINE - 1;

    // -------------------------------------------------------------------------
    // Thanh ghi nội bộ
    // -------------------------------------------------------------------------
    reg [INDEX_BITS:0] flush_set_cnt;   // thừa 1 bit để nhận biết đã quét hết
    reg                flush_pending;   // chốt xung cache_flush khi FSM đang bận
    reg                inval_pending;   // chốt xung cache_invalidate khi FSM đang bận
    reg                req_active;      // đang giữ giao dịch Miss/Uncached đã chốt

    assign flush_set      = flush_set_cnt[INDEX_BITS-1:0];
    assign dp_use_latched = (state == S_REFILL) || (state == S_UNCACHED);

    wire flush_req   = cache_flush      || flush_pending;
    wire inval_req   = cache_invalidate || inval_pending;
    wire cpu_pending = cpu_req && !cpu_ready;
    wire req_busy    = cpu_pending || req_active;
    wire last_word   = (word_cnt == LAST_WORD);
    wire flush_end   = (flush_set_cnt >= NUM_SETS);

    // -------------------------------------------------------------------------
    // Giá trị kế tiếp
    // -------------------------------------------------------------------------
    reg [2:0]          state_nxt;
    reg [1:0]          word_cnt_nxt;
    reg                saved_victim_way_nxt;
    reg [INDEX_BITS:0] flush_set_cnt_nxt;
    reg                flush_way_nxt;
    reg                flush_pending_nxt;
    reg                inval_pending_nxt;
    reg                req_active_nxt;
    reg                cpu_ready_nxt;
    reg                maint_done_nxt;
    reg                mem_req_nxt;
    reg                mem_we_nxt;

    // CPU chỉ bị dừng khi có yêu cầu chưa hoàn tất trong chu kỳ hiện tại (!cpu_ready_nxt),
    // hoặc khi Cache đang bận quét Flush. Khi Hit (cpu_ready_nxt = 1), cpu_stall = 0.
    assign cpu_stall = (req_busy && !cpu_ready_nxt) || (state == S_FLUSH);

    // Chuyển con trỏ flush sang dòng kế tiếp (way 0 -> way 1 -> set kế)
    task flush_advance;
        begin
            if (flush_way || (WAYS == 1)) begin
                flush_way_nxt     = 1'b0;
                flush_set_cnt_nxt = flush_set_cnt + 1'b1;
            end else begin
                flush_way_nxt     = 1'b1;
            end
        end
    endtask

    // Bắt đầu xả Write Buffer xuống bộ nhớ
    task start_wb_drain;
        begin
            state_nxt    = S_WB_DRAIN;
            word_cnt_nxt = 2'd0;
            mem_req_nxt  = 1'b1;
            mem_we_nxt   = 1'b1;
            dp_mem_ld    = 1'b1;
            dp_mem_sel   = MS_WB;
            dp_mem_word  = 2'd0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Khối tổ hợp: logic trạng thái kế tiếp + strobe
    // -------------------------------------------------------------------------
    always @(*) begin
        // Mặc định: giữ nguyên
        state_nxt            = state;
        word_cnt_nxt         = word_cnt;
        saved_victim_way_nxt = saved_victim_way;
        flush_set_cnt_nxt    = flush_set_cnt;
        flush_way_nxt        = flush_way;
        flush_pending_nxt    = flush_pending | cache_flush;
        inval_pending_nxt    = inval_pending | cache_invalidate;
        req_active_nxt       = req_active;
        cpu_ready_nxt        = 1'b0;   // xung 1 chu kỳ
        maint_done_nxt       = 1'b0;   // xung 1 chu kỳ
        mem_req_nxt          = mem_req;
        mem_we_nxt           = mem_we;

        dp_req_latch   = 1'b0;
        dp_inval_all   = 1'b0;
        dp_hit_rd      = 1'b0;
        dp_hit_wr      = 1'b0;
        dp_wb_load     = 1'b0;
        dp_wb_clear    = 1'b0;
        dp_refill_we   = 1'b0;
        dp_refill_done = 1'b0;
        dp_unc_rdata   = 1'b0;
        dp_flush_clean = 1'b0;
        dp_mem_ld      = 1'b0;
        dp_mem_sel     = MS_UNCACHED;
        dp_mem_word    = 2'd0;

        ev_access      = 1'b0;
        ev_miss        = 1'b0;
        ev_stall       = 1'b0;
        ev_mem_xfer    = 1'b0;
        ev_coherence   = 1'b0;

        case (state)
            // =================================================================
            S_IDLE: begin
                if (wb_valid) begin
                    // 1. Ưu tiên xả Write Buffer trước để tránh ghi đè dữ liệu bẩn
                    start_wb_drain;
                end else if (flush_req) begin
                    // 2a. CLEAN hoặc CLEAN_INVALIDATE:
                    //     Ưu tiên quét và ghi trả toàn bộ dòng Dirty về RAM trước.
                    //     Nếu đi kèm inval_req (CLEAN_INVALIDATE), inval_pending được giữ lại
                    //     để xóa Valid toàn bộ ngay khi hoàn tất S_FLUSH.
                    flush_pending_nxt = 1'b0;
                    flush_set_cnt_nxt = 0;
                    flush_way_nxt     = 1'b0;
                    word_cnt_nxt      = 2'd0;
                    state_nxt         = S_FLUSH;
                    ev_coherence      = 1'b1;
                end else if (inval_req) begin
                    // 2b. INVALIDATE có điều kiện (1 chu kỳ):
                    //     Xóa Valid của các dòng Clean (!Dirty), bảo vệ dòng Dirty không mất dữ liệu.
                    inval_pending_nxt = 1'b0;
                    dp_inval_all      = 1'b1;
                    maint_done_nxt    = 1'b1;
                    ev_coherence      = 1'b1;
                end else if (cpu_pending) begin
                    if (is_uncached) begin
                        // 3a. Uncached: chốt yêu cầu và chuyển thẳng xuống bộ nhớ
                        dp_req_latch   = 1'b1;
                        req_active_nxt = 1'b1;
                        state_nxt      = S_UNCACHED;
                        mem_req_nxt    = 1'b1;
                        mem_we_nxt     = cpu_we;
                        dp_mem_ld      = 1'b1;
                        dp_mem_sel     = MS_UNCACHED;
                    end else if (cache_hit) begin
                        // 3b. Hit: hoàn tất trong 1 chu kỳ (0 chu kỳ stall)
                        ev_access     = 1'b1;
                        cpu_ready_nxt = 1'b1;
                        dp_hit_wr     = cpu_we;
                        dp_hit_rd     = !cpu_we;
                    end else begin
                        // 3c. Miss: chốt yêu cầu + (đẩy victim Dirty vào WB) + bắt đầu Refill
                        ev_access            = 1'b1;
                        ev_miss              = 1'b1;
                        dp_req_latch         = 1'b1;
                        req_active_nxt       = 1'b1;
                        saved_victim_way_nxt = victim_way;
                        word_cnt_nxt         = 2'd0;
                        dp_wb_load           = victim_dirty;
                        state_nxt            = S_REFILL;
                        mem_req_nxt          = 1'b1;
                        mem_we_nxt           = 1'b0;
                        dp_mem_ld            = 1'b1;
                        dp_mem_sel           = MS_REFILL;
                        dp_mem_word          = 2'd0;
                    end
                end
            end

            // =================================================================
            S_REFILL: begin
                if (mem_ready) begin
                    ev_mem_xfer  = 1'b1;
                    dp_refill_we = 1'b1;
                    if (last_word) begin
                        mem_req_nxt    = 1'b0;
                        dp_refill_done = 1'b1;
                        cpu_ready_nxt  = 1'b1;
                        req_active_nxt = 1'b0;
                        if (wb_valid) start_wb_drain;
                        else          state_nxt = S_IDLE;
                    end else begin
                        word_cnt_nxt = word_cnt + 1'b1;
                        dp_mem_ld    = 1'b1;
                        dp_mem_sel   = MS_REFILL;
                        dp_mem_word  = word_cnt + 1'b1;
                    end
                end
            end

            // =================================================================
            S_WB_DRAIN: begin
                if (mem_ready) begin
                    ev_mem_xfer = 1'b1;
                    if (last_word) begin
                        mem_req_nxt = 1'b0;
                        mem_we_nxt  = 1'b0;
                        dp_wb_clear = 1'b1;
                        state_nxt   = S_IDLE;
                    end else begin
                        word_cnt_nxt = word_cnt + 1'b1;
                        dp_mem_ld    = 1'b1;
                        dp_mem_sel   = MS_WB;
                        dp_mem_word  = word_cnt + 1'b1;
                    end
                end
            end

            // =================================================================
            S_UNCACHED: begin
                if (mem_ready) begin
                    ev_mem_xfer    = 1'b1;
                    mem_req_nxt    = 1'b0;
                    mem_we_nxt     = 1'b0;
                    dp_unc_rdata   = 1'b1;
                    cpu_ready_nxt  = 1'b1;
                    req_active_nxt = 1'b0;
                    state_nxt      = S_IDLE;
                end
            end

            // =================================================================
            S_FLUSH: begin
                ev_coherence = 1'b1;
                if (!flush_end) begin
                    if (flush_line_dirty) begin
                        if (!mem_req) begin
                            // Bắt đầu ghi word hiện tại của dòng Dirty
                            mem_req_nxt = 1'b1;
                            mem_we_nxt  = 1'b1;
                            dp_mem_ld   = 1'b1;
                            dp_mem_sel  = MS_FLUSH;
                            dp_mem_word = word_cnt;
                        end else if (mem_ready) begin
                            ev_mem_xfer = 1'b1;
                            if (last_word) begin
                                mem_req_nxt    = 1'b0;
                                mem_we_nxt     = 1'b0;
                                dp_flush_clean = 1'b1;
                                word_cnt_nxt   = 2'd0;
                                flush_advance;
                            end else begin
                                word_cnt_nxt = word_cnt + 1'b1;
                                dp_mem_ld    = 1'b1;
                                dp_mem_sel   = MS_FLUSH;
                                dp_mem_word  = word_cnt + 1'b1;
                            end
                        end
                    end else begin
                        // Dòng sạch / không hợp lệ: bỏ qua
                        flush_advance;
                    end
                end else begin
                    // Khi hoàn tất quét CLEAN toàn bộ Cache: nếu có yêu cầu CLEAN_INVALIDATE
                    // (inval_req == 1), xóa toàn bộ Valid trước khi phát maint_done.
                    if (inval_req) begin
                        inval_pending_nxt = 1'b0;
                        dp_inval_all      = 1'b1;
                    end
                    maint_done_nxt = 1'b1;
                    state_nxt      = S_IDLE;
                end
            end

            default: state_nxt = S_IDLE;
        endcase

        // Chỉ đếm chu kỳ dừng (stall) của các truy cập Cached chưa hoàn tất
        ev_stall = req_busy && !cpu_ready_nxt && !is_uncached;
    end

    // -------------------------------------------------------------------------
    // Khối tuần tự: cập nhật thanh ghi
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= S_IDLE;
            word_cnt         <= 2'd0;
            saved_victim_way <= 1'b0;
            flush_set_cnt    <= 0;
            flush_way        <= 1'b0;
            flush_pending    <= 1'b0;
            inval_pending    <= 1'b0;
            req_active       <= 1'b0;
            cpu_ready        <= 1'b0;
            maint_done       <= 1'b0;
            mem_req          <= 1'b0;
            mem_we           <= 1'b0;
        end else begin
            state            <= state_nxt;
            word_cnt         <= word_cnt_nxt;
            saved_victim_way <= saved_victim_way_nxt;
            flush_set_cnt    <= flush_set_cnt_nxt;
            flush_way        <= flush_way_nxt;
            flush_pending    <= flush_pending_nxt;
            inval_pending    <= inval_pending_nxt;
            req_active       <= req_active_nxt;
            cpu_ready        <= cpu_ready_nxt;
            maint_done       <= maint_done_nxt;
            mem_req          <= mem_req_nxt;
            mem_we           <= mem_we_nxt;
        end
    end

endmodule
