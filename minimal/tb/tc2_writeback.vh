// =============================================================================
// minimal/tb/tc2_writeback.vh
// KỊCH BẢN 2 (TC2): KIỂM TRA CLEAN CONFLICT MISS VS. DIRTY CONFLICT MISS (WRITE-BACK)
//   - Tập trung trên Set 8 (Địa chỉ 0x0000_0020 [Tag=0] và 0x0000_0120 [Tag=1])
//   - Mục đích: So sánh tốc độ xử lý khi trục xuất dòng sạch (Dirty=0, chỉ tốn
//     S_ALLOCATE) so với trục xuất dòng bẩn (Dirty=1, phải qua S_WRITEBACK + S_ALLOCATE).
// =============================================================================
task run_tc2_writeback;
    begin
        $display("-------------------------------------------------------------------------------------------------------------------------");
        $display(" [TC2] KIEM TRA TRUC XUAT: CLEAN CONFLICT MISS VS. DIRTY CONFLICT MISS & WRITE-BACK (Tai Set 8)");
        $display("-------------------------------------------------------------------------------------------------------------------------");

        // 1. Nạp dòng sạch Tag=0 (0x0000_0020) vào Set 8 (Dirty = 0)
        trace_load(32'h0000_0020, 32'h1000_0008, "TC2.1: Nap dong sach Tag=0 vao Set 8 (Dirty=0)");

        // 2. Clean Conflict Miss: Đọc Tag=1 (0x0000_0120, cùng Set 8).
        //    Vì dòng cũ đang sạch (Dirty=0), Cache đè lên ngay, KHÔNG tốn Write-Back!
        trace_load(32'h0000_0120, 32'h1000_0048, "TC2.2: Clean Conflict Miss (De dong sach, ko WB)");

        // 3. Làm bẩn dòng Tag=1 ở Set 8 bằng lệnh Write Hit (Dirty = 1)
        trace_store(32'h0000_0120, 32'hCAFE_BABE, "TC2.3: Write Hit lam ban dong Tag=1 (Dirty=1)");

        // 4. Dirty Conflict Miss: Đọc lại Tag=0 (0x0000_0020, cùng Set 8).
        //    Vì dòng Tag=1 đang có Dirty=1, FSM bắt buộc đi qua S_WRITEBACK rồi mới S_ALLOCATE!
        trace_load(32'h0000_0020, 32'h1000_0008, "TC2.4: Dirty Conflict Miss (WriteBack + Refill)");

        // 5. Đọc lại Tag=1 (0x0000_0120) từ RAM để chứng minh dữ liệu 0xCAFE_BABE đã được ghi trả xuống RAM
        trace_load(32'h0000_0120, 32'hCAFE_BABE, "TC2.5: Reload Tag=1 tu RAM chung minh WB dung");
    end
endtask
