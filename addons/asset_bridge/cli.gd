extends SceneTree
## Headless command line interface, meant for scripts, CI and AI agents.
##
##   godot --headless --path <project> --script res://addons/asset_bridge/cli.gd -- <command> [args]
##
## Commands:
##   inspect <source>                 Detect what a file/folder contains. Writes nothing.
##   import  <source>... [--out res://x] Convert into the project, run Godot's importer, verify.
##           Several sources (e.g. model.zip textures.zip) are imported together.
##           [--no-prefabs] [--no-scenes] [--normal-convention auto|opengl|directx]
##           [--prefer auto|all|unreal] [--texture-resolution 1k|2k|4k|max]
##           [--no-reimport] [--report <file.json>]
##   verify  <res://dir>              Load every generated scene/material and report failures.
##
## The result is printed as one line: ASSET_BRIDGE_RESULT {json}
## Exit code: 0 ok, 1 errors, 2 usage error.

const Pipeline = preload("core/pipeline.gd")
const U = preload("core/util.gd")
const MARKER := "ASSET_BRIDGE_RESULT "


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty() or args[0] in ["-h", "--help", "help"]:
		_usage()
		quit(2)
		return
	var cmd: String = args[0]
	var rest := args.slice(1)
	var result := {}
	match cmd:
		"inspect":
			if rest.is_empty():
				_usage()
				quit(2)
				return
			result = Pipeline.inspect(rest[0], _options(rest))
		"import":
			if rest.is_empty():
				_usage()
				quit(2)
				return
			result = _import(rest)
		"verify":
			result = _verify(rest[0] if not rest.is_empty() else "res://imported")
		_:
			_usage()
			quit(2)
			return
	var report_path := _flag(rest, "--report", "")
	if report_path != "":
		U.write_text(report_path, JSON.stringify(result, "  "))
	print(MARKER + JSON.stringify(result))
	quit(0 if result.get("ok", false) else 1)


func _import(rest: PackedStringArray) -> Dictionary:
	# Positional arguments before the first flag are sources.
	var sources := []
	for a in rest:
		if a.begins_with("--"):
			break
		sources.append(a)
	var source: String = sources[0]
	var out := _flag(rest, "--out", "")
	if out == "":
		out = "res://imported/" + U.sanitize_file_name(source.trim_suffix("/").get_file().get_basename()).replace(" ", "_")
	var result := Pipeline.import_source(sources if sources.size() > 1 else source, out, _options(rest))
	if not result.get("ok", false) or rest.has("--no-reimport"):
		return result
	# Let the editor import the new files, then load everything to check it.
	var exe := OS.get_executable_path()
	var project := ProjectSettings.globalize_path("res://")
	var import_log := []
	var code := OS.execute(exe, ["--headless", "--path", project, "--import"], import_log, true)
	result["godot_import_exit_code"] = code
	var vout := []
	OS.execute(exe, ["--headless", "--path", project, "--script", "res://addons/asset_bridge/cli.gd", "--", "verify", out], vout, true)
	var verify := _parse_result("\n".join(vout))
	result["verify"] = verify
	if not verify.get("ok", false):
		result["ok"] = false
	return result


func _verify(dir: String) -> Dictionary:
	var res := {"ok": true, "checked": 0, "failed": [], "empty_mesh_nodes": [], "warnings": []}
	for f in U.list_files(dir):
		var e := U.ext_of(f)
		if e != "tscn" and e != "tres" and not (e in U.MODEL_EXTS):
			continue
		var rp := ProjectSettings.localize_path(f)
		res.checked += 1
		var r = ResourceLoader.load(rp)
		if r == null:
			res.failed.append(rp)
			res.ok = false
			continue
		if r is PackedScene:
			var inst: Node = r.instantiate()
			if inst == null:
				res.failed.append(rp)
				res.ok = false
				continue
			_check_meshes(inst, rp, res)
			inst.free()
	return res


func _check_meshes(n: Node, scene: String, res: Dictionary) -> void:
	if n is MeshInstance3D and n.mesh == null:
		res.empty_mesh_nodes.append("%s:%s" % [scene, n.name])
	for c in n.get_children():
		_check_meshes(c, scene, res)


static func _parse_result(text: String) -> Dictionary:
	for line in text.split("\n"):
		var i := line.find(MARKER)
		if i >= 0:
			var parsed = JSON.parse_string(line.substr(i + MARKER.length()))
			if parsed is Dictionary:
				return parsed
	return {"ok": false, "error": "no result from verify step", "output_tail": text.right(2000)}


func _options(rest: PackedStringArray) -> Dictionary:
	var o := {}
	if rest.has("--no-prefabs"):
		o.prefabs = false
	if rest.has("--no-scenes"):
		o.scenes = false
	if rest.has("--keep-staging"):
		o.keep_staging = true
	var nc := _flag(rest, "--normal-convention", "")
	if nc != "":
		o.normal_convention = nc
	var pr := _flag(rest, "--prefer", "")
	if pr != "":
		o.prefer = pr
	var tr := _flag(rest, "--texture-resolution", "")
	if tr != "":
		o.texture_resolution = tr
	return o


static func _flag(rest: PackedStringArray, flag: String, def: String) -> String:
	var i := rest.find(flag)
	if i >= 0 and i + 1 < rest.size():
		return rest[i + 1]
	return def


func _usage() -> void:
	print("""Asset Bridge %s
usage: godot --headless --path <project> --script res://addons/asset_bridge/cli.gd -- <command> ...
  inspect <source>
  import  <source>... [--out res://imported/name] [--no-prefabs] [--no-scenes]
          [--normal-convention auto|opengl|directx] [--prefer auto|all|unreal]
          [--texture-resolution 1k|2k|4k|max]
          [--no-reimport] [--report file.json]
  verify  <res://dir>
<source>: .unitypackage, .zip, Unity project/folder, folder or file of FBX/OBJ/glTF + textures""" % Pipeline.VERSION)
