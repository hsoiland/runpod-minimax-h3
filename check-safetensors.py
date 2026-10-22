#!/usr/bin/env python3
"""Exit 0 when every given .safetensors file is complete, 1 otherwise.

A safetensors file is an 8-byte header length, a JSON header listing each
tensor's data_offsets, then the data — so a complete file is exactly
8 + header_len + max(end offset) bytes. Catches the truncated copies an
interrupted pod sync leaves on the volume without any network round trip.
Non-safetensors paths are reported OK (nothing to check).

    check-safetensors.py FILE...        # prints "BAD <path>: <why>" per bad file
"""
import json
import os
import struct
import sys


def problem(path):
    if not path.endswith(".safetensors"):
        return None
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            raw = f.read(8)
            if len(raw) < 8:
                return f"only {size} bytes"
            (n,) = struct.unpack("<Q", raw)
            if n > size - 8 or n > 100 << 20:
                return "header length past end of file"
            header = json.loads(f.read(n))
    except (OSError, ValueError) as e:
        return str(e)
    end = max((t["data_offsets"][1] for k, t in header.items() if k != "__metadata__"), default=0)
    if size != 8 + n + end:
        return f"{size} bytes, header expects {8 + n + end}"
    return None


bad = 0
for p in sys.argv[1:]:
    why = problem(p)
    if why:
        bad += 1
        print(f"BAD {p}: {why}", flush=True)
sys.exit(1 if bad else 0)
