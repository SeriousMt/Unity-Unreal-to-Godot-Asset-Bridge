@tool
extends RefCounted
## Imports plain model + texture folders (Fab "additional formats", Leartes
## Cosmos FBX/OBJ downloads, Megascans-style texture sets, ...).
##
## Textures are grouped into sets by name (T_Crate_BaseColor, T_Crate_N, ...),
## each set becomes a StandardMaterial3D, and model materials are remapped to
## the set whose name matches (M_Crate -> crate).

const U = preload("util.gd")
const Probe = preload("model_probe.gd")
const Mat = preload("materials.gd")
const TextWriter = preload("text_writer.gd")

const TEX_PREFIXES := ["t", "tx", "tex", "texture"]
const MAT_PREFIXES := ["m", "mi", "mat", "mtl", "material"]
const MAT_SUFFIXES := ["mat", "material", "mtl", "inst"]
const MESH_PREFIXES := ["sm", "s", "sk", "mesh", "geo"]

## Texture-name suffix -> slot. Two-token suffixes are tried before one-token ones.
const SLOTS := {
	"basecolor": "albedo", "basecolour": "albedo", "albedo": "albedo", "diffuse": "albedo",
	"diff": "albedo", "color": "albedo", "colour": "albedo", "col": "albedo", "bc": "albedo",
	"d": "albedo", "alb": "albedo", "albedotransparency": "albedo", "basemap": "albedo",
	"normal": "normal", "nrm": "normal", "nor": "normal", "n": "normal", "nml": "normal",
	"norm": "normal", "normalmap": "normal",
	"normalgl": "normal_gl", "normalopengl": "normal_gl", "ngl": "normal_gl",
	"normaldx": "normal_dx", "normaldirectx": "normal_dx", "ndx": "normal_dx",
	"orm": "orm", "arm": "orm", "aorm": "orm", "occlusionroughnessmetallic": "orm",
	"mra": "mra", "mrao": "mra", "rma": "rma",
	"maskmap": "unity_mask", "metallicsmoothness": "metal_smooth", "ms": "metal_smooth",
	"roughness": "roughness", "rough": "roughness", "rgh": "roughness", "r": "roughness",
	"metallic": "metallic", "metalness": "metallic", "metal": "metallic", "m": "metallic", "mtl": "metallic",
	"ao": "ao", "occlusion": "ao", "ambientocclusion": "ao", "occ": "ao",
	"emissive": "emission", "emission": "emission", "emit": "emission", "e": "emission", "glow": "emission",
	"opacity": "opacity", "alpha": "opacity", "transparency": "opacity", "mask": "opacity",
	"opacitymask": "opacity", "op": "opacity",
	"gloss": "gloss", "glossiness": "gloss", "smoothness": "gloss",
	"height": "height", "displacement": "height", "disp": "height", "h": "height", "bump": "height",
	"specular": "specular", "spec": "specular",
	"cavity": "ignore", "translucency": "ignore", "fuzz": "ignore", "preview": "ignore", "thumb": "ignore",
}
## Suffixes recognised even without a separator (e.g. "CrateBaseColor").
const GLUED_SUFFIXES := ["basecolor", "albedo", "diffuse", "normal", "roughness", "metallic", "occlusion", "emissive", "opacity"]

const RES_PREFERENCE := {"1k": 1, "2k": 2, "4k": 4, "8k": 8}

var report
var opts: Dictionary
var out_root: String
var entries: Array  # [[abs path, relative path], ...]
var directx := false


func _init(p_report, p_opts: Dictionary, p_out_root: String, p_entries: Array, p_directx: bool) -> void:
	report = p_report
	opts = p_opts
	out_root = p_out_root
	entries = p_entries
	directx = p_directx


func run() -> void:
	var textures := {}  # res path -> abs path of the copy
	var models := []    # [abs src, res]
	var skip := _unchosen_variants()
	for entry in entries:
		var f: String = entry[0]
		var rel: String = entry[1]
		var e := U.ext_of(f)
		var dst := _out(rel)
		if skip.has(f):
			continue
		if e in U.TEXTURE_EXTS:
			if U.copy_file(f, dst) == OK:
				textures[dst] = U.globalize(dst)
		elif e in U.CONVERTIBLE_TEXTURE_EXTS:
			dst = dst.get_basename() + ".png"
			var err := Mat.convert_to_png(f, U.globalize(dst))
			if err == "":
				textures[dst] = U.globalize(dst)
			else:
				report.warn(err)
		elif e in U.MODEL_EXTS:
			if U.copy_file(f, dst) == OK:
				models.append([f, dst])
				report.file(dst)
				report.stat("models")
		elif e in U.FOREIGN_MODEL_EXTS:
			report.warn("%s: .%s can't be imported by Godot; export it to FBX or glTF" % [rel, e])
	for t in textures:
		report.file(t)
	report.stat("textures", textures.size())

	var sets := _texture_sets(textures.keys())
	var set_materials := {}
	for key in sets:
		var res := _write_set_material(key, sets[key])
		if res != "":
			set_materials[key] = res

	for m in models:
		_remap_model(m[1], sets, set_materials)


func _out(rel: String) -> String:
	var parts := PackedStringArray()
	for part in rel.split("/", false):
		parts.append(U.sanitize_file_name(part))
	return U.res_join(out_root, "/".join(parts))


# --- texture sets -------------------------------------------------------------

## Splits a texture file stem into {key, slot, display, dx}.
static func classify_texture(stem: String) -> Dictionary:
	var toks := _tokens(stem)
	var display_toks := _tokens_raw(stem)
	var res := {"key": "", "slot": "", "display": stem, "gl_hint": ""}
	if toks.is_empty():
		return res
	# Drop resolution tokens (2K, 4096) anywhere at the end.
	while toks.size() > 1 and _is_noise(toks[toks.size() - 1]):
		toks.remove_at(toks.size() - 1)
		display_toks.remove_at(display_toks.size() - 1)
	var slot := ""
	var used := 0
	if toks.size() >= 3 and SLOTS.has(toks[-2] + toks[-1]):
		slot = SLOTS[toks[-2] + toks[-1]]
		used = 2
	elif toks.size() >= 2 and SLOTS.has(toks[-1]):
		slot = SLOTS[toks[-1]]
		used = 1
	else:
		var last: String = toks[-1]
		for suf in GLUED_SUFFIXES:
			if last.length() > suf.length() + 1 and last.ends_with(suf):
				slot = SLOTS[suf]
				toks[-1] = last.substr(0, last.length() - suf.length())
				display_toks[-1] = display_toks[-1].substr(0, display_toks[-1].length() - suf.length())
				break
	if slot == "":
		slot = "implicit"  # no suffix: usually the base color map
	for _i in used:
		toks.remove_at(toks.size() - 1)
		display_toks.remove_at(display_toks.size() - 1)
	while toks.size() > 1 and _is_noise(toks[toks.size() - 1]):
		toks.remove_at(toks.size() - 1)
		display_toks.remove_at(display_toks.size() - 1)
	if toks.size() > 1 and TEX_PREFIXES.has(toks[0]):
		toks.remove_at(0)
		display_toks.remove_at(0)
	res.slot = slot
	res.key = "_".join(toks)
	res.display = "_".join(display_toks)
	return res


static func material_key(name: String) -> String:
	var toks := _tokens(name)
	while toks.size() > 1 and (MAT_SUFFIXES.has(toks[-1]) or _is_noise(toks[-1])):
		toks.remove_at(toks.size() - 1)
	if toks.size() > 1 and (MAT_PREFIXES.has(toks[0]) or MESH_PREFIXES.has(toks[0])):
		toks.remove_at(0)
	return "_".join(toks)


static func _tokens(s: String) -> PackedStringArray:
	var out := PackedStringArray()
	for t in _tokens_raw(s):
		out.append(t.to_lower())
	return out


static func _tokens_raw(s: String) -> PackedStringArray:
	var out := PackedStringArray()
	for t in RegEx.create_from_string("[^_\\-\\s.]+").search_all(s):
		out.append(t.get_string())
	return out


static func _is_noise(t: String) -> bool:
	return RegEx.create_from_string("^(\\d+k|\\d{3,5}|lod\\d*|v\\d+)$").search(t) != null


func _texture_sets(texture_res: Array) -> Dictionary:
	var sets := {}
	var unknown := 0
	for res in texture_res:
		if String(res).get_base_dir().ends_with(".fbm"):
			continue  # textures extracted from an FBX; the FBX references them itself
		var c := classify_texture(String(res).get_file().get_basename())
		if c.slot == "" or c.slot == "ignore" or c.key == "":
			unknown += 1
			continue
		if not sets.has(c.key):
			sets[c.key] = {"__display": c.display, "__dir": String(res).get_base_dir()}
		if not sets[c.key].has(c.slot):
			sets[c.key][c.slot] = res
	for key in sets:
		if sets[key].has("implicit") and not sets[key].has("albedo"):
			sets[key]["albedo"] = sets[key]["implicit"]
		sets[key].erase("implicit")
	if unknown > 0:
		report.stat("textures_without_known_suffix", unknown)
	return sets


## Downloads often ship every texture at 1K/2K/4K. Picks one resolution per
## texture set (opts.texture_resolution, default 2k) and returns the source
## paths of the other variants so they are not copied.
func _unchosen_variants() -> Dictionary:
	var groups := {}  # set key + slot -> {res_rank: [abs paths]}
	for entry in entries:
		var f: String = entry[0]
		var e := U.ext_of(f)
		if not (e in U.TEXTURE_EXTS or e in U.CONVERTIBLE_TEXTURE_EXTS):
			continue
		var rank := _resolution_rank(String(entry[1]))
		var c := classify_texture(f.get_file().get_basename())
		var gk: String = c.key + "|" + c.slot
		if not groups.has(gk):
			groups[gk] = {}
		if not groups[gk].has(rank):
			groups[gk][rank] = []
		groups[gk][rank].append(f)
	var want: int = RES_PREFERENCE.get(String(opts.get("texture_resolution", "2k")).to_lower(), 0)
	var skip := {}
	var dropped := 0
	for gk in groups:
		var ranks: Array = groups[gk].keys()
		if ranks.size() < 2:
			continue
		ranks.sort()
		var pick: int = ranks[-1]
		if want > 0:
			pick = ranks[0]
			for r in ranks:
				if r <= want:
					pick = r
		for r in ranks:
			if r != pick:
				for f in groups[gk][r]:
					skip[f] = true
					dropped += 1
	if dropped > 0:
		report.stat("texture_variants_skipped", dropped)
		report.hint("Several texture resolutions were found; using %s. Pass texture_resolution (1k/2k/4k/max) to change." % opts.get("texture_resolution", "2k"))
	return skip


## 1, 2, 4, 8 for "1K"/"2048"/... found in the path, 0 if none.
static func _resolution_rank(rel: String) -> int:
	var m := RegEx.create_from_string("(?i)(?:^|[^a-z0-9])(1|2|4|8)k(?:[^a-z0-9]|$)").search(rel)
	if m != null:
		return int(m.get_string(1))
	m = RegEx.create_from_string("(?:^|[^0-9])(1024|2048|4096|8192)(?:[^0-9]|$)").search(rel)
	if m != null:
		return int(m.get_string(1)) / 1024
	return 0


func _write_set_material(key: String, s: Dictionary) -> String:
	var name: String = s.__display
	var spec := {"name": name}
	var mat_dir := U.res_join(out_root, "materials")
	var res := U.res_join(mat_dir, U.sanitize_file_name(name) + ".tres")
	if s.has("albedo"):
		spec.albedo_texture = s.albedo
		if s.has("opacity"):
			var packed := U.res_join(mat_dir, U.sanitize_file_name(name) + "_albedo_alpha.png")
			var err := Mat.pack_opacity(U.globalize(s.albedo), U.globalize(s.opacity), U.globalize(packed))
			if err == "":
				spec.albedo_texture = packed
				report.file(packed)
			else:
				report.warn("%s: %s" % [name, err])
			spec.transparency = "scissor"
			spec.alpha_cutoff = 0.5
			spec.cull = "none"
		elif _has_alpha(U.globalize(s.albedo)):
			spec.transparency = "scissor"
			spec.alpha_cutoff = 0.5
			spec.cull = "none"
		if RegEx.create_from_string("(?i)leaf|leaves|foliage|grass|branch|fern|plant|bush|ivy|hair").search(name) != null:
			spec.cull = "none"
	elif not (s.has("normal") or s.has("normal_gl") or s.has("normal_dx")):
		return ""  # nothing that looks like a material

	for slot in ["normal_dx", "normal_gl", "normal"]:
		if s.has(slot):
			spec.normal_texture = s[slot]
			var invert: bool = slot == "normal_dx" or (slot == "normal" and directx)
			Mat.write_normal_map_import(s[slot], invert)
			break

	if s.has("orm"):
		_channels(spec, s.orm, "b", "g", "r")
	elif s.has("mra"):
		_channels(spec, s.mra, "r", "g", "b")
	elif s.has("rma"):
		_channels(spec, s.rma, "g", "r", "b")
	elif s.has("unity_mask") or s.has("metal_smooth"):
		var src: String = s.get("unity_mask", s.get("metal_smooth"))
		spec.metallic_texture = src
		spec.metallic_channel = "r"
		if s.has("unity_mask"):
			spec.ao_texture = src
			spec.ao_channel = "g"
		_gen_roughness(spec, name, src, "a")
	else:
		if s.has("metallic"):
			spec.metallic_texture = s.metallic
			spec.metallic_channel = "r"
		if s.has("roughness"):
			spec.roughness_texture = s.roughness
			spec.roughness_channel = "r"
		elif s.has("gloss"):
			_gen_roughness(spec, name, s.gloss, "r")
		if s.has("ao"):
			spec.ao_texture = s.ao
			spec.ao_channel = "r"
	if s.has("emission"):
		spec.emission_texture = s.emission
		spec.emission = Color.WHITE
	if Mat.write_material(spec, res):
		report.file(res)
		report.stat("materials")
		return res
	return ""


static func _has_alpha(abs_path: String) -> bool:
	var img := Image.load_from_file(abs_path)
	if img == null or img.is_empty():
		return false
	if img.is_compressed():
		img.decompress()
	return img.detect_alpha() != Image.ALPHA_NONE


static func _channels(spec: Dictionary, tex: String, metal: String, rough: String, ao: String) -> void:
	spec.metallic_texture = tex
	spec.metallic_channel = metal
	spec.roughness_texture = tex
	spec.roughness_channel = rough
	spec.ao_texture = tex
	spec.ao_channel = ao


func _gen_roughness(spec: Dictionary, name: String, src: String, channel: String) -> void:
	var out := U.res_join(U.res_join(out_root, "materials"), U.sanitize_file_name(name) + "_roughness.png")
	var err := Mat.make_roughness(U.globalize(src), channel, 1.0, 0.0, U.globalize(out))
	if err == "":
		spec.roughness_texture = out
		spec.roughness_channel = "r"
		report.file(out)
	else:
		report.warn("%s: %s" % [name, err])


# --- models -------------------------------------------------------------------

func _remap_model(res: String, sets: Dictionary, set_materials: Dictionary) -> void:
	var e := U.ext_of(res)
	var stem_key := material_key(res.get_file().get_basename())
	if e == "obj":
		var key := _match_set(stem_key, set_materials)
		if key != "":
			var w := TextWriter.new()
			w.node(U.sanitize_node_name(res.get_file().get_basename()), "MeshInstance3D", null, [
				["mesh", w.ext("Mesh", res)],
				["surface_material_override/0", w.ext("Material", set_materials[key])],
			])
			var scene := res.get_basename() + ".tscn"
			if U.write_text(scene, w.scene_text()):
				report.file(scene)
				report.stat("scenes")
		return
	if not (e in U.PROBE_MODEL_EXTS):
		return
	var info := Probe.probe(U.globalize(res))
	if not info.ok:
		report.warn("%s: %s" % [res.get_file(), info.error])
		return
	var material_map := {}
	var unmatched := []
	for mname in info.materials:
		if (e == "gltf" or e == "glb") and info.textured_materials.has(mname):
			continue  # glTF already carries a complete PBR material
		var key := _match_set(material_key(mname), set_materials)
		if key == "" and info.materials.size() == 1:
			key = _match_set(stem_key, set_materials)
		if key != "":
			material_map[mname] = set_materials[key]
		else:
			unmatched.append(mname)
	if not unmatched.is_empty() and (e == "fbx" or e == "obj"):
		report.warn("%s: no texture set found for material(s) %s; Godot keeps the model's own material" % [res.get_file(), ", ".join(unmatched)])
	if not material_map.is_empty() or e == "fbx":
		Mat.write_model_import(res, material_map, {})


static func _match_set(key: String, set_materials: Dictionary) -> String:
	if key == "":
		return ""
	if set_materials.has(key):
		return key
	# Score by shared name tokens (Mobile28_Trunk ~ Mobile_Trees_Trunk). The
	# best set must beat the runner-up, otherwise the match is ambiguous.
	var toks := key.split("_", false)
	var best := ""
	var best_score := 0.0
	var second := 0.0
	for k in set_materials:
		var score := _token_score(toks, String(k).split("_", false))
		if score > best_score:
			second = best_score
			best_score = score
			best = k
		elif score > second:
			second = score
	return best if best_score >= 1.0 and best_score > second else ""


static func _token_score(a: PackedStringArray, b: PackedStringArray) -> float:
	var score := 0.0
	for t in a:
		if b.has(t):
			score += 1.0
			continue
		for u in b:
			if t.length() >= 3 and u.length() >= 3 and (t.begins_with(u) or u.begins_with(t)):
				score += 0.5
				break
	# Penalise tokens of the set that the material doesn't mention.
	for u in b:
		if not a.has(u):
			score -= 0.1
	return score
