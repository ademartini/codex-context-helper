#!/usr/bin/env python3
"""Remove PNG text/EXIF metadata without changing pixel or color-profile chunks."""
from pathlib import Path
import sys


def strip_metadata(data):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Expected a PNG file")
    result = bytearray(data[:8])
    offset = 8
    while offset + 12 <= len(data):
        size = int.from_bytes(data[offset:offset + 4], "big")
        end = offset + size + 12
        if end > len(data):
            raise ValueError("Truncated PNG chunk")
        kind = data[offset + 4:offset + 8]
        if kind not in {b"tEXt", b"zTXt", b"iTXt", b"eXIf"}:
            result.extend(data[offset:end])
        offset = end
    if offset != len(data):
        raise ValueError("Unexpected trailing PNG data")
    return bytes(result)


if __name__ == "__main__":
    for filename in sys.argv[1:]:
        path = Path(filename)
        path.write_bytes(strip_metadata(path.read_bytes()))
