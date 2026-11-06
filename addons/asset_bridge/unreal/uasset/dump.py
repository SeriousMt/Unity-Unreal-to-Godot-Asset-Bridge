"""python3 -m uasset.dump <file.uasset> : print tables and properties."""
import sys
from .uasset import load

def short(v, n=200):
    s = repr(v)
    return s if len(s) <= n else s[:n] + "..."

for path in sys.argv[1:]:
    p = load(path)
    print(f"== {path}\n  legacy={p.legacy_version} ue4={p.ue4_version} ue5={p.ue5_version} saved_by={p.saved_by} flags={p.package_flags:#x} names={len(p.names)} imports={len(p.imports)} exports={len(p.exports)} bulk_start={p.bulk_data_start}")
    for i, imp in enumerate(p.imports):
        print(f"  import -{i+1}: {imp.class_name} {p.object_path(-(i+1))}")
    for e in p.exports:
        try:
            p.read_export(e) if e.class_name != "MetaData" else None
        except Exception as err:
            print(f"  export {e.index}: {e.class_name} '{e.object_name}' ERROR {err}")
            continue
        print(f"  export {e.index}: {e.class_name} '{e.object_name}' outer={e.outer_index} size={e.serial_size} off={e.serial_offset} tail={e.tail_offset - e.serial_offset}")
        for k, v in e.properties.items():
            print(f"      {k} = {short(v)}")
