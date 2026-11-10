`timescale 1ns / 1ps
// =============================================================================
// riscv_cache_soc.v
// Hệ thống tích hợp Lõi RISC-V (RV32I) + Bộ nhớ lệnh (IMEM) + D-Cache 2-Way (ĐA2).
//   Cấu trúc:
//   riscv_cache_soc
//   ├── imem     : Bộ nhớ lệnh (nạp mã máy chương trình C từ file .hex)
//   ├── u_core   : riscv_core_rv32i  (Lõi RISC-V thực thi chương trình C)
//   └── u_dcache : riscv_dcache_2way (D-Cache 2-Way Set-Associative + Write Buffer)
// =============================================================================
module riscv_cache_soc #(
    parameter WAYS           = 2,
    parameter NUM_SETS       = 64,
    parameter IMEM_WORDS     = 256,
    parameter IMEM_INIT_FILE = "sw/program.hex"
)(
    input  wire        clk,
    input  wire        rst_n,

    // --- Điều khiển bảo trì Cache (tùy chọn) ---
    input  wire        cache_flush,
    input  wire        cache_invalidate,
    output wire        maint_done,

    // --- Giao tiếp Bộ nhớ chính (nối tới var_latency_mem) ---
    output wire        mem_req,
    output wire        mem_we,
    output wire [3:0]  mem_wstrb,
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ready,

    // --- Trạng thái Core & Các bộ đếm Đánh giá Hiệu năng (ĐA2 Metrics) ---
    output wire        cpu_halted,
    output wire [31:0] cpu_cycles,
    output wire [31:0] cpu_instrs,
    output wire [31:0] cnt_accesses,
    output wire [31:0] cnt_misses,
    output wire [31:0] cnt_stall_cycles,
    output wire [31:0] cnt_mem_traffic,
    output wire [31:0] cnt_coherence_cyc
);

    // -------------------------------------------------------------------------
    // Bộ nhớ lệnh (Instruction Memory - Synchronous ROM cho M10K FPGA DE10-Standard)
    //   - Đọc đồng bộ theo sườn lên xung nhịp (always @(posedge clk)) để Quartus
    //     ánh xạ trực tiếp vào khối phần cứng M10K Block RAM trên Cyclone V.
    //   - Lõi riscv_core_rv32i tích hợp bộ đệm giữ lệnh (Instruction Skid Buffer)
    //     ở tầng IF/ID để xử lý độ trễ đọc đồng bộ 1 chu kỳ khi Pipeline bị Stall
    //     mà không làm lệch PC hay lặp lệnh.
    // -------------------------------------------------------------------------
    (* ramstyle = "M10K" *) reg [31:0] imem [0:IMEM_WORDS-1];
    wire [31:0] imem_addr;
    reg  [31:0] imem_rdata;

    integer k;
    initial begin
        for (k = 0; k < IMEM_WORDS; k = k + 1)
            imem[k] = 32'h0000_0013; // NOP (addi x0, x0, 0)
        if (IMEM_INIT_FILE != "")
            $readmemh(IMEM_INIT_FILE, imem);
    end

    always @(posedge clk) begin
        imem_rdata <= imem[imem_addr[9:2]];
    end

    // -------------------------------------------------------------------------
    // Dây kết nối giữa Lõi RISC-V và D-Cache 2-Way
    // -------------------------------------------------------------------------
    wire        dcache_req;
    wire        dcache_we;
    wire [3:0]  dcache_wstrb;
    wire [31:0] dcache_addr;
    wire [31:0] dcache_wdata;
    wire [31:0] dcache_rdata;
    wire        dcache_stall;
    wire        dcache_ready;

    // -------------------------------------------------------------------------
    // Khởi tạo Lõi RISC-V (RV32I)
    // -------------------------------------------------------------------------
    riscv_core_rv32i #(
        .RESET_PC (32'h0000_0000)
    ) u_core (
        .clk          (clk),
        .rst_n        (rst_n),
        .imem_addr    (imem_addr),
        .imem_rdata   (imem_rdata),
        .dcache_req   (dcache_req),
        .dcache_we    (dcache_we),
        .dcache_wstrb (dcache_wstrb),
        .dcache_addr  (dcache_addr),
        .dcache_wdata (dcache_wdata),
        .dcache_rdata (dcache_rdata),
        .dcache_stall (dcache_stall),
        .dcache_ready (dcache_ready),
        .halted       (cpu_halted),
        .cycle_cnt    (cpu_cycles),
        .instr_cnt    (cpu_instrs)
    );

    // -------------------------------------------------------------------------
    // Khởi tạo D-Cache (WAYS=1: Direct-Mapped ĐA1, WAYS=2: 2-Way ĐA2)
    // -------------------------------------------------------------------------
    riscv_dcache_2way #(
        .NUM_SETS (NUM_SETS),
        .WAYS     (WAYS)
    ) u_dcache (
        .clk               (clk),
        .rst_n             (rst_n),
        .cpu_req           (dcache_req),
        .cpu_req_ready     (),
        .cpu_we            (dcache_we),
        .cpu_wstrb         (dcache_wstrb),
        .cpu_addr          (dcache_addr),
        .cpu_wdata         (dcache_wdata),
        .cpu_rdata         (dcache_rdata),
        .cpu_stall         (dcache_stall),
        .cpu_ready         (dcache_ready),
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

endmodule
