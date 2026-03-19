#!/usr/bin/env python3
"""Convert a raw binary to a NEORV32 VHDL IMEM image package."""
import sys
import struct
import math

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <input.bin> <output.vhd>")
        sys.exit(1)

    with open(sys.argv[1], "rb") as f:
        data = f.read()

    if len(data) == 0:
        print("[ERROR] Input binary is empty!")
        sys.exit(1)

    while len(data) % 4 != 0:
        data += b"\x00"

    raw_size = len(data)
    n_words = raw_size // 4

    ext_size = 1
    while ext_size < n_words:
        ext_size *= 2

    with open(sys.argv[2], "w") as f:
        f.write("-- Auto-generated NEORV32 IMEM image from raw binary\n")
        f.write("library ieee;\nuse ieee.std_logic_1164.all;\n\n")
        f.write("package neorv32_imem_image is\n\n")
        f.write(f"type rom_t is array (0 to {ext_size - 1}) of std_ulogic_vector(31 downto 0);\n")
        f.write(f"constant image_size_c : natural := {raw_size};\n")
        f.write("constant image_data_c : rom_t := (\n")

        for i in range(ext_size):
            if i < n_words:
                word = struct.unpack_from("<I", data, i * 4)[0]
            else:
                word = 0
            comma = "," if i < ext_size - 1 else ""
            f.write(f'x"{word:08x}"{comma}\n')

        f.write(");\n\nend neorv32_imem_image;\n")

    print(f"VHDL image: {raw_size} bytes ({n_words} words, padded to {ext_size})")

if __name__ == "__main__":
    main()
