`timescale 1ns / 1ps
// =============================================================================
// tb_riscv_cache_soc.v
// Testbench toàn diện cho Đồ án 2 (ĐA2):
//   1. Chạy chương trình C (sw/benchmark_da2.c) trên SoC RISC-V Pipeline 5 tầng.
//   2. Kiểm chứng đầy đủ 2 chiều thay thế LRU (Trục xuất Way 0 & Trục xuất Way 1)
//      kết hợp xả dữ liệu bẩn qua Write Buffer.
//   3. So sánh trực tiếp hiệu năng Direct-Mapped (ĐA1, WAYS=1) và 2-Way (ĐA2, WAYS=2)
//      trên cùng chương trình C.
//   4. Thống kê phân bố độ trễ RAM biến thiên (2..5 chu kỳ) và khảo sát ảnh hưởng
//      khi thay đổi dải độ trễ RAM (Fast 1-cyc / Variable 2..5-cyc / Slow 4..7-cyc).
//   5. Kiểm thử Corner Cases (Word-3 Refill Bypass, Back-to-Back Dirty Eviction)
//      và Random Stress Test (200 giao dịch ngẫu nhiên đối chiếu với Golden Scoreboard).
// =============================================================================
module tb_riscv_cache_soc;

    reg clk;
    reg rst_n;

    integer pass_cnt = 0;
    integer fail_cnt = 0;

    // =========================================================================
    // 1. Khởi tạo các SoC chạy song song cùng chương trình C:
    //    - u_soc_2w   : 2-Way D-Cache (ĐA2) + RAM biến thiên 2..5 chu kỳ (Chuẩn)
    //    - u_soc_dm   : Direct-Mapped D-Cache (ĐA1, WAYS=1) + RAM biến thiên 2..5 chu kỳ
    //    - u_soc_fast : 2-Way D-Cache (ĐA2) + Fast RAM cố định 1 chu kỳ
    //    - u_soc_slow : 2-Way D-Cache (ĐA2) + Slow RAM biến thiên 4..7 chu kỳ
    // =========================================================================

    // --- (A) SoC 2-Way Set-Associative (ĐA2 - 2 KB: 64 Sets x 2 Ways, RAM 2..5 cycles) ---
    wire        mem_req_2w, mem_we_2w, mem_ready_2w, halted_2w;
    wire [3:0]  mem_wstrb_2w;
    wire [31:0] mem_addr_2w, mem_wdata_2w, mem_rdata_2w;
    wire [31:0] cyc_2w, ins_2w, acc_2w, miss_2w, stall_2w, traf_2w, coh_2w;

    riscv_cache_soc #(
        .WAYS           (2),
        .NUM_SETS       (64),
        .IMEM_WORDS     (256),
        .IMEM_INIT_FILE ("sw/program.hex")
    ) u_soc_2w (
        .clk               (clk),
        .rst_n             (rst_n),
        .cache_flush       (1'b0),
        .cache_invalidate  (1'b0),
        .maint_done        (),
        .mem_req           (mem_req_2w),
        .mem_we            (mem_we_2w),
        .mem_wstrb         (mem_wstrb_2w),
        .mem_addr          (mem_addr_2w),
        .mem_wdata         (mem_wdata_2w),
        .mem_rdata         (mem_rdata_2w),
        .mem_ready         (mem_ready_2w),
        .cpu_halted        (halted_2w),
        .cpu_cycles        (cyc_2w),
        .cpu_instrs        (ins_2w),
        .cnt_accesses      (acc_2w),
        .cnt_misses        (miss_2w),
        .cnt_stall_cycles  (stall_2w),
        .cnt_mem_traffic   (traf_2w),
        .cnt_coherence_cyc (coh_2w)
    );

    var_latency_mem #(
        .BASE_DELAY (3'd2),
        .VAR_ENABLE (1)
    ) u_mem_2w (
        .clk        (clk),
        .rst_n      (rst_n),
        .mem_req    (mem_req_2w),
        .mem_we     (mem_we_2w),
        .mem_wstrb  (mem_wstrb_2w),
        .mem_addr   (mem_addr_2w),
        .mem_wdata  (mem_wdata_2w),
        .mem_rdata  (mem_rdata_2w),
        .mem_ready  (mem_ready_2w),
        .addr_error ()
    );

    // --- (B1) SoC Direct-Mapped 1 KB (DM-1K: 64 Sets x 1 Way, RAM 2..5 cycles) ---
    wire        mem_req_dm, mem_we_dm, mem_ready_dm, halted_dm;
    wire [3:0]  mem_wstrb_dm;
    wire [31:0] mem_addr_dm, mem_wdata_dm, mem_rdata_dm;
    wire [31:0] cyc_dm, ins_dm, acc_dm, miss_dm, stall_dm, traf_dm, coh_dm;

    riscv_cache_soc #(
        .WAYS           (1),
        .NUM_SETS       (64),
        .IMEM_WORDS     (256),
        .IMEM_INIT_FILE ("sw/program.hex")
    ) u_soc_dm (
        .clk               (clk),
        .rst_n             (rst_n),
        .cache_flush       (1'b0),
        .cache_invalidate  (1'b0),
        .maint_done        (),
        .mem_req           (mem_req_dm),
        .mem_we            (mem_we_dm),
        .mem_wstrb         (mem_wstrb_dm),
        .mem_addr          (mem_addr_dm),
        .mem_wdata         (mem_wdata_dm),
        .mem_rdata         (mem_rdata_dm),
        .mem_ready         (mem_ready_dm),
        .cpu_halted        (halted_dm),
        .cpu_cycles        (cyc_dm),
        .cpu_instrs        (ins_dm),
        .cnt_accesses      (acc_dm),
        .cnt_misses        (miss_dm),
        .cnt_stall_cycles  (stall_dm),
        .cnt_mem_traffic   (traf_dm),
        .cnt_coherence_cyc (coh_dm)
    );

    var_latency_mem #(
        .BASE_DELAY (3'd2),
        .VAR_ENABLE (1)
    ) u_mem_dm (
        .clk        (clk),
        .rst_n      (rst_n),
        .mem_req    (mem_req_dm),
        .mem_we     (mem_we_dm),
        .mem_wstrb  (mem_wstrb_dm),
        .mem_addr   (mem_addr_dm),
        .mem_wdata  (mem_wdata_dm),
        .mem_rdata  (mem_rdata_dm),
        .mem_ready  (mem_ready_dm),
        .addr_error ()
    );

    // --- (B2) SoC Direct-Mapped 2 KB (DM-2K: 128 Sets x 1 Way, cùng dung lượng 2 KB với 2W-2K) ---
    wire        mem_req_dm2k, mem_we_dm2k, mem_ready_dm2k, halted_dm2k;
    wire [3:0]  mem_wstrb_dm2k;
    wire [31:0] mem_addr_dm2k, mem_wdata_dm2k, mem_rdata_dm2k;
    wire [31:0] cyc_dm2k, ins_dm2k, acc_dm2k, miss_dm2k, stall_dm2k, traf_dm2k, coh_dm2k;

    riscv_cache_soc #(
        .WAYS           (1),
        .NUM_SETS       (128),
        .IMEM_WORDS     (256),
        .IMEM_INIT_FILE ("sw/program.hex")
    ) u_soc_dm2k (
        .clk               (clk),
        .rst_n             (rst_n),
        .cache_flush       (1'b0),
        .cache_invalidate  (1'b0),
        .maint_done        (),
        .mem_req           (mem_req_dm2k),
        .mem_we            (mem_we_dm2k),
        .mem_wstrb         (mem_wstrb_dm2k),
        .mem_addr          (mem_addr_dm2k),
        .mem_wdata         (mem_wdata_dm2k),
        .mem_rdata         (mem_rdata_dm2k),
        .mem_ready         (mem_ready_dm2k),
        .cpu_halted        (halted_dm2k),
        .cpu_cycles        (cyc_dm2k),
        .cpu_instrs        (ins_dm2k),
        .cnt_accesses      (acc_dm2k),
        .cnt_misses        (miss_dm2k),
        .cnt_stall_cycles  (stall_dm2k),
        .cnt_mem_traffic   (traf_dm2k),
        .cnt_coherence_cyc (coh_dm2k)
    );

    var_latency_mem #(
        .BASE_DELAY (3'd2),
        .VAR_ENABLE (1)
    ) u_mem_dm2k (
        .clk        (clk),
        .rst_n      (rst_n),
        .mem_req    (mem_req_dm2k),
        .mem_we     (mem_we_dm2k),
        .mem_wstrb  (mem_wstrb_dm2k),
        .mem_addr   (mem_addr_dm2k),
        .mem_wdata  (mem_wdata_dm2k),
        .mem_rdata  (mem_rdata_dm2k),
        .mem_ready  (mem_ready_dm2k),
        .addr_error ()
    );

    // --- (C) SoC 2-Way với Fast RAM (Cố định 1 chu kỳ) ---
    wire        mem_req_fast, mem_we_fast, mem_ready_fast, halted_fast;
    wire [3:0]  mem_wstrb_fast;
    wire [31:0] mem_addr_fast, mem_wdata_fast, mem_rdata_fast;
    wire [31:0] cyc_fast, ins_fast, acc_fast, miss_fast, stall_fast, traf_fast, coh_fast;

    riscv_cache_soc #(
        .WAYS           (2),
        .NUM_SETS       (64),
        .IMEM_WORDS     (256),
        .IMEM_INIT_FILE ("sw/program.hex")
    ) u_soc_fast (
        .clk               (clk),
        .rst_n             (rst_n),
        .cache_flush       (1'b0),
        .cache_invalidate  (1'b0),
        .maint_done        (),
        .mem_req           (mem_req_fast),
        .mem_we            (mem_we_fast),
        .mem_wstrb         (mem_wstrb_fast),
        .mem_addr          (mem_addr_fast),
        .mem_wdata         (mem_wdata_fast),
        .mem_rdata         (mem_rdata_fast),
        .mem_ready         (mem_ready_fast),
        .cpu_halted        (halted_fast),
        .cpu_cycles        (cyc_fast),
        .cpu_instrs        (ins_fast),
        .cnt_accesses      (acc_fast),
        .cnt_misses        (miss_fast),
        .cnt_stall_cycles  (stall_fast),
        .cnt_mem_traffic   (traf_fast),
        .cnt_coherence_cyc (coh_fast)
    );

    var_latency_mem #(
        .BASE_DELAY (3'd1),
        .VAR_ENABLE (0)
    ) u_mem_fast (
        .clk        (clk),
        .rst_n      (rst_n),
        .mem_req    (mem_req_fast),
        .mem_we     (mem_we_fast),
        .mem_wstrb  (mem_wstrb_fast),
        .mem_addr   (mem_addr_fast),
        .mem_wdata  (mem_wdata_fast),
        .mem_rdata  (mem_rdata_fast),
        .mem_ready  (mem_ready_fast),
        .addr_error ()
    );

    // --- (D) SoC 2-Way với Slow Variable RAM (Biến thiên 4..7 chu kỳ) ---
    wire        mem_req_slow, mem_we_slow, mem_ready_slow, halted_slow;
    wire [3:0]  mem_wstrb_slow;
    wire [31:0] mem_addr_slow, mem_wdata_slow, mem_rdata_slow;
    wire [31:0] cyc_slow, ins_slow, acc_slow, miss_slow, stall_slow, traf_slow, coh_slow;

    riscv_cache_soc #(
        .WAYS           (2),
        .NUM_SETS       (64),
        .IMEM_WORDS     (256),
        .IMEM_INIT_FILE ("sw/program.hex")
    ) u_soc_slow (
        .clk               (clk),
        .rst_n             (rst_n),
        .cache_flush       (1'b0),
        .cache_invalidate  (1'b0),
        .maint_done        (),
        .mem_req           (mem_req_slow),
        .mem_we            (mem_we_slow),
        .mem_wstrb         (mem_wstrb_slow),
        .mem_addr          (mem_addr_slow),
        .mem_wdata         (mem_wdata_slow),
        .mem_rdata         (mem_rdata_slow),
        .mem_ready         (mem_ready_slow),
        .cpu_halted        (halted_slow),
        .cpu_cycles        (cyc_slow),
        .cpu_instrs        (ins_slow),
        .cnt_accesses      (acc_slow),
        .cnt_misses        (miss_slow),
        .cnt_stall_cycles  (stall_slow),
        .cnt_mem_traffic   (traf_slow),
        .cnt_coherence_cyc (coh_slow)
    );

    var_latency_mem #(
        .BASE_DELAY (3'd4),
        .VAR_ENABLE (1)
    ) u_mem_slow (
        .clk        (clk),
        .rst_n      (rst_n),
        .mem_req    (mem_req_slow),
        .mem_we     (mem_we_slow),
        .mem_wstrb  (mem_wstrb_slow),
        .mem_addr   (mem_addr_slow),
        .mem_wdata  (mem_wdata_slow),
        .mem_rdata  (mem_rdata_slow),
        .mem_ready  (mem_ready_slow),
        .addr_error ()
    );

    // =========================================================================
    // 2. Khối DUT riêng cho Kiểm thử Corner Cases & Random Stress Test (600 txns)
    // =========================================================================
    reg         st_req, st_we;
    reg         st_flush, st_inval;
    reg  [3:0]  st_wstrb;
    reg  [31:0] st_addr, st_wdata;
    wire [31:0] st_rdata;
    wire        st_stall, st_ready, st_maint_done;
    wire        st_mem_req, st_mem_we, st_mem_ready;
    wire [3:0]  st_mem_wstrb;
    wire [31:0] st_mem_addr, st_mem_wdata, st_mem_rdata;
    wire [31:0] st_acc, st_miss, st_stall_cyc, st_traf, st_coh;

    riscv_dcache_2way u_dut_stress (
        .clk               (clk),
        .rst_n             (rst_n),
        .cpu_req           (st_req),
        .cpu_req_ready     (),
        .cpu_we            (st_we),
        .cpu_wstrb         (st_wstrb),
        .cpu_addr          (st_addr),
        .cpu_wdata         (st_wdata),
        .cpu_rdata         (st_rdata),
        .cpu_stall         (st_stall),
        .cpu_ready         (st_ready),
        .cache_flush       (st_flush),
        .cache_invalidate  (st_inval),
        .maint_done        (st_maint_done),
        .mem_req           (st_mem_req),
        .mem_we            (st_mem_we),
        .mem_wstrb         (st_mem_wstrb),
        .mem_addr          (st_mem_addr),
        .mem_wdata         (st_mem_wdata),
        .mem_rdata         (st_mem_rdata),
        .mem_ready         (st_mem_ready),
        .cnt_accesses      (st_acc),
        .cnt_misses        (st_miss),
        .cnt_stall_cycles  (st_stall_cyc),
        .cnt_mem_traffic   (st_traf),
        .cnt_coherence_cyc (st_coh)
    );

    var_latency_mem #(
        .BASE_DELAY (3'd2),
        .VAR_ENABLE (1)
    ) u_mem_stress (
        .clk        (clk),
        .rst_n      (rst_n),
        .mem_req    (st_mem_req),
        .mem_we     (st_mem_we),
        .mem_wstrb  (st_mem_wstrb),
        .mem_addr   (st_mem_addr),
        .mem_wdata  (st_mem_wdata),
        .mem_rdata  (st_mem_rdata),
        .mem_ready  (st_mem_ready),
        .addr_error ()
    );

    // Mảng bộ nhớ chuẩn (Golden Scoreboard) để đối chiếu tự động trong Random Test
    reg [31:0] golden_ram [0:16383];
    integer g;
    initial begin
        for (g = 0; g < 16384; g = g + 1)
            golden_ram[g] = 32'h1000_0000 + g;
    end

    // Xung nhịp 100 MHz
    always #5 clk = ~clk;

    // =========================================================================
    // ASSERTION MONITOR Ở MỨC GIAO THỨC TRÊN KHỐI STRESS TEST (u_dut_stress)
    //   Kiểm tra liên tục ở mọi chu kỳ xung nhịp:
    //     1. st_maint_done |-> !st_writeback_pending
    //     2. Ổn định tín hiệu bus RAM khi đang chờ (st_mem_req && !st_mem_ready)
    // =========================================================================
    integer st_assert_pass = 0;
    reg     st_was_clean, st_was_inval;
    reg     st_rst_prev, st_mem_req_prev, st_mem_ready_prev, st_mem_we_prev;
    reg [3:0]  st_mem_wstrb_prev;
    reg [31:0] st_mem_addr_prev, st_mem_wdata_prev;
    integer as_s, as_w;
    reg     st_any_dirty, st_any_valid;
    wire    st_writeback_pending;

    always @(*) begin
        st_any_dirty = 1'b0;
        st_any_valid = 1'b0;
        for (as_s = 0; as_s < 64; as_s = as_s + 1) begin
            for (as_w = 0; as_w < 2; as_w = as_w + 1) begin
                if (u_dut_stress.u_dp.valid_array[as_s][as_w]) begin
                    st_any_valid = 1'b1;
                    if (u_dut_stress.u_dp.dirty_array[as_s][as_w])
                        st_any_dirty = 1'b1;
                end
            end
        end
    end

    assign st_writeback_pending = u_dut_stress.wb_valid ||
                                  st_mem_req ||
                                  st_mem_we ||
                                  (u_dut_stress.u_ctrl.state != 3'd0) ||
                                  u_dut_stress.u_ctrl.flush_pending ||
                                  u_dut_stress.u_ctrl.inval_pending ||
                                  (st_was_clean && st_any_dirty) ||
                                  (st_was_clean && st_was_inval && st_any_valid);

    always @(posedge clk) begin
        if (!rst_n) begin
            st_was_clean      <= 1'b0;
            st_was_inval      <= 1'b0;
            st_rst_prev       <= 1'b0;
            st_mem_req_prev   <= 1'b0;
            st_mem_ready_prev <= 1'b0;
            st_mem_we_prev    <= 1'b0;
            st_mem_wstrb_prev <= 4'b0000;
            st_mem_addr_prev  <= 32'd0;
            st_mem_wdata_prev <= 32'd0;
        end else begin
            st_rst_prev       <= 1'b1;
            st_mem_req_prev   <= st_mem_req;
            st_mem_ready_prev <= st_mem_ready;
            st_mem_we_prev    <= st_mem_we;
            st_mem_wstrb_prev <= st_mem_wstrb;
            st_mem_addr_prev  <= st_mem_addr;
            st_mem_wdata_prev <= st_mem_wdata;

            if (st_flush) st_was_clean <= 1'b1;
            if (st_inval) st_was_inval <= 1'b1;

            if (st_maint_done) begin
                if (st_writeback_pending) begin
                    $display("[ASSERT-FAIL] st_maint_done=1 nhung st_writeback_pending=1!");
                    fail_cnt = fail_cnt + 1;
                    $fatal(1, "Protocol Assertion Failed: st_maint_done |-> !st_writeback_pending");
                end else begin
                    st_assert_pass = st_assert_pass + 1;
                end
                st_was_clean <= 1'b0;
                st_was_inval <= 1'b0;
            end

            if (st_rst_prev && st_mem_req_prev && !st_mem_ready_prev) begin
                if (st_mem_req !== 1'b1 ||
                    st_mem_we !== st_mem_we_prev ||
                    st_mem_addr !== st_mem_addr_prev ||
                    st_mem_wdata !== st_mem_wdata_prev ||
                    st_mem_wstrb !== st_mem_wstrb_prev) begin
                    $display("[ASSERT-FAIL] Bus RAM thay doi khi st_mem_ready=0!");
                    fail_cnt = fail_cnt + 1;
                    $fatal(1, "Protocol Assertion Failed: RAM Bus Unstable under Backpressure");
                end else begin
                    st_assert_pass = st_assert_pass + 1;
                end
            end
        end
    end

    // Task phát lệnh bảo trì Cache (CLEAN / INVALIDATE / CLEAN_INVALIDATE) trên u_dut_stress
    task stress_maint(input do_flush, input do_inval);
        begin
            @(posedge clk);
            st_flush <= do_flush;
            st_inval <= do_inval;
            @(posedge clk);
            st_flush <= 1'b0;
            st_inval <= 1'b0;
            wait (st_maint_done == 1'b1);
            @(posedge clk);
        end
    endtask

    // -------------------------------------------------------------------------
    // Các Task hỗ trợ kiểm tra
    // -------------------------------------------------------------------------
    task check_val(
        input [31:0]   got,
        input [31:0]   exp,
        input [8*64:1] msg
    );
        begin
            if (got === exp) begin
                $display("[PASS] %0s | Got: 0x%08h", msg, got);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[FAIL] %0s | Got: 0x%08h | Exp: 0x%08h", msg, got, exp);
                fail_cnt = fail_cnt + 1;
            end
        end
    endtask

    function [31:0] golden_merge(
        input [31:0] old_w,
        input [31:0] new_w,
        input [3:0]  strb
    );
        begin
            golden_merge[7:0]   = strb[0] ? new_w[7:0]   : old_w[7:0];
            golden_merge[15:8]  = strb[1] ? new_w[15:8]  : old_w[15:8];
            golden_merge[23:16] = strb[2] ? new_w[23:16] : old_w[23:16];
            golden_merge[31:24] = strb[3] ? new_w[31:24] : old_w[31:24];
        end
    endfunction

    task stress_write(input [31:0] addr, input [31:0] wdata, input [3:0] wstrb);
        begin
            @(posedge clk);
            st_req   <= 1'b1;
            st_we    <= 1'b1;
            st_wstrb <= wstrb;
            st_addr  <= addr;
            st_wdata <= wdata;
            golden_ram[addr[15:2]] = golden_merge(golden_ram[addr[15:2]], wdata, wstrb);
            wait (st_ready == 1'b1);
            @(posedge clk);
            st_req   <= 1'b0;
            st_we    <= 1'b0;
        end
    endtask

    task stress_read_and_check(input [31:0] addr, output reg is_ok);
        reg [31:0] exp_val;
        begin
            exp_val = golden_ram[addr[15:2]];
            @(posedge clk);
            st_req   <= 1'b1;
            st_we    <= 1'b0;
            st_wstrb <= 4'b0000;
            st_addr  <= addr;
            wait (st_ready == 1'b1);
            @(posedge clk);
            if (st_rdata === exp_val) begin
                is_ok = 1'b1;
            end else begin
                is_ok = 1'b0;
                $display("[FAIL-RANDOM] Addr: 0x%08h | Got: 0x%08h | Golden: 0x%08h",
                         addr, st_rdata, exp_val);
            end
            st_req <= 1'b0;
        end
    endtask

    // Biến phục vụ thống kê và Random Stress Test
    real mr_2w, amat_2w, cpi_2w;
    real mr_dm, amat_dm, cpi_dm;
    real mr_dm2k, amat_dm2k, cpi_dm2k;
    real amat_fast, cpi_fast, amat_slow, cpi_slow;
    real avg_ram_lat;

    integer r_idx, m_idx, seed_idx, rand_errors, maint_cnt;
    integer cov_set [0:63];
    integer cov_tag [0:3];
    reg [31:0] lfsr_rng;
    reg [1:0]  r_tag, r_word;
    reg [5:0]  r_set;
    reg [2:0]  r_strb_sel;
    reg [3:0]  r_wstrb;
    reg [31:0] r_addr, r_wdata;
    reg        r_we, r_ok;

    // =========================================================================
    // Kịch bản Kiểm chứng Tổng hợp
    // =========================================================================
    initial begin
        clk       = 1'b0;
        rst_n     = 1'b0;
        st_req    = 1'b0;
        st_we     = 1'b0;
        st_flush  = 1'b0;
        st_inval  = 1'b0;
        st_wstrb  = 4'b0000;
        st_addr   = 32'd0;
        st_wdata  = 32'd0;
        maint_cnt = 0;
        for (r_idx = 0; r_idx < 64; r_idx = r_idx + 1)
            cov_set[r_idx] = 0;
        for (r_idx = 0; r_idx < 4; r_idx = r_idx + 1)
            cov_tag[r_idx] = 0;

        #25 rst_n = 1'b1;

        $display("================================================================================");
        $display(" PHAN 1: KIEM CHUNG CORE RISC-V PIPELINE 5 TANG + D-CACHE 2-WAY CHAY C (DA2)");
        $display("================================================================================");

        // Chờ cả 5 SoC hoàn tất chương trình C và xả hết Write Buffer
        wait (halted_2w && halted_dm && halted_dm2k && halted_fast && halted_slow);
        wait (u_soc_2w.u_dcache.u_ctrl.state   == 3'd0 && !u_soc_2w.u_dcache.wb_valid);
        wait (u_soc_dm.u_dcache.u_ctrl.state   == 3'd0 && !u_soc_dm.u_dcache.wb_valid);
        wait (u_soc_dm2k.u_dcache.u_ctrl.state == 3'd0 && !u_soc_dm2k.u_dcache.wb_valid);
        wait (u_soc_slow.u_dcache.u_ctrl.state == 3'd0 && !u_soc_slow.u_dcache.wb_valid);
        @(posedge clk);

        $display("[INFO] Chuong trinh C (sw/benchmark_da2.c) da hoan tat (%0d lenh RV32I retired).", ins_2w);

        // 1. Kết quả tính toán trên Core RISC-V
        check_val(u_soc_2w.u_core.regfile[19], 32'h0000_0F78,
                  "Test 1: Core RISC-V tinh sum = Sigma(A[i]+B[i]) = 3960");
        check_val(u_soc_2w.u_core.regfile[21], 32'hBEEF_1234,
                  "Test 2: Core RISC-V SH/SB/LW Byte-Strobe (0xBEEF1234) ");

        // 2. Bằng chứng LRU Eviction CHIỀU 1 (lru_bit = 0 -> Trục xuất Way 0 chứa A xuống RAM tại 0x0100)
        check_val(u_mem_2w.ram[14'h0040], 32'd10,
                  "Test 3: LRU Chieu 1 (Evict Way 0 -> WB -> RAM) A[0]=10");
        check_val(u_mem_2w.ram[14'h0047], 32'd80,
                  "Test 4: LRU Chieu 1 (Evict Way 0 -> WB -> RAM) A[7]=80");

        // 3. Bằng chứng LRU Eviction CHIỀU 2 (lru_bit = 1 -> Trục xuất Way 1 chứa B[0..3] xuống RAM tại 0x0900)
        check_val(u_mem_2w.ram[14'h0240], 32'd110,
                  "Test 5: LRU Chieu 2 (Evict Way 1 -> WB -> RAM) B[0]=110");
        check_val(u_mem_2w.ram[14'h0243], 32'd440,
                  "Test 6: LRU Chieu 2 (Evict Way 1 -> WB -> RAM) B[3]=440");

        // 4. Kiểm tra các dòng đang giữ trong Set 16, 17, 48 của M10K Data Array (D-Cache 2-Way)
        check_val({u_soc_2w.u_dcache.u_dp.gen_way[0].gen_word[0].bank_b3[16],
                   u_soc_2w.u_dcache.u_dp.gen_way[0].gen_word[0].bank_b2[16],
                   u_soc_2w.u_dcache.u_dp.gen_way[0].gen_word[0].bank_b1[16],
                   u_soc_2w.u_dcache.u_dp.gen_way[0].gen_word[0].bank_b0[16]}, 32'd111,
                  "Test 7: Set 16 Way 0 giu nguyen C[0]=111 khi Way 1 bi da");
        check_val({u_soc_2w.u_dcache.u_dp.gen_way[1].gen_word[0].bank_b3[16],
                   u_soc_2w.u_dcache.u_dp.gen_way[1].gen_word[0].bank_b2[16],
                   u_soc_2w.u_dcache.u_dp.gen_way[1].gen_word[0].bank_b1[16],
                   u_soc_2w.u_dcache.u_dp.gen_way[1].gen_word[0].bank_b0[16]}, 32'd1111,
                  "Test 8: Set 16 Way 1 nap dung D[0]=1111 sau khi da B[0]");
        check_val({u_soc_2w.u_dcache.u_dp.gen_way[1].gen_word[3].bank_b3[17],
                   u_soc_2w.u_dcache.u_dp.gen_way[1].gen_word[3].bank_b2[17],
                   u_soc_2w.u_dcache.u_dp.gen_way[1].gen_word[3].bank_b1[17],
                   u_soc_2w.u_dcache.u_dp.gen_way[1].gen_word[3].bank_b0[17]}, 32'd880,
                  "Test 9: Set 17 Way 1 giu nguyen B[7]=880 (Dirty)       ");
        check_val({u_soc_2w.u_dcache.u_dp.gen_way[0].gen_word[2].bank_b3[48],
                   u_soc_2w.u_dcache.u_dp.gen_way[0].gen_word[2].bank_b2[48],
                   u_soc_2w.u_dcache.u_dp.gen_way[0].gen_word[2].bank_b1[48],
                   u_soc_2w.u_dcache.u_dp.gen_way[0].gen_word[2].bank_b0[48]}, 32'hCAFE_0001,
                  "Test 10: D-Cache RESULT[2] = status (0xCAFE0001)       ");

        // 5. Kiểm tra kết quả chương trình C trên SoC Direct-Mapped 1 KB (DM-1K) và 2 KB (DM-2K)
        check_val(u_soc_dm.u_core.regfile[19], 32'h0000_0F78,
                  "Test 11a: SoC Direct-Mapped 1KB (DM-1K) tinh dung sum=3960");
        check_val(u_soc_dm2k.u_core.regfile[19], 32'h0000_0F78,
                  "Test 11b: SoC Direct-Mapped 2KB (DM-2K) tinh dung sum=3960");

        // =====================================================================
        // PHẦN 2: KIỂM THỬ CORNER CASES & RANDOM STRESS TEST (3 SEEDS x 200 TXNS)
        // =====================================================================
        $display("================================================================================");
        $display(" PHAN 2: KIEM THU CORNER CASES & RANDOM STRESS TEST (3 SEEDS x 200 GIAO DICH)");
        $display("================================================================================");

        // Corner Case 1: Write-Miss + Halfword Store (SH) vào đúng Word cuối cùng của dòng
        // (word_offset = 3, địa chỉ 0x0000_003C -> RAM gốc = 0x1000_000F)
        // Kiểm chứng đường mux refill_req_word = (req_word == 3) ? mem_rdata : data_array[...]
        stress_write(32'h0000_003C, 32'hABCD_9999, 4'b1100);
        stress_read_and_check(32'h0000_003C, r_ok);
        check_val(st_rdata, 32'hABCD_000F,
                  "Test 12 [Corner Case]: Write-Miss SH tai Word cuoi (offset=3)");

        // Corner Case 2: Byte Store (SB) trên từng byte lẻ liên tiếp + Read-Back
        stress_write(32'h0000_003C, 32'h0000_005A, 4'b0001);
        stress_write(32'h0000_003C, 32'h0000_A500, 4'b0010);
        stress_read_and_check(32'h0000_003C, r_ok);
        check_val(st_rdata, 32'hABCD_A55A,
                  "Test 13 [Corner Case]: Byte-lane SB ket hop tren Word cuoi   ");

        // Corner Case 3: Back-to-Back Dirty Eviction + Reload ngay dòng vừa bị trục xuất
        stress_write(32'h0000_043C, 32'h1122_3344, 4'b1111); // Set 3, Way 1 (Dirty)
        stress_write(32'h0000_083C, 32'h5566_7788, 4'b1111); // Set 3, Tag 2 -> Evict Way 0 (0x003C)
        stress_write(32'h0000_0C3C, 32'h99AA_BBCC, 4'b1111); // Set 3, Tag 3 -> Evict Way 1 (0x043C)
        stress_read_and_check(32'h0000_003C, r_ok);           // Reload 0x003C từ RAM
        check_val(st_rdata, 32'hABCD_A55A,
                  "Test 14 [Corner Case]: Back-to-Back Dirty Evict & Reload     ");

        // Random Stress Test: 3 LFSR Seeds x 200 giao dịch ngẫu nhiên = 600 giao dịch
        // Trải đúng trên 4 Sets (Set 8..11) x 4 Tags (0..3) x 4 Words (0..3)
        rand_errors = 0;

        for (seed_idx = 0; seed_idx < 3; seed_idx = seed_idx + 1) begin
            case (seed_idx)
                0: lfsr_rng = 32'hACE1_2026;
                1: lfsr_rng = 32'hDEAD_BEEF;
                default: lfsr_rng = 32'hC0FF_EE01;
            endcase

            for (r_idx = 0; r_idx < 200; r_idx = r_idx + 1) begin
                lfsr_rng   = {lfsr_rng[30:0], lfsr_rng[31] ^ lfsr_rng[21] ^ lfsr_rng[1] ^ lfsr_rng[0]};
                r_tag      = lfsr_rng[1:0];                 // 4 Tags (0..3) trên mỗi Set -> ép Eviction liên tục
                r_set      = {4'b0000, lfsr_rng[3:2]} + 6'd8; // 4 Sets (Set 8..11) - Đủ 6-bit Set Index!
                r_word     = lfsr_rng[5:4];                 // 4 Words (0..3)
                r_we       = lfsr_rng[6];                   // 0: Read, 1: Write
                r_strb_sel = lfsr_rng[9:7];

                cov_set[r_set] = cov_set[r_set] + 1;
                cov_tag[r_tag] = cov_tag[r_tag] + 1;

                case (r_strb_sel)
                    3'd0: r_wstrb = 4'b0001;
                    3'd1: r_wstrb = 4'b0010;
                    3'd2: r_wstrb = 4'b0100;
                    3'd3: r_wstrb = 4'b1000;
                    3'd4: r_wstrb = 4'b0011;
                    3'd5: r_wstrb = 4'b1100;
                    default: r_wstrb = 4'b1111;
                endcase

                r_addr  = {20'd0, r_tag, r_set, r_word, 2'b00};
                r_wdata = lfsr_rng ^ (32'h5A5A_0000 + (seed_idx * 200) + r_idx);

                if (r_we) begin
                    stress_write(r_addr, r_wdata, r_wstrb);
                end else begin
                    stress_read_and_check(r_addr, r_ok);
                    if (!r_ok) rand_errors = rand_errors + 1;
                end

                // T17 — Random Cache Maintenance kết hợp nhiều Set và Way:
                // Cứ mỗi 40 giao dịch ngẫu nhiên, phát ngẫu nhiên CLEAN, INVALIDATE
                // hoặc CLEAN_INVALIDATE và đối chiếu trực tiếp mảng RAM với Golden Scoreboard!
                if ((r_idx % 40) == 39) begin
                    maint_cnt = maint_cnt + 1;
                    case (lfsr_rng[11:10])
                        2'd0: begin
                            // CLEAN: Ghi trả toàn bộ Dirty xuống RAM, giữ Valid
                            stress_maint(1'b1, 1'b0);
                            for (m_idx = 0; m_idx < 64; m_idx = m_idx + 1) begin
                                r_addr = {20'd0, m_idx[5:4], ({4'b0000, m_idx[3:2]} + 6'd8), m_idx[1:0], 2'b00};
                                if (u_mem_stress.ram[r_addr[15:2]] !== golden_ram[r_addr[15:2]])
                                    rand_errors = rand_errors + 1;
                            end
                        end
                        2'd1: begin
                            // Conditional INVALIDATE: Xóa dòng Clean, bảo vệ dòng Dirty
                            stress_maint(1'b0, 1'b1);
                        end
                        default: begin
                            // CLEAN_INVALIDATE: Ghi trả toàn bộ Dirty xuống RAM rồi xóa hết Valid
                            stress_maint(1'b1, 1'b1);
                            for (m_idx = 0; m_idx < 64; m_idx = m_idx + 1) begin
                                r_addr = {20'd0, m_idx[5:4], ({4'b0000, m_idx[3:2]} + 6'd8), m_idx[1:0], 2'b00};
                                if (u_mem_stress.ram[r_addr[15:2]] !== golden_ram[r_addr[15:2]])
                                    rand_errors = rand_errors + 1;
                            end
                        end
                    endcase
                end
            end

            // Đọc kiểm tra lại toàn bộ 4 Sets (8..11) x 4 Tags x 4 Words = 64 words sau mỗi Seed
            for (r_idx = 0; r_idx < 64; r_idx = r_idx + 1) begin
                r_tag  = r_idx[5:4];
                r_set  = {4'b0000, r_idx[3:2]} + 6'd8;
                r_word = r_idx[1:0];
                r_addr = {20'd0, r_tag, r_set, r_word, 2'b00};
                stress_read_and_check(r_addr, r_ok);
                if (!r_ok) rand_errors = rand_errors + 1;
            end
        end

        $display("[COVERAGE] Set 8: %0d | Set 9: %0d | Set 10: %0d | Set 11: %0d txns",
                 cov_set[8], cov_set[9], cov_set[10], cov_set[11]);
        $display("[COVERAGE] Tag 0: %0d | Tag 1: %0d | Tag 2 : %0d | Tag 3 : %0d txns",
                 cov_tag[0], cov_tag[1], cov_tag[2], cov_tag[3]);
        $display("[ASSERTIONS] %0d Random Maintenance ops (T17) & %0d Protocol Assertions PASSED",
                 maint_cnt, st_assert_pass);

        check_val(rand_errors, 32'd0,
                  "Test 15 [Random Stress + T17 Maint]: 600 Txns + 15 Maint vs Golden");
        check_val((cov_set[8] > 0 && cov_set[9] > 0 && cov_set[10] > 0 && cov_set[11] > 0) ? 32'd1 : 32'd0,
                  32'd1,
                  "Test 16 [Coverage]: Do bao phu du 100%% cac Set 8..11 & Tag 0..3");

        // =====================================================================
        // PHẦN 3: BÁO CÁO ĐỐI SÁNH DIRECT-MAPPED (DM-1K & DM-2K) VS. 2-WAY (2W-2K)
        // =====================================================================
        mr_dm     = 100.0 * miss_dm / acc_dm;
        amat_dm   = 1.0 + (1.0 * stall_dm / acc_dm);
        cpi_dm    = 1.0 * cyc_dm / ins_dm;

        mr_dm2k   = 100.0 * miss_dm2k / acc_dm2k;
        amat_dm2k = 1.0 + (1.0 * stall_dm2k / acc_dm2k);
        cpi_dm2k  = 1.0 * cyc_dm2k / ins_dm2k;

        mr_2w     = 100.0 * miss_2w / acc_2w;
        amat_2w   = 1.0 + (1.0 * stall_2w / acc_2w);
        cpi_2w    = 1.0 * cyc_2w / ins_2w;

        amat_fast = 1.0 + (1.0 * stall_fast / acc_fast);
        cpi_fast  = 1.0 * cyc_fast / ins_fast;

        amat_slow = 1.0 + (1.0 * stall_slow / acc_slow);
        cpi_slow  = 1.0 * cyc_slow / ins_slow;

        avg_ram_lat = (u_mem_2w.total_xfers > 0)
                    ? (1.0 * u_mem_2w.total_lat_cycles / u_mem_2w.total_xfers) : 0.0;

        $display("=====================================================================================================");
        $display(" PHAN 3: BANG DOI CHUNG CONG BANG DM-1K (1KB), DM-2K (2KB) VA 2W-2K (2KB) TREN CUNG CHUONG TRINH C");
        $display("=====================================================================================================");
        $display(" Chi tieu danh gia        | DM-1K (64S,1W,1KB) | DM-2K (128S,1W,2KB)| 2W-2K (64S,2W,2KB) | 2W-2K vs DM-2K");
        $display("--------------------------+--------------------+--------------------+--------------------+---------------");
        $display(" Tong so lenh RV32I       | %11d instrs | %11d instrs | %11d instrs |       -",
                 ins_dm, ins_dm2k, ins_2w);
        $display(" Tong truy cap D-Cache    | %9d accesses | %9d accesses | %9d accesses |       -",
                 acc_dm, acc_dm2k, acc_2w);
        $display(" So lan Cache Hit         | %13d hits | %13d hits | %13d hits | +%0d hits",
                 acc_dm - miss_dm, acc_dm2k - miss_dm2k, acc_2w - miss_2w,
                 (acc_2w - miss_2w) - (acc_dm2k - miss_dm2k));
        $display(" So lan Cache Miss        | %11d misses | %11d misses | %11d misses | -%0.1f %%",
                 miss_dm, miss_dm2k, miss_2w, 100.0 * (miss_dm2k - miss_2w) / miss_dm2k);
        $display(" Miss Rate                | %16.2f %% | %16.2f %% | %16.2f %% | -%0.2f %%",
                 mr_dm, mr_dm2k, mr_2w, mr_dm2k - mr_2w);
        $display(" Stall Cycles             | %11d cycles | %11d cycles | %11d cycles | -%0.1f %%",
                 stall_dm, stall_dm2k, stall_2w, 100.0 * (stall_dm2k - stall_2w) / stall_dm2k);
        $display(" AMAT (cycles/access)     | %18.2f | %18.2f | %18.2f | -%0.1f %% (%0.2fx)",
                 amat_dm, amat_dm2k, amat_2w, 100.0 * (amat_dm2k - amat_2w) / amat_dm2k, amat_dm2k / amat_2w);
        $display(" Tong chu ky CPU (Cycles) | %11d cycles | %11d cycles | %11d cycles | -%0.1f %%",
                 cyc_dm, cyc_dm2k, cyc_2w, 100.0 * (cyc_dm2k - cyc_2w) / cyc_dm2k);
        $display(" CPI (Cycles / Instr)     | %18.2f | %18.2f | %18.2f | -%0.1f %%",
                 cpi_dm, cpi_dm2k, cpi_2w, 100.0 * (cpi_dm2k - cpi_2w) / cpi_dm2k);
        $display(" Memory Traffic           | %8dW (%4dB) | %8dW (%4dB) | %8dW (%4dB) | -%0.1f %%",
                 traf_dm, traf_dm * 4, traf_dm2k, traf_dm2k * 4, traf_2w, traf_2w * 4,
                 100.0 * (traf_dm2k - traf_2w) / traf_dm2k);

        $display("=====================================================================================================");
        $display(" PHAN 4: BANG CHUNG DO TRE RAM BIEN THIEN (LFSR) & KHAO SAT THAY DOI RAM LATENCY");
        $display("=====================================================================================================");
        $display(" [1] Phan bo do tre RAM bien thien (2..5 chu ky) tren SoC 2-Way (%0d word xfers):",
                 u_mem_2w.total_xfers);
        $display("     + Do tre 2 chu ky : %0d lan", u_mem_2w.lat_hist[2]);
        $display("     + Do tre 3 chu ky : %0d lan", u_mem_2w.lat_hist[3]);
        $display("     + Do tre 4 chu ky : %0d lan", u_mem_2w.lat_hist[4]);
        $display("     + Do tre 5 chu ky : %0d lan", u_mem_2w.lat_hist[5]);
        $display("     => Do tre RAM trung binh thuc nghiem: %0.2f cycles/word", avg_ram_lat);
        $display("-----------------------------------------------------------------------------------------------------");
        $display(" [2] Khao sat anh huong khi thay doi cau hinh do tre RAM (tren cung Cache 2-Way):");
        $display("     + Fast RAM (Co dinh 1 cyc/word)       : Stall = %3d cyc | AMAT = %0.2f | CPI = %0.2f",
                 stall_fast, amat_fast, cpi_fast);
        $display("     + Variable RAM (Bien thien 2..5 cyc)  : Stall = %3d cyc | AMAT = %0.2f | CPI = %0.2f",
                 stall_2w, amat_2w, cpi_2w);
        $display("     + Slow Variable RAM (Bien thien 4..7) : Stall = %3d cyc | AMAT = %0.2f | CPI = %0.2f",
                 stall_slow, amat_slow, cpi_slow);
        $display("=====================================================================================================");
        $display(" TONG KET KIEM CHUNG DA2 : %0d PASSED, %0d FAILED", pass_cnt, fail_cnt);
        $display("=====================================================================================================");
        if (fail_cnt != 0)
            $fatal(1, "TEST FAILED: %0d errors", fail_cnt);
        else
            $display("ALL TESTS PASSED");
        $finish;
    end

    // Watchdog tránh treo mô phỏng
    initial begin
        #500000;
        $fatal(1, "[TIMEOUT] Mo phong vuot qua 500us!");
    end

endmodule
