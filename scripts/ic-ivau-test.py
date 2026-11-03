#!/usr/bin/env python3
"""Check that IC IVAU drops QEMU's translations of code another process wrote.

Regression test for patches/0001. Guest RAM is a shared file that this script
maps too. A bare-metal guest calls a routine that returns 1; the script then
rewrites the routine to return 2, as a vhost-user back-end writes guest RAM,
and the guest calls it again after DC CVAU, DSB, IC IVAU, DSB, ISB. QEMU
never sees the script's write, so only IC IVAU can drop the stale
translation: without patches/0001 the second call still returns 1.

Usage: ic-ivau-test.py QEMU_BINARY
"""

import mmap
import os
import struct
import subprocess
import sys
import tempfile
import time

RAM_BASE = 0x40000000  # the virt machine's RAM
RAM_SIZE = 64 << 20
# Above the device tree QEMU puts at the start of RAM. Each part has its own
# page: the guest writes DATA, and a guest write to the routine's page would
# drop its translations on its own.
CODE = 0x40200000
ROUTINE = CODE + 0x1000
DATA = CODE + 0x2000  # +0 stage, +8 rewritten, +16 first result, +24 second
TIMEOUT = 30

MAIN = [
    0xD2A80401,  # movz x1, #0x4020, lsl #16    x1 = CODE
    0x91400823,  # add  x3, x1, #0x2000         x3 = DATA
    0x91400421,  # add  x1, x1, #0x1000         x1 = ROUTINE
    0xD63F0020,  # blr  x1
    0xB9001060,  # str  w0, [x3, #16]
    0x52800022,  # mov  w2, #1
    0xB9000062,  # str  w2, [x3]                stage 1
    0xB9400862,  # 1: ldr w2, [x3, #8]
    0x34FFFFE2,  # cbz  w2, 1b                  until the routine is rewritten
    0xD50B7B21,  # dc   cvau, x1
    0xD5033B9F,  # dsb  ish
    0xD50B7521,  # ic   ivau, x1
    0xD5033B9F,  # dsb  ish
    0xD5033FDF,  # isb
    0xD63F0020,  # blr  x1
    0xB9001860,  # str  w0, [x3, #24]
    0x52800042,  # mov  w2, #2
    0xB9000062,  # str  w2, [x3]                stage 2
    0xD503207F,  # 2: wfi
    0x17FFFFFF,  # b    2b
]
RETURN_1 = [0x52800020, 0xD65F03C0]  # mov w0, #1; ret
RETURN_2 = [0x52800040, 0xD65F03C0]  # mov w0, #2; ret


def words(values):
    return struct.pack(f"<{len(values)}I", *values)


def elf():
    """An AArch64 ELF executable with one segment: CODE, ROUTINE and DATA."""
    image = bytearray(0x3000)
    image[: 4 * len(MAIN)] = words(MAIN)
    image[0x1000 : 0x1000 + 4 * len(RETURN_1)] = words(RETURN_1)
    offset = 0x1000
    header = struct.pack(
        "<4sBBBBB7sHHIQQQIHHHHHH",
        b"\x7fELF", 2, 1, 1, 0, 0, bytes(7),  # ELFCLASS64, little endian
        2, 183, 1, CODE,  # ET_EXEC, EM_AARCH64, EV_CURRENT, entry
        64, 0, 0, 64, 56, 1, 64, 0, 0,  # one program header, no sections
    )
    segment = struct.pack(
        "<IIQQQQQQ",
        1, 7, offset, CODE, CODE, len(image), len(image), 0x1000,  # PT_LOAD, RWX
    )
    return (header + segment).ljust(offset, b"\0") + image


def main():
    qemu = sys.argv[1]
    with tempfile.TemporaryDirectory() as tmp:
        kernel = os.path.join(tmp, "ic-ivau.elf")
        with open(kernel, "wb") as f:
            f.write(elf())
        ram = os.path.join(tmp, "ram")
        with open(ram, "wb") as f:
            f.truncate(RAM_SIZE)
        with open(ram, "r+b") as f:
            mem = mmap.mmap(f.fileno(), RAM_SIZE)

        def word(addr):
            return struct.unpack_from("<I", mem, addr - RAM_BASE)[0]

        cmd = [
            qemu,
            "-M", "virt,memory-backend=ram", "-accel", "tcg", "-cpu", "max",
            "-smp", "1", "-m", "64M",
            "-object", f"memory-backend-file,id=ram,size=64M,mem-path={ram},share=on",
            "-nodefaults", "-display", "none",
            "-kernel", kernel,
        ]
        print("+", " ".join(cmd), flush=True)
        proc = subprocess.Popen(cmd)
        try:
            def wait_stage(stage):
                deadline = time.monotonic() + TIMEOUT
                while word(DATA) != stage:
                    if proc.poll() is not None:
                        sys.exit(f"FAIL QEMU exited with status {proc.returncode}")
                    if time.monotonic() > deadline:
                        sys.exit(f"FAIL guest did not reach stage {stage} within {TIMEOUT}s")
                    time.sleep(0.01)

            wait_stage(1)
            first = word(DATA + 16)
            mem[ROUTINE - RAM_BASE : ROUTINE - RAM_BASE + 4 * len(RETURN_2)] = words(RETURN_2)
            # Python has no store barrier; give the code time to land before
            # the flag the guest polls.
            time.sleep(0.1)
            struct.pack_into("<I", mem, DATA + 8 - RAM_BASE, 1)
            wait_stage(2)
            second = word(DATA + 24)
        finally:
            proc.kill()
            proc.wait()
            mem.close()

    print(f"routine returned {first} before the rewrite, {second} after IC IVAU")
    if (first, second) != (1, 2):
        print("FAIL code rewritten by another process ran stale after IC IVAU (patches/0001)")
        sys.exit(1)
    print("ok   IC IVAU drops translations of code another process wrote")


if __name__ == "__main__":
    main()
