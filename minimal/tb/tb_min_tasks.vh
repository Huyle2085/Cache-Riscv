// =============================================================================
// minimal/tb/tb_min_tasks.vh
// CÁC HÀM (TASK) DÙNG CHUNG CHO TESTBENCH D-CACHE SƠ KHAI
// -----------------------------------------------------------------------------
// Tách riêng các task giao tiếp CPU (trace_load, trace_store) và hàm in báo cáo
// (print_da1_report) vào file header này để các file Testbench chính ngắn gọn,
// chỉ tập trung vào kịch bản kiểm thử.
// =============================================================================

    // -------------------------------------------------------------------------
    // Task 1: Mô phỏng lệnh ĐỌC (CPU Load) + Đo số chu kỳ xử lý & kiểm tra dữ liệu
    // -------------------------------------------------------------------------
    task trace_load(
        input [31:0]   addr,
        input [31:0]   exp_data,
        input [8*52:1] desc
    );
        integer stall_before, cyc_taken, stall_taken;
        reg        was_hit, was_dirty;
        reg [23:0] tag_val;
        reg [5:0]  set_val;
        begin
            tx_id   = tx_id + 1;
            tag_val = addr[31:8];
            set_val = addr[7:2];

            @(posedge clk);
            cpu_req      <= 1'b1;
            cpu_we       <= 1'b0;
            cpu_wstrb    <= 4'b1111;
            cpu_addr     <= addr;
            stall_before = cnt_stall;

            #1; // Đợi tín hiệu tổ hợp ổn định tại chu kỳ S_IDLE
            was_hit   = dbg_hit;
            was_dirty = dbg_dirty;

            wait (cpu_ready == 1'b1);
            @(posedge clk);
            stall_taken = cnt_stall - stall_before;
            cyc_taken   = 1 + stall_taken;
            cpu_req     <= 1'b0;

            if (cpu_rdata === exp_data) begin
                pass_cnt = pass_cnt + 1;
                $display("[PASS] #%02d LOAD  | Addr:0x%08h (Tag:0x%02h, Set:%02d) | %s | Speed: %2d cyc (Stall: %2d) | Data:0x%08h | %0s",
                         tx_id, addr, tag_val[7:0], set_val,
                         was_hit   ? "READ HIT           " :
                         was_dirty ? "MISS (Dirty->WB)   " :
                                     "MISS (Clean Refill)",
                         cyc_taken, stall_taken, cpu_rdata, desc);
            end else begin
                fail_cnt = fail_cnt + 1;
                $display("[FAIL] #%02d LOAD  | Addr:0x%08h | Got:0x%08h != Exp:0x%08h | %0s",
                         tx_id, addr, cpu_rdata, exp_data, desc);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Task 2: Mô phỏng lệnh GHI (CPU Store) + Đo số chu kỳ xử lý
    // -------------------------------------------------------------------------
    task trace_store(
        input [31:0]   addr,
        input [31:0]   wdata,
        input [8*52:1] desc
    );
        integer stall_before, cyc_taken, stall_taken;
        reg        was_hit, was_dirty;
        reg [23:0] tag_val;
        reg [5:0]  set_val;
        begin
            tx_id   = tx_id + 1;
            tag_val = addr[31:8];
            set_val = addr[7:2];

            @(posedge clk);
            cpu_req      <= 1'b1;
            cpu_we       <= 1'b1;
            cpu_wstrb    <= 4'b1111;
            cpu_addr     <= addr;
            cpu_wdata    <= wdata;
            stall_before = cnt_stall;

            #1;
            was_hit   = dbg_hit;
            was_dirty = dbg_dirty;

            wait (cpu_ready == 1'b1);
            @(posedge clk);
            stall_taken = cnt_stall - stall_before;
            cyc_taken   = 1 + stall_taken;
            cpu_req     <= 1'b0;
            cpu_we      <= 1'b0;

            pass_cnt = pass_cnt + 1;
            $display("[PASS] #%02d STORE | Addr:0x%08h (Tag:0x%02h, Set:%02d) | %s | Speed: %2d cyc (Stall: %2d) | WData:0x%08h | %0s",
                     tx_id, addr, tag_val[7:0], set_val,
                     was_hit   ? "WRITE HIT (Dirty=1)" :
                     was_dirty ? "WMISS (Dirty->WB)  " :
                                 "WMISS (WriteAlloc) ",
                     cyc_taken, stall_taken, wdata, desc);
        end
    endtask

    // -------------------------------------------------------------------------
    // Task 3: In bảng tổng hợp thông số hiệu năng & phân bố độ trễ RAM biến thiên
    // -------------------------------------------------------------------------
    task print_da1_report(input [8*48:1] title_str);
        real hit_rate, miss_rate, amat, avg_ram_lat;
        begin
            hit_rate    = (cnt_acc > 0) ? ((100.0 * cnt_hits) / cnt_acc) : 0.0;
            miss_rate   = (cnt_acc > 0) ? ((100.0 * cnt_miss) / cnt_acc) : 0.0;
            amat        = (cnt_acc > 0) ? (1.0 + (1.0 * cnt_stall / cnt_acc)) : 0.0;
            avg_ram_lat = (u_mem.total_xfers > 0)
                        ? (1.0 * u_mem.total_lat_cycles / u_mem.total_xfers) : 0.0;

            $display("=========================================================================================================================");
            $display(" BAO CAO HIEU NANG & DO TRE RAM BIEN THIEN: %0s", title_str);
            $display("=========================================================================================================================");
            $display(" [1] Thong ke truy cap Cache:");
            $display("     + Tong truy cap (Accesses) : %2d lan  (Read Hit: %0d, Write Hit: %0d | Read Miss: %0d, Write Miss: %0d)",
                     cnt_acc, cnt_rhit, cnt_whit, cnt_rmiss, cnt_wmiss);
            $display("     + Ty le Hit / Miss         : Hit Rate = %0.2f %% | Miss Rate = %0.2f %%", hit_rate, miss_rate);
            $display("     + So lan Dirty Write-Back  : %2d lan", cnt_wb);
            $display("     + Tong chu ky Stall        : %2d cycles", cnt_stall);
            $display("     + Toc do trung binh (AMAT) : %0.2f cycles/access  (= 1 + %0d/%0d)", amat, cnt_stall, cnt_acc);
            $display("     + Luu luong RAM (Traffic)  : %2d words (%0d bytes)", cnt_traf, cnt_traf * 4);
            $display("-------------------------------------------------------------------------------------------------------------------------");
            $display(" [2] Phan bo do tre RAM bien thien (LFSR 2..5 chu ky) tren %0d giao dich RAM:", u_mem.total_xfers);
            $display("     + Do tre 2 chu ky : %0d lan", u_mem.lat_hist[2]);
            $display("     + Do tre 3 chu ky : %0d lan", u_mem.lat_hist[3]);
            $display("     + Do tre 4 chu ky : %0d lan", u_mem.lat_hist[4]);
            $display("     + Do tre 5 chu ky : %0d lan", u_mem.lat_hist[5]);
            $display("     => Do tre RAM trung binh thuc nghiem: %0.2f cycles/word", avg_ram_lat);
            $display("=========================================================================================================================");
            $display(" KET QUA KIEM TRA: %0d PASSED, %0d FAILED", pass_cnt, fail_cnt);
            $display("=========================================================================================================================");
        end
    endtask
