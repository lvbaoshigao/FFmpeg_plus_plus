#!/usr/bin/env python3
"""
Patch server.exe to replace requireAdministrator with asInvoker in the UAC manifest.
Uses pefile to properly modify the RT_MANIFEST resource.
"""
import sys
import pefile

NEW_MANIFEST = b'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
<trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
\t<security>
\t\t<requestedPrivileges>
\t\t\t<requestedExecutionLevel level="asInvoker" uiAccess="false" />
\t\t</requestedPrivileges>
\t</security>
</trustInfo>
</assembly>'''

def patch_server_exe(exe_path):
    pe = pefile.PE(exe_path)

    for rt in pe.DIRECTORY_ENTRY_RESOURCE.entries:
        if rt.id == 24:  # RT_MANIFEST
            for rid in rt.directory.entries:
                for lang in rid.directory.entries:
                    d = lang.data
                    old_data = pe.get_data(d.struct.OffsetToData, d.struct.Size)
                    old_text = old_data.decode('utf-8', errors='replace')

                    if 'requireAdministrator' in old_text:
                        print(f"  Found manifest (size {d.struct.Size})")

                        # Write new manifest (pad with nulls to same size)
                        padded = NEW_MANIFEST + b'\0' * (d.struct.Size - len(NEW_MANIFEST))
                        pe.set_bytes_at_rva(d.struct.OffsetToData, padded)
                        print(f"  Replaced manifest ({len(NEW_MANIFEST)} bytes padded to {d.struct.Size})")

                        pe.write(exe_path)
                        pe.close()

                        # Verify
                        with open(exe_path, 'rb') as f:
                            raw = f.read()
                        print(f"  After: admin={raw.count(b'requireAdministrator')}, invoker={raw.count(b'asInvoker')}")
                        return True
                    elif 'asInvoker' in old_text:
                        print(f"  Already patched")
                        pe.close()
                        return True

    print(f"  No RT_MANIFEST found")
    pe.close()
    return False

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: patch_manifest.py <path_to_server.exe>")
        sys.exit(1)
    success = patch_server_exe(sys.argv[1])
    sys.exit(0 if success else 1)
