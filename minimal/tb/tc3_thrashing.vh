// =============================================================================
// minimal/tb/tc3_thrashing.vh
// KỊCH BẢN 3 (TC3): KIỂM TRA WRITE-ALLOCATE & HIỆN TƯỢNG PING-PONG THRASHING
//   - Tập trung trên Set 12 (Địa chỉ 0x0000_0030 [Tag=0] và 0x0000_0130 [Tag=1])
//   - Mục đích:
//       + Kiểm tra chính sách Write-Allocate khi ghi vào dòng trống (Write Miss).
//       + Minh họa nhược điểm Thrashing của Direct-Mapped: 2 địa chỉ cùng Set
//         thay nhau truy cập làm Cache Miss liên tục (0% Hit).
// =============================================================================
task run_tc3_thrashing;
    begin
        $display("-------------------------------------------------------------------------------------------------------------------------");
        $display(" [TC3] KIEM TRA WRITE-ALLOCATE & PING-PONG THRASHING TREN DIRECT-MAPPED (Tai Set 12)");
        $display("-------------------------------------------------------------------------------------------------------------------------");

        // 1. Write Miss (Write-Allocate) vào Set 12 đang trống (0x0000_0030, Tag=0)
        trace_store(32'h0000_0030, 32'hDEAD_BEEF, "TC3.1: Write Miss (Write-Allocate vao Set 12)");

        // 2. Read Hit kiểm tra dữ liệu vừa Write-Allocate
        trace_load(32'h0000_0030, 32'hDEAD_BEEF, "TC3.2: Read Hit kiem tra sau Write-Allocate");

        // 3. Ping-Pong Thrashing: Truy cập luân phiên Tag=1 (0x0130) và Tag=0 (0x0030) cùng Set 12
        trace_load(32'h0000_0130, 32'h1000_004C, "TC3.3: Ping-Pong 1 (Doc Tag=1 -> Da Tag=0 Dirty)");
        trace_load(32'h0000_0030, 32'hDEAD_BEEF, "TC3.4: Ping-Pong 2 (Doc Tag=0 -> Da Tag=1 Clean)");
        trace_load(32'h0000_0130, 32'h1000_004C, "TC3.5: Ping-Pong 3 (Doc Tag=1 -> Lai Miss 100%)");
    end
endtask
