#!/usr/bin/env python3
"""Boot an ArcBox arm64 kernel with -kernel under the packaged QEMU.

Uses the device set the ArcBox daemon uses: guest RAM in memory-backend-shm,
virtio-blk-pci, a virtio-net-pci NIC on a SOCK_DGRAM socketpair passed by fd,
virtio-serial-pci + virtconsole, virtio-rng-pci and QMP. With no root
filesystem the kernel panics once it has probed its devices; panic=-1 plus
-no-reboot makes QEMU exit, so the test ends on its own.

Usage: boot-test.py QEMU_BINARY KERNEL
"""

import json
import os
import socket
import subprocess
import sys
import tempfile
import time

TIMEOUT = 180


def qmp(path, *commands):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for _ in range(100):
        try:
            sock.connect(path)
            break
        except OSError:
            time.sleep(0.1)
    stream = sock.makefile("rw")

    def read():
        while True:
            msg = json.loads(stream.readline())
            if "event" not in msg:
                return msg

    greeting = read()
    replies = []
    for cmd in ("qmp_capabilities",) + commands:
        stream.write(json.dumps({"execute": cmd}) + "\n")
        stream.flush()
        replies.append(read())
    sock.close()
    return greeting, replies[1:]


def main():
    qemu, kernel = sys.argv[1:3]
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        disk = os.path.join(tmp, "disk.img")
        with open(disk, "wb") as f:
            f.truncate(64 << 20)
        serial = os.path.join(tmp, "serial.log")
        hvc0 = os.path.join(tmp, "hvc0.log")
        qmp_sock = os.path.join(tmp, "qmp.sock")
        host_end, guest_end = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)

        cmd = [
            qemu,
            "-M", "virt,memory-backend=ram", "-accel", "tcg", "-cpu", "max",
            "-smp", "2", "-m", "512M",
            "-object", "memory-backend-shm,id=ram,size=512M,share=on",
            "-nodefaults", "-display", "none", "-no-reboot",
            "-kernel", kernel,
            "-append", "console=ttyAMA0 console=hvc0 earlycon panic=-1",
            "-serial", f"file:{serial}",
            "-device", "virtio-serial-pci,addr=0x3",
            "-chardev", f"file,id=hvc0,path={hvc0}",
            "-device", "virtconsole,chardev=hvc0",
            "-device", "virtio-rng-pci,addr=0x4",
            "-drive", f"file={disk},format=raw,if=none,id=vda,discard=unmap",
            "-device", "virtio-blk-pci,drive=vda,addr=0x5",
            "-netdev", f"dgram,id=net0,local.type=fd,local.str={guest_end.fileno()}",
            # romfile= : the package ships no firmware, and the default
            # efi-virtio.rom option ROM is only used by UEFI network boot.
            "-device", "virtio-net-pci,netdev=net0,mac=02:ab:cd:00:00:02,addr=0x6,romfile=",
            "-qmp", f"unix:{qmp_sock},server=on,wait=off",
        ]
        print("+", " ".join(cmd), flush=True)
        start = time.monotonic()
        proc = subprocess.Popen(cmd, pass_fds=[guest_end.fileno()])
        guest_end.close()

        try:
            greeting, (status,) = qmp(qmp_sock, "query-status")
            print("QMP:", greeting["QMP"]["version"]["qemu"], status, flush=True)
            if status.get("return", {}).get("status") != "running":
                failures.append(f"QMP query-status: {status}")
        except (OSError, ValueError) as e:
            failures.append(f"QMP: {e}")

        try:
            rc = proc.wait(TIMEOUT)
        except subprocess.TimeoutExpired:
            proc.kill()
            rc = proc.wait()
            failures.append(f"QEMU did not exit within {TIMEOUT}s")
        elapsed = time.monotonic() - start
        host_end.close()

        log = open(serial, errors="replace").read()
        console = open(hvc0, errors="replace").read()
        print(f"--- serial (ttyAMA0), {len(log.splitlines())} lines, QEMU exit {rc} after {elapsed:.1f}s")
        lines = log.splitlines()
        print("\n".join(lines[:3] + ["..."] + [l for l in lines if "virtio" in l] + ["..."] + lines[-4:]))
        print(f"--- hvc0 (virtconsole), {len(console.splitlines())} lines")

        expect = {
            "kernel banner on ttyAMA0": "Linux version" in log,
            "virtio-blk probed (vda)": "[vda]" in log,
            "guest enabled all four virtio-pci devices": all(
                f"virtio-pci 0000:00:0{slot}.0: enabling device" in log for slot in "3456"
            ),
            "kernel console on hvc0": "Kernel panic" in console or "VFS:" in console,
            "kernel reached root mount": "VFS: Unable to mount root" in log or "Kernel panic" in log,
        }
        for name, ok in expect.items():
            print(f"{'ok  ' if ok else 'FAIL'} {name}")
            if not ok:
                failures.append(name)
        if rc != 0:
            failures.append(f"QEMU exit status {rc}")

    if failures:
        print("boot test failed:", "; ".join(failures), file=sys.stderr)
        sys.exit(1)
    print("boot test passed")


if __name__ == "__main__":
    main()
