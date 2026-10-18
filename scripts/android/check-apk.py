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
        loads = 0
        for i in range(phnum):
            kind, flags, offset, vaddr, paddr, filesz, memsz, align = struct.unpack_from('<II6Q', data, phoff + i * phsize)
            if kind == 1:
                loads += 1
                assert align >= 16384 and (vaddr - offset) % 16384 == 0, f'Unaligned LOAD: {name}'
            if kind == 0x6474e552:
                assert (vaddr + memsz) % 16384 == 0, f'Unaligned RELRO end: {name}'
        assert loads, f'No LOAD segments: {name}'
    print(f'Checked {len(libraries)} arm64 ELF files: 16 KiB alignment OK')
