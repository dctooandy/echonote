#!/usr/bin/env python3
"""Checks that a built echo_core library exports exactly abi/exports.txt.

Usage: check_exports.py <library file or directory to search>

macOS uses `nm -gU`, Linux `nm -D --defined-only`; on Windows the DLL's PE
export table is read directly, so no Visual Studio tools are needed.
"""
import pathlib
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
NAMES = ("libecho_core.dylib", "libecho_core.so", "echo_core.dll")


def find_library(arg: str) -> pathlib.Path:
    path = pathlib.Path(arg)
    if path.is_file():
        return path
    for name in NAMES:
        found = sorted(path.rglob(name))
        if found:
            return found[0]
    sys.exit(f"no echo_core library under {path}")


def pe_exports(path: pathlib.Path) -> set[str]:
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        sys.exit(f"{path} is not a PE file")
    sections, opt_size = struct.unpack_from("<H12xH", data, pe + 6)
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    dirs = opt + (112 if magic == 0x20B else 96)  # PE32+ / PE32
    export_rva = struct.unpack_from("<I", data, dirs)[0]
    table = opt + opt_size

    def offset(rva: int) -> int:
        for i in range(sections):
            vsize, vaddr, _, raw = struct.unpack_from("<4I", data, table + i * 40 + 8)
            if vaddr <= rva < vaddr + max(vsize, 1):
                return rva - vaddr + raw
        sys.exit(f"RVA {rva:#x} is in no section")

    if export_rva == 0:
        return set()
    base = offset(export_rva)
    count, names_rva = struct.unpack_from("<I4xI", data, base + 24)
    names = offset(names_rva)
    result = set()
    for i in range(count):
        start = offset(struct.unpack_from("<I", data, names + 4 * i)[0])
        result.add(data[start:data.index(b"\0", start)].decode())
    return result


def exports(path: pathlib.Path) -> set[str]:
    if path.suffix == ".dll":
        return pe_exports(path)
    if path.suffix == ".dylib":
        out = subprocess.run(["nm", "-gU", str(path)], check=True,
                             capture_output=True, text=True).stdout
        return {line.split()[-1].removeprefix("_") for line in out.splitlines() if line.strip()}
    out = subprocess.run(["nm", "-D", "--defined-only", str(path)], check=True,
                         capture_output=True, text=True).stdout
    return {line.split()[-1] for line in out.splitlines()
            if len(line.split()) == 3 and line.split()[1] in "TW"}


def main() -> None:
    library = find_library(sys.argv[1] if len(sys.argv) > 1 else str(ROOT / "build" / "native"))
    expected = {line.strip() for line in (ROOT / "abi" / "exports.txt").read_text().splitlines()
                if line.strip() and not line.startswith("#")}
    actual = exports(library)
    missing, extra = sorted(expected - actual), sorted(actual - expected)
    if missing or extra:
        print(f"{library}: exports differ from abi/exports.txt")
        for name in missing:
            print(f"  missing: {name}")
        for name in extra:
            print(f"  extra:   {name}")
        sys.exit(1)
    print(f"{library}: exports match abi/exports.txt ({len(actual)} symbols)")


if __name__ == "__main__":
    main()
