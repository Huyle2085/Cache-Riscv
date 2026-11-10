`timescale 1ns / 1ps
// Module phụ chỉ để ghi waveform, không cần sửa testbench gốc.
module dump_wave;
    initial begin
        $dumpfile("sim/tb_riscv_dcache_2way.vcd");
        $dumpvars(0, tb_riscv_dcache_2way);
    end

    // Watchdog: dừng mô phỏng nếu bị treo (vd. chờ maint_done mãi)
    initial begin
        #20000;
        $display("[TIMEOUT] Mo phong vuot qua 20us - dung lai (co the bi treo).");
        $finish;
    end
endmodule
