`timescale 1ns / 1ps
// =============================================================================
// minimal/tb_compare_models.v
// TESTBENCH CHUYÊN BIỆT: ĐỐI CHIẾU TỐC ĐỘ MÔ HÌNH SƠ KHAI (ĐA1) VS. 2-WAY (ĐA2)
// -----------------------------------------------------------------------------
// Mục đích:
//   Tách riêng phần so sánh hiệu năng ra khỏi Testbench ĐA1 để code gọn nhẹ.
//   Chạy cùng một Workload thực tế (64 lần đọc/ghi bộ nhớ) trên 2 mô hình:
//     1. u_min  : Mô hình Sơ khai (dcache_minimal: 1-Way, 1 Word/Line, Không WB)
//     2. u_full : Mô hình Hiện tại (riscv_dcache_2way: 2-Way LRU, 4 Words/Line, Có WB)
//   Từ đó thu thập bảng so sánh trực tiếp: Hit/Miss Rate, Stall Cycles, AMAT, Traffic.
// =============================================================================
module tb_compare_models;

    reg clk;
    reg rst_n;

    // Xung nhịp 100 MHz (1 chu kỳ = 10 ns)
    always #5 clk = ~clk;

    // =========================================================================
    // 1. MÔ HÌNH SƠ KHAI (dcache_minimal - ĐA1)
    // =========================================================================
    reg         min_req, min_we;
    reg  [31:0] min_addr, min_wdata;
    wire [31:0] min_rdata;
    wire        min_stall, min_ready;
    wire        min_mem_req, min_mem_we, min_mem_ready;
    wire [31:0] min_mem_addr, min_mem_wdata, min_mem_rdata;
    wire [31:0] min_acc, min_hits, min_rhit, min_whit;
    wire [31:0] min_miss, min_rmiss, min_wmiss, min_wb;
    wire [31:0] min_stall_cyc, min_traf;

    dcache_minimal u_min (
        .clk              (clk),
        .rst_n            (rst_n),
        .cpu_req          (min_req),
        .cpu_we           (min_we),
        .cpu_wstrb        (4'b1111),
        .cpu_addr         (min_addr),
        .cpu_wdata        (min_wdata),
        .cpu_rdata        (min_rdata),
        .cpu_stall        (min_stall),
        .cpu_ready        (min_ready),
        .mem_req          (min_mem_req),
        .mem_we           (min_mem_we),
        .mem_addr         (min_mem_addr),
        .mem_wdata        (min_mem_wdata),
        .mem_rdata        (min_mem_rdata),
        .mem_ready        (min_mem_ready),
        .cnt_accesses     (min_acc),
        .cnt_hits         (min_hits),
        .cnt_read_hits    (min_rhit),
        .cnt_write_hits   (min_whit),
        .cnt_misses       (min_miss),
        .cnt_read_misses  (min_rmiss),
        .cnt_write_misses (min_wmiss),
        .cnt_writebacks   (min_wb),
        .cnt_stall_cycles (min_stall_cyc),
        .cnt_mem_traffic  (min_traf),
        .dbg_state        (),
        .dbg_cache_hit    (),
        .dbg_victim_dirty ()
    );

    var_latency_mem #(
        .BASE_DELAY (3'd2),
        .VAR_ENABLE (1)
    ) u_mem_min (
        .clk       (clk),
        .rst_n     (rst_n),
        .mem_req   (min_mem_req),
        .mem_we    (min_mem_we),
        .mem_wstrb (4'b1111),
        .mem_addr  (min_mem_addr),
        .mem_wdata (min_mem_wdata),
        .mem_rdata (min_mem_rdata),
        .mem_ready (min_mem_ready)
    );

    // =========================================================================
    // 2. MÔ HÌNH HIỆN TẠI (riscv_dcache_2way - ĐA2)
    // =========================================================================
    reg         full_req, full_we;
    reg  [31:0] full_addr, full_wdata;
    wire [31:0] full_rdata;
    wire        full_stall, full_ready;
    wire        full_mem_req, full_mem_we, full_mem_ready;
    wire [3:0]  full_mem_wstrb;
    wire [31:0] full_mem_addr, full_mem_wdata, full_mem_rdata;
    wire [31:0] full_acc, full_miss, full_stall_cyc, full_traf, full_coh;

    riscv_dcache_2way u_full (
        .clk               (clk),
        .rst_n             (rst_n),
        .cpu_req           (full_req),
        .cpu_we            (full_we),
        .cpu_wstrb         (4'b1111),
        .cpu_addr          (full_addr),
        .cpu_wdata         (full_wdata),
        .cpu_rdata         (full_rdata),
        .cpu_stall         (full_stall),
        .cpu_ready         (full_ready),
        .cache_flush       (1'b0),
        .cache_invalidate  (1'b0),
        .maint_done        (),
        .mem_req           (full_mem_req),
        .mem_we            (full_mem_we),
        .mem_wstrb         (full_mem_wstrb),
        .mem_addr          (full_mem_addr),
        .mem_wdata         (full_mem_wdata),
        .mem_rdata         (full_mem_rdata),
        .mem_ready         (full_mem_ready),
        .cnt_accesses      (full_acc),
        .cnt_misses        (full_miss),
        .cnt_stall_cycles  (full_stall_cyc),
        .cnt_mem_traffic   (full_traf),
        .cnt_coherence_cyc (full_coh)
    );

    var_latency_mem #(
        .BASE_DELAY (3'd2),
        .VAR_ENABLE (1)
    ) u_mem_full (
        .clk       (clk),
        .rst_n     (rst_n),
        .mem_req   (full_mem_req),
        .mem_we    (full_mem_we),
        .mem_wstrb (full_mem_wstrb),
        .mem_addr  (full_mem_addr),
        .mem_wdata (full_mem_wdata),
        .mem_rdata (full_mem_rdata),
        .mem_ready (full_mem_ready)
    );

    // =========================================================================
    // 3. CÁC TASK PHÁT YÊU CẦU TRUY CẬP BỘ NHỚ
    // =========================================================================
    task min_access(input we, input [31:0] addr, input [31:0] wdata);
        begin
            @(posedge clk);
            min_req   <= 1'b1;
            min_we    <= we;
            min_addr  <= addr;
            min_wdata <= wdata;
            wait (min_ready == 1'b1);
            @(posedge clk);
            min_req   <= 1'b0;
            min_we    <= 1'b0;
        end
    endtask

    task full_access(input we, input [31:0] addr, input [31:0] wdata);
        begin
            @(posedge clk);
            full_req   <= 1'b1;
            full_we    <= we;
            full_addr  <= addr;
            full_wdata <= wdata;
            wait (full_ready == 1'b1);
            @(posedge clk);
            full_req   <= 1'b0;
            full_we    <= 1'b0;
        end
    endtask

    integer k, round;
    real min_hr, min_mr, min_amat;
    real full_hr, full_mr, full_amat;

    // =========================================================================
    // 4. KỊCH BẢN CHẠY WORKLOAD ĐỐI CHIẾU
    //    - Giai đoạn A (16 accesses): Đọc tuần tự mảng 16 words liên tiếp
    //      -> Minh họa tác dụng của việc nâng 1 Word/Line lên 4 Words/Line.
    //    - Giai đoạn B (48 accesses): Lặp 4 vòng cộng 2 mảng A[4] (0x0100) và
    //      B[4] (0x0500) cùng ánh xạ vào 1 Set
    //      -> Minh họa tác dụng của 2-Way Set-Associative (LRU) + Write Buffer.
    // =========================================================================
    initial begin
        clk        = 1'b0;
        rst_n      = 1'b0;
        min_req    = 1'b0;
        min_we     = 1'b0;
        min_addr   = 32'd0;
        min_wdata  = 32'd0;
        full_req   = 1'b0;
        full_we    = 1'b0;
        full_addr  = 32'd0;
        full_wdata = 32'd0;

        #25 rst_n = 1'b1;

        // --- Chạy Workload trên Mô hình Sơ khai (dcache_minimal) ---
        for (k = 0; k < 16; k = k + 1)
            min_access(1'b0, 32'h0000_0200 + (k * 4), 32'd0);

        for (round = 0; round < 4; round = round + 1) begin
            for (k = 0; k < 4; k = k + 1) begin
                min_access(1'b0, 32'h0000_0100 + (k * 4), 32'd0);
                min_access(1'b0, 32'h0000_0500 + (k * 4), 32'd0);
                min_access(1'b1, 32'h0000_0500 + (k * 4), 32'h2000_0000 + k);
            end
        end

        // --- Chạy cùng Workload trên Mô hình Hiện tại (riscv_dcache_2way) ---
        for (k = 0; k < 16; k = k + 1)
            full_access(1'b0, 32'h0000_0200 + (k * 4), 32'd0);

        for (round = 0; round < 4; round = round + 1) begin
            for (k = 0; k < 4; k = k + 1) begin
                full_access(1'b0, 32'h0000_0100 + (k * 4), 32'd0);
                full_access(1'b0, 32'h0000_0500 + (k * 4), 32'd0);
                full_access(1'b1, 32'h0000_0500 + (k * 4), 32'h2000_0000 + k);
            end
        end
        wait (u_full.u_ctrl.state == 3'd0 && !u_full.wb_valid);
        @(posedge clk);

        min_hr    = (100.0 * min_hits) / min_acc;
        min_mr    = (100.0 * min_miss) / min_acc;
        min_amat  = 1.0 + (1.0 * min_stall_cyc / min_acc);

        full_hr   = (100.0 * (full_acc - full_miss)) / full_acc;
        full_mr   = (100.0 * full_miss) / full_acc;
        full_amat = 1.0 + (1.0 * full_stall_cyc / full_acc);

        $display("========================================================================================================================");
        $display(" BANG SO SANH TOC DO XU LY: MO HINH SO KHAI (DA1: dcache_minimal) VS. MO HINH HIEN TAI (DA2: riscv_dcache_2way)");
        $display("========================================================================================================================");
        $display(" Thong so danh gia            | Mo hinh So khai (Minimal) | Mo hinh Hien tai (2-Way)  | Y nghia khi nang cap");
        $display("------------------------------+---------------------------+---------------------------+---------------------------------");
        $display(" Cau hinh Cache               | 1-Way, 1 Word/Line, No WB | 2-Way, 4 Words/Line, WB   | Tang Spatial + Giam Conflict");
        $display(" Tong so truy cap (Accesses)  | %15d accesses  | %15d accesses  | Cung 64 giao dich doc/ghi",
                 min_acc, full_acc);
        $display(" So lan Cache Hit             | %19d hits  | %19d hits  | +%0d lan Hit them",
                 min_hits, (full_acc - full_miss), (full_acc - full_miss) - min_hits);
        $display(" So lan Cache Miss            | %17d misses  | %17d misses  | Giam %0.1f %% so lan Miss",
                 min_miss, full_miss, 100.0 * (min_miss - full_miss) / min_miss);
        $display(" Hit Rate                     | %22.2f %%  | %22.2f %%  | Tang manh ty le trung Cache",
                 min_hr, full_hr);
        $display(" Miss Rate                    | %22.2f %%  | %22.2f %%  | Giam manh ty le truot Cache",
                 min_mr, full_mr);
        $display(" Chu ky dung CPU (Stall Cyc)  | %17d cycles  | %17d cycles  | Giam %0.1f %% thoi gian cho RAM",
                 min_stall_cyc, full_stall_cyc, 100.0 * (min_stall_cyc - full_stall_cyc) / min_stall_cyc);
        $display(" Toc do TB (AMAT cyc/access)  | %24.2f  | %24.2f  | Nhanh gap %0.2fx lan",
                 min_amat, full_amat, min_amat / full_amat);
        $display(" Luu luong RAM (Mem Traffic)  | %18d words  | %18d words  | Tiet kiem bang thong bus RAM",
                 min_traf, full_traf);
        $display("========================================================================================================================");
        $finish;
    end

endmodule
