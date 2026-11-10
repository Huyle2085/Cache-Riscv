// =============================================================================
// minimal/tb/tc1_hit_miss.vh
// KỊCH BẢN 1 (TC1): KIỂM TRA COLD MISS (REFILL), READ HIT & WRITE HIT CƠ BẢN
//   - Tập trung trên Set 4 (Địa chỉ 0x0000_0010, Tag = 0)
//   - Mục đích: Quan sát hành trình FSM cơ bản nhất:
//       + Lần đầu đọc (Cold Miss): S_IDLE -> S_ALLOCATE -> S_IDLE
//       + Đọc lại (Read Hit)     : S_IDLE (1 chu kỳ, 0 Stall)
//       + Ghi đè (Write Hit)     : S_IDLE (1 chu kỳ, 0 Stall, bật Dirty = 1)
// =============================================================================
task run_tc1_hit_miss;
    begin
        $display("-------------------------------------------------------------------------------------------------------------------------");
        $display(" [TC1] KIEM TRA CO BAN: COLD READ MISS (REFILL) -> READ HIT -> WRITE HIT -> READ HIT (Tai Set 4)");
        $display("-------------------------------------------------------------------------------------------------------------------------");

        // 1. Cold Read Miss: Set 4 đang trống (Valid = 0), nạp từ RAM (0x1000_0004)
        trace_load(32'h0000_0010, 32'h1000_0004, "TC1.1: Cold Read Miss (Refill tu RAM vao Set 4)");

        // 2. Read Hit: Đọc lại đúng địa chỉ 0x0000_0010 (1 chu kỳ, Stall = 0)
        trace_load(32'h0000_0010, 32'h1000_0004, "TC1.2: Read Hit (Lay ngay tu Set 4 trong 1 chu ky)");

        // 3. Write Hit: Ghi đè 0x1111_2222 vào 0x0000_0010 (1 chu kỳ, bật Dirty = 1)
        trace_store(32'h0000_0010, 32'h1111_2222, "TC1.3: Write Hit (Ghi tai cho 1 cyc, bat Dirty=1)");

        // 4. Read Hit sau khi Write: Xác nhận dữ liệu trong Cache đã đổi thành 0x1111_2222
        trace_load(32'h0000_0010, 32'h1111_2222, "TC1.4: Read Hit xac nhan du lieu moi trong Cache");
    end
endtask
