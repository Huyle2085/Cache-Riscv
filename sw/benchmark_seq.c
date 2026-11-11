/* =============================================================================
 * sw/benchmark_seq.c
 * Benchmark 2: Workload Tuần tự & Ít xung đột (Sequential / Low-Conflict)
 * kiểm chứng tính khách quan của D-Cache 2-Way (ĐA2) so với Direct-Mapped (ĐA1).
 *
 * Đặc điểm Workload:
 *   - Khác với benchmark_da2.c (cố ý đặt các mảng cách nhau bội số 2 KB để
 *     gây xung đột trực diện trên cùng Set 16..17), chương trình này cấp phát
 *     3 mảng liên tiếp trong bộ nhớ:
 *       + X[16] tại 0x0000_0400 .. 0x0000_043C (Set 16..19, 4 dòng cache)
 *       + Y[16] tại 0x0000_0440 .. 0x0000_047C (Set 20..23, 4 dòng cache)
 *       + Z[16] tại 0x0000_0480 .. 0x0000_04BC (Set 24..27, 4 dòng cache)
 *   - Các mảng ánh xạ vào các Set hoàn toàn tách biệt (Set 16..27), không xảy ra
 *     Conflict Miss trên cả Direct-Mapped (DM-1K, DM-2K) lẫn 2-Way (2W-2K).
 *   - Đánh giá độ lợi cục bộ không gian (Spatial Locality: 4 words/line -> 1 lần
 *     Cold Miss phục vụ 3 lần Hit liên tiếp) và cục bộ thời gian (Temporal Locality:
 *     tái sử dụng X[i], Y[i], Z[i] trong bộ lọc đạt 100% Hit).
 * ============================================================================= */

#include <stdint.h>

#define ADDR_SEQ_X      ((volatile int32_t  *)0x00000400)
#define ADDR_SEQ_Y      ((volatile int32_t  *)0x00000440)
#define ADDR_SEQ_Z      ((volatile int32_t  *)0x00000480)
#define ADDR_RESULT     ((volatile uint32_t *)0x00000300)

int main(void) {
    volatile int32_t *X = ADDR_SEQ_X;
    volatile int32_t *Y = ADDR_SEQ_Y;
    volatile int32_t *Z = ADDR_SEQ_Z;

    /* 1. Khởi tạo tuần tự X[0..15] và Y[0..15] (Spatial Locality: 4 words/line) */
    int32_t vx = 1;
    int32_t vy = 10;
    for (int i = 0; i < 16; i++) {
        X[i] = vx;
        Y[i] = vy;
        vx += 1;
        vy += 10;
    }

    /* 2. Tính tuần tự Z[i] = X[i] + Y[i] và tích lũy sum_z
     *    - Đọc X[i], Y[i]: 100% Cache Hit (nhờ Temporal Locality)
     *    - Ghi Z[i]      : 4 Cold Misses + 12 Hits (nhờ Spatial Locality) */
    int32_t sum_z = 0;
    for (int i = 0; i < 16; i++) {
        int32_t z = X[i] + Y[i];
        Z[i] = z;
        sum_z += z; /* Kỳ vọng: 11 * (16 * 17 / 2) = 1496 (0x000005D8) */
    }

    /* 3. Quét lại Z[i] và X[i] để kiểm chứng Temporal Reuse (100% Cache Hit) */
    int32_t filter_acc = 0;
    for (int i = 0; i < 16; i++) {
        filter_acc += (Z[i] - X[i]); /* Kỳ vọng: sum(Y[i]) = 1360 (0x00000550) */
    }

    /* 4. Ghi kết quả kiểm chứng ra ADDR_RESULT (0x0000_0300) */
    ADDR_RESULT[0] = (uint32_t)sum_z;      /* 0x00000300: 0x000005D8 (1496) */
    ADDR_RESULT[1] = (uint32_t)filter_acc; /* 0x00000304: 0x00000550 (1360) */
    ADDR_RESULT[2] = 0xCAFE0002u;          /* 0x00000308: Cờ hoàn tất Seq   */

    return sum_z;
}
