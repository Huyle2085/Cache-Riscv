@echo off
REM ============================================================================
REM minimal/run_minimal.bat
REM Cach dung:
REM   minimal\run_minimal.bat          -> Chay tong hop tat ca Test Case DA1 (TC1 + TC2 + TC3)
REM   minimal\run_minimal.bat tc1      -> Chi chay rieng TC1: Cold Miss, Read Hit, Write Hit
REM   minimal\run_minimal.bat tc2      -> Chi chay rieng TC2: Clean Conflict vs. Dirty Write-Back
REM   minimal\run_minimal.bat tc3      -> Chi chay rieng TC3: Write-Allocate & Ping-Pong Thrashing
REM   minimal\run_minimal.bat compare  -> Chay so sanh toc do DA1 vs. DA2 (tb_compare_models)
REM ============================================================================
cd /d "%~dp0\.."

if /i "%1"=="tc1"     goto RUN_TC1
if /i "%1"=="tc2"     goto RUN_TC2
if /i "%1"=="tc3"     goto RUN_TC3
if /i "%1"=="compare" goto RUN_COMPARE

:RUN_ALL
echo [1/2] Bien dich Testbench Tong hop DA1 [tb_dcache_minimal]...
vlog minimal/dcache_min_controller.v ^
     minimal/dcache_min_datapath.v ^
     minimal/dcache_min_perf_counters.v ^
     minimal/dcache_minimal.v ^
     tb/var_latency_mem.v ^
     minimal/tb_dcache_minimal.v
if errorlevel 1 exit /b 1
echo [2/2] Chay mo phong [tb_dcache_minimal]...
vsim -c -do "run -all; quit -f" tb_dcache_minimal
exit /b 0

:RUN_TC1
echo [1/2] Bien dich Testbench nho TC1 [tb_tc1_hit_miss]...
vlog minimal/dcache_min_controller.v ^
     minimal/dcache_min_datapath.v ^
     minimal/dcache_min_perf_counters.v ^
     minimal/dcache_minimal.v ^
     tb/var_latency_mem.v ^
     minimal/tb/tb_tc1_hit_miss.v
if errorlevel 1 exit /b 1
echo [2/2] Chay mo phong [tb_tc1_hit_miss]...
vsim -c -do "run -all; quit -f" tb_tc1_hit_miss
exit /b 0

:RUN_TC2
echo [1/2] Bien dich Testbench nho TC2 [tb_tc2_writeback]...
vlog minimal/dcache_min_controller.v ^
     minimal/dcache_min_datapath.v ^
     minimal/dcache_min_perf_counters.v ^
     minimal/dcache_minimal.v ^
     tb/var_latency_mem.v ^
     minimal/tb/tb_tc2_writeback.v
if errorlevel 1 exit /b 1
echo [2/2] Chay mo phong [tb_tc2_writeback]...
vsim -c -do "run -all; quit -f" tb_tc2_writeback
exit /b 0

:RUN_TC3
echo [1/2] Bien dich Testbench nho TC3 [tb_tc3_thrashing]...
vlog minimal/dcache_min_controller.v ^
     minimal/dcache_min_datapath.v ^
     minimal/dcache_min_perf_counters.v ^
     minimal/dcache_minimal.v ^
     tb/var_latency_mem.v ^
     minimal/tb/tb_tc3_thrashing.v
if errorlevel 1 exit /b 1
echo [2/2] Chay mo phong [tb_tc3_thrashing]...
vsim -c -do "run -all; quit -f" tb_tc3_thrashing
exit /b 0

:RUN_COMPARE
echo [1/2] Bien dich Testbench So sanh DA1 vs. DA2 [tb_compare_models]...
vlog minimal/dcache_min_controller.v ^
     minimal/dcache_min_datapath.v ^
     minimal/dcache_min_perf_counters.v ^
     minimal/dcache_minimal.v ^
     rtl/dcache_controller.v ^
     rtl/dcache_datapath.v ^
     rtl/dcache_perf_counters.v ^
     rtl/riscv_dcache_2way.v ^
     tb/var_latency_mem.v ^
     minimal/tb_compare_models.v
if errorlevel 1 exit /b 1
echo [2/2] Chay mo phong [tb_compare_models]...
vsim -c -do "run -all; quit -f" tb_compare_models
exit /b 0
