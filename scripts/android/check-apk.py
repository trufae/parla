#!/usr/bin/env python3
"""Reject wrong ABIs, missing backend and non-16-KiB ELF LOAD/RELRO segments."""
import struct
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as apk:
    libraries = [name for name in apk.namelist() if name.startswith('lib/') and name.endswith('.so')]
    assert 'lib/arm64-v8a/libchatmail-rpc.so' in libraries, 'Missing Chatmail Core'
    assert 'lib/arm64-v8a/libparla.so' in libraries, 'Missing Parla'
    for name in libraries:
        assert name.startswith('lib/arm64-v8a/'), f'Unexpected ABI: {name}'
        data = apk.read(name)
        assert data[:6] == b'\x7fELF\x02\x01', f'Not ELF64 little-endian: {name}'
        assert struct.unpack_from('<H', data, 18)[0] == 183, f'Not AArch64: {name}'
        phoff = struct.unpack_from('<Q', data, 32)[0]
        phsize, phnum = struct.unpack_from('<HH', data, 54)
        loads = []
        relros = []
        for i in range(phnum):
            kind, flags, offset, vaddr, paddr, filesz, memsz, align = struct.unpack_from('<II6Q', data, phoff + i * phsize)
            if kind == 1:
                loads.append((vaddr, vaddr + memsz, flags))
                assert align >= 16384 and (vaddr - offset) % 16384 == 0, f'Unaligned LOAD: {name}'
            if kind == 0x6474e552:
                relros.append((vaddr, vaddr + memsz))
        assert loads, f'No LOAD segments: {name}'
        for start, end in relros:
            # Bionic rounds RELRO protection up to a page boundary. A RELRO
            # suffix can safely end inside a page when its LOAD ends there
            # too (as in the NDK's libc++), with no writable data in the tail.
            protected_start = start & ~16383
            protected_end = (end + 16383) & ~16383
            for lo, hi, flags in loads:
                overlap_start = max(lo, protected_start)
                overlap_end = min(hi, protected_end)
                if flags & 2 and overlap_start < overlap_end:
                    assert start <= overlap_start and overlap_end <= end, \
                        f'RELRO would protect writable data: {name}'
    print(f'Checked {len(libraries)} arm64 ELF files: 16 KiB alignment OK')
