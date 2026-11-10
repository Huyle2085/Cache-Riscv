`timescale 1ns / 1ps
// =============================================================================
// riscv_core_rv32i.v
// Lõi vi xử lý RISC-V 32-bit (RV32I) kiến trúc Pipeline 5 tầng (IF-ID-EX-MEM-WB)
// tích hợp giao tiếp D-Cache cho Đồ án 2 (ĐA2).
//
// Ưu điểm kiến trúc Pipeline 5 tầng so với Single-Cycle:
//   1. Cắt ngắn đường trễ tới hạn (Critical Path) thành 5 công đoạn độc lập:
//      - IF  : Đọc bộ nhớ lệnh (PC -> IMEM -> Thanh ghi IF/ID)
//      - ID  : Giải mã lệnh & Đọc Register File (có WB-to-ID Bypass -> Thanh ghi ID/EX)
//      - EX  : ALU, Forwarding MUX & Tính địa chỉ/rẽ nhánh (-> Thanh ghi EX/MEM)
//      - MEM : Giao tiếp D-Cache. Toàn bộ tín hiệu dcache_addr, dcache_wdata,
//              dcache_wstrb, dcache_we xuất phát TRỰC TIẾP từ thanh ghi EX/MEM,
//              giúp tách biệt hoàn toàn đường trễ ALU khỏi đường trễ tra cứu Tag
//              của D-Cache, tối ưu tần số Fmax khi tổng hợp logic (Synthesis).
//      - WB  : Căn chỉnh Byte/Halfword từ thanh ghi cpu_rdata của D-Cache và
//              ghi ngược về Register File.
//   2. Tích hợp đầy đủ:
//      - Khối Forwarding Unit (EX/MEM -> EX và MEM/WB -> EX)
//      - Khối Hazard Detection Unit (Load-Use Stall 1 chu kỳ & Branch Flush)
//      - Cơ chế đóng băng Pipeline (Pipeline Freeze) khi D-Cache báo bận (dcache_stall).
// =============================================================================
module riscv_core_rv32i #(
    parameter RESET_PC = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        rst_n,

    // --- Giao tiếp Bộ nhớ Lệnh (Instruction Memory Interface - IF Stage) ---
    output reg  [31:0] imem_addr,
    input  wire [31:0] imem_rdata,

    // --- Giao tiếp D-Cache (Data Cache LSU Interface - MEM Stage) ---
    output wire        dcache_req,
    output wire        dcache_we,
    output wire [3:0]  dcache_wstrb,
    output wire [31:0] dcache_addr,
    output wire [31:0] dcache_wdata,
    input  wire [31:0] dcache_rdata,
    input  wire        dcache_stall,
    input  wire        dcache_ready,

    // --- Trạng thái thực thi chương trình ---
    output reg         halted,       // Lên 1 khi lệnh EBREAK/ECALL hoàn tất ở tầng WB
    output reg  [31:0] cycle_cnt,    // Tổng số chu kỳ xung nhịp thực thi chương trình
    output reg  [31:0] instr_cnt     // Tổng số lệnh RV32I đã hoàn tất (retired ở WB)
);

    // Mã Opcode chuẩn RV32I
    localparam OP_LUI    = 7'b0110111;
    localparam OP_AUIPC  = 7'b0010111;
    localparam OP_JAL    = 7'b1101111;
    localparam OP_JALR   = 7'b1100111;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_IMM    = 7'b0010011;
    localparam OP_REG    = 7'b0110011;
    localparam OP_FENCE  = 7'b0001111;
    localparam OP_SYSTEM = 7'b1110011;

    // -------------------------------------------------------------------------
    // Tập thanh ghi đa dụng (Register File: x0 .. x31)
    // -------------------------------------------------------------------------
    reg [31:0] regfile [0:31];
    integer i;

    // =========================================================================
    // Khai báo các thanh ghi đường ống (Pipeline Registers)
    // =========================================================================
    // --- 1. Thanh ghi IF/ID & Skid Buffer cho Synchronous IMEM (M10K Block RAM) ---
    // Vì IMEM đọc đồng bộ theo xung nhịp (always @(posedge clk) imem_rdata <= imem[imem_addr]),
    // trong chế độ chạy liên tục không dừng, tại sườn lên clk khi if_id_pc chốt imem_addr thì
    // thanh ghi đầu ra M10K (imem_rdata) cũng đồng thời chốt lệnh tương ứng với if_id_pc.
    // Khi Pipeline bị dừng (mem_stall hoặc load_use_hazard), imem_rdata đã kịp chuyển sang
    // lệnh kế tiếp; do đó bộ đệm if_instr_buf sẽ bắt giữ lại lệnh hiện tại ở chu kỳ đầu tiên
    // của Stall để bảo toàn tuyệt đối lệnh tại tầng ID mà không bị lệch PC hay lặp lệnh.
    reg        if_id_valid;
    reg [31:0] if_id_pc;
    reg        if_buf_valid;
    reg [31:0] if_instr_buf;
    wire [31:0] if_id_instr = if_buf_valid ? if_instr_buf : imem_rdata;

    // --- 2. Thanh ghi ID/EX ---
    reg        id_ex_valid;
    reg [31:0] id_ex_pc;
    reg [6:0]  id_ex_opcode;
    reg [2:0]  id_ex_funct3;
    reg [6:0]  id_ex_funct7;
    reg [4:0]  id_ex_rd;
    reg [4:0]  id_ex_rs1;
    reg [4:0]  id_ex_rs2;
    reg [31:0] id_ex_rs1_val;
    reg [31:0] id_ex_rs2_val;
    reg [31:0] id_ex_imm;
    reg        id_ex_is_load;
    reg        id_ex_is_store;
    reg        id_ex_rf_we;
    reg        id_ex_is_system;

    // --- 3. Thanh ghi EX/MEM ---
    reg        ex_mem_valid;
    reg [2:0]  ex_mem_funct3;
    reg [4:0]  ex_mem_rd;
    reg [31:0] ex_mem_alu_out;
    reg [31:0] ex_mem_wdata;
    reg [3:0]  ex_mem_wstrb;
    reg        ex_mem_is_load;
    reg        ex_mem_is_store;
    reg        ex_mem_rf_we;
    reg        ex_mem_is_system;

    // --- 4. Thanh ghi MEM/WB ---
    reg        mem_wb_valid;
    reg [2:0]  mem_wb_funct3;
    reg [4:0]  mem_wb_rd;
    reg [31:0] mem_wb_alu_out;
    reg        mem_wb_is_load;
    reg        mem_wb_rf_we;
    reg        mem_wb_is_system;

    // =========================================================================
    // Tín hiệu điều khiển Stall & Flush toàn cục
    // =========================================================================
    wire ex_mem_is_mem = ex_mem_is_load || ex_mem_is_store;

    // Khi tầng MEM có lệnh đọc/ghi bộ nhớ:
    // - Nếu lệnh trước vừa hoàn tất ở D-Cache (dcache_ready == 1), đợi 1 nhịp để tránh
    //   ghi đè thanh ghi dcache_rdata khi tầng WB đang đọc dữ liệu đó.
    // - Hoặc khi D-Cache báo dcache_stall (Miss / đang bận), đóng băng toàn bộ Pipeline.
    wire mem_stall = dcache_stall || (ex_mem_valid && ex_mem_is_mem && dcache_ready);

    // =========================================================================
    // TẦNG 5: WRITE-BACK (WB Stage)
    // - Trích xuất dữ liệu từ thanh ghi dcache_rdata (cho lệnh Load) hoặc lấy kết quả ALU
    // =========================================================================
    wire [1:0]  wb_byte_off = mem_wb_alu_out[1:0];
    wire [7:0]  wb_ld_byte  = (wb_byte_off == 2'd0) ? dcache_rdata[7:0]   :
                              (wb_byte_off == 2'd1) ? dcache_rdata[15:8]  :
                              (wb_byte_off == 2'd2) ? dcache_rdata[23:16] :
                                                      dcache_rdata[31:24];
    wire [15:0] wb_ld_half  = wb_byte_off[1] ? dcache_rdata[31:16] : dcache_rdata[15:0];

    reg [31:0] wb_load_aligned;
    always @(*) begin
        case (mem_wb_funct3)
            3'b000: wb_load_aligned = {{24{wb_ld_byte[7]}}, wb_ld_byte};  // LB
            3'b001: wb_load_aligned = {{16{wb_ld_half[15]}}, wb_ld_half}; // LH
            3'b010: wb_load_aligned = dcache_rdata;                       // LW
            3'b100: wb_load_aligned = {24'd0, wb_ld_byte};                // LBU
            3'b101: wb_load_aligned = {16'd0, wb_ld_half};                // LHU
            default: wb_load_aligned = dcache_rdata;
        endcase
    end

    wire [31:0] wb_wdata = mem_wb_is_load ? wb_load_aligned : mem_wb_alu_out;
    wire        wb_rf_we = mem_wb_valid && mem_wb_rf_we && (mem_wb_rd != 5'd0);

    // =========================================================================
    // TẦNG 2: INSTRUCTION DECODE (ID Stage) & HAZARD DETECTION
    // =========================================================================
    wire [6:0] id_opcode = if_id_instr[6:0];
    wire [4:0] id_rd     = if_id_instr[11:7];
    wire [2:0] id_funct3 = if_id_instr[14:12];
    wire [4:0] id_rs1    = if_id_instr[19:15];
    wire [4:0] id_rs2    = if_id_instr[24:20];
    wire [6:0] id_funct7 = if_id_instr[31:25];

    // Giải mã hằng số tức thời (Immediate Generator) tại tầng ID
    wire [31:0] id_imm_i = {{20{if_id_instr[31]}}, if_id_instr[31:20]};
    wire [31:0] id_imm_s = {{20{if_id_instr[31]}}, if_id_instr[31:25], if_id_instr[11:7]};
    wire [31:0] id_imm_b = {{19{if_id_instr[31]}}, if_id_instr[31], if_id_instr[7],
                            if_id_instr[30:25], if_id_instr[11:8], 1'b0};
    wire [31:0] id_imm_u = {if_id_instr[31:12], 12'b0};
    wire [31:0] id_imm_j = {{11{if_id_instr[31]}}, if_id_instr[31], if_id_instr[19:12],
                            if_id_instr[20], if_id_instr[30:21], 1'b0};

    reg [31:0] id_imm;
    always @(*) begin
        case (id_opcode)
            OP_STORE:              id_imm = id_imm_s;
            OP_BRANCH:             id_imm = id_imm_b;
            OP_LUI, OP_AUIPC:      id_imm = id_imm_u;
            OP_JAL:                id_imm = id_imm_j;
            default:               id_imm = id_imm_i;
        endcase
    end

    wire id_is_load   = (id_opcode == OP_LOAD);
    wire id_is_store  = (id_opcode == OP_STORE);
    wire id_is_system = (id_opcode == OP_SYSTEM);
    wire id_rf_we     = (id_opcode == OP_LUI)  || (id_opcode == OP_AUIPC) ||
                        (id_opcode == OP_JAL)  || (id_opcode == OP_JALR)  ||
                        (id_opcode == OP_LOAD) || (id_opcode == OP_IMM)   ||
                        (id_opcode == OP_REG);

    // Đọc Register File có hỗ trợ Write-First Bypass từ tầng WB (WB -> ID Forwarding)
    wire [31:0] id_rs1_val = (id_rs1 == 5'd0) ? 32'd0 :
                             (wb_rf_we && (mem_wb_rd == id_rs1)) ? wb_wdata : regfile[id_rs1];
    wire [31:0] id_rs2_val = (id_rs2 == 5'd0) ? 32'd0 :
                             (wb_rf_we && (mem_wb_rd == id_rs2)) ? wb_wdata : regfile[id_rs2];

    // Phát hiện xung đột Load-Use Hazard (Lệnh ở EX là Load và lệnh ở ID cần dùng ngay rd đó)
    wire id_uses_rs1 = (id_opcode == OP_JALR)   || (id_opcode == OP_BRANCH) ||
                       (id_opcode == OP_LOAD)   || (id_opcode == OP_STORE)  ||
                       (id_opcode == OP_IMM)    || (id_opcode == OP_REG);
    wire id_uses_rs2 = (id_opcode == OP_BRANCH) || (id_opcode == OP_STORE)  ||
                       (id_opcode == OP_REG);

    wire load_use_hazard = if_id_valid && id_ex_valid && id_ex_is_load && (id_ex_rd != 5'd0) &&
                           ((id_uses_rs1 && (id_rs1 == id_ex_rd)) ||
                            (id_uses_rs2 && (id_rs2 == id_ex_rd)));

    // =========================================================================
    // TẦNG 3: EXECUTE (EX Stage) & FORWARDING UNIT
    // =========================================================================
    // Forwarding cho toán hạng rs1 và rs2 tại tầng EX (ưu tiên EX/MEM trước MEM/WB)
    wire ex_mem_fwd_valid = ex_mem_valid && ex_mem_rf_we && !ex_mem_is_load && (ex_mem_rd != 5'd0);

    wire [31:0] ex_rs1_val = (ex_mem_fwd_valid && (ex_mem_rd == id_ex_rs1)) ? ex_mem_alu_out :
                             (wb_rf_we         && (mem_wb_rd == id_ex_rs1)) ? wb_wdata       :
                                                                              id_ex_rs1_val;

    wire [31:0] ex_rs2_val = (ex_mem_fwd_valid && (ex_mem_rd == id_ex_rs2)) ? ex_mem_alu_out :
                             (wb_rf_we         && (mem_wb_rd == id_ex_rs2)) ? wb_wdata       :
                                                                              id_ex_rs2_val;

    // Toán hạng đưa vào ALU
    wire [31:0] alu_in_a = ex_rs1_val;
    wire [31:0] alu_in_b = (id_ex_opcode == OP_REG) ? ex_rs2_val : id_ex_imm;
    wire [4:0]  shamt    = alu_in_b[4:0];
    wire        sub_sra  = (id_ex_opcode == OP_REG) && id_ex_funct7[5];

    reg [31:0] alu_math_out;
    always @(*) begin
        case (id_ex_funct3)
            3'b000: alu_math_out = sub_sra ? (alu_in_a - alu_in_b) : (alu_in_a + alu_in_b);
            3'b001: alu_math_out = alu_in_a << shamt;
            3'b010: alu_math_out = ($signed(alu_in_a) < $signed(alu_in_b)) ? 32'd1 : 32'd0;
            3'b011: alu_math_out = (alu_in_a < alu_in_b) ? 32'd1 : 32'd0;
            3'b100: alu_math_out = alu_in_a ^ alu_in_b;
            3'b101: alu_math_out = id_ex_funct7[5] ? ($signed(alu_in_a) >>> shamt)
                                                   : (alu_in_a >> shamt);
            3'b110: alu_math_out = alu_in_a | alu_in_b;
            3'b111: alu_math_out = alu_in_a & alu_in_b;
            default: alu_math_out = 32'd0;
        endcase
    end

    // Chọn kết quả ghi vào thanh ghi ex_mem_alu_out
    wire [31:0] ex_addr_calc = ex_rs1_val + id_ex_imm;
    reg  [31:0] ex_result;
    always @(*) begin
        case (id_ex_opcode)
            OP_LUI:              ex_result = id_ex_imm;
            OP_AUIPC:            ex_result = id_ex_pc + id_ex_imm;
            OP_JAL, OP_JALR:     ex_result = id_ex_pc + 32'd4;
            OP_LOAD, OP_STORE:   ex_result = ex_addr_calc;
            default:             ex_result = alu_math_out;
        endcase
    end

    // Chuẩn bị dữ liệu ghi và Byte Strobe tại cuối tầng EX để chốt vào thanh ghi EX/MEM
    wire [1:0] ex_byte_off = ex_addr_calc[1:0];
    reg  [3:0] ex_wstrb_calc;
    reg [31:0] ex_wdata_calc;
    always @(*) begin
        case (id_ex_funct3[1:0])
            2'b00: begin // SB
                ex_wstrb_calc = 4'b0001 << ex_byte_off;
                ex_wdata_calc = {4{ex_rs2_val[7:0]}};
            end
            2'b01: begin // SH
                ex_wstrb_calc = ex_byte_off[1] ? 4'b1100 : 4'b0011;
                ex_wdata_calc = {2{ex_rs2_val[15:0]}};
            end
            default: begin // SW
                ex_wstrb_calc = 4'b1111;
                ex_wdata_calc = ex_rs2_val;
            end
        endcase
    end

    // Giải quyết Rẽ nhánh / Nhảy (Branch & Jump Resolution) tại tầng EX
    reg ex_branch_cond;
    always @(*) begin
        case (id_ex_funct3)
            3'b000: ex_branch_cond = (ex_rs1_val == ex_rs2_val);                   // BEQ
            3'b001: ex_branch_cond = (ex_rs1_val != ex_rs2_val);                   // BNE
            3'b100: ex_branch_cond = ($signed(ex_rs1_val) <  $signed(ex_rs2_val)); // BLT
            3'b101: ex_branch_cond = ($signed(ex_rs1_val) >= $signed(ex_rs2_val)); // BGE
            3'b110: ex_branch_cond = (ex_rs1_val <  ex_rs2_val);                   // BLTU
            3'b111: ex_branch_cond = (ex_rs1_val >= ex_rs2_val);                   // BGEU
            default: ex_branch_cond = 1'b0;
        endcase
    end

    wire ex_take_branch = id_ex_valid && (
        (id_ex_opcode == OP_JAL)  ||
        (id_ex_opcode == OP_JALR) ||
        ((id_ex_opcode == OP_BRANCH) && ex_branch_cond)
    );

    wire [31:0] ex_branch_target = (id_ex_opcode == OP_JALR)
                                 ? ((ex_rs1_val + id_ex_imm) & ~32'd1)
                                 : (id_ex_pc + id_ex_imm);

    // =========================================================================
    // TẦNG 4: MEMORY ACCESS (MEM Stage - Giao tiếp trực tiếp D-Cache)
    // - Tất cả các đường địa chỉ/dữ liệu/điều khiển đi vào D-Cache đều xuất phát
    //   trực tiếp từ các Flip-Flop của thanh ghi đường ống EX/MEM!
    // =========================================================================
    assign dcache_req   = !halted && ex_mem_valid && ex_mem_is_mem && !dcache_ready;
    assign dcache_we    = ex_mem_is_store;
    assign dcache_wstrb = ex_mem_wstrb;
    assign dcache_addr  = ex_mem_alu_out;
    assign dcache_wdata = ex_mem_wdata;

    // Ngừng nạp lệnh mới khi đã phát hiện lệnh hệ thống (EBREAK/ECALL) trong đường ống
    wire system_in_pipe = (if_id_valid  && id_is_system)     ||
                          (id_ex_valid  && id_ex_is_system)  ||
                          (ex_mem_valid && ex_mem_is_system) ||
                          (mem_wb_valid && mem_wb_is_system);

    // =========================================================================
    // Khối tuần tự: Cập nhật PC, các thanh ghi Pipeline (IF/ID, ID/EX, EX/MEM, MEM/WB)
    // và Register File
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        i = 0;
        if (!rst_n) begin
            imem_addr        <= RESET_PC;
            halted           <= 1'b0;
            cycle_cnt        <= 32'd0;
            instr_cnt        <= 32'd0;

            if_id_valid      <= 1'b0;
            if_id_pc         <= 32'd0;
            if_buf_valid     <= 1'b0;
            if_instr_buf     <= 32'h0000_0013;

            id_ex_valid      <= 1'b0;
            id_ex_pc         <= 32'd0;
            id_ex_opcode     <= 7'd0;
            id_ex_funct3     <= 3'd0;
            id_ex_funct7     <= 7'd0;
            id_ex_rd         <= 5'd0;
            id_ex_rs1        <= 5'd0;
            id_ex_rs2        <= 5'd0;
            id_ex_rs1_val    <= 32'd0;
            id_ex_rs2_val    <= 32'd0;
            id_ex_imm        <= 32'd0;
            id_ex_is_load    <= 1'b0;
            id_ex_is_store   <= 1'b0;
            id_ex_rf_we      <= 1'b0;
            id_ex_is_system  <= 1'b0;

            ex_mem_valid     <= 1'b0;
            ex_mem_funct3    <= 3'd0;
            ex_mem_rd        <= 5'd0;
            ex_mem_alu_out   <= 32'd0;
            ex_mem_wdata     <= 32'd0;
            ex_mem_wstrb     <= 4'd0;
            ex_mem_is_load   <= 1'b0;
            ex_mem_is_store  <= 1'b0;
            ex_mem_rf_we     <= 1'b0;
            ex_mem_is_system <= 1'b0;

            mem_wb_valid     <= 1'b0;
            mem_wb_funct3    <= 3'd0;
            mem_wb_rd        <= 5'd0;
            mem_wb_alu_out   <= 32'd0;
            mem_wb_is_load   <= 1'b0;
            mem_wb_rf_we     <= 1'b0;
            mem_wb_is_system <= 1'b0;

            for (i = 0; i < 32; i = i + 1)
                regfile[i] <= 32'd0;
        end else if (!halted) begin
            cycle_cnt <= cycle_cnt + 1'b1;

            // -----------------------------------------------------------------
            // 1. Hoàn tất lệnh ở tầng WB (Write-Back vào Register File)
            // -----------------------------------------------------------------
            if (mem_wb_valid) begin
                instr_cnt <= instr_cnt + 1'b1;
                if (wb_rf_we)
                    regfile[mem_wb_rd] <= wb_wdata;
                if (mem_wb_is_system)
                    halted <= 1'b1;
            end

            // -----------------------------------------------------------------
            // 2. Cập nhật các tầng Pipeline (Đóng băng khi mem_stall == 1)
            // -----------------------------------------------------------------
            if (mem_stall) begin
                // D-Cache đang bận: giữ nguyên IF/ID, ID/EX, EX/MEM; chèn bubble vào MEM/WB.
                // Chốt lại lệnh từ Synchronous IMEM vào Skid Buffer nếu chưa chốt.
                if (!if_buf_valid) begin
                    if_buf_valid <= 1'b1;
                    if_instr_buf <= imem_rdata;
                end
                // Chốt lại giá trị đã Forwarding ở EX để không bị mất khi lệnh ở MEM/WB vừa thoát đi.
                mem_wb_valid  <= 1'b0;
                id_ex_rs1_val <= ex_rs1_val;
                id_ex_rs2_val <= ex_rs2_val;
            end else begin
                // --- Chuyển tầng EX/MEM -> MEM/WB ---
                mem_wb_valid     <= ex_mem_valid;
                mem_wb_funct3    <= ex_mem_funct3;
                mem_wb_rd        <= ex_mem_rd;
                mem_wb_alu_out   <= ex_mem_alu_out;
                mem_wb_is_load   <= ex_mem_is_load;
                mem_wb_rf_we     <= ex_mem_rf_we;
                mem_wb_is_system <= ex_mem_is_system;

                // --- Chuyển tầng ID/EX -> EX/MEM ---
                ex_mem_valid     <= id_ex_valid;
                ex_mem_funct3    <= id_ex_funct3;
                ex_mem_rd        <= id_ex_rd;
                ex_mem_alu_out   <= ex_result;
                ex_mem_wdata     <= ex_wdata_calc;
                ex_mem_wstrb     <= ex_wstrb_calc;
                ex_mem_is_load   <= id_ex_is_load;
                ex_mem_is_store  <= id_ex_is_store;
                ex_mem_rf_we     <= id_ex_rf_we;
                ex_mem_is_system <= id_ex_is_system;

                // --- Chuyển tầng IF/ID -> ID/EX & Cập nhật PC ---
                if (ex_take_branch) begin
                    // Rẽ nhánh thành công ở EX: Xóa (Flush) IF/ID, Skid Buffer và ID/EX, nạp PC đích
                    imem_addr       <= ex_branch_target;
                    if_id_valid     <= 1'b0;
                    if_buf_valid    <= 1'b0;
                    id_ex_valid     <= 1'b0;
                end else if (load_use_hazard) begin
                    // Load-Use Hazard: Giữ nguyên PC và IF/ID trong 1 chu kỳ, chèn Bubble vào ID/EX.
                    // Chốt lệnh hiện tại từ Synchronous IMEM vào Skid Buffer để chu kỳ sau dùng lại.
                    id_ex_valid     <= 1'b0;
                    if (!if_buf_valid) begin
                        if_buf_valid <= 1'b1;
                        if_instr_buf <= imem_rdata;
                    end
                end else begin
                    // Hoạt động bình thường: dịch lệnh từ IF/ID sang ID/EX, giải phóng Skid Buffer
                    if_buf_valid    <= 1'b0;
                    id_ex_valid     <= if_id_valid;
                    id_ex_pc        <= if_id_pc;
                    id_ex_opcode    <= id_opcode;
                    id_ex_funct3    <= id_funct3;
                    id_ex_funct7    <= id_funct7;
                    id_ex_rd        <= id_rd;
                    id_ex_rs1       <= id_rs1;
                    id_ex_rs2       <= id_rs2;
                    id_ex_rs1_val   <= id_rs1_val;
                    id_ex_rs2_val   <= id_rs2_val;
                    id_ex_imm       <= id_imm;
                    id_ex_is_load   <= id_is_load;
                    id_ex_is_store  <= id_is_store;
                    id_ex_rf_we     <= id_rf_we;
                    id_ex_is_system <= id_is_system;

                    // Nạp lệnh mới từ Synchronous IMEM vào IF/ID (ngừng nạp thêm sau khi gặp EBREAK)
                    if (system_in_pipe) begin
                        if_id_valid <= 1'b0;
                    end else begin
                        if_id_valid <= 1'b1;
                        if_id_pc    <= imem_addr;
                        imem_addr   <= imem_addr + 32'd4;
                    end
                end
            end
        end
    end

endmodule
