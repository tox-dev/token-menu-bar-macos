#!/usr/bin/env python3
"""Re-encode PNG files with a filter the image actually suits.

macOS wants every icon size in the asset catalog, and the encoder AppKit uses leaves roughly half the bytes on the
table for a smooth gradient. This picks the filter that compresses best and re-deflates at maximum effort.
"""

from __future__ import annotations

import pathlib
import struct
import sys
import zlib
from typing import Final

_HEADER: Final = b"\x89PNG\r\n\x1a\n"
_FILTERS: Final = (1, 2, 4)


def _chunks(data: bytes) -> list[tuple[bytes, bytes]]:
    out: list[tuple[bytes, bytes]] = []
    index = len(_HEADER)
    while index < len(data):
        length = struct.unpack(">I", data[index : index + 4])[0]
        out.append((data[index + 4 : index + 8], data[index + 8 : index + 8 + length]))
        index += 12 + length
    return out


def _predict(kind: int, value: int, left: int, up: int, upleft: int, encode: bool) -> int:
    if kind == 1:
        base = left
    elif kind == 2:
        base = up
    else:
        estimate = left + up - upleft
        distances = (abs(estimate - left), abs(estimate - up), abs(estimate - upleft))
        base = (left, up, upleft)[distances.index(min(distances))]
    return (value - base if encode else value + base) & 0xFF


def _rows(raw: bytes, stride: int, height: int) -> list[bytes]:
    rows: list[bytes] = []
    previous = bytes(stride)
    offset = 0
    for _ in range(height):
        kind = raw[offset]
        line = bytearray(raw[offset + 1 : offset + 1 + stride])
        offset += 1 + stride
        if kind:
            for i in range(stride):
                line[i] = _predict(
                    kind, line[i], line[i - 4] if i >= 4 else 0, previous[i], previous[i - 4] if i >= 4 else 0, False
                )
        rows.append(bytes(line))
        previous = bytes(line)
    return rows


def repack(path: pathlib.Path) -> int:
    data = path.read_bytes()
    if data[: len(_HEADER)] != _HEADER:
        return 0
    parts = _chunks(data)
    header = next(payload for kind, payload in parts if kind == b"IHDR")
    width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", header)
    if (depth, colour, interlace) != (8, 6, 0):
        return 0
    stride = width * 4
    rows = _rows(zlib.decompress(b"".join(payload for kind, payload in parts if kind == b"IDAT")), stride, height)
    best: bytes | None = None
    for kind in _FILTERS:
        packed = bytearray()
        previous = bytes(stride)
        for row in rows:
            packed.append(kind)
            for i in range(stride):
                packed.append(
                    _predict(kind, row[i], row[i - 4] if i >= 4 else 0, previous[i], previous[i - 4] if i >= 4 else 0, True)
                )
            previous = row
        candidate = zlib.compress(bytes(packed), 9)
        if best is None or len(candidate) < len(best):
            best = candidate
    out = bytearray(_HEADER)
    for kind, payload in ((b"IHDR", header), (b"IDAT", best or b""), (b"IEND", b"")):
        out += struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    saved = len(data) - len(out)
    if saved > 0:
        path.write_bytes(bytes(out))
    return max(saved, 0)


def main(paths: list[str]) -> int:
    saved = sum(repack(file) for root in paths for file in sorted(pathlib.Path(root).rglob("*.png")))
    print(f"saved {saved / 1e6:.2f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
