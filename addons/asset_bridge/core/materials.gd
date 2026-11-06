@tool
extends RefCounted
## Engine-neutral material description -> StandardMaterial3D (.tres), plus the
## texture processing and .import files the materials depend on.
##
## Spec keys (all optional except name; textures are res:// paths):
##   name, albedo_color:Color, albedo_texture,
##   normal_texture, normal_scale,
##   metallic, metallic_texture, metallic_channel,
##   roughness, roughness_texture, roughness_channel,
##   ao_texture, ao_channel,
##   emission:Color, emission_texture, emission_energy,
##   transparency: "opaque"|"alpha"|"scissor", alpha_cutoff,
##   cull: "back"|"front"|"none", unshaded:bool,
##   uv_scale:Vector2, uv_offset:Vector2

const U = preload("util.gd")
const TextWriter = preload("text_writer.gd")

const CHANNELS := {"r": 0, "g": 1, "b": 2, "a": 3, "gray": 4}


static func material_text(spec: Dictionary) -> String:
	var w := TextWriter.new()
	var p := []
	p.append(["resource_name", String(spec.get("name", ""))])
	match spec.get("transparency", "opaque"):
		"alpha":
			p.append(["transparency", 1])
		"scissor":
			p.append(["transparency", 2])
			p.append(["alpha_scissor_threshold", float(spec.get("alpha_cutoff", 0.5))])
	match spec.get("cull", "back"):
		"front":
			p.append(["cull_mode", 1])
		"none":
			p.append(["cull_mode", 2])
	if spec.get("unshaded", false):
		p.append(["shading_mode", 0])
	if spec.has("albedo_color"):
		p.append(["albedo_color", spec.albedo_color])
	if spec.get("albedo_texture", "") != "":
		p.append(["albedo_texture", w.ext("Texture2D", spec.albedo_texture)])

	var metallic_tex: String = spec.get("metallic_texture", "")
	p.append(["metallic", 1.0 if metallic_tex != "" else float(spec.get("metallic", 0.0))])
	if metallic_tex != "":
		p.append(["metallic_texture", w.ext("Texture2D", metallic_tex)])
		p.append(["metallic_texture_channel", CHANNELS.get(spec.get("metallic_channel", "r"), 0)])
	var rough_tex: String = spec.get("roughness_texture", "")
	p.append(["roughness", 1.0 if rough_tex != "" else float(spec.get("roughness", 1.0))])
	if rough_tex != "":
		p.append(["roughness_texture", w.ext("Texture2D", rough_tex)])
		p.append(["roughness_texture_channel", CHANNELS.get(spec.get("roughness_channel", "r"), 0)])

	if spec.get("emission_texture", "") != "" or spec.has("emission"):
		p.append(["emission_enabled", true])
		p.append(["emission", spec.get("emission", Color.WHITE)])
		p.append(["emission_energy_multiplier", float(spec.get("emission_energy", 1.0))])
		if spec.get("emission_texture", "") != "":
			# Unity/Unreal multiply the emission map by the color; Godot adds by default.
			p.append(["emission_operator", 1])
			p.append(["emission_texture", w.ext("Texture2D", spec.emission_texture)])

	if spec.get("normal_texture", "") != "":
		p.append(["normal_enabled", true])
		p.append(["normal_scale", float(spec.get("normal_scale", 1.0))])
		p.append(["normal_texture", w.ext("Texture2D", spec.normal_texture)])

	if spec.get("ao_texture", "") != "":
		p.append(["ao_enabled", true])
		p.append(["ao_texture", w.ext("Texture2D", spec.ao_texture)])
		p.append(["ao_texture_channel", CHANNELS.get(spec.get("ao_channel", "r"), 0)])

	var uv_scale: Vector2 = spec.get("uv_scale", Vector2.ONE)
	var uv_offset: Vector2 = spec.get("uv_offset", Vector2.ZERO)
	if uv_scale != Vector2.ONE:
		p.append(["uv1_scale", Vector3(uv_scale.x, uv_scale.y, 1.0)])
	if uv_offset != Vector2.ZERO:
		p.append(["uv1_offset", Vector3(uv_offset.x, uv_offset.y, 0.0)])
	return w.resource_text("StandardMaterial3D", p)


static func write_material(spec: Dictionary, res_path: String) -> bool:
	return U.write_text(res_path, material_text(spec))


# --- .import files ------------------------------------------------------------

## Marks a texture as a normal map; [param invert_y] converts DirectX-style
## (Unreal) normal maps to the OpenGL convention Godot uses.
static func write_normal_map_import(texture_res: String, invert_y: bool) -> void:
	var path := U.globalize(texture_res) + ".import"
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(path):
		cfg.load(path)
	cfg.set_value("remap", "importer", "texture")
	cfg.set_value("remap", "type", "CompressedTexture2D")
	if cfg.has_section_key("remap", "valid"):
		cfg.erase_section_key("remap", "valid")
	cfg.set_value("params", "compress/normal_map", 1)
	cfg.set_value("params", "process/normal_map_invert_y", invert_y)
	cfg.save(path)


## Undoes a previous normal-map marking (e.g. from an earlier, wrong import).
static func clear_normal_map_import(texture_res: String) -> void:
	var path := U.globalize(texture_res) + ".import"
	if not FileAccess.file_exists(path):
		return
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	if int(cfg.get_value("params", "compress/normal_map", 0)) == 1:
		cfg.set_value("params", "compress/normal_map", 0)
		cfg.set_value("params", "process/normal_map_invert_y", false)
		cfg.save(path)


## Writes scene-importer settings for a model: [param material_map] maps the
## model's material names to external .tres paths, [param mesh_map] maps mesh
## names to .res paths the importer should save them to.
static func write_model_import(model_res: String, material_map: Dictionary, mesh_map: Dictionary, root_scale := 1.0, anim_map := {}) -> void:
	var path := U.globalize(model_res) + ".import"
	var cfg := ConfigFile.new()
	if FileAccess.file_exists(path):
		cfg.load(path)
	cfg.set_value("remap", "importer", "scene")
	cfg.set_value("remap", "type", "PackedScene")
	if cfg.has_section_key("remap", "valid"):
		cfg.erase_section_key("remap", "valid")
	if U.ext_of(model_res) == "fbx":
		# Without this, hand-written .import files fall back to FBX2glTF.
		cfg.set_value("params", "fbx/importer", 0)
	if root_scale != 1.0:
		cfg.set_value("params", "nodes/root_scale", root_scale)
	var subres: Dictionary = cfg.get_value("params", "_subresources", {})
	if not material_map.is_empty():
		var mats: Dictionary = subres.get("materials", {})
		for mname in material_map:
			mats[mname] = {"use_external/enabled": true, "use_external/path": material_map[mname]}
		subres["materials"] = mats
	if not mesh_map.is_empty():
		var meshes: Dictionary = subres.get("meshes", {})
		for mname in mesh_map:
			U.ensure_dir(String(mesh_map[mname]).get_base_dir())
			meshes[mname] = {"save_to_file/enabled": true, "save_to_file/path": mesh_map[mname]}
		subres["meshes"] = meshes
	if not anim_map.is_empty():
		var anims: Dictionary = subres.get("animations", {})
		for aname in anim_map:
			var a: Dictionary = anim_map[aname]
			U.ensure_dir(String(a.path).get_base_dir())
			anims[aname] = {"save_to_file/enabled": true, "save_to_file/path": a.path, "settings/loop_mode": 1 if a.get("loop", false) else 0}
		subres["animations"] = anims
	cfg.set_value("params", "_subresources", subres)
	cfg.save(path)


# --- image processing ---------------------------------------------------------

## Converts an image Godot can't import (PSD, TIFF, ...) to PNG.
static func convert_to_png(src_abs: String, dst_abs: String) -> String:
	var mg := U.magick()
	if mg == "":
		return "ImageMagick not found; cannot convert " + src_abs.get_file()
	U.ensure_dir(dst_abs.get_base_dir())
	var r := U.run(mg, [src_abs + "[0]", dst_abs])
	if r.code != 0 or not FileAccess.file_exists(dst_abs):
		return "ImageMagick failed on %s: %s" % [src_abs.get_file(), r.output.strip_edges()]
	return ""


## Writes a grayscale roughness map: 1 - (src[channel] * mul + add).
## Used for Unity's smoothness-in-alpha packing, which Godot can't invert.
static func make_roughness(src_abs: String, channel: String, mul: float, add: float, dst_abs: String) -> String:
	U.ensure_dir(dst_abs.get_base_dir())
	var mg := U.magick()
	if mg != "":
		var args := PackedStringArray([src_abs])
		if channel == "a":
			args.append_array(["-alpha", "extract"])
		else:
			args.append_array(["-alpha", "off", "-channel", channel.to_upper(), "-separate", "+channel"])
		args.append_array(["-evaluate", "multiply", str(mul), "-evaluate", "add", "%s%%" % str(add * 100.0), "-negate", "-depth", "8", dst_abs])
		var r := U.run(mg, args)
		if r.code == 0 and FileAccess.file_exists(dst_abs):
			return ""
	var img := Image.load_from_file(src_abs)
	if img == null or img.is_empty():
		return "cannot read " + src_abs.get_file()
	if img.is_compressed():
		img.decompress()
	img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var count := img.get_width() * img.get_height()
	var off: int = CHANNELS.get(channel, 0)
	var out := PackedByteArray()
	out.resize(count)
	for i in count:
		var v := float(data[i * 4 + off]) / 255.0 * mul + add
		out[i] = int(clampf(1.0 - v, 0.0, 1.0) * 255.0 + 0.5)
	var o := Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_L8, out)
	return "" if o.save_png(dst_abs) == OK else "cannot write " + dst_abs


## Writes a copy of [param albedo_abs] whose alpha comes from [param opacity_abs].
static func pack_opacity(albedo_abs: String, opacity_abs: String, dst_abs: String) -> String:
	U.ensure_dir(dst_abs.get_base_dir())
	var mg := U.magick()
	if mg != "":
		var r := U.run(mg, [albedo_abs, "-alpha", "off", "(", opacity_abs, "-colorspace", "gray", "-alpha", "off", ")", "-compose", "CopyOpacity", "-composite", dst_abs])
		if r.code == 0 and FileAccess.file_exists(dst_abs):
			return ""
	var a := Image.load_from_file(albedo_abs)
	var o := Image.load_from_file(opacity_abs)
	if a == null or o == null or a.is_empty() or o.is_empty():
		return "cannot read albedo/opacity images"
	for img in [a, o]:
		if img.is_compressed():
			img.decompress()
	a.convert(Image.FORMAT_RGBA8)
	o.convert(Image.FORMAT_RGBA8)
	if o.get_size() != a.get_size():
		o.resize(a.get_width(), a.get_height())
	var ad := a.get_data()
	var od := o.get_data()
	for i in a.get_width() * a.get_height():
		ad[i * 4 + 3] = od[i * 4]
	var res := Image.create_from_data(a.get_width(), a.get_height(), false, Image.FORMAT_RGBA8, ad)
	return "" if res.save_png(dst_abs) == OK else "cannot write " + dst_abs


## Swaps the red and blue channels of an image file in place.
static func swap_red_blue(abs_path: String) -> String:
	var mg := U.magick()
	if mg != "":
		var tmp := abs_path.get_basename() + ".swap.png"
		var r := U.run(mg, [abs_path, "-channel-fx", "red<=>blue", tmp])
		if r.code == 0 and FileAccess.file_exists(tmp):
			DirAccess.remove_absolute(abs_path)
			DirAccess.rename_absolute(tmp, abs_path)
			return ""
	var img := Image.load_from_file(abs_path)
	if img == null or img.is_empty():
		return "cannot read " + abs_path.get_file()
	if img.is_compressed():
		img.decompress()
	var has_alpha := img.detect_alpha() != Image.ALPHA_NONE
	img.convert(Image.FORMAT_RGBA8)
	var d := img.get_data()
	for i in range(0, d.size(), 4):
		var t := d[i]
		d[i] = d[i + 2]
		d[i + 2] = t
	var out := Image.create_from_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8, d)
	if not has_alpha:
		out.convert(Image.FORMAT_RGB8)
	return "" if out.save_png(abs_path) == OK else "cannot write " + abs_path
