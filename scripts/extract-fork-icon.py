#!/usr/bin/env python3
"""Copy the largest PNG icon embedded in Fork.exe."""
import struct
import sys
from pathlib import Path


def rva_to_offset(sections, rva):
    for virtual_address, virtual_size, raw, raw_size in sections:
        span = max(virtual_size, raw_size)
        if virtual_address <= rva < virtual_address + span:
            return raw + (rva - virtual_address)
    raise ValueError(f"RVA {rva:#x} is outside the executable")


def resource_entries(data, offset):
    named_count, id_count = struct.unpack_from("<HH", data, offset + 12)
    entries = []
    entry_offset = offset + 16
    for index in range(named_count + id_count):
        name, nxt = struct.unpack_from("<II", data, entry_offset + index * 8)
        entries.append((name, nxt))
    return entries


def png_icons(data):
    e_lfanew = struct.unpack_from("<I", data, 0x3C)[0]
    coff = e_lfanew + 4
    section_count = struct.unpack_from("<H", data, coff + 2)[0]
    optional_size = struct.unpack_from("<H", data, coff + 16)[0]
    optional = coff + 20
    magic = struct.unpack_from("<H", data, optional)[0]
    directories = optional + (112 if magic == 0x20B else 96)
    resource_rva = struct.unpack_from("<I", data, directories + 16)[0]
    section_table = optional + optional_size
    sections = []
    for index in range(section_count):
        offset = section_table + index * 40
        virtual_size, virtual_address, raw_size, raw = struct.unpack_from(
            "<IIII", data, offset + 8
        )
        sections.append((virtual_address, virtual_size, raw, raw_size))

    root = rva_to_offset(sections, resource_rva)
    icons = []
    for resource_type, type_offset in resource_entries(data, root):
        if resource_type != 3 or not (type_offset & 0x80000000):
            continue
        for _name, name_offset in resource_entries(data, root + (type_offset & 0x7FFFFFFF)):
            if not (name_offset & 0x80000000):
                continue
            for _lang, leaf_offset in resource_entries(
                data, root + (name_offset & 0x7FFFFFFF)
            ):
                leaf = root + leaf_offset
                icon_rva, icon_size = struct.unpack_from("<II", data, leaf)
                start = rva_to_offset(sections, icon_rva)
                blob = data[start : start + icon_size]
                if blob[:8] == b"\x89PNG\r\n\x1a\n":
                    icons.append(blob)
    return icons


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} Fork.exe output.png", file=sys.stderr)
        return 1
    icons = png_icons(Path(sys.argv[1]).read_bytes())
    if not icons:
        print("Fork.exe has no PNG icon.", file=sys.stderr)
        return 1
    destination = Path(sys.argv[2])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(max(icons, key=len))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
