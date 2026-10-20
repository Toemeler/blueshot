#!/usr/bin/env python3
"""Fetch the iPad's screen from the BlueShot broadcast over Bluetooth LE.

    pip install bleak
    python blueshot.py shot.jpg                 # one screenshot
    python blueshot.py shot.jpg --watch 2       # refresh every 2 s while the screen changes

The broadcast must be running on the iPad (BlueShot app -> Start Broadcast).
"""
import argparse
import asyncio
import struct
import sys
import time

from bleak import BleakClient, BleakScanner

SERVICE = "b5c0a1e0-6f1d-4e7a-9c3b-2d4f5a6b7c80"
CONTROL = "b5c0a1e0-6f1d-4e7a-9c3b-2d4f5a6b7c81"
DATA = "b5c0a1e0-6f1d-4e7a-9c3b-2d4f5a6b7c82"
HEADER = struct.Struct("<BBIIHH")  # magic, version, seq, length, width, height


class Receiver:
    def __init__(self):
        self.buf = bytearray()
        self.header = None
        self.done = asyncio.Event()

    def on_data(self, _char, data: bytearray):
        if self.header is None:
            if len(data) != HEADER.size or data[0] != 0xB5:
                return  # tail of an older frame
            self.header = HEADER.unpack(data)
        else:
            self.buf += data
        if self.header and len(self.buf) >= self.header[3]:
            self.done.set()

    def reset(self):
        self.buf.clear()
        self.header = None
        self.done.clear()


async def find(timeout):
    dev = await BleakScanner.find_device_by_filter(
        lambda d, ad: SERVICE in [u.lower() for u in ad.service_uuids] or d.name == "BlueShot",
        timeout=timeout)
    if dev is None:
        raise RuntimeError("BlueShot not found: is the broadcast running on the iPad?")
    return dev


async def fetch(width=1024, quality=50, scan=10, timeout=30):
    """One screenshot: (jpeg bytes, width, height). For other scripts (the iPad skill)."""
    dev = await find(scan)
    async with BleakClient(dev) as client:
        rx = Receiver()
        await client.start_notify(DATA, rx.on_data)
        await client.write_gatt_char(CONTROL, struct.pack("<BHBI", 1, width, quality, 0), response=True)
        await asyncio.wait_for(rx.done.wait(), timeout)
        _, _, _, length, w, h = rx.header
        if not length:
            raise RuntimeError("the broadcast has no frame yet")
        return bytes(rx.buf[:length]), w, h


async def run(args):
    dev = await find(args.scan)
    async with BleakClient(dev) as client:
        rx = Receiver()
        await client.start_notify(DATA, rx.on_data)
        seq = 0
        while True:
            rx.reset()
            t0 = time.perf_counter()
            await client.write_gatt_char(
                CONTROL, struct.pack("<BHBI", 1, args.width, args.quality, seq), response=True)
            await asyncio.wait_for(rx.done.wait(), args.timeout)
            _, _, new_seq, length, w, h = rx.header
            dt = time.perf_counter() - t0
            if length:
                with open(args.out, "wb") as fh:
                    fh.write(rx.buf[:length])
                seq = new_seq
                print(f"{args.out}: {w}x{h}, {length // 1024} KB in {dt:.1f} s "
                      f"({length / 1024 / dt:.0f} KB/s)", flush=True)
            elif not args.watch:
                print("unchanged (no frame yet?)")
            if not args.watch:
                return
            await asyncio.sleep(args.watch)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("out", nargs="?", default="blueshot.jpg")
    p.add_argument("--width", type=int, default=1024, help="max width in px (default 1024)")
    p.add_argument("--quality", type=int, default=50, help="JPEG quality 1-100 (default 50)")
    p.add_argument("--watch", type=float, default=0, help="keep fetching every N seconds")
    p.add_argument("--scan", type=float, default=10, help="scan timeout in s")
    p.add_argument("--timeout", type=float, default=30, help="per-frame timeout in s")
    asyncio.run(run(p.parse_args()))


if __name__ == "__main__":
    main()
