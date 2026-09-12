#!/usr/bin/env python3
"""Patch Wine shell32's null filesystem-folder target crash on ARM64.

The bundled DLL comes from the pinned Wine submodule but is not rebuilt by the
iOS dependency job. Refuse to touch any unknown binary so an upstream change
cannot silently receive a patch at the wrong offset.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
import struct
import sys


ORIGINAL_SHA256 = "9f0f17a3c1fc81372a810e6ddb846a4929c78e3a58d51461f507cce3cc1f3dae"
PATCHED_SHA256 = "f6918048a1a6c08317583eae92f21b670d80430e0547e1594963c125da80347e"

# shell32!IShellFolder_fnParseDisplayName, RVA 0x63048:
#   ldrh w8, [x28]             -> ldr x9, [x22, #0x38]
#   cbz  w8, 0x63170           -> cbz x9, 0x633e0 (release bind data and fail)
#   ldr  x9, [x22, #0x38]      -> nop
#
# The function already rejected an empty display name at RVA 0x62fe8. The new
# check rejects an uninitialised IGenericSFImpl::sPathTarget before lstrcpynW
# dereferences it at RVA 0x6305c.
ORIGINAL_INSTRUCTIONS = bytes.fromhex("8803407928090034c91e40f9")
PATCHED_INSTRUCTIONS = bytes.fromhex("c91e40f9a91c00b41f2003d5")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} SHELL32_DLL")

    dll = Path(sys.argv[1])
    data = dll.read_bytes()
    digest = sha256(data)

    if digest == PATCHED_SHA256:
        print(f"shell32 null-target patch already present: {dll}")
        return
    if digest != ORIGINAL_SHA256:
        raise SystemExit(
            f"refusing to patch unknown shell32.dll: sha256={digest}, path={dll}"
        )
    if data[:2] != b"MZ":
        raise SystemExit(f"not a PE image: {dll}")

    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise SystemExit(f"invalid PE signature: {dll}")
    machine = struct.unpack_from("<H", data, pe_offset + 4)[0]
    if machine != 0xAA64:
        raise SystemExit(f"expected ARM64 PE machine 0xaa64, got {machine:#x}: {dll}")

    if data.count(ORIGINAL_INSTRUCTIONS) != 1:
        raise SystemExit("expected a unique shell32 ParseDisplayName instruction sequence")

    patched = data.replace(ORIGINAL_INSTRUCTIONS, PATCHED_INSTRUCTIONS, 1)
    patched_digest = sha256(patched)
    if patched_digest != PATCHED_SHA256:
        raise SystemExit(f"patched shell32 checksum mismatch: {patched_digest}")

    dll.write_bytes(patched)
    print(f"patched shell32 null-target crash: sha256={patched_digest}")


if __name__ == "__main__":
    main()
