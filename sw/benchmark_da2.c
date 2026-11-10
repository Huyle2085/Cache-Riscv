/* =============================================================================
 * sw/benchmark_da2.c
 * Chương trình C kiểm chứng tích hợp Lõi RISC-V (RV32I) + D-Cache 2-Way (ĐA2).
 *
 * Kịch bản kiểm thử toàn diện:
 *   1. Khởi tạo 2 mảng A[8] (0x0000_0100) và B[8] (0x0000_0900).
 *      Hai mảng cách nhau 2 KB (0x800) nên ánh xạ vào CÙNG Set 16..17 trên cả
 *      Cache 64-set (DM-1K, 2W-2K) lẫn Cache 128-set (DM-2K cùng dung lượng 2 KB).
 *      Nhờ cấu trúc 2-Way Set-Associative, A nằm ở Way 0 và B nằm ở Way 1
 *      mà không xảy ra xung đột (Conflict Miss).
 *   2. Cộng hai mảng B[i] = A[i] + B[i] và tính tổng sum += B[i].
 *      Toàn bộ 24 lần truy cập bộ nhớ trong vòng lặp này đạt 100% Cache Hit
 *      trên Cache 2-Way (trong khi Direct-Mapped 1KB và 2KB bị Conflict Miss liên tục).
 *      Kết thúc vòng lặp, B (Way 1) là MRU và A (Way 0) là LRU (lru_bit = 0).
 *   3. Kiểm chứng LRU Chiều 1 (Trục xuất Way 0):
 *      Ghi mảng C[8] tại 0x0000_1100 (cùng Set 16..17).
 *      Cache chọn A (Way 0 - LRU) làm Victim, đẩy A xuống RAM qua Write Buffer,
 *      nạp C vào Way 0 và giữ nguyên B ở Way 1. Lúc này C (Way 0) thành MRU
 *      và B (Way 1) thành LRU (lru_bit = 1).
 *   4. Kiểm chứng LRU Chiều 2 (Trục xuất Way 1):
 *      Ghi mảng D[4] tại 0x0000_1900 (cùng Set 16).
 *      Vì tại Set 16 đang có B (Way 1) là LRU (lru_bit = 1), Cache chọn Way 1
 *      làm Victim, đẩy B[0..3] xuống RAM qua Write Buffer, nạp D[0..3] vào Way 1
 *      và giữ nguyên C[0..3] ở Way 0!
 *   5. Kiểm tra các lệnh truy cập mức Byte/Halfword (SH, SB, LW) tại 0x0000_0200.
 *   6. Ghi kết quả kiểm chứng vào vùng Result (0x0000_0300) và kết thúc (ebreak).
 * ============================================================================= */

#include <stdint.h>

#define ADDR_ARRAY_A    ((volatile int32_t  *)0x00000100)
#define ADDR_ARRAY_B    ((volatile int32_t  *)0x00000900)
#define ADDR_ARRAY_C    ((volatile int32_t  *)0x00001100)
#define ADDR_ARRAY_D    ((volatile int32_t  *)0x00001900)
#define ADDR_BYTE_TEST  ((volatile uint32_t *)0x00000200)
#define ADDR_RESULT     ((volatile uint32_t *)0x00000300)

int main(void) {
    volatile int32_t *A = ADDR_ARRAY_A;
    volatile int32_t *B = ADDR_ARRAY_B;
    volatile int32_t *C = ADDR_ARRAY_C;
    volatile int32_t *D = ADDR_ARRAY_D;

    /* 1. Khởi tạo mảng A (Way 0) và B (Way 1) tại Set 16..17 */
    int32_t val_a = 10;
    int32_t val_b = 100;
    for (int i = 0; i < 8; i++) {
        A[i] = val_a;
        B[i] = val_b;
        val_a += 10;
        val_b += 100;
    }

    /* 2. Tính B[i] = A[i] + B[i] và tổng sum (100% Hit trên 2-Way; Way 0 thành LRU) */
    int32_t sum = 0;
    for (int i = 0; i < 8; i++) {
        int32_t c = A[i] + B[i];
        B[i] = c;
        sum += c; /* Kỳ vọng: 110 + 220 + ... + 880 = 3960 (0x00000F78) */
    }

    /* 3. LRU Eviction Chiều 1 (lru_bit=0 -> Trục xuất Way 0 chứa A xuống RAM, nạp C vào Way 0) */
    int32_t val_c = 111;
    for (int i = 0; i < 8; i++) {
        C[i] = val_c;
        val_c += 111;
    }

    /* 4. LRU Eviction Chiều 2 (lru_bit=1 -> Trục xuất Way 1 chứa B[0..3] xuống RAM, nạp D vào Way 1) */
    int32_t val_d = 1111;
    for (int i = 0; i < 4; i++) {
        D[i] = val_d;
        val_d += 1111;
    }

    /* 5. Kiểm tra ghi/đọc Byte và Halfword (SH, SB, LW với cpu_wstrb) */
    ADDR_BYTE_TEST[0] = 0;
    *((volatile uint16_t *)0x00000200) = 0x1234;
    *((volatile uint8_t  *)0x00000202) = 0xEF;
    *((volatile uint8_t  *)0x00000203) = 0xBE;
    uint32_t packed = ADDR_BYTE_TEST[0]; /* Kỳ vọng: 0xBEEF1234 */

    /* 6. Xuất kết quả ra bộ nhớ để Testbench đối chiếu */
    ADDR_RESULT[0] = (uint32_t)sum;    /* 0x00000300: 0x00000F78 (3960) */
    ADDR_RESULT[1] = packed;           /* 0x00000304: 0xBEEF1234        */
    ADDR_RESULT[2] = 0xCAFE0001u;      /* 0x00000308: Cờ báo hoàn tất   */

    return 0;
}
