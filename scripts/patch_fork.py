#!/usr/bin/env python3
"""Patch Fork.exe so it can start under Wine.

Fork is a .NET Framework WPF app. Under Wine it crashes in three places that
do not affect Git itself:

- WinRT theme detection (no WinRT runtime on Linux)
- WPF diff line-number text measurement (Wine Mono FormattedText bug)
- WPF spell check (NaturalLanguage6 is not available)

Each patched method becomes a no-op or returns the fallback the caller already
passed in. This does not change Fork's license check.

Method lookup is by name from the .NET metadata tables, based on the
Fork 2.16.1 Wine setup published by Jason Nicholson:
https://jasonhnicholson.com/posts/2026/04/18-fork-on-wine-linux.html
"""
import os
import shutil
import struct
import sys

EXPECTED_PATCHES = 7


def rva_to_offset(sections, rva):
    for vaddr, vsize, raw_offset in sections:
        if vaddr <= rva < vaddr + vsize:
            return rva - vaddr + raw_offset
    return None


def get_sections(data):
    pe_offset = struct.unpack_from("<I", data, 0x3C)[0]
    num_sections = struct.unpack_from("<H", data, pe_offset + 6)[0]
    opt_hdr_size = struct.unpack_from("<H", data, pe_offset + 20)[0]
    section_offset = pe_offset + 24 + opt_hdr_size
    sections = []
    for i in range(num_sections):
        off = section_offset + i * 40
        vsize = struct.unpack_from("<I", data, off + 8)[0]
        vaddr = struct.unpack_from("<I", data, off + 12)[0]
        raw_offset = struct.unpack_from("<I", data, off + 20)[0]
        sections.append((vaddr, vsize, raw_offset))
    return sections


def read_method_header(data, offset):
    b = data[offset]
    if (b & 0x3) == 0x2:
        return offset + 1, b >> 2, False, 1
    if (b & 0x3) == 0x3:
        hdr_size = (struct.unpack_from("<H", data, offset)[0] >> 12) * 4
        code_size = struct.unpack_from("<I", data, offset + 4)[0]
        return offset + hdr_size, code_size, True, hdr_size
    return None, None, None, None


def patch_noop(data, fo):
    co, cs, fat, _hs = read_method_header(data, fo)
    if co is None:
        return False
    if fat:
        old_flags = struct.unpack_from("<H", data, fo)[0]
        struct.pack_into("<H", data, fo, old_flags & ~0x08)
        struct.pack_into("<H", data, fo + 2, 0)
        struct.pack_into("<I", data, fo + 4, 1)
        struct.pack_into("<I", data, fo + 8, 0)
        data[co] = 0x2A
        for i in range(1, cs):
            data[co + i] = 0
    else:
        data[fo] = 0x06
        data[fo + 1] = 0x2A
        for i in range(2, 1 + cs):
            data[fo + i] = 0
    return True


def patch_return_false(data, fo):
    """Replace method body with: return false."""
    co, cs, fat, _hs = read_method_header(data, fo)
    if co is None:
        return False
    il = bytes([0x16, 0x2A])
    if fat:
        old_flags = struct.unpack_from("<H", data, fo)[0]
        struct.pack_into("<H", data, fo, old_flags & ~0x08)
        struct.pack_into("<H", data, fo + 2, 1)
        struct.pack_into("<I", data, fo + 4, len(il))
        struct.pack_into("<I", data, fo + 8, 0)
        for i, byte in enumerate(il):
            data[co + i] = byte
        for i in range(len(il), cs):
            data[co + i] = 0
    else:
        data[fo] = (len(il) << 2) | 0x02
        for i, byte in enumerate(il):
            data[fo + 1 + i] = byte
        for i in range(len(il), cs):
            data[fo + 1 + i] = 0
    return True


def patch_return_arg(data, fo, ai):
    co, cs, fat, _hs = read_method_header(data, fo)
    if co is None:
        return False
    il = bytes([0x02 + ai, 0x2A]) if ai <= 3 else bytes([0x0E, ai, 0x2A])
    if fat:
        old_flags = struct.unpack_from("<H", data, fo)[0]
        struct.pack_into("<H", data, fo, old_flags & ~0x08)
        struct.pack_into("<H", data, fo + 2, 1)
        struct.pack_into("<I", data, fo + 4, len(il))
        struct.pack_into("<I", data, fo + 8, 0)
        for i, byte in enumerate(il):
            data[co + i] = byte
        for i in range(len(il), cs):
            data[co + i] = 0
    else:
        data[fo] = (len(il) << 2) | 0x02
        for i, byte in enumerate(il):
            data[fo + 1 + i] = byte
        for i in range(len(il), cs):
            data[fo + 1 + i] = 0
    return True


def patch_call_base_ctor(data, fo, ctor_token):
    """Replace an instance constructor with: ldarg.0; call base.ctor(); ret."""
    co, cs, fat, _hs = read_method_header(data, fo)
    if co is None or ctor_token is None:
        return False
    il = bytes([0x02, 0x28]) + struct.pack("<I", ctor_token) + bytes([0x2A])
    if fat:
        old_flags = struct.unpack_from("<H", data, fo)[0]
        struct.pack_into("<H", data, fo, old_flags & ~0x08)
        struct.pack_into("<H", data, fo + 2, 2)
        struct.pack_into("<I", data, fo + 4, len(il))
        struct.pack_into("<I", data, fo + 8, 0)
        for i, byte in enumerate(il):
            data[co + i] = byte
        for i in range(len(il), cs):
            data[co + i] = 0
    else:
        data[fo] = (len(il) << 2) | 0x02
        for i, byte in enumerate(il):
            data[fo + 1 + i] = byte
        for i in range(len(il), cs):
            data[fo + 1 + i] = 0
    return True


def patch_return_size(data, fo, size_token, width=50.0):
    """Replace method body with: return new Size(width, 0.0)."""
    co, cs, fat, _hs = read_method_header(data, fo)
    if co is None or not fat:
        return False
    if size_token is None:
        print("    WARNING: Could not find Size constructor token, using ret")
        return patch_noop(data, fo)
    new_il = bytearray()
    new_il += b"\x23" + struct.pack("<d", width)
    new_il += b"\x23" + struct.pack("<d", 0.0)
    new_il += b"\x73" + struct.pack("<I", size_token)
    new_il += b"\x2a"
    struct.pack_into("<H", data, fo, 0x3003)
    struct.pack_into("<H", data, fo + 2, 2)
    struct.pack_into("<I", data, fo + 4, len(new_il))
    struct.pack_into("<I", data, fo + 8, 0)
    for i, byte in enumerate(new_il):
        data[co + i] = byte
    for i in range(len(new_il), cs):
        data[co + i] = 0
    return True


def main():
    import dnfile

    fork_path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("FORK_EXE", "")
    if not fork_path or not os.path.exists(fork_path):
        print(f"ERROR: Fork.exe not found at {fork_path!r}", file=sys.stderr)
        sys.exit(1)

    backup = fork_path + ".original"
    if not os.path.exists(backup):
        shutil.copy2(fork_path, backup)
        print(f"Backed up to: {backup}")
    else:
        print(f"Backup exists: {backup}")

    dn = dnfile.dnPE(fork_path)

    theme_targets = {}
    for row in dn.net.mdtables.MethodDef:
        name = str(row.Name)
        if name in ("SubscribeToSystemEvents", "GetSystemBrush") and row.Rva > 0:
            theme_targets.setdefault(name, []).append(row.Rva)

    diff_targets = {}
    spelling_target = None
    update_start = None
    notify_uc_ctor = None
    notify_methods = []
    mainwindow_apply = None
    menu_manager_ctor_token = None
    for trow in dn.net.mdtables.TypeDef:
        tname = str(trow.TypeName)
        if tname == "DiffLineNumberMargin":
            for idx_obj in trow.MethodList:
                mrow = idx_obj.row
                mname = str(mrow.Name)
                if mname in ("MeasureOverride", "OnRender") and mrow.Rva > 0:
                    diff_targets[mname] = mrow.Rva
        elif tname == "SpellingPlaceholderTextBox":
            for idx_obj in trow.MethodList:
                mrow = idx_obj.row
                if str(mrow.Name) == "RefreshSpellChecking" and mrow.Rva > 0:
                    spelling_target = mrow.Rva
        elif tname == "UpdateScheduler":
            for idx_obj in trow.MethodList:
                mrow = idx_obj.row
                if str(mrow.Name) == "Start" and mrow.Rva > 0:
                    update_start = mrow.Rva
        elif tname == "NotificationManagerUserControl":
            for idx_obj in trow.MethodList:
                mrow = idx_obj.row
                if str(mrow.Name) == ".ctor" and mrow.Rva > 0:
                    notify_uc_ctor = mrow.Rva
        elif tname == "NotificationManager":
            for idx_obj in trow.MethodList:
                mrow = idx_obj.row
                mname = str(mrow.Name)
                if mname in (".ctor", ".cctor", "add_IsActiveChanged", "remove_IsActiveChanged", "get_IsActive") and mrow.Rva > 0:
                    notify_methods.append((mname, mrow.Rva))
        elif tname == "MainWindow":
            for idx_obj in trow.MethodList:
                mrow = idx_obj.row
                if str(mrow.Name) == "OnApplyTemplate" and mrow.Rva > 0:
                    mainwindow_apply = mrow.Rva
        elif tname == "MainWindowMenuManager":
            for idx_obj in trow.MethodList:
                mrow = idx_obj.row
                if str(mrow.Name) == ".ctor" and mrow.Rva > 0:
                    for rid, md in enumerate(dn.net.mdtables.MethodDef, start=1):
                        if md.Rva == mrow.Rva and str(md.Name) == ".ctor":
                            menu_manager_ctor_token = (0x06 << 24) | rid
                            break

    size_ctor_token = None
    usercontrol_ctor_token = None
    applytemplate_token = None
    for i, row in enumerate(dn.net.mdtables.MemberRef):
        cls = row.Class
        if not (cls and hasattr(cls, "row") and hasattr(cls.row, "TypeName")):
            continue
        tname = str(cls.row.TypeName)
        tns = str(getattr(cls.row, "TypeNamespace", ""))
        token = (0x0A << 24) | (i + 1)
        mname = str(row.Name)
        if mname == ".ctor":
            if tname == "Size" and tns == "System.Windows":
                size_ctor_token = token
            elif tname == "UserControl" and tns == "System.Windows.Controls":
                usercontrol_ctor_token = token
        elif mname == "OnApplyTemplate" and tname == "FrameworkElement" and tns == "System.Windows":
            applytemplate_token = token
    if size_ctor_token:
        print(f"Found Size ctor token: 0x{size_ctor_token:08x}")
    else:
        print("WARNING: Size ctor token not found")
    if usercontrol_ctor_token:
        print(f"Found UserControl ctor token: 0x{usercontrol_ctor_token:08x}")
    else:
        print("WARNING: UserControl ctor token not found")

    data = bytearray(open(fork_path, "rb").read())
    sections = get_sections(data)
    count = 0

    for name, rvas in theme_targets.items():
        for rva in rvas:
            fo = rva_to_offset(sections, rva)
            if fo is None:
                continue
            if name == "SubscribeToSystemEvents":
                ok = patch_noop(data, fo)
            else:
                ok = patch_return_arg(data, fo, 1)
            print(f"  {'OK' if ok else 'FAIL'}: {name} @ RVA 0x{rva:08x}")
            if ok:
                count += 1

    for mname, rva in diff_targets.items():
        fo = rva_to_offset(sections, rva)
        if fo is None:
            continue
        if mname == "MeasureOverride":
            ok = patch_return_size(data, fo, size_ctor_token, width=50.0)
        else:
            ok = patch_noop(data, fo)
        print(f"  {'OK' if ok else 'FAIL'}: DiffLineNumberMargin.{mname} @ RVA 0x{rva:08x}")
        if ok:
            count += 1

    if spelling_target:
        fo = rva_to_offset(sections, spelling_target)
        if fo is not None:
            ok = patch_noop(data, fo)
            print(f"  {'OK' if ok else 'FAIL'}: SpellingPlaceholderTextBox.RefreshSpellChecking")
            if ok:
                count += 1
    else:
        print("  SKIP: SpellingPlaceholderTextBox.RefreshSpellChecking not found")

    if update_start:
        fo = rva_to_offset(sections, update_start)
        if fo is not None:
            ok = patch_noop(data, fo)
            print(f"  {'OK' if ok else 'FAIL'}: UpdateScheduler.Start")
            if ok:
                count += 1
    else:
        print("  SKIP: UpdateScheduler.Start not found")

    if notify_uc_ctor:
        fo = rva_to_offset(sections, notify_uc_ctor)
        if fo is not None:
            ok = patch_call_base_ctor(data, fo, usercontrol_ctor_token)
            print(f"  {'OK' if ok else 'FAIL'}: NotificationManagerUserControl..ctor")
            if ok:
                count += 1
    else:
        print("  SKIP: NotificationManagerUserControl..ctor not found")

    if mainwindow_apply and menu_manager_ctor_token:
        fo = rva_to_offset(sections, mainwindow_apply)
        if fo is not None:
            co, cs, fat, _hs = read_method_header(data, fo)
            ok = False
            if co is not None:
                needle = b"\x73" + struct.pack("<I", menu_manager_ctor_token)
                body = bytes(data[co : co + cs])
                idx = body.find(needle)
                if idx >= 0:
                    pos = idx + 5
                    if pos < cs and data[co + pos] == 0x7D:
                        pos += 5
                    if pos < cs:
                        data[co + pos] = 0x2A
                        for i in range(pos + 1, cs):
                            data[co + i] = 0
                        if fat:
                            struct.pack_into("<I", data, fo + 4, pos + 1)
                        ok = True
            print(f"  {'OK' if ok else 'FAIL'}: MainWindow.OnApplyTemplate keep menu, skip notifications")
            if ok:
                count += 1
    elif mainwindow_apply:
        print("  SKIP: MainWindowMenuManager..ctor token not found")

    for mname, rva in notify_methods:
        fo = rva_to_offset(sections, rva)
        if fo is None:
            continue
        if mname == "get_IsActive":
            ok = patch_return_false(data, fo)
        else:
            ok = patch_noop(data, fo)
        print(f"  {'OK' if ok else 'FAIL'}: NotificationManager.{mname}")
        if ok:
            count += 1

    open(fork_path, "wb").write(data)
    print(f"Patched {count} methods. Original saved as {backup}")
    if count < EXPECTED_PATCHES:
        print(
            f"ERROR: expected at least {EXPECTED_PATCHES} patches, applied {count}",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
