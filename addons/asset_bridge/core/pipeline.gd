@tool
extends RefCounted
## Entry point: detects what a source is (archive, .unitypackage, Unity folder,
## loose models/textures, Unreal content, ...) and runs the right importer.
##
##   var Pipeline = preload("res://addons/asset_bridge/core/pipeline.gd")
##   var report: Dictionary = Pipeline.import_source("/path/pack.zip", "res://imported/pack")

const U = preload("util.gd")
const Report = preload("report.gd")
const UnityImporter = preload("unity_importer.gd")
const LooseImporter = preload("loose_importer.gd")
const UnrealImporter = preload("unreal_importer.gd")

const VERSION := "0.1.0"


static func default_options() -> Dictionary:
	return {
		"prefabs": true,
		"scenes": true,
		## auto | opengl | directx: convention of normal maps in loose texture sets.
		"normal_convention": "auto",
		## auto: Unity content wins over loose models of the same download; all: import everything.
		"prefer": "auto",
		## 1k | 2k | 4k | 8k | max: which variant to use when textures come in several resolutions.
		"texture_resolution": "2k",
		"keep_staging": false,
	}


## Lists what would be imported, without writing into the project.
static func inspect(source, options := {}) -> Dictionary:
	var opts := _merge(options)
	var report := Report.new()
	report.data.source = source
	var staging := _new_staging(str(source))
	var units := _detect_all(source, staging, report)
	_choose(units, opts, report)
	for u in units:
		report.unit(_unit_summary(u))
	if not opts.keep_staging:
		U.remove_tree(staging)
	return report.to_dict()


## [param source] is a path, or an Array of paths that belong together
## (e.g. a model zip and a separate textures zip of the same download).
static func import_source(source, out_dir: String, options := {}) -> Dictionary:
	var opts := _merge(options)
	var report := Report.new()
	var sources: Array = source if source is Array else [source]
	var src := ", ".join(sources.map(func(x): return U.globalize(str(x))))
	report.data.source = src
	report.data.output = out_dir
	report.data["version"] = VERSION
	for x in sources:
		if not (U.is_file(U.globalize(str(x))) or U.is_dir(U.globalize(str(x)))):
			report.error("source not found: " + U.globalize(str(x)))
			return report.to_dict()
	if not out_dir.begins_with("res://"):
		report.error("output must be a res:// path inside the Godot project")
		return report.to_dict()
	var staging := _new_staging(src)
	var units := _detect_all(source, staging, report)
	_choose(units, opts, report)
	var active := units.filter(func(u): return u.status == "import")
	for u in units:
		if u.status != "import":
			report.unit(_unit_summary(u))
			continue
		var dest := out_dir
		if active.size() > 1:
			dest = U.res_join(out_dir, U.sanitize_file_name(u.name))
		u["output"] = dest
		U.ensure_dir(dest)
		match u.kind:
			"unitypackage":
				var dir := U.res_join(staging, "pkg_" + u.path.md5_text().substr(0, 8))
				var err := U.extract_tar_gz(u.path, dir)
				if err != "":
					report.error(err)
					u.status = "failed"
				else:
					UnityImporter.new(report, opts, dest).import_package_dir(dir)
					u.status = "imported"
			"unity_folder":
				UnityImporter.new(report, opts, dest).import_folder(u.root)
				u.status = "imported"
			"unreal":
				var ok := UnrealImporter.new(report, opts, dest).run(u.root, staging)
				u.status = "imported" if ok else "failed"
			"models":
				var dx: bool = opts.normal_convention == "directx" or (opts.normal_convention == "auto" and u.get("unreal_hint", false))
				u["normal_convention"] = "directx" if dx else "opengl"
				LooseImporter.new(report, opts, dest, u.entries, dx).run()
				u.status = "imported"
		report.unit(_unit_summary(u))
	if active.is_empty():
		report.error("nothing importable found in " + src)
	if not opts.keep_staging:
		U.remove_tree(staging)
	if report.data.ok:
		U.write_text(U.res_join(out_dir, "asset_bridge_report.json"), JSON.stringify(report.to_dict(), "  "))
	return report.to_dict()


static func _merge(options: Dictionary) -> Dictionary:
	var o := default_options()
	for k in options:
		o[k] = options[k]
	return o


static func _new_staging(source: String) -> String:
	var dir := U.staging_root() + "/" + (source + str(Time.get_ticks_usec())).md5_text().substr(0, 12)
	U.ensure_dir(dir)
	return dir


static func _unit_summary(u: Dictionary) -> Dictionary:
	var s := {}
	for k in ["kind", "name", "status", "path", "root", "output", "reason", "normal_convention", "file_count"]:
		if u.has(k):
			s[k] = u[k]
	if u.has("entries"):
		s["file_count"] = u.entries.size()
	return s


# --- detection ----------------------------------------------------------------

## Returns a list of units: {kind, name, path|root, files?, status, reason?}.
static func detect(path: String, staging: String, report, depth: int) -> Array:
	var units := []
	if U.is_file(path):
		var e := U.ext_of(path)
		var name := path.get_file().get_basename()
		match e:
			"unitypackage":
				units.append({"kind": "unitypackage", "name": name, "path": path, "status": "import"})
			"zip":
				if depth > 3:
					return units
				var dir := staging + "/zip_" + path.md5_text().substr(0, 8)
				var err := U.extract_zip(path, dir)
				if err != "":
					report.error(err)
					return units
				return detect(dir, staging, report, depth + 1)
			"uasset", "umap", "pak", "utoc", "ucas":
				units.append(_unreal_unit(path, name, [path]))
			"sbsar":
				units.append(_unsupported("substance", name, path, "Substance archive: render it to PNG maps (Substance Player or sbsrender), then import those."))
			"vrmesh", "vrmat", "vrscene":
				units.append(_unsupported("vray", name, path, "V-Ray asset: export from a V-Ray host app to FBX/glTF."))
			_:
				if e in U.MODEL_EXTS or e in U.TEXTURE_EXTS or e in U.CONVERTIBLE_TEXTURE_EXTS:
					units.append({"kind": "models", "name": name, "root": path.get_base_dir(), "entries": [[path, path.get_file()]], "status": "import"})
				else:
					report.error("unsupported file type: ." + e)
		return units

	var all := U.list_files(path)
	var metas := []
	var loose := []
	var unreal := []
	for f in all:
		var e := U.ext_of(f)
		if e == "meta":
			metas.append(f)
		elif e == "unitypackage" or e == "zip":
			units.append_array(detect(f, staging, report, depth + 1))
		elif e in ["uasset", "umap", "pak", "utoc", "ucas"]:
			unreal.append(f)
		elif e == "sbsar":
			units.append(_unsupported("substance", f.get_file().get_basename(), f, "Substance archive: render it to PNG maps (Substance Player or sbsrender), then import those."))
		elif e in ["vrmesh", "vrmat", "vrscene"]:
			units.append(_unsupported("vray", f.get_file().get_basename(), f, "V-Ray asset: export from a V-Ray host app to FBX/glTF."))
		elif e in U.MODEL_EXTS or e in U.TEXTURE_EXTS or e in U.CONVERTIBLE_TEXTURE_EXTS or e in U.FOREIGN_MODEL_EXTS:
			loose.append(f)

	var unity_roots := []
	if not metas.is_empty():
		var r := _common_dir(metas)
		unity_roots.append(r)
		units.append({"kind": "unity_folder", "name": r.get_file(), "root": r, "status": "import"})
	if not unreal.is_empty():
		var ur := _common_dir(unreal)
		units.append(_unreal_unit(ur, ur.get_file(), unreal))
	var free := loose.filter(func(f): return not unity_roots.any(func(r): return f.begins_with(r + "/")))
	if not free.is_empty():
		var root := _common_dir(free)
		var hint: bool = not unreal.is_empty() or RegEx.create_from_string("(?i)(^|/)(unreal|ue4|ue5)[^/]*(/|$)").search(root.substr(path.length())) != null
		var entries := free.map(func(f): return [f, f.substr(root.length() + 1)])
		units.append({"kind": "models", "name": path.get_file(), "root": root, "entries": entries, "status": "import", "unreal_hint": hint})
	return _merge_loose(units, path.get_file())


static func _detect_all(source, staging: String, report) -> Array:
	if not (source is Array):
		return detect(U.globalize(str(source)), staging, report, 0)
	var units := []
	for x in source:
		units.append_array(detect(U.globalize(str(x)), staging, report, 0))
	return _merge_loose(units, "import")


## Loose files that arrive in several archives (model zip + texture zip) are
## imported as one unit so materials can find their textures.
static func _merge_loose(units: Array, name: String) -> Array:
	var loose := units.filter(func(u): return u.kind == "models")
	if loose.size() < 2:
		return units
	var merged := {"kind": "models", "name": name, "root": "", "entries": [], "status": "import", "unreal_hint": false}
	for u in loose:
		merged.entries.append_array(u.entries)
		merged.unreal_hint = merged.unreal_hint or u.get("unreal_hint", false)
	var out := units.filter(func(u): return u.kind != "models")
	out.append(merged)
	return out


static func _unreal_unit(path: String, name: String, files: Array) -> Dictionary:
	var assets := files.filter(func(f): return U.ext_of(f) == "uasset")
	if assets.is_empty() or UnrealImporter.python() == "":
		return _unsupported("unreal", name, path,
			"Unreal .uasset content needs Python 3 for the bundled converter (or download the listing's FBX/GLB format). "
			+ "Cooked game files (.pak/.utoc) are not supported. (%d Unreal files found)" % files.size())
	# /Game/ paths inside the packages are relative to the project's Content folder.
	var root := path if U.is_dir(path) else path.get_base_dir()
	var probe := root
	while probe != "" and probe != "/" and probe.get_file() != "Content":
		probe = probe.get_base_dir()
	if probe.get_file() == "Content":
		root = probe
	return {"kind": "unreal", "name": name, "root": root, "status": "import", "file_count": files.size(),
		"reason": "experimental: static meshes, textures and materials from uncooked UE4.26+ assets"}


static func _unsupported(kind: String, name: String, path: String, reason: String) -> Dictionary:
	return {"kind": kind, "name": name, "path": path, "status": "unsupported", "reason": reason}


## Decides which units to import when a download contains several variants.
static func _choose(units: Array, opts: Dictionary, report) -> void:
	var has_unity := units.any(func(u): return u.kind == "unitypackage" or u.kind == "unity_folder")
	var has_loose := units.any(func(u): return u.kind == "models")
	for u in units:
		if u.status == "unsupported":
			report.hint(u.reason)
		elif u.kind == "models" and has_unity and opts.prefer == "auto":
			u.status = "skipped"
			u.reason = "Unity version of this download is imported instead (it carries materials and prefabs). Use prefer=all to import both."
		elif u.kind == "unreal" and (has_unity or has_loose) and opts.prefer == "auto":
			u.status = "skipped"
			u.reason = "Another format of this download is imported instead. Use prefer=unreal or prefer=all to convert the Unreal files."
		elif u.kind != "unreal" and opts.prefer == "unreal" and units.any(func(x): return x.kind == "unreal"):
			u.status = "skipped"
			u.reason = "prefer=unreal"


static func _common_dir(files: Array) -> String:
	var parts: PackedStringArray = String(files[0]).get_base_dir().split("/")
	var n := parts.size()
	for f in files:
		var p: PackedStringArray = String(f).get_base_dir().split("/")
		var i := 0
		while i < mini(n, p.size()) and p[i] == parts[i]:
			i += 1
		n = i
	return "/".join(parts.slice(0, n))
