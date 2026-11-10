`timescale 1ns / 1ps

module tb_riscv_dcache_2way;

    reg         clk;
    reg         rst_n;
    reg         cpu_req;
    reg         cpu_we;
    reg  [3:0]  cpu_wstrb;
    reg  [31:0] cpu_addr;
    reg  [31:0] cpu_wdata;
    wire        cpu_req_ready;
    wire [31:0] cpu_rdata;
    wire        cpu_stall;
    wire        cpu_ready;
    wire        addr_error;

    // Tín hiệu kiểm thử qua dcache_req_rsp_adapter (Vấn đề B)
    reg         use_adapter;
    reg         m_req_valid;
    wire        m_req_ready;
    reg         m_req_we;
    reg  [3:0]  m_req_wstrb;
    reg  [31:0] m_req_addr;
    reg  [31:0] m_req_wdata;
    wire        m_rsp_valid;
    wire [31:0] m_rsp_rdata;

    wire        adp_cpu_req;
    wire        adp_cpu_we;
    wire [3:0]  adp_cpu_wstrb;
    wire [31:0] adp_cpu_addr;
    wire [31:0] adp_cpu_wdata;

    wire        dut_cpu_req   = use_adapter ? adp_cpu_req   : cpu_req;
    wire        dut_cpu_we    = use_adapter ? adp_cpu_we    : cpu_we;
    wire [3:0]  dut_cpu_wstrb = use_adapter ? adp_cpu_wstrb : cpu_wstrb;
    wire [31:0] dut_cpu_addr  = use_adapter ? adp_cpu_addr  : cpu_addr;
    wire [31:0] dut_cpu_wdata = use_adapter ? adp_cpu_wdata : cpu_wdata;

    reg         cache_flush;
    reg         cache_invalidate;
    wire        maint_done;

    wire        mem_req;
    wire        mem_we;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [31:0] mem_rdata;
    wire        mem_ready;

    wire [31:0] cnt_accesses;
    wire [31:0] cnt_misses;
    wire [31:0] cnt_stall_cycles;
    wire [31:0] cnt_mem_traffic;
    wire [31:0] cnt_coherence_cyc;

    integer pass_cnt = 0;
    integer fail_cnt = 0;
    integer assert_pass_cnt = 0;
    reg [31:0] snap_accesses, snap_misses, snap_stalls, snap_traffic, snap_coherence;
    real    miss_rate, amat;

    // Bộ chuyển đổi giao thức 2 pha Request/Response (dcache_req_rsp_adapter - Vấn đề B)
    dcache_req_rsp_adapter u_adapter (
        .clk           (clk),
        .rst_n         (rst_n),
        .req_valid     (m_req_valid),
        .req_ready     (m_req_ready),
        .req_we        (m_req_we),
        .req_wstrb     (m_req_wstrb),
        .req_addr      (m_req_addr),
        .req_wdata     (m_req_wdata),
        .rsp_valid     (m_rsp_valid),
        .rsp_rdata     (m_rsp_rdata),
        .cpu_req       (adp_cpu_req),
        .cpu_req_ready (cpu_req_ready),
        .cpu_we        (adp_cpu_we),
        .cpu_wstrb     (adp_cpu_wstrb),
        .cpu_addr      (adp_cpu_addr),
        .cpu_wdata     (adp_cpu_wdata),
        .cpu_rdata     (cpu_rdata),
        .cpu_ready     (cpu_ready)
    );

    // Khởi tạo Cache 2-Way (DUT)
    riscv_dcache_2way u_dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .cpu_req           (dut_cpu_req),
        .cpu_req_ready     (cpu_req_ready),
        .cpu_we            (dut_cpu_we),
        .cpu_wstrb         (dut_cpu_wstrb),
        .cpu_addr          (dut_cpu_addr),
        .cpu_wdata         (dut_cpu_wdata),
        .cpu_rdata         (cpu_rdata),
        .cpu_stall         (cpu_stall),
        .cpu_ready         (cpu_ready),
        .cache_flush       (cache_flush),
        .cache_invalidate  (cache_invalidate),
        .maint_done        (maint_done),
        .mem_req           (mem_req),
        .mem_we            (mem_we),
        .mem_wstrb         (mem_wstrb),
        .mem_addr          (mem_addr),
        .mem_wdata         (mem_wdata),
        .mem_rdata         (mem_rdata),
        .mem_ready         (mem_ready),
        .cnt_accesses      (cnt_accesses),
        .cnt_misses        (cnt_misses),
        .cnt_stall_cycles  (cnt_stall_cycles),
        .cnt_mem_traffic   (cnt_mem_traffic),
        .cnt_coherence_cyc (cnt_coherence_cyc)
    );

    // Khởi tạo Mô hình Bộ nhớ có Độ trễ Biến thiên & Giải mã Địa chỉ SoC
    var_latency_mem u_mem (
        .clk        (clk),
        .rst_n      (rst_n),
        .mem_req    (mem_req),
        .mem_we     (mem_we),
        .mem_wstrb  (mem_wstrb),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_rdata  (mem_rdata),
        .mem_ready  (mem_ready),
        .addr_error (addr_error)
    );

    // Xung nhịp 100 MHz (chu kỳ 10ns)
    always #5 clk = ~clk;

    // =========================================================================
    // ASSERTION MONITOR Ở MỨC GIAO THỨC (KIỂM TRA LIÊN TỤC MỖI CHU KỲ CLOCK)
    //   1. maint_done |-> !writeback_pending
    //      Trong đó writeback_pending bao gồm:
    //        - Write Buffer đang còn dữ liệu bẩn chưa xả (wb_valid == 1)
    //        - Giao dịch RAM đang chờ hoàn tất (mem_req == 1 hoặc mem_we == 1)
    //        - FSM chưa về S_IDLE hoặc còn cờ flush_pending / inval_pending
    //        - Còn bất kỳ dòng Dirty nào trong Cache sau lệnh CLEAN / CLEAN_INVALIDATE
    //   2. RAM Backpressure Stability:
    //      Khi mem_req == 1 và mem_ready == 0, các tín hiệu mem_req, mem_we,
    //      mem_addr, mem_wdata, mem_wstrb phải giữ nguyên ổn định tuyệt đối.
    // =========================================================================
    reg        mon_was_clean;
    reg        mon_was_inval;
    reg        mon_rst_prev;
    reg        mon_mem_req_prev;
    reg        mon_mem_ready_prev;
    reg        mon_mem_we_prev;
    reg [3:0]  mon_mem_wstrb_prev;
    reg [31:0] mon_mem_addr_prev;
    reg [31:0] mon_mem_wdata_prev;

    integer as_s, as_w;
    reg     any_dirty_in_cache;
    reg     any_valid_in_cache;
    wire    writeback_pending;

    always @(*) begin
        any_dirty_in_cache = 1'b0;
        any_valid_in_cache = 1'b0;
        for (as_s = 0; as_s < 64; as_s = as_s + 1) begin
            for (as_w = 0; as_w < 2; as_w = as_w + 1) begin
                if (u_dut.u_dp.valid_array[as_s][as_w]) begin
                    any_valid_in_cache = 1'b1;
                    if (u_dut.u_dp.dirty_array[as_s][as_w])
                        any_dirty_in_cache = 1'b1;
                end
            end
        end
    end

    assign writeback_pending = u_dut.wb_valid ||
                               mem_req ||
                               mem_we ||
                               (u_dut.u_ctrl.state != 3'd0) ||
                               u_dut.u_ctrl.flush_pending ||
                               u_dut.u_ctrl.inval_pending ||
                               (mon_was_clean && any_dirty_in_cache) ||
                               (mon_was_clean && mon_was_inval && any_valid_in_cache);

    always @(posedge clk) begin
        if (!rst_n) begin
            mon_was_clean      <= 1'b0;
            mon_was_inval      <= 1'b0;
            mon_rst_prev       <= 1'b0;
            mon_mem_req_prev   <= 1'b0;
            mon_mem_ready_prev <= 1'b0;
            mon_mem_we_prev    <= 1'b0;
            mon_mem_wstrb_prev <= 4'b0000;
            mon_mem_addr_prev  <= 32'd0;
            mon_mem_wdata_prev <= 32'd0;
        end else begin
            mon_rst_prev       <= 1'b1;
            mon_mem_req_prev   <= mem_req;
            mon_mem_ready_prev <= mem_ready;
            mon_mem_we_prev    <= mem_we;
            mon_mem_wstrb_prev <= mem_wstrb;
            mon_mem_addr_prev  <= mem_addr;
            mon_mem_wdata_prev <= mem_wdata;

            if (cache_flush)      mon_was_clean <= 1'b1;
            if (cache_invalidate) mon_was_inval <= 1'b1;

            // --- Assertion 1: maint_done |-> !writeback_pending ---
            if (maint_done) begin
                if (writeback_pending) begin
                    $display("[ASSERT-FAIL] maint_done=1 nhung writeback_pending=1! (wb=%b, mem_req=%b, dirty=%b)",
                             u_dut.wb_valid, mem_req, any_dirty_in_cache);
                    fail_cnt = fail_cnt + 1;
                    $fatal(1, "Protocol Assertion Failed: maint_done |-> !writeback_pending");
                end else begin
                    assert_pass_cnt = assert_pass_cnt + 1;
                end
                mon_was_clean <= 1'b0;
                mon_was_inval <= 1'b0;
            end

            // --- Assertion 2: RAM Backpressure Bus Stability ---
            if (mon_rst_prev && mon_mem_req_prev && !mon_mem_ready_prev) begin
                if (mem_req !== 1'b1 ||
                    mem_we !== mon_mem_we_prev ||
                    mem_addr !== mon_mem_addr_prev ||
                    mem_wdata !== mon_mem_wdata_prev ||
                    mem_wstrb !== mon_mem_wstrb_prev) begin
                    $display("[ASSERT-FAIL] Tin hieu bus RAM thay doi khi mem_ready=0!");
                    fail_cnt = fail_cnt + 1;
                    $fatal(1, "Protocol Assertion Failed: RAM Bus Unstable under Backpressure");
                end else begin
                    assert_pass_cnt = assert_pass_cnt + 1;
                end
            end
        end
    end

    // Task mô phỏng lệnh Load (CPU Read)
    task cpu_load(input [31:0] addr, input [31:0] expected_data, input [8*72:1] test_name);
        begin
            @(posedge clk);
            cpu_req   <= 1'b1;
            cpu_we    <= 1'b0;
            cpu_wstrb <= 4'b0000;
            cpu_addr  <= addr;
            wait (cpu_ready == 1'b1);
            @(posedge clk);
            if (cpu_rdata === expected_data) begin
                $display("[PASS] %0s | Addr: 0x%08h | RData: 0x%08h", test_name, addr, cpu_rdata);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("[FAIL] %0s | Addr: 0x%08h | Got: 0x%08h | Exp: 0x%08h",
                         test_name, addr, cpu_rdata, expected_data);
                fail_cnt = fail_cnt + 1;
            end
            cpu_req <= 1'b0;
        end
    endtask

    // Task mô phỏng lệnh Store (CPU Write)
    task cpu_store(input [31:0] addr, input [31:0] wdata, input [3:0] wstrb);
        begin
            @(posedge clk);
            cpu_req   <= 1'b1;
            cpu_we    <= 1'b1;
            cpu_wstrb <= wstrb;
            cpu_addr  <= addr;
            cpu_wdata <= wdata;
            wait (cpu_ready == 1'b1);
            @(posedge clk);
            cpu_req   <= 1'b0;
            cpu_we    <= 1'b0;
        end
    endtask

    // Kịch bản Kiểm thử
    initial begin
        clk              = 0;
        rst_n            = 0;
        use_adapter      = 0;
        m_req_valid      = 0;
        m_req_we         = 0;
        m_req_wstrb      = 4'b0000;
        m_req_addr       = 32'd0;
        m_req_wdata      = 32'd0;
        cpu_req          = 0;
        cpu_we           = 0;
        cpu_wstrb        = 4'b0000;
        cpu_addr         = 32'd0;
        cpu_wdata        = 32'd0;
        cache_flush      = 0;
        cache_invalidate = 0;

        #25 rst_n = 1;
        $display("==================================================================");
        $display(" BAT DAU KIEM THU CACHE 2-WAY SET-ASSOCIATIVE (DA2 -> DATN)");
        $display("==================================================================");

        // 1. Compulsory Read Miss vào Set 2, Way 0 (Địa chỉ 0x0000_0020 -> word index 8)
        cpu_load(32'h0000_0020, 32'h1000_0008, "Test 1: Compulsory Read Miss (Way 0)");

        // 2. Spatial Locality Read Hit cùng dòng Cache (Địa chỉ 0x0000_0024 -> word index 9)
        cpu_load(32'h0000_0024, 32'h1000_0009, "Test 2: Spatial Locality Read Hit");

        // 3. Write Hit vào Set 2, Way 0 (Làm dòng ở Way 0 trở thành Dirty)
        cpu_store(32'h0000_0020, 32'hCAFE_BABE, 4'b1111);
        cpu_load(32'h0000_0020, 32'hCAFE_BABE, "Test 3: Write-Hit & Read-Hit Verify");

        // 4. Ghi mức Byte/Halfword (Kiểm tra wstrb cho lệnh SB/SH của RISC-V)
        cpu_store(32'h0000_0020, 32'h0000_1234, 4'b0011);
        cpu_load(32'h0000_0020, 32'hCAFE_1234, "Test 4: Halfword Store (SH) Hit");

        // 5. Truy cập địa chỉ thứ 2 cùng ánh xạ vào Set 2 (Tag = 1 -> 0x0000_0420) -> Nạp vào Way 1
        cpu_store(32'h0000_0420, 32'hDEAD_BEEF, 4'b1111);
        cpu_load(32'h0000_0420, 32'hDEAD_BEEF, "Test 5: Way 1 Write-Allocate & Hit");

        // Lúc này Set 2 có: Way 0 (Tag=0, Dirty) và Way 1 (Tag=1, Dirty, vừa dùng gần nhất -> Way 0 là LRU)
        // 6. Truy cập địa chỉ thứ 3 cùng Set 2 (Tag = 2 -> 0x0000_0820)
        // -> Phải trục xuất Way 0 (LRU) qua Write Buffer xuống RAM và nạp Tag=2 vào Way 0!
        cpu_load(32'h0000_0820, 32'h1000_0208, "Test 6: Conflict Miss & LRU Eviction");

        // 7. Đọc lại địa chỉ 0x0000_0020 (đã bị đẩy xuống RAM) để kiểm chứng Write-Back đúng dữ liệu
        cpu_load(32'h0000_0020, 32'hCAFE_1234, "Test 7: Reload Evicted Dirty Line");

        // 8. Kiểm tra CLEAN (cache_flush=1, cache_invalidate=0) nhiều dòng Dirty ở cả 2 Way:
        //    Làm bẩn thêm Way 0 của Set 2 (0x0000_0024) và Set 4 (0x0000_0040, 0x0000_0440)
        cpu_store(32'h0000_0024, 32'hABCD_EF00, 4'b1111); // Set 2, Way 0 Dirty
        cpu_store(32'h0000_0040, 32'h1111_2222, 4'b1111); // Set 4, Way 0 Dirty
        cpu_store(32'h0000_0440, 32'h3333_4444, 4'b1111); // Set 4, Way 1 Dirty
        @(posedge clk);
        cache_flush <= 1'b1;
        @(posedge clk);
        cache_flush <= 1'b0;
        wait (maint_done == 1'b1);
        @(posedge clk);
        if (u_mem.ram[14'h0108] === 32'hDEAD_BEEF &&
            u_mem.ram[14'h0009] === 32'hABCD_EF00 &&
            u_mem.ram[14'h0010] === 32'h1111_2222 &&
            u_mem.ram[14'h0110] === 32'h3333_4444 &&
            u_dut.u_dp.valid_array[2][0] === 1'b1 &&
            u_dut.u_dp.dirty_array[2][0] === 1'b0) begin
            $display("[PASS] Test 8: CLEAN nhieu dong o 2 Way thanh cong (giu Valid=1, Dirty=0)");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 8: CLEAN nhieu dong sai du lieu hoac trang thai!");
            fail_cnt = fail_cnt + 1;
        end

        // 9. Kiểm tra truy cập vùng nhớ Uncached (Bit 31 = 1) với SW, SH, SB (mem_wstrb)
        cpu_store(32'h8000_0010, 32'h1122_3344, 4'b1111); // SW
        cpu_store(32'h8000_0010, 32'hABCD_0000, 4'b1100); // SH (ghi 2 byte cao)
        cpu_store(32'h8000_0010, 32'h0000_00EF, 4'b0001); // SB (ghi 1 byte thấp)
        cpu_load(32'h8000_0010, 32'hABCD_33EF, "Test 9: Uncached SW/SH/SB Byte-Enable");

        // 10. Kiểm tra INVALIDATE có điều kiện (cache_flush=0, cache_invalidate=1):
        //     Tạo 1 dòng Dirty tại Set 6 (0x0000_0060), trong khi Set 2 đang Clean.
        //     Gọi cache_invalidate -> Dòng Clean ở Set 2 bị xóa Valid, dòng Dirty ở Set 6 được bảo vệ!
        cpu_store(32'h0000_0060, 32'h55AA_55AA, 4'b1111);
        // Đợi Write Buffer rỗng hoàn toàn trước khi kiểm tra
        wait (u_dut.wb_valid == 1'b0 && u_dut.u_ctrl.state == 3'd0);
        @(posedge clk);
        cache_invalidate <= 1'b1;
        @(posedge clk);
        cache_invalidate <= 1'b0;
        wait (maint_done == 1'b1);
        @(posedge clk);
        if (u_dut.u_dp.valid_array[2][0] === 1'b0 &&
            u_dut.u_dp.valid_array[6][0] === 1'b1 &&
            u_dut.u_dp.dirty_array[6][0] === 1'b1) begin
            $display("[PASS] Test 10: Conditional INVALIDATE xoa Clean, bao ve Dirty line!");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 10: Conditional INVALIDATE sai trang thai Valid/Dirty!");
            fail_cnt = fail_cnt + 1;
        end
        cpu_load(32'h0000_0060, 32'h55AA_55AA, "Test 10b: Dirty Line van Hit sau Invalidate");

        // 11. Kiểm tra CLEAN_INVALIDATE (cache_flush=1, cache_invalidate=1):
        //     Ghi trả dòng Dirty ở Set 6 (0x0000_0060) về RAM trước, sau đó xóa toàn bộ Valid=0!
        @(posedge clk);
        cache_flush      <= 1'b1;
        cache_invalidate <= 1'b1;
        @(posedge clk);
        cache_flush      <= 1'b0;
        cache_invalidate <= 1'b0;
        wait (maint_done == 1'b1);
        @(posedge clk);
        if (u_mem.ram[14'h0018] === 32'h55AA_55AA &&
            u_dut.u_dp.valid_array[6][0] === 1'b0 &&
            u_dut.u_dp.dirty_array[6][0] === 1'b0) begin
            $display("[PASS] Test 11: CLEAN_INVALIDATE ghi tra Dirty ve RAM roi xoa Valid!");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 11: CLEAN_INVALIDATE sai du lieu RAM hoac Valid/Dirty!");
            fail_cnt = fail_cnt + 1;
        end

        // 12. Kiểm tra hợp đồng chốt yêu cầu CPU (Thay đổi cpu_addr/wdata/wstrb giữa lúc Miss)
        @(posedge clk);
        cpu_req   <= 1'b1;
        cpu_we    <= 1'b1;
        cpu_wstrb <= 4'b1111;
        cpu_addr  <= 32'h0000_00A0;
        cpu_wdata <= 32'h1357_2468;
        @(posedge clk);
        // Khi Cache đã vào S_REFILL, cố tình làm nhiễu cpu_addr, cpu_wdata, cpu_wstrb
        cpu_addr  <= 32'h0000_00F0;
        cpu_wdata <= 32'hDEAD_0000;
        cpu_wstrb <= 4'b0001;
        wait (cpu_ready == 1'b1);
        @(posedge clk);
        cpu_req   <= 1'b0;
        cpu_we    <= 1'b0;
        cpu_load(32'h0000_00A0, 32'h1357_2468, "Test 12: Request Latch khi doi tin hieu giua Miss");

        // =====================================================================
        // BỔ SUNG 5 BÀI KIỂM THỬ TRƯỚC KHI TÍCH HỢP DMA (T14 .. T18)
        // =====================================================================

        // 14. T14 — Dirty write-back + RAM delay (Không báo maint_done quá sớm):
        //     Tăng độ trễ RAM thêm 6 chu kỳ. Làm bẩn 2 Way của Set 3 (0x0030 và 0x0430),
        //     ép trục xuất Way 0 vào Write Buffer (khi đọc 0x0830), rồi phát lệnh CLEAN
        //     ngay khi Write Buffer đang xả dở (wb_valid = 1). Kiểm tra maint_done chỉ
        //     bật sau khi cả Write Buffer lẫn Way 1 đều đã ghi xong xuống RAM!
        u_mem.backpressure_extra = 6;
        cpu_store(32'h0000_0030, 32'hAAAA_1111, 4'b1111); // Set 3, Way 0 Dirty
        cpu_store(32'h0000_0430, 32'hBBBB_2222, 4'b1111); // Set 3, Way 1 Dirty
        cpu_load(32'h0000_0830, 32'h1000_020C, "Test 14a: Evict Set 3 Way 0 vao Write Buffer");
        // Lúc này CPU vừa nhận dữ liệu 0x0830, nhưng Write Buffer đang xả ngầm ở S_WB_DRAIN!
        // Phát ngay cache_flush khi wb_valid vẫn đang = 1:
        @(posedge clk);
        cache_flush <= 1'b1;
        @(posedge clk);
        cache_flush <= 1'b0;
        wait (maint_done == 1'b1);
        @(posedge clk);
        if (u_mem.ram[14'h000C] === 32'hAAAA_1111 &&
            u_mem.ram[14'h010C] === 32'hBBBB_2222 &&
            !u_dut.wb_valid && !mem_req) begin
            $display("[PASS] Test 14b [T14]: Dirty WB + RAM Delay khong bao maint_done som!");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 14b [T14]: Du lieu WB hoac trang thai maint_done sai!");
            fail_cnt = fail_cnt + 1;
        end
        u_mem.backpressure_extra = 0;

        // 16. T16 — CLEAN rồi CPU ghi lại (Dirty bit phải được đặt lại 1):
        //     Ghi vào Set 7 (0x0070) -> CLEAN (Valid=1, Dirty=0) -> CPU ghi đè giá trị mới
        //     (Write Hit) -> Kiểm tra Dirty bit phải bật lại = 1 và lần CLEAN kế tiếp đẩy
        //     đúng giá trị mới xuống RAM!
        cpu_store(32'h0000_0070, 32'h1111_0001, 4'b1111);
        @(posedge clk);
        cache_flush <= 1'b1;
        @(posedge clk);
        cache_flush <= 1'b0;
        wait (maint_done == 1'b1);
        @(posedge clk);
        // Ghi đè lần 2 (Write Hit trên dòng vừa CLEAN)
        cpu_store(32'h0000_0070, 32'h2222_0002, 4'b1111);
        if (u_dut.u_dp.valid_array[7][0] === 1'b1 &&
            u_dut.u_dp.dirty_array[7][0] === 1'b1) begin
            $display("[PASS] Test 16a [T16]: Write Hit sau CLEAN dat lai Dirty=1 chinh xac!");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 16a [T16]: Dirty bit khong bat lai sau khi CLEAN + Write!");
            fail_cnt = fail_cnt + 1;
        end
        @(posedge clk);
        cache_flush <= 1'b1;
        @(posedge clk);
        cache_flush <= 1'b0;
        wait (maint_done == 1'b1);
        @(posedge clk);
        if (u_mem.ram[14'h001C] === 32'h2222_0002) begin
            $display("[PASS] Test 16b [T16]: CLEAN lan 2 cap nhat dung du lieu moi xuong RAM");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 16b [T16]: RAM chua nhan du lieu moi sau CLEAN lan 2!");
            fail_cnt = fail_cnt + 1;
        end

        // 18. T18 — RAM Backpressure (Kìm hãm mem_ready 14..17 chu kỳ/word):
        //     Kiểm tra không phát lại hoặc bỏ sót giao dịch khi RAM phản hồi rất chậm.
        u_mem.backpressure_extra = 12;
        cpu_store(32'h0000_00B0, 32'hB0B0_0001, 4'b1111);
        cpu_store(32'h0000_00B4, 32'hB0B0_0002, 4'b1111);
        cpu_store(32'h0000_00B8, 32'hB0B0_0003, 4'b1111);
        cpu_store(32'h0000_00BC, 32'hB0B0_0004, 4'b1111);
        cpu_store(32'h8000_00B0, 32'hABCD_9876, 4'b1111); // Uncached dưới Backpressure
        cpu_load(32'h0000_00B0, 32'hB0B0_0001, "Test 18a [T18]: Backpressure Cached Word 0");
        cpu_load(32'h0000_00BC, 32'hB0B0_0004, "Test 18b [T18]: Backpressure Cached Word 3");
        cpu_load(32'h8000_00B0, 32'hABCD_9876, "Test 18c [T18]: Backpressure Uncached Read");
        u_mem.backpressure_extra = 0;

        // 19. Kiểm chứng Vấn đề B — Giao thức 2 pha Request (req_valid/req_ready) & Response (rsp_valid):
        //   19a: Phát xung cpu_req = 1 đúng 1 chu kỳ khi cpu_req_ready == 1 trên địa chỉ Miss (0x0000_0120),
        //        sau đó hạ ngay cpu_req = 0. Cache vẫn phải hoàn tất Refill 4 words và báo cpu_ready = 1!
        wait (cpu_req_ready == 1'b1);
        @(posedge clk);
        cpu_req   <= 1'b1;
        cpu_we    <= 1'b0;
        cpu_wstrb <= 4'b0000;
        cpu_addr  <= 32'h0000_0120;
        @(posedge clk);
        // Hạ ngay cpu_req = 0 sau 1 chu kỳ bắt tay (trong khi Cache đang ở S_REFILL)
        cpu_req   <= 1'b0;
        cpu_addr  <= 32'h0000_0000;
        wait (cpu_ready == 1'b1);
        @(posedge clk);
        if (cpu_rdata === 32'h1000_0048) begin
            $display("[PASS] Test 19a [Van de B]: 1-cycle Request Pulse tren Miss hoan tat dung (0x%08h)", cpu_rdata);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 19a [Van de B]: 1-cycle Request Pulse sai du lieu (0x%08h)!", cpu_rdata);
            fail_cnt = fail_cnt + 1;
        end

        //   19b: Kiểm thử qua dcache_req_rsp_adapter: Phát yêu cầu mới (req_valid = 1) NGAY TRONG
        //        CHU KỲ rsp_valid == 1 (cpu_ready == 1) của giao dịch trước (Back-to-Back 0-bubble)!
        @(posedge clk);
        use_adapter <= 1'b1;
        @(posedge clk);
        // Giao dịch 1 qua Adapter: Ghi 0x7777_8888 vào 0x0000_0120 (Write Hit)
        wait (m_req_ready == 1'b1);
        @(posedge clk);
        m_req_valid <= 1'b1;
        m_req_we    <= 1'b1;
        m_req_wstrb <= 4'b1111;
        m_req_addr  <= 32'h0000_0120;
        m_req_wdata <= 32'h7777_8888;
        // Đợi sườn lên clk nơi Giao dịch 1 được bắt tay (m_req_valid && m_req_ready == 1)
        @(posedge clk);
        // Ngay khi sang chu kỳ kế tiếp (lúc m_rsp_valid = cpu_ready vừa bật lên 1),
        // Master lập tức phát yêu cầu mới (Giao dịch 2: Đọc 0x0000_0120) ngay trong chu kỳ m_rsp_valid == 1!
        m_req_valid <= 1'b1;
        m_req_we    <= 1'b0;
        m_req_wstrb <= 4'b0000;
        m_req_addr  <= 32'h0000_0120;
        m_req_wdata <= 32'h0000_0000;
        wait (m_rsp_valid == 1'b1 && m_req_ready == 1'b1);
        // Tại sườn lên clk kế tiếp (khi m_rsp_valid đang bằng 1), Adapter bắt tay nhận Giao dịch 2 vào Skid Buffer!
        @(posedge clk);
        // Hạ m_req_valid = 0 ngay sau chu kỳ bắt tay của Giao dịch 2
        m_req_valid <= 1'b0;
        // Đợi xung m_rsp_valid của Giao dịch 1 kết thúc sau vùng NBA, rồi bắt xung m_rsp_valid của Giao dịch 2
        wait (m_rsp_valid == 1'b0);
        wait (m_rsp_valid == 1'b1);
        @(posedge clk);
        if (m_rsp_rdata === 32'h7777_8888) begin
            $display("[PASS] Test 19b [Van de B]: Adapter nhan Request moi ngay khi rsp_valid=1 (0x%08h)", m_rsp_rdata);
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 19b [Van de B]: Adapter that bai khi phat Request luc rsp_valid=1 (0x%08h)!", m_rsp_rdata);
            fail_cnt = fail_cnt + 1;
        end
        use_adapter <= 1'b0;
        @(posedge clk);

        // 20. Kiểm chứng Vấn đề C — Giải mã địa chỉ SoC không còn Alias:
        //   - 0x0000_0010 (Cacheable Main RAM -> ram[14'h0004])
        //   - 0x8000_0010 (Uncached Shared RAM / DMA Buffer -> ram[14'h3004])
        //   - 0x8001_0000 (Uncached MMIO / DMA Control Register -> mmio_regs[0])
        //   - 0x9000_0000 (Invalid Address -> addr_error = 1, rdata = 0xDEAD_BAD0)
        cpu_store(32'h0000_0010, 32'hCACA_0010, 4'b1111); // Cached RAM
        cpu_store(32'h8000_0010, 32'hDADA_8010, 4'b1111); // Uncached Shared RAM
        cpu_store(32'h8001_0000, 32'hABCD_EF01, 4'b1111); // MMIO DMA Register 0
        cpu_load(32'h0000_0010, 32'hCACA_0010, "Test 20a [Van de C]: Cached RAM 0x0000_0010 khong bi de boi 0x8000_0010");
        cpu_load(32'h8000_0010, 32'hDADA_8010, "Test 20b [Van de C]: Uncached RAM 0x8000_0010 tach biet vat ly");
        cpu_load(32'h8001_0000, 32'hABCD_EF01, "Test 20c [Van de C]: MMIO DMA Reg 0x8001_0000 doc/ghi chinh xac");
        cpu_load(32'h9000_0000, 32'hDEAD_BAD0, "Test 20d [Van de C]: Invalid Addr 0x9000_0000 tra ve 0xDEAD_BAD0");
        if (u_mem.addr_err_cnt == 1) begin
            $display("[PASS] Test 20e [Van de C]: Bo giai ma bat co addr_error dung 1 lan cho 0x9000_0000");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 20e [Van de C]: addr_err_cnt = %0d (ky vong 1)!", u_mem.addr_err_cnt);
            fail_cnt = fail_cnt + 1;
        end

        // Chốt các bộ đếm hiệu năng trước khi thử các bài Reset cứng (Test 13 & T15)
        wait (u_dut.wb_valid == 1'b0 && u_dut.u_ctrl.state == 3'd0);
        @(posedge clk);
        snap_accesses  = cnt_accesses;
        snap_misses    = cnt_misses;
        snap_stalls    = cnt_stall_cycles;
        snap_traffic   = cnt_mem_traffic;
        snap_coherence = cnt_coherence_cyc;

        // 13. Kiểm tra khôi phục khi Reset giữa quá trình Refill
        @(posedge clk);
        cpu_req   <= 1'b1;
        cpu_we    <= 1'b0;
        cpu_wstrb <= 4'b0000;
        cpu_addr  <= 32'h0000_01E0;
        @(posedge clk);
        @(posedge clk); // Đang ở giữa S_REFILL
        rst_n     <= 1'b0;
        cpu_req   <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        rst_n     <= 1'b1;
        @(posedge clk);
        if (u_dut.u_ctrl.state === 3'd0 && cpu_ready === 1'b0 && mem_req === 1'b0) begin
            $display("[PASS] Test 13a: Reset giua Refill khoi phuc FSM ve S_IDLE an toan");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 13a: Reset giua Refill khong dua FSM ve S_IDLE!");
            fail_cnt = fail_cnt + 1;
        end
        cpu_load(32'h0000_0060, 32'h55AA_55AA, "Test 13b: Giao dich moi hoat dong dung sau Reset");

        // 15. T15 (Vấn đề A) — Kiểm chứng hợp đồng bảo toàn / hủy dữ liệu khi Reset giữa S_WB_DRAIN:
        //     - Ghi cả 4 word của dòng Set 5 Way 0 (0x0000_0050..0x0000_005C):
        //       Word 0 = 0x5555_0000, Word 1 = 0x5555_0001, Word 2 = 0x5555_0002, Word 3 = 0x5555_0003.
        //     - Ghi Set 5 Way 1 (0x0000_0450) rồi đọc 0x0000_0850 để đẩy Way 0 vào Write Buffer.
        //     - Đợi trong S_WB_DRAIN đến đúng sườn clk khi Word 0 vừa hoàn tất bắt tay ghi xuống RAM
        //       (mem_req && mem_we && mem_ready && word_cnt == 0), còn Words 1..3 chưa kịp ghi xong,
        //       thì kéo rst_n = 0!
        //     - Kiểm chứng trực tiếp trên RAM và qua CPU Load sau Reset:
        //       + Word 0 (0x0000_0050 -> ram[14'h0014]) ĐÃ bắt tay xong trước Reset -> BẢO TOÀN (0x5555_0000).
        //       + Words 1..3 (0x0000_0054..0x0000_005C -> ram[14'h0015..14'h0017]) CHƯA bắt tay xong
        //         khi Reset -> BỊ HỦY theo hợp đồng Hard Reset (giữ nguyên giá trị RAM cũ 0x1000_0015..17).
        u_mem.backpressure_extra = 4;
        cpu_store(32'h0000_0050, 32'h5555_0000, 4'b1111); // Set 5, Way 0, Word 0
        cpu_store(32'h0000_0054, 32'h5555_0001, 4'b1111); // Set 5, Way 0, Word 1
        cpu_store(32'h0000_0058, 32'h5555_0002, 4'b1111); // Set 5, Way 0, Word 2
        cpu_store(32'h0000_005C, 32'h5555_0003, 4'b1111); // Set 5, Way 0, Word 3
        cpu_store(32'h0000_0450, 32'h5555_BBBB, 4'b1111); // Set 5, Way 1 Dirty
        cpu_load(32'h0000_0850, 32'h1000_0214, "Test 15a [T15/Van de A]: Trigger WB Drain tren Set 5");
        // Đợi đúng lúc Word 0 của Write Buffer hoàn tất bắt tay ghi xuống RAM (mem_ready == 1 tại word_cnt == 0)
        wait (u_dut.u_ctrl.state == 3'd2 && mem_req == 1'b1 && mem_we == 1'b1 &&
              mem_ready == 1'b1 && u_dut.u_ctrl.word_cnt == 2'd0);
        @(posedge clk); // Tại sườn lên này, Word 0 đã ghi vào RAM, FSM chuyển sang word_cnt = 1
        rst_n   <= 1'b0; // Phát Hard Reset trước khi Words 1..3 kịp hoàn thành!
        cpu_req <= 1'b0;
        @(posedge clk);
        @(posedge clk);
        rst_n   <= 1'b1;
        u_mem.backpressure_extra = 0;
        @(posedge clk);
        if (u_dut.u_ctrl.state === 3'd0 && u_dut.wb_valid === 1'b0 &&
            mem_req === 1'b0 && mem_we === 1'b0 && cpu_ready === 1'b0) begin
            $display("[PASS] Test 15b [T15/Van de A]: Reset khi WB chua drain xoa sach wb_valid & FSM");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 15b [T15/Van de A]: Trang thai WB hoac FSM khong sach sau Reset!");
            fail_cnt = fail_cnt + 1;
        end
        // Kiểm tra trực tiếp mảng RAM sau Reset giữa Write-Back:
        if (u_mem.ram[14'h0014] === 32'h5555_0000 &&
            u_mem.ram[14'h0015] === 32'h1000_0015 &&
            u_mem.ram[14'h0016] === 32'h1000_0016 &&
            u_mem.ram[14'h0017] === 32'h1000_0017) begin
            $display("[PASS] Test 15c [T15/Van de A]: Kiem tra RAM truc tiep: Word 0 (da commit) bao toan 0x55550000, Words 1..3 (chua commit) bi huy!");
            pass_cnt = pass_cnt + 1;
        end else begin
            $display("[FAIL] Test 15c [T15/Van de A]: Sai trang thai RAM sau Reset giua WB (W0=%08h, W1=%08h)!",
                     u_mem.ram[14'h0014], u_mem.ram[14'h0015]);
            fail_cnt = fail_cnt + 1;
        end
        // Đọc lại qua Cache sau Reset để xác nhận CPU thấy đúng Word 0 đã commit và Word 1 chưa commit:
        cpu_load(32'h0000_0050, 32'h5555_0000, "Test 15d [T15/Van de A]: CPU doc lai Word 0 da commit truoc Reset");
        cpu_load(32'h0000_0054, 32'h1000_0015, "Test 15e [T15/Van de A]: CPU doc lai Word 1 chua commit (giu gia tri cu)");
        cpu_store(32'h0000_0054, 32'hCAFE_5555, 4'b1111);
        cpu_load(32'h0000_0054, 32'hCAFE_5555, "Test 15f [T15/Van de A]: Giao dich doc/ghi moi hoat dong chuan sau Reset");

        #50;
        miss_rate = (snap_accesses > 0) ? (100.0 * snap_misses / snap_accesses) : 0.0;
        amat      = (snap_accesses > 0) ? (1.0 + (1.0 * snap_stalls / snap_accesses)) : 0.0;

        $display("==================================================================");
        $display(" BAO CAO CHI TIEU DANH GIA (METRICS REPORT - U14)");
        $display("==================================================================");
        $display(" - Ket qua Test          : %0d PASSED, %0d FAILED", pass_cnt, fail_cnt);
        $display(" - Protocol Assertions   : %0d checks PASSED (maint_done & backpressure)", assert_pass_cnt);
        $display(" - Tong truy cap Cached  : %0d accesses", snap_accesses);
        $display(" - So lan Cache Miss     : %0d misses", snap_misses);
        $display(" - Miss Rate             : %0.2f %%", miss_rate);
        $display(" - Stall Cycles          : %0d cycles", snap_stalls);
        $display(" - AMAT (Thuc nghiem)    : %0.2f cycles/access", amat);
        $display(" - Memory Traffic        : %0d words (%0d bytes)", snap_traffic, snap_traffic * 4);
        $display(" - Coherence Overhead    : %0d cycles (Flush/Invalidate)", snap_coherence);
        $display("==================================================================");
        if (fail_cnt != 0)
            $fatal(1, "TEST FAILED: %0d errors", fail_cnt);
        else
            $display("ALL TESTS PASSED");
        $finish;
    end

    // Watchdog tránh treo mô phỏng
    initial begin
        #100000;
        $fatal(1, "[TIMEOUT] Mo phong tb_riscv_dcache_2way vuot qua 100us!");
    end

endmodule