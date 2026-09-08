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
_SUB: Final = 1
_UP: Final = 2
_PAETH: Final = 4
_FILTERS: Final = (_SUB, _UP, _PAETH)
_CHANNELS: Final = 4


def _chunks(data: bytes) -> list[tuple[bytes, bytes]]:
    out: list[tuple[bytes, bytes]] = []
    index = len(_HEADER)
    while index < len(data):
        length = struct.unpack(">I", data[index : index + 4])[0]
        out.append((data[index + 4 : index + 8], data[index + 8 : index + 8 + length]))
        index += 12 + length
    return out


def _base(kind: int, left: int, up: int, upleft: int) -> int:
    if kind == _SUB:
        return left
    if kind == _UP:
        return up
    estimate = left + up - upleft
    distances = (abs(estimate - left), abs(estimate - up), abs(estimate - upleft))
    return (left, up, upleft)[distances.index(min(distances))]


def _neighbours(line: bytes, previous: bytes, index: int) -> tuple[int, int, int]:
    behind = index >= _CHANNELS
    return (
        line[index - _CHANNELS] if behind else 0,
        previous[index],
        previous[index - _CHANNELS] if behind else 0,
    )


def _decode(raw: bytes, stride: int, height: int) -> list[bytes]:
    rows: list[bytes] = []
    previous = bytes(stride)
    offset = 0
    for _ in range(height):
        kind = raw[offset]
        line = bytearray(raw[offset + 1 : offset + 1 + stride])
        offset += 1 + stride
        for index in range(stride * bool(kind)):
            line[index] = (line[index] + _base(kind, *_neighbours(line, previous, index))) & 0xFF
        rows.append(bytes(line))
        previous = bytes(line)
    return rows


def _encode(rows: list[bytes], stride: int, kind: int) -> bytes:
    packed = bytearray()
    previous = bytes(stride)
    for row in rows:
        packed.append(kind)
        for index in range(stride):
            packed.append((row[index] - _base(kind, *_neighbours(row, previous, index))) & 0xFF)
        previous = row
    return zlib.compress(bytes(packed), 9)


def _rebuild(header: bytes, data: bytes) -> bytes:
    out = bytearray(_HEADER)
    for kind, payload in ((b"IHDR", header), (b"IDAT", data), (b"IEND", b"")):
        out += struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    return bytes(out)


def repack(path: pathlib.Path) -> int:
    """Rewrite one file when a different filter compresses it better.

    Args:
        path: The PNG to rewrite in place.

    Returns:
        The number of bytes saved, or zero when the file is already as small as this can make it.

    """
    data = path.read_bytes()
    if data[: len(_HEADER)] != _HEADER:
        return 0
    parts = _chunks(data)
    header = next(payload for kind, payload in parts if kind == b"IHDR")
    width, height, depth, colour, _, _, interlace = struct.unpack(">IIBBBBB", header)
    if (depth, colour, interlace) != (8, 6, 0):
        return 0
    stride = width * _CHANNELS
    raw = zlib.decompress(b"".join(payload for kind, payload in parts if kind == b"IDAT"))
    rows = _decode(raw, stride, height)
    best = min((_encode(rows, stride, kind) for kind in _FILTERS), key=len)
    out = _rebuild(header, best)
    if len(out) >= len(data):
        return 0
    path.write_bytes(out)
    return len(data) - len(out)


def main(paths: list[str]) -> int:
    """Repack every PNG under each path, reporting the total saved.

    Args:
        paths: Directories to walk.

    Returns:
        A process exit code.

    """
    saved = sum(repack(file) for root in paths for file in sorted(pathlib.Path(root).rglob("*.png")))
    sys.stderr.write(f"saved {saved / 1e6:.2f} MB\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
