# =============================================================================
# sw/start.S
# Điểm khởi đầu (C Runtime Startup crt0) cho chương trình C trên Lõi RV32I:
#   1. Khởi tạo con trỏ ngăn xếp sp = 0x0000_4000 (vùng RAM Cacheable).
#   2. Gọi hàm main() được biên dịch từ C bằng lệnh jal ra, main.
#   3. Khi main() trả về (kết quả nằm ở thanh ghi a0 = x10), thực thi lệnh
#      ebreak để báo hiệu hoàn tất chương trình cho Testbench / SoC.
# =============================================================================
    .section .text.init, "ax", @progbits
    .globl _start
    .type _start, @function

_start:
    lui  sp, 0x4                # sp = 0x0000_4000 (Stack Pointer)
    jal  ra, main               # Gọi hàm main() của chương trình C
    ebreak                      # Dừng CPU (halted = 1) sau khi main() kết thúc
