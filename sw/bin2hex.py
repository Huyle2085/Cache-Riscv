#!/usr/bin/env python3
"""
sw/bin2hex.py
Chuyển đổi file nhị phân phẳng (.bin) xuất từ riscv64-unknown-elf-objcopy
thành file mã máy 32-bit (.hex, mỗi dòng 1 word 8 ký tự hex Little-Endian)
để nạp vào bộ nhớ lệnh IMEM ($readmemh) của Lõi RISC-V RV32I.
"""
import sys
import struct

def bin_to_hex(bin_path: str, hex_path: str) -> int:
    with open(bin_path, "rb") as f:
        data = f.read()

    # Căn chỉnh độ dài theo bội số của 4 bytes (32-bit word) bằng lệnh NOP (0x00000013)
    rem = len(data) % 4
    if rem != 0:
        data += b"\x00" * (4 - rem)

    num_words = len(data) // 4
    with open(hex_path, "w", newline="\n") as out:
        for i in range(num_words):
            (word,) = struct.unpack_from("<I", data, i * 4)
            out.write(f"{word:08X}\n")

    return num_words

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 bin2hex.py <input.bin> <output.hex>")
        sys.exit(1)
    words = bin_to_hex(sys.argv[1], sys.argv[2])
    print(f"[HEX] Generated {sys.argv[2]} ({words} 32-bit RV32I words)")
