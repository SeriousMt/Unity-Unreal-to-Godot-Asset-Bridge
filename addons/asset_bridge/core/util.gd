@tool
extends RefCounted
## Shared helpers: paths, filesystem, archives and external tools.

const TEXTURE_EXTS := ["png", "jpg", "jpeg", "tga", "bmp", "webp", "exr", "hdr", "svg", "dds", "ktx"]
## Image formats Godot cannot import; converted to PNG with ImageMagick when available.
const CONVERTIBLE_TEXTURE_EXTS := ["tif", "tiff", "psd", "psb", "gif", "iff", "pict", "pct"]
const MODEL_EXTS := ["fbx", "gltf", "glb", "obj", "dae", "blend"]
## Models whose node/mesh/material names we can read before import.
const PROBE_MODEL_EXTS := ["fbx", "gltf", "glb"]
## DCC/interchange formats Godot cannot import directly.
const FOREIGN_MODEL_EXTS := ["max", "ma", "mb", "c4d", "3ds", "skp", "lwo", "lxo", "usd", "usda", "usdc", "usdz", "abc"]
const AUDIO_EXTS := ["wav", "ogg", "mp3"]

static var _tool_cache := {}


static func ext_of(path: String) -> String:
	return path.get_extension().to_lower()


static func globalize(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return ProjectSettings.globalize_path(path)
	return path


static func res_join(a: String, b: String) -> String:
	if b == "":
		return a
	if a.ends_with("/"):
		return a + b
	return a + "/" + b


static func ensure_dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(globalize(path))


static func is_dir(path: String) -> bool:
	return DirAccess.dir_exists_absolute(globalize(path))


static func is_file(path: String) -> bool:
	return FileAccess.file_exists(globalize(path))


## Recursively lists files below [param root] (absolute paths). Skips hidden
## directories, macOS resource forks and Godot's .godot folder.
static func list_files(root: String) -> PackedStringArray:
	var out := PackedStringArray()
	_walk(globalize(root).trim_suffix("/"), out)
	return out


static func _walk(dir_path: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.include_hidden = false
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry != "." and entry != "..":
			var full := dir_path + "/" + entry
			if d.current_is_dir():
				if not (entry.begins_with(".") or entry == "__MACOSX"):
					_walk(full, out)
			else:
				out.append(full)
		entry = d.get_next()
	d.list_dir_end()


static func list_subdirs(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(globalize(dir_path))
	if d == null:
		return out
	d.list_dir_begin()
	var entry := d.get_next()
	while entry != "":
		if entry != "." and entry != ".." and d.current_is_dir():
			out.append(globalize(dir_path).trim_suffix("/") + "/" + entry)
		entry = d.get_next()
	d.list_dir_end()
	return out


static func read_text(path: String) -> String:
	return FileAccess.get_file_as_string(globalize(path))


static func write_text(path: String, text: String) -> bool:
	var abs_path := globalize(path)
	ensure_dir(abs_path.get_base_dir())
	var f := FileAccess.open(abs_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	f.close()
	return true


static func copy_file(src: String, dst: String) -> int:
	var d := globalize(dst)
	ensure_dir(d.get_base_dir())
	return DirAccess.copy_absolute(globalize(src), d)


## Deletes a directory tree. Refuses anything outside the staging root.
static func remove_tree(abs_dir: String) -> void:
	if not abs_dir.begins_with(staging_root()):
		return
	for f in list_files(abs_dir):
		DirAccess.remove_absolute(f)
	_remove_dirs(abs_dir)


static func _remove_dirs(abs_dir: String) -> void:
	for sub in list_subdirs(abs_dir):
		_remove_dirs(sub)
	DirAccess.remove_absolute(abs_dir)


static func staging_root() -> String:
	return ProjectSettings.globalize_path("user://asset_bridge_staging")


## Node names may not contain . : @ / " %
static func sanitize_node_name(n: String) -> String:
	var s := n.strip_edges()
	for c in [".", ":", "@", "/", "\"", "%"]:
		s = s.replace(c, "_")
	return s if s != "" else "Node"


static func sanitize_file_name(n: String) -> String:
	var s := n.strip_edges()
	for c in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		s = s.replace(c, "_")
	return s if s != "" else "unnamed"


# --- external tools -----------------------------------------------------------

static func run(cmd: String, args: PackedStringArray) -> Dictionary:
	var out := []
	var code := OS.execute(cmd, args, out, true)
	return {"code": code, "output": "\n".join(out)}


static func has_tool(cmd: String) -> bool:
	if _tool_cache.has(cmd):
		return _tool_cache[cmd]
	var ok := false
	if OS.get_name() == "Windows":
		ok = run("where", [cmd]).code == 0
	else:
		ok = run("sh", ["-c", "command -v " + cmd]).code == 0
	_tool_cache[cmd] = ok
	return ok


## Returns the ImageMagick command ("magick" or "convert") or "" if missing.
static func magick() -> String:
	if _tool_cache.has("__magick"):
		return _tool_cache["__magick"]
	var found := ""
	if has_tool("magick"):
		found = "magick"
	elif has_tool("convert") and run("convert", ["-version"]).output.contains("ImageMagick"):
		found = "convert"
	_tool_cache["__magick"] = found
	return found


# --- archives -----------------------------------------------------------------

## Extracts a zip archive into [param dest]. Returns "" on success.
static func extract_zip(src: String, dest: String) -> String:
	ensure_dir(dest)
	if OS.get_name() != "Windows" and has_tool("unzip"):
		var r := run("unzip", ["-q", "-o", src, "-d", dest])
		if r.code == 0 or r.code == 1:  # 1 = warnings
			return ""
	var z := ZIPReader.new()
	if z.open(src) != OK:
		return "cannot open zip: " + src
	for entry in z.get_files():
		var rel: String = entry.replace("\\", "/")
		if not _safe_rel(rel):
			continue
		var target := dest + "/" + rel
		if rel.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(target)
			continue
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var f := FileAccess.open(target, FileAccess.WRITE)
		if f:
			f.store_buffer(z.read_file(entry))
			f.close()
	z.close()
	return ""


## Extracts a .tar.gz (e.g. .unitypackage) into [param dest]. Returns "" on success.
static func extract_tar_gz(src: String, dest: String) -> String:
	ensure_dir(dest)
	if has_tool("tar"):
		var r := run("tar", ["-xzf", src, "-C", dest])
		if r.code == 0:
			return ""
	var packed := FileAccess.get_file_as_bytes(src)
	var data := packed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if data.is_empty():
		return "gzip decompression failed: " + src
	var pos := 0
	var long_name := ""
	while pos + 512 <= data.size():
		var header := data.slice(pos, pos + 512)
		if header.count(0) == 512:
			break
		var entry_name := _cstr(header, 0, 100)
		var size := _octal(_cstr(header, 124, 12))
		var typeflag := header[156]
		if _cstr(header, 257, 5) == "ustar":
			var prefix := _cstr(header, 345, 155)
			if prefix != "":
				entry_name = prefix + "/" + entry_name
		var body_start := pos + 512
		pos = body_start + int(ceil(size / 512.0)) * 512
		if typeflag == 76:  # 'L' GNU long name
			long_name = data.slice(body_start, body_start + size).get_string_from_utf8()
			continue
		if typeflag == 120 or typeflag == 103:  # 'x'/'g' pax headers
			var pax := data.slice(body_start, body_start + size).get_string_from_utf8()
			for rec in pax.split("\n", false):
				var eq := rec.find("path=")
				if eq >= 0:
					long_name = rec.substr(eq + 5)
			continue
		if long_name != "":
			entry_name = long_name
			long_name = ""
		entry_name = entry_name.trim_prefix("./")
		if not _safe_rel(entry_name):
			continue
		var target := dest + "/" + entry_name
		if typeflag == 53:  # '5' directory
			DirAccess.make_dir_recursive_absolute(target)
		elif typeflag == 48 or typeflag == 0:  # '0' or NUL: regular file
			DirAccess.make_dir_recursive_absolute(target.get_base_dir())
			var f := FileAccess.open(target, FileAccess.WRITE)
			if f:
				f.store_buffer(data.slice(body_start, body_start + size))
				f.close()
	return ""


static func _safe_rel(rel: String) -> bool:
	if rel == "" or rel.begins_with("/") or rel.contains(":"):
		return false
	for part in rel.split("/"):
		if part == "..":
			return false
	return true


static func _cstr(bytes: PackedByteArray, offset: int, length: int) -> String:
	var s := bytes.slice(offset, offset + length)
	var nul := s.find(0)
	if nul >= 0:
		s = s.slice(0, nul)
	return s.get_string_from_utf8().strip_edges()


static func _octal(s: String) -> int:
	var n := 0
	for c in s.strip_edges():
		if c < "0" or c > "7":
			break
		n = n * 8 + (c.unicode_at(0) - 48)
	return n


## Godot before 4.4 imports models before the external materials they are
## remapped to can be loaded, so the first import keeps the model's own
## materials. Returns the generated models that need a second import.
static func models_needing_second_import(files: Array) -> PackedStringArray:
	var out := PackedStringArray()
	var v := Engine.get_version_info()
	if int(v.major) > 4 or (int(v.major) == 4 and int(v.minor) >= 4):
		return out
	for f in files:
		var path := String(f)
		if not (ext_of(path) in PROBE_MODEL_EXTS):
			continue
		var imp := globalize(path) + ".import"
		if FileAccess.file_exists(imp) and read_text(imp).contains("use_external/enabled"):
			out.append(path)
	return out


## Makes the next --import run reimport [param res_paths] by dropping their
## cached import checksums.
static func invalidate_imports(res_paths: PackedStringArray) -> void:
	var dir := ProjectSettings.globalize_path("res://.godot/imported")
	var names := DirAccess.get_files_at(dir)
	for p in res_paths:
		var prefix := p.get_file() + "-"
		for n in names:
			if n.begins_with(prefix) and n.ends_with(".md5"):
				DirAccess.remove_absolute(dir + "/" + n)
