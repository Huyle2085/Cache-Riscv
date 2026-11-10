# U14 — Thiết kế Cache 2-Way Set-Associative tích hợp Lõi RISC-V (RV32I Pipeline 5 tầng)

Dự án thiết kế phần cứng bằng Verilog HDL theo lộ trình **ĐA1 $\rightarrow$ ĐA2 $\rightarrow$ ĐATN**:
- **ĐA1 (`minimal/`)**: Cache Direct-Mapped tối giản (4 sets $\times$ 1 way $\times$ 4 words/line = 64 Bytes), hỗ trợ Write-Back + Write-Allocate, kiểm chứng với mô hình bộ nhớ có độ trễ biến thiên.
- **ĐA2 (`rtl/`, `sw/`, `tb/`)**: Cache 2-Way Set-Associative (64 sets $\times$ 2 ways $\times$ 4 words/line = 2 KB), thay thế **LRU**, **Write-Back + Write-Allocate**, **Write Buffer 1 dòng (Eviction Buffer)**, tích hợp vào **Lõi vi xử lý RISC-V RV32I Pipeline 5 tầng (`IF-ID-EX-MEM-WB`)** chạy chương trình C thực tế, hỗ trợ đầy đủ các cơ chế bảo trì nhất quán dữ liệu (`CLEAN`, `Conditional INVALIDATE`, `CLEAN_INVALIDATE`), vùng nhớ Uncached/MMIO và giao thức 2 pha Request/Response chuẩn bị cho tích hợp DMA (ĐATN) và triển khai trên FPGA **DE10-Standard (`Cyclone V 5CSXFC6D6F31C6`)**.

---

## 1. Cấu trúc Thư mục

| Thư mục / Tệp | Mô tả |
| :--- | :--- |
| `rtl/riscv_dcache_2way.v` | Top-level D-Cache 2-Way Set-Associative (2 KB, tham số hóa `NUM_SETS`, `WAYS`) |
| `rtl/dcache_controller.v` | FSM 5 trạng thái (`S_IDLE`, `S_REFILL`, `S_WB_DRAIN`, `S_UNCACHED`, `S_FLUSH`) + Giao thức 2 pha (`cpu_req` / `cpu_req_ready` / `cpu_ready`) |
| `rtl/dcache_datapath.v` | `data_array` đồng bộ suy diễn **M10K Block RAM** (Dual-Port, byte-enable), `tag_array`, `valid_array`, `dirty_array`, `lru_bit`, Write Buffer 1 dòng và thanh ghi chốt yêu cầu CPU (`req_*_q`) |
| `rtl/dcache_req_rsp_adapter.v` | Bộ chuyển đổi chuẩn hóa giao thức 2 pha độc lập (`req_valid`/`req_ready` & `rsp_valid`/`rsp_rdata`) có Skid Buffer nhận yêu cầu mới ngay trong chu kỳ `rsp_valid = 1` |
| `rtl/dcache_perf_counters.v` | 5 bộ đếm hiệu năng phần cứng 32-bit (`cnt_accesses`, `cnt_misses`, `cnt_stall_cycles`, `cnt_mem_traffic`, `cnt_coherence_cyc`) |
| `rtl/riscv_core_rv32i.v` | Lõi RISC-V RV32I Pipeline 5 tầng (`IF-ID-EX-MEM-WB`) có Forwarding, Hazard Detection và IF Skid Buffer cho M10K Synchronous IMEM |
| `rtl/riscv_cache_soc.v` | Top-level SoC tích hợp Lõi RV32I + Bộ nhớ lệnh đồng bộ M10K (`imem`) + D-Cache 2-Way |
| `sw/benchmark_da2.c` | Chương trình C đánh giá hiệu năng Thrashing 2 chiều LRU & Byte/Halfword Strobe |
| `sw/start.S`, `sw/program.hex` | Mã khởi động Assembly và mã máy RV32I nạp vào `imem` |
| `tb/var_latency_mem.v` | Mô hình RAM độ trễ biến thiên (LFSR) kèm bộ giải mã địa chỉ SoC 4 vùng không alias |
| `tb/tb_riscv_dcache_2way.v` | Testbench kiểm chứng D-Cache 2-Way độc lập (35 bài test định hướng + Protocol Assertions) |
| `tb/tb_riscv_cache_soc.v` | Testbench toàn hệ thống SoC chạy C, đối sánh công bằng `DM-1K` / `DM-2K` / `2W-2K` và Random Stress Test (600 giao dịch $\times$ 3 seeds) |
| `quartus/riscv_cache_soc.qsf` | Cấu hình tổng hợp Quartus II cho FPGA DE10-Standard (`Cyclone V 5CSXFC6D6F31C6`) |
| `minimal/` | Mô hình Cache Direct-Mapped tối giản của giai đoạn ĐA1 |

---

## 2. Bản đồ Địa chỉ SoC (SoC Address Map — Không Alias)

| Vùng địa chỉ | Kích thước | Thuộc tính Cache | Ánh xạ vật lý trong `var_latency_mem` |
| :--- | :---: | :---: | :--- |
| `0x0000_0000 .. 0x0000_BFFF` | 48 KB | **Cacheable** (`bit[31]=0`) | Main RAM `ram[14'h0000 .. 14'h2FFF]` |
| `0x8000_0000 .. 0x8000_3FFF` | 16 KB | **Uncached** (`bit[31]=1`) | Shared RAM / DMA Buffer `ram[14'h3000 .. 14'h3FFF]` |
| `0x8001_0000 .. 0x8001_003F` | 64 B | **Uncached** (`bit[31]=1`) | Thanh ghi điều khiển MMIO / DMA `mmio_regs[0:15]` |
| Địa chỉ ngoài 3 vùng trên | — | — | **Invalid Address**: bật `addr_error = 1`, chặn ghi, trả về `0xDEAD_BAD0` |

---

## 3. Kết quả Đối sánh Hiệu năng trên Chương trình C (`tb_riscv_cache_soc`)

| Chỉ tiêu đánh giá | DM-1K (64S, 1W, 1 KB) | DM-2K (128S, 1W, 2 KB) | 2W-2K (64S, 2W, 2 KB) | Cải thiện (2W-2K vs DM-2K) |
| :--- | :---: | :---: | :---: | :---: |
| Tổng số lệnh RV32I hoàn tất | 257 instrs | 257 instrs | 257 instrs | — |
| Tổng truy cập D-Cache | 60 accesses | 60 accesses | 60 accesses | — |
| Số lần Cache Hit | 23 hits | 23 hits | **51 hits** | **+28 hits** |
| Số lần Cache Miss | 37 misses | 37 misses | **9 misses** | **-75.7%** |
| **Miss Rate** | 61.67% | 61.67% | **15.00%** | **-46.67%** |
| **Stall Cycles** | 1,283 cycles | 1,283 cycles | **244 cycles** | **-81.0%** |
| **AMAT (cycles/access)** | 22.38 | 22.38 | **5.07** | **-77.4% (nhanh hơn 4.42x)** |
| **Tổng chu kỳ CPU** | 1,602 cycles | 1,602 cycles | **563 cycles** | **-64.9%** |
| **CPI (Cycles / Instr)** | 6.23 | 6.23 | **2.19** | **-64.9%** |
| **Memory Traffic** | 248W (992 B) | 248W (992 B) | **48W (192 B)** | **-80.6%** |

---

## 4. Kết quả Tổng hợp Phần cứng trên FPGA DE10-Standard (`Cyclone V 5CSXFC6D6F31C6`)

Tổng hợp thực tế bằng **Quartus II 64-Bit Analysis & Synthesis (`quartus_map`)** sau khi chuyển cả `imem` và `data_array` sang kiến trúc bộ nhớ đồng bộ suy diễn **M10K Block RAM (`altsyncram` / `cyclonev_ram_block`)**:

### 4.1. Bảng phân bổ tài nguyên theo phân cấp (Hierarchy Utilization)

| Khối phân cấp (Entity) | Combinational ALUTs | Dedicated Registers | Block Memory Bits (M10K) |
| :--- | :---: | :---: | :---: |
| **`riscv_cache_soc` (Toàn SoC)** | **6,753** *(6,067 ALMs / 14.5%)* | **5,084** *(3.0%)* | **24,576 bits (33 M10K blocks)** |
| ├── `altsyncram:imem_rtl_0` (`imem`) | 0 | 0 | **8,192 bits (1 KB ROM)** |
| ├── `riscv_core_rv32i:u_core` | 1,811 | 1,439 | 0 |
| └── `riscv_dcache_2way:u_dcache` | 4,941 | 3,645 | **16,384 bits (2 KB Dual-Port RAM)** |
| &nbsp;&nbsp;&nbsp;&nbsp;├── `dcache_controller:u_ctrl` | 85 | 22 | 0 |
| &nbsp;&nbsp;&nbsp;&nbsp;├── `dcache_datapath:u_dp` | 4,696 | 3,463 | **16,384 bits (32 $\times$ 512-bit `altsyncram`)** |
| &nbsp;&nbsp;&nbsp;&nbsp;└── `dcache_perf_counters:u_perf` | 160 | 160 | 0 |

### 4.2. So sánh Trước và Sau khi chuyển `data_array` sang M10K Block RAM

| Chỉ số tổng hợp (`Cyclone V 5CSXFC6D6F31C6`) | Trước (`data_array` bằng FF/LUT) | Sau (`data_array` suy diễn M10K) | Mức cải thiện |
| :--- | :---: | :---: | :---: |
| **Ước lượng ALMs (`ALMs needed`)** | 15,573 / 41,910 (37.2%) | **6,067 / 41,910 (14.5%)** | **-61.0% ALMs** |
| **Combinational ALUTs (`riscv_cache_soc`)** | 11,317 | **6,753** | **-40.3% ALUTs** |
| **Dedicated Logic Registers (`riscv_cache_soc`)** | 21,462 | **5,084** | **-76.3% Registers (-16,378 FFs)** |
| **Riêng `dcache_datapath` (ALUTs / Registers)** | 9,335 ALUTs / 19,842 FFs | **4,696 ALUTs / 3,463 FFs** | **-49.7% ALUTs / -82.5% FFs** |
| **Block Memory Bits (M10K)** | 8,192 bits (`imem` only) | **24,576 bits (`imem` + `data_array`)** | **100% `data_array` (16,384 bits) vào M10K** |
| **Thời gian chạy `quartus_map`** | 49 giây | **26 giây** | **Nhanh hơn 1.88x** |

---

## 5. Hướng dẫn Chạy Mô phỏng (ModelSim)

```powershell
# 1. Biên dịch toàn bộ RTL và Testbench
C:\altera\13.0sp1\modelsim_ase\win32aloem\vlog.exe -work work rtl/dcache_perf_counters.v rtl/dcache_controller.v rtl/dcache_datapath.v rtl/riscv_dcache_2way.v rtl/dcache_req_rsp_adapter.v rtl/riscv_core_rv32i.v rtl/riscv_cache_soc.v tb/var_latency_mem.v tb/tb_riscv_dcache_2way.v tb/tb_riscv_cache_soc.v

# 2. Chạy kiểm thử D-Cache 2-Way độc lập (35/35 PASS + 897 Protocol Assertions)
C:\altera\13.0sp1\modelsim_ase\win32aloem\vsim.exe -c -do "run -all; quit -f" work.tb_riscv_dcache_2way

# 3. Chạy kiểm thử SoC RISC-V + D-Cache 2-Way chạy C (17/17 PASS + 11,023 Protocol Assertions)
C:\altera\13.0sp1\modelsim_ase\win32aloem\vsim.exe -c -do "run -all; quit -f" work.tb_riscv_cache_soc
```
