# =============================================================================
# sw/start.S
# Mã hợp ngữ RV32I tương đương sau biên dịch của sw/benchmark_da2.c
# =============================================================================
    .section .text
    .globl _start

_start:
    addi s7, x0, -0x800         # 0x00: 80000B93 | s7 = -2048 (-0x800: bước nhảy 2 KB)
    addi s0, x0, 0x100          # 0x04: 10000413 | s0 = &A[0] (0x0000_0100)
    sub  s1, s0, s7             # 0x08: 417404B3 | s1 = &B[0] (0x0000_0900, cách A 2 KB)
    addi t0, x0, 0              # 0x0C: 00000293 | i = 0
    addi t1, x0, 8              # 0x10: 00800313 | N = 8
    addi t2, x0, 10             # 0x14: 00A00393 | val_a = 10
    addi t3, x0, 100            # 0x18: 06400E13 | val_b = 100

loop_init:
    slli t4, t0, 2              # 0x1C: 00229E93 | offset = i * 4
    add  t5, s0, t4             # 0x20: 01D40F33 | &A[i]
    sw   t2, 0(t5)              # 0x24: 007F2023 | A[i] = val_a
    add  t5, s1, t4             # 0x28: 01D48F33 | &B[i]
    sw   t3, 0(t5)              # 0x2C: 01CF2023 | B[i] = val_b
    addi t2, t2, 10             # 0x30: 00A38393 | val_a += 10
    addi t3, t3, 100            # 0x34: 064E0E13 | val_b += 100
    addi t0, t0, 1              # 0x38: 00128293 | i++
    blt  t0, t1, loop_init      # 0x3C: FE62C0E3 | if (i < 8) goto loop_init

    addi s3, x0, 0              # 0x40: 00000993 | sum = 0
    addi t0, x0, 0              # 0x44: 00000293 | i = 0

loop_add:
    slli t4, t0, 2              # 0x48: 00229E93 | offset = i * 4
    add  t5, s0, t4             # 0x4C: 01D40F33 | &A[i]
    lw   t2, 0(t5)              # 0x50: 000F2383 | a = A[i]
    add  t5, s1, t4             # 0x54: 01D48F33 | &B[i]
    lw   t3, 0(t5)              # 0x58: 000F2E03 | b = B[i]
    add  t2, t2, t3             # 0x5C: 01C383B3 | c = a + b
    sw   t2, 0(t5)              # 0x60: 007F2023 | B[i] = c
    add  s3, s3, t2             # 0x64: 007989B3 | sum += c
    addi t0, t0, 1              # 0x68: 00128293 | i++
    blt  t0, t1, loop_add       # 0x6C: FC62CEE3 | if (i < 8) goto loop_add

    # LRU Chiều 1: Trục xuất Way 0 (A) xuống RAM, nạp C vào Way 0
    sub  s2, s1, s7             # 0x70: 41748933 | s2 = &C[0] (0x0000_1100, cách B 2 KB)
    addi t0, x0, 0              # 0x74: 00000293 | i = 0
    addi t2, x0, 111            # 0x78: 06F00393 | val_c = 111

loop_evict_way0:
    slli t4, t0, 2              # 0x7C: 00229E93 | offset = i * 4
    add  t5, s2, t4             # 0x80: 01D90F33 | &C[i]
    sw   t2, 0(t5)              # 0x84: 007F2023 | C[i] = val_c
    addi t2, t2, 111            # 0x88: 06F38393 | val_c += 111
    addi t0, t0, 1              # 0x8C: 00128293 | i++
    blt  t0, t1, loop_evict_way0 # 0x90: FE62C6E3 | if (i < 8) goto loop_evict_way0

    # LRU Chiều 2: Trục xuất Way 1 (B[0..3]) ở Set 16 xuống RAM, nạp D[0..3] vào Way 1
    sub  s2, s2, s7             # 0x94: 41790933 | s2 = &D[0] (0x0000_1900, cách C 2 KB)
    addi t0, x0, 0              # 0x98: 00000293 | i = 0
    addi t1, x0, 4              # 0x9C: 00400313 | N = 4
    addi t2, x0, 1111           # 0xA0: 45700393 | val_d = 1111

loop_evict_way1:
    slli t4, t0, 2              # 0xA4: 00229E93 | offset = i * 4
    add  t5, s2, t4             # 0xA8: 01D90F33 | &D[i]
    sw   t2, 0(t5)              # 0xAC: 007F2023 | D[i] = val_d
    addi t2, t2, 1111           # 0xB0: 45738393 | val_d += 1111
    addi t0, t0, 1              # 0xB4: 00128293 | i++
    blt  t0, t1, loop_evict_way1 # 0xB8: FE62C6E3 | if (i < 4) goto loop_evict_way1

    # Kiểm tra ghi/đọc Byte & Halfword (SH, SB, LW)
    addi s4, x0, 0x200          # 0xBC: 20000A13 | s4 = 0x0000_0200
    sw   x0, 0(s4)              # 0xC0: 000A2023 | *(uint32_t*)0x200 = 0
    lui  t2, 0x1                # 0xC4: 000013B7 | t2 = 0x1000
    addi t2, t2, 0x234          # 0xC8: 23438393 | t2 = 0x1234
    sh   t2, 0(s4)              # 0xCC: 007A1023 | *(uint16_t*)0x200 = 0x1234
    addi t2, x0, 0xEF           # 0xD0: 0EF00393 | t2 = 0xEF
    sb   t2, 2(s4)              # 0xD4: 007A0123 | *(uint8_t*)0x202  = 0xEF
    addi t2, x0, 0xBE           # 0xD8: 0BE00393 | t2 = 0xBE
    sb   t2, 3(s4)              # 0xDC: 007A01A3 | *(uint8_t*)0x203  = 0xBE
    lw   s5, 0(s4)              # 0xE0: 000A2A83 | packed = *(uint32_t*)0x200

    # Xuất kết quả ra vùng RESULT (0x0000_0300) và kết thúc
    addi s6, x0, 0x300          # 0xE4: 30000B13 | s6 = 0x0000_0300 (ADDR_RESULT)
    sw   s3, 0(s6)              # 0xE8: 013B2023 | RESULT[0] = sum (3960 = 0xF78)
    sw   s5, 4(s6)              # 0xEC: 015B2223 | RESULT[1] = packed (0xBEEF1234)
    lui  t2, 0xCAFE0            # 0xF0: CAFE03B7 | t2 = 0xCAFE0000
    addi t2, t2, 1              # 0xF4: 00138393 | t2 = 0xCAFE0001
    sw   t2, 8(s6)              # 0xF8: 007B2423 | RESULT[2] = 0xCAFE0001
    ebreak                      # 0xFC: 00100073 | Kết thúc chương trình
