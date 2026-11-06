@tool
extends RefCounted
## Imports uncooked Unreal content (a project's Content folder, as Fab ships
## it) without Unreal Engine: the bundled Python converter (unreal/uasset)
## extracts textures and static meshes and describes the materials in a
## manifest, which this importer turns into Godot resources.

const U = preload("util.gd")
const Mat = preload("materials.gd")

var report
var opts: Dictionary
var out_root: String


func _init(p_report, p_opts: Dictionary, p_out_root: String) -> void:
	report = p_report
	opts = p_opts
	out_root = p_out_root


static func python() -> String:
	for p in ["python3", "python"]:
		if U.has_tool(p):
			return p
	return ""


static func converter_dir() -> String:
	return ProjectSettings.globalize_path("res://addons/asset_bridge/unreal")


func run(content_root: String, staging: String) -> bool:
	var py := python()
	if py == "":
		report.error("Unreal content needs Python 3 for the .uasset converter")
		report.hint("Install Python 3 (python3 on PATH), then import again.")
		return false
	var work := staging + "/unreal_" + content_root.md5_text().substr(0, 8)
	var code := "import sys; sys.path.insert(0, sys.argv[1]); from uasset.convert import main; sys.exit(main(sys.argv[2:]))"
	var r := U.run(py, ["-I", "-c", code, converter_dir(), content_root, work])
	var manifest_path := work + "/manifest.json"
	if not FileAccess.file_exists(manifest_path):
		report.error("Unreal converter failed: " + r.output.strip_edges().right(600))
		return false
	var manifest = JSON.parse_string(U.read_text(manifest_path))
	if not (manifest is Dictionary):
		report.error("Unreal converter wrote an unreadable manifest")
		return false
	for e in manifest.get("errors", []):
		report.warn("unreal: " + str(e))
	if int(manifest.get("oodle_missing", 0)) > 0:
		report.warn("unreal: %d UE5 assets skipped because they are Oodle-compressed" % int(manifest.oodle_missing))
		report.hint("UE5-saved Unreal content is Oodle-compressed. Build the optional decompressor once with tools/ooz-helper/build.sh (needs g++ or clang++), then import again.")
	var skipped: Dictionary = manifest.get("skipped", {})
	for cls in skipped:
		report.stat("unreal_skipped_" + str(cls), int(skipped[cls]))
	if skipped.has("World") or skipped.has("SkeletalMesh") or skipped.has("Blueprint"):
		report.hint("Unreal maps, skeletal meshes and Blueprints are not converted yet; static meshes, textures and materials are.")

	var textures := {}  # /Game path -> res path
	for game in manifest.get("textures", {}):
		var t: Dictionary = manifest.textures[game]
		var dst := U.res_join(out_root, String(t.file))
		if U.copy_file(work + "/" + String(t.file), dst) == OK:
			if t.get("swap_rb", false):
				var err := Mat.swap_red_blue(U.globalize(dst))
				if err != "":
					report.warn(err)
			textures[game] = dst
			report.file(dst)
			report.stat("textures")

	var materials := {}  # /Game path -> res path
	var normal_textures := {}
	for game in manifest.get("materials", {}):
		var m: Dictionary = manifest.materials[game]
		var res := U.res_join(out_root, _rel_from_game(game) + ".tres")
		var spec := _spec(m, textures, normal_textures, res)
		if Mat.write_material(spec, res):
			materials[game] = res
			report.file(res)
			report.stat("materials")
	for game in textures:
		if not normal_textures.has(textures[game]):
			Mat.clear_normal_map_import(textures[game])
	for tex in normal_textures:
		# Unreal normal maps use the DirectX convention (green down).
		Mat.write_normal_map_import(tex, true)

	for game in manifest.get("meshes", {}):
		var mesh: Dictionary = manifest.meshes[game]
		var dst := U.res_join(out_root, String(mesh.file))
		if U.copy_file(work + "/" + String(mesh.file), dst) != OK:
			continue
		report.file(dst)
		report.stat("models")
		var remap := {}
		for slot in mesh.get("slots", []):
			if materials.has(slot.get("material", "")):
				remap[String(slot.material_name)] = materials[slot.material]
			else:
				report.warn("%s: material %s was not converted" % [String(mesh.file).get_file(), slot.get("material", "?")])
		Mat.write_model_import(dst, remap, {})
	return true


static func _rel_from_game(game: String) -> String:
	var pkg := game.get_slice(".", 0).trim_prefix("/Game/")
	var parts := PackedStringArray()
	for p in pkg.split("/", false):
		parts.append(U.sanitize_file_name(p))
	return "/".join(parts)


func _spec(m: Dictionary, textures: Dictionary, normal_textures: Dictionary, res: String) -> Dictionary:
	var spec := {"name": String(m.get("name", res.get_file().get_basename()))}
	var bc = m.get("base_color")
	if bc is Dictionary:
		if textures.has(bc.get("texture", "")):
			spec.albedo_texture = textures[bc.texture]
			var tint = bc.get("tint")
			if tint is Array and tint.size() >= 3:
				spec.albedo_color = Color(tint[0], tint[1], tint[2])
		elif bc.get("constant") is Array:
			var c: Array = bc.constant
			spec.albedo_color = Color(c[0], c[1], c[2])
	var nm = m.get("normal")
	if nm is Dictionary and textures.has(nm.get("texture", "")):
		spec.normal_texture = textures[nm.texture]
		normal_textures[spec.normal_texture] = true
	for pair in [["roughness", "roughness"], ["metallic", "metallic"]]:
		var v = m.get(pair[0])
		if v is Dictionary:
			if textures.has(v.get("texture", "")):
				spec[pair[1] + "_texture"] = textures[v.texture]
				spec[pair[1] + "_channel"] = _channel(v.get("channel", "r"))
			elif v.get("constant") != null:
				spec[pair[1]] = _scalar(v.constant)
	if not spec.has("roughness") and not spec.has("roughness_texture"):
		spec.roughness = 0.5
	var ao = m.get("ao")
	if ao is Dictionary and textures.has(ao.get("texture", "")):
		spec.ao_texture = textures[ao.texture]
		spec.ao_channel = _channel(ao.get("channel", "r"))
	var em = m.get("emissive")
	if em is Dictionary:
		if textures.has(em.get("texture", "")):
			spec.emission_texture = textures[em.texture]
			spec.emission = Color.WHITE
		elif em.get("constant") is Array and _scalar(em.constant) > 0.0:
			var ec: Array = em.constant
			spec.emission = Color(ec[0], ec[1], ec[2])

	var blend := String(m.get("blend", "BLEND_Opaque"))
	if blend == "BLEND_Masked":
		spec.transparency = "scissor"
		spec.alpha_cutoff = float(m.get("opacity_mask_clip", 0.3333))
		var om = m.get("opacity_mask")
		var albedo_src = bc.get("texture", "") if bc is Dictionary else ""
		if om is Dictionary and textures.has(om.get("texture", "")) and (om.texture != albedo_src or om.get("channel") != "a"):
			var packed := res.get_basename() + "_albedo_alpha.png"
			if spec.has("albedo_texture"):
				var err := Mat.pack_opacity(U.globalize(spec.albedo_texture), U.globalize(textures[om.texture]), U.globalize(packed))
				if err == "":
					spec.albedo_texture = packed
					report.file(packed)
				else:
					report.warn("%s: %s" % [spec.name, err])
	elif blend in ["BLEND_Translucent", "BLEND_Additive", "BLEND_Modulate"]:
		spec.transparency = "alpha"
	if m.get("two_sided", false):
		spec.cull = "none"
	if String(m.get("shading", "")) == "MSM_Unlit":
		spec.unshaded = true
	return spec


static func _channel(c: String) -> String:
	return c if c in ["r", "g", "b", "a"] else "r"


static func _scalar(v) -> float:
	if v is Array:
		return float(v[0]) if not v.is_empty() else 0.0
	return float(v)
