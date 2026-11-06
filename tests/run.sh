#!/usr/bin/env bash
# End-to-end test: builds fixtures, imports them into a throwaway Godot
# project with the addon linked in, and checks the JSON results.
#   GODOT=/path/to/godot tests/run.sh [work_dir]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
work="${1:-$here/out}"
rm -rf "$work"
mkdir -p "$work/fixtures" "$work/project/addons"
python3 "$here/make_fixtures.py" "$work/fixtures" >/dev/null
printf 'config_version=5\n\n[application]\n\nconfig/name="asset_bridge_test"\n' > "$work/project/project.godot"
ln -s "$repo/addons/asset_bridge" "$work/project/addons/asset_bridge"

fail=0
check() {  # name, json file, python expression over r
  if python3 -c "import json,sys; r=json.load(open('$2')); sys.exit(0 if ($3) else 1)"; then
    echo "  ok   $1"
  else
    echo "  FAIL $1"; fail=1
  fi
}

echo "unit tests (Unreal converter)"
if python3 -I "$here/test_uasset.py" >"$work/unit.log" 2>&1; then echo "  ok   uasset format tests"; else echo "  FAIL uasset format tests"; cat "$work/unit.log"; fail=1; fi

ab="$repo/tools/asset-bridge"
echo "inspect cosmos_style.zip"
"$ab" --project "$work/project" inspect "$work/fixtures/cosmos_style.zip" > "$work/inspect.json" || true
check "detects loose models" "$work/inspect.json" "any(u['kind']=='models' for u in r['units'])"
check "unreal skipped in favour of FBX" "$work/inspect.json" "any(u['kind']=='unreal' and u['status']=='skipped' for u in r['units'])"

echo "import demo.unitypackage"
"$ab" --project "$work/project" import "$work/fixtures/demo.unitypackage" --out res://imported/demo > "$work/unity.json" || true
check "import ok" "$work/unity.json" "r['ok']"
check "materials converted" "$work/unity.json" "r['stats'].get('materials')==2"
check "prefabs converted" "$work/unity.json" "r['stats'].get('prefabs')==3"
check "scene converted" "$work/unity.json" "r['stats'].get('scenes')==1"
check "tiff converted" "$work/unity.json" "any(f.endswith('moss.png') for f in r['files'])"
check "verify loaded all" "$work/unity.json" "r['verify']['ok'] and not r['verify']['failed']"
check "no empty meshes" "$work/unity.json" "not r['verify']['empty_mesh_nodes']"

cp "$here/dump_scene.gd" "$work/project/dump_scene.gd"
dump() { "$GODOT" --headless --path "$work/project" --script res://dump_scene.gd -- "$1" 2>/dev/null | grep '^DUMP ' | sed 's/^DUMP //' > "$2"; }
dump res://imported/demo/Demo/Prefabs/RockVariant.tscn "$work/variant.json"
check "variant material override applied" "$work/variant.json" "[c for c in r['children'] if c['name']=='Rock_A'][0]['materials'][0]=='M_Moss'"
check "variant moved to x=-3 (mirrored)" "$work/variant.json" "r['pos'][0]==-3"
dump res://imported/demo/Demo/Prefabs/Nested.tscn "$work/nested.json"
check "nested keeps source z and rotation" "$work/nested.json" "r['children'][0]['pos']==[5,0,2] and r['children'][0]['rot_y']==-45"
dump res://imported/demo/Demo/Prefabs/Rock.tscn "$work/rock.json"
check "rock uses converted materials" "$work/rock.json" "r['materials']==['M_Rock','M_Moss']"
dump res://imported/demo/Demo/Scenes/Demo.tscn "$work/scene.json"
check "scene has ground, rock, sun" "$work/scene.json" "[c['type'] for c in r['children']]==['MeshInstance3D','MeshInstance3D','Node3D']"

echo "import cosmos_style.zip"
"$ab" --project "$work/project" import "$work/fixtures/cosmos_style.zip" --out res://imported/cosmos > "$work/cosmos.json" || true
check "import ok" "$work/cosmos.json" "r['ok']"
check "texture-set materials" "$work/cosmos.json" "r['stats'].get('materials')==3"
check "one resolution variant kept" "$work/cosmos.json" "r['stats'].get('texture_variants_skipped')==3 and not any('Crate_4K' in f for f in r['files'])"
if grep -q "transparency = 2" "$work/project/imported/cosmos/materials/Fern_Leaves.tres" && grep -q "albedo_texture" "$work/project/imported/cosmos/materials/Fern_Leaves.tres"; then echo "  ok   suffix-less albedo + alpha cutout"; else echo "  FAIL suffix-less albedo + alpha cutout"; fail=1; fi
check "verify loaded all" "$work/cosmos.json" "r['verify']['ok']"
dump res://imported/cosmos/FBX/SM_Crate.fbx "$work/crate.json"
check "crate uses texture-set material" "$work/crate.json" "r['children'][0]['materials']==['Crate']"
check "unreal normals detected" "$work/cosmos.json" "any(u.get('normal_convention')=='directx' for u in r['units'])"

exit $fail
