/* =============================================================================
 * sw/link.ld
 * Linker Script cho Lõi RISC-V RV32I Bare-Metal (ĐA2)
 *   - Bộ nhớ lệnh (IMEM): bắt đầu tại 0x0000_0000 (1 KB = 256 words)
 *   - Bộ nhớ dữ liệu (DMEM / D-Cache): 0x0000_0100 .. 0x0000_BFFF
 * ============================================================================= */
OUTPUT_ARCH("riscv")
ENTRY(_start)

SECTIONS
{
    . = 0x00000000;

    .text : ALIGN(4) {
        KEEP(*(.text.init))
        *(.text*)
        *(.rodata*)
    }

    .data : ALIGN(4) {
        *(.data*)
        *(.sdata*)
    }

    .bss : ALIGN(4) {
        *(.bss*)
        *(.sbss*)
        *(COMMON)
    }

    /DISCARD/ : {
        *(.comment)
        *(.note*)
        *(.eh_frame*)
        *(.riscv.attributes)
    }
}
