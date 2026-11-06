@tool
extends RefCounted
## Converts Unity content (a .unitypackage or a folder with .meta files) into
## Godot resources: textures, models (with material remaps and mesh
## extraction), StandardMaterial3D materials, and prefabs/scenes as .tscn.

const U = preload("util.gd")
const Yaml = preload("unity_yaml.gd")
const Probe = preload("model_probe.gd")
const Mat = preload("materials.gd")
const TextWriter = preload("text_writer.gd")

const BUILTIN_EXTRA_GUID := "0000000000000000e000000000000000"
const BUILTIN_DEFAULT_GUID := "0000000000000000f000000000000000"
const URP_UNLIT_GUID := "650dd9526735d5b46b79224bc6e94025"

# Unity class IDs
const C_GAMEOBJECT := 1
const C_TRANSFORM := 4
const C_CAMERA := 20
const C_MESHRENDERER := 23
const C_MESHFILTER := 33
const C_RIGIDBODY := 54
const C_MESHCOLLIDER := 64
const C_BOXCOLLIDER := 65
const C_LIGHT := 108
const C_MONOBEHAVIOUR := 114
const C_SPHERECOLLIDER := 135
const C_CAPSULECOLLIDER := 136
const C_SKINNEDMESHRENDERER := 137
const C_LODGROUP := 205
const C_RECTTRANSFORM := 224
const C_PREFABINSTANCE := 1001
const C_ANIMATOR := 95
const LOOP_HINTS := ["idle", "walk", "run", "loop", "sprint", "swim", "fly", "crouch", "strafe"]

var report
var opts: Dictionary
var out_root: String

var assets := {}            # guid -> {guid, path, src, ext}
var _metas := {}            # guid -> parsed meta (lazy)
var out_paths := {}         # guid -> res:// path of converted output
var mats_by_name := {}      # lowercase material name -> [guid]
var model_info := {}        # guid -> probe result
var model_meshes := {}      # guid -> {godot mesh name: res path}
var normal_maps := {}       # texture guid -> true
var model_anims := {}       # model guid -> {godot anim name: {path, loop}}
var _material_maps := {}    # model guid -> {model material name: res path}
var _libraries := {}        # controller guid -> AnimationLibrary res path ("" if none)
var _scene_cache := {}      # guid -> info dict (or "busy")
var _planned_outputs := {}  # res path -> true


func _init(p_report, p_opts: Dictionary, p_out_root: String) -> void:
	report = p_report
	opts = p_opts
	out_root = p_out_root


# --- entry points -------------------------------------------------------------

## [param staging_dir] holds the extracted package (<guid>/pathname, asset, asset.meta).
func import_package_dir(staging_dir: String) -> void:
	for sub in U.list_subdirs(staging_dir):
		var pathname_file := sub + "/pathname"
		if not FileAccess.file_exists(pathname_file):
			continue
		var rel := U.read_text(pathname_file).split("\n")[0].strip_edges()
		var guid := sub.get_file()
		var src := sub + "/asset"
		var meta_text := U.read_text(sub + "/asset.meta") if FileAccess.file_exists(sub + "/asset.meta") else ""
		if FileAccess.file_exists(src):
			_add_asset(guid, rel, src, meta_text)
	_run()


## [param root] is a Unity project (contains Assets/) or any folder with .meta files.
func import_folder(root: String) -> void:
	var base := root.trim_suffix("/")
	for f in U.list_files(base):
		if not f.ends_with(".meta"):
			continue
		var src := f.trim_suffix(".meta")
		if not FileAccess.file_exists(src):
			continue  # folder meta
		var meta_text := U.read_text(f)
		var m := RegEx.create_from_string("guid:\\s*([0-9a-fA-F]{32})").search(meta_text)
		if m == null:
			continue
		_add_asset(m.get_string(1).to_lower(), src.substr(base.length() + 1), src, meta_text)
	_run()


func _add_asset(guid: String, rel: String, src: String, meta_text: String) -> void:
	assets[guid] = {"guid": guid, "path": rel, "src": src, "ext": U.ext_of(rel), "meta_text": meta_text}


func _meta(guid: String) -> Dictionary:
	if not _metas.has(guid):
		var a = assets.get(guid)
		_metas[guid] = Yaml.parse(a.meta_text) if a != null and a.meta_text != "" else {}
	return _metas[guid]


func _out_path_for(rel: String, new_ext := "") -> String:
	var r := rel
	if r.begins_with("Assets/"):
		r = r.substr(7)
	if new_ext != "":
		r = r.get_basename() + "." + new_ext
	var parts := PackedStringArray()
	for part in r.split("/", false):
		parts.append(U.sanitize_file_name(part))
	var p := U.res_join(out_root, "/".join(parts))
	if _planned_outputs.has(p):
		p = p.get_basename() + "_" + rel.get_extension() + "." + p.get_extension()
	_planned_outputs[p] = true
	return p


# --- pipeline -----------------------------------------------------------------

func _run() -> void:
	var by_kind := {"texture": [], "model": [], "material": [], "prefab": [], "scene": [], "audio": []}
	var skipped := {}
	for guid in assets:
		var e: String = assets[guid].ext
		if e in U.TEXTURE_EXTS or e in U.CONVERTIBLE_TEXTURE_EXTS:
			by_kind.texture.append(guid)
		elif e in U.MODEL_EXTS:
			by_kind.model.append(guid)
		elif e == "mat":
			by_kind.material.append(guid)
		elif e == "prefab":
			by_kind.prefab.append(guid)
		elif e == "unity":
			by_kind.scene.append(guid)
		elif e in U.AUDIO_EXTS:
			by_kind.audio.append(guid)
		else:
			skipped[e] = int(skipped.get(e, 0)) + 1
	for e in skipped:
		report.stat("unity_skipped_." + e, skipped[e])
	if skipped.has("cs"):
		report.hint("C# scripts were not converted; MonoBehaviours are kept as node metadata 'unity_scripts'.")
	if skipped.has("shader") or skipped.has("shadergraph"):
		report.hint("Custom Unity shaders were approximated with StandardMaterial3D.")
	if skipped.has("anim") or skipped.has("controller"):
		report.hint("Animator Controllers become AnimationLibrary resources (clips only; state machines and blend trees are not converted).")

	for guid in by_kind.texture:
		_import_texture(guid)
	for guid in by_kind.audio:
		_copy_plain(guid, "audio")
	for guid in by_kind.material:
		var m := _read_docs(guid)
		for d in m:
			if d.class_id == 21:
				var name: String = d.data.get("m_Name", assets[guid].path.get_file().get_basename())
				var key := name.to_lower()
				if not mats_by_name.has(key):
					mats_by_name[key] = []
				mats_by_name[key].append(guid)
		out_paths[guid] = _out_path_for(assets[guid].path, "tres")
	for guid in by_kind.model:
		_copy_model(guid)
	for guid in by_kind.material:
		_convert_material(guid)
	if opts.get("prefabs", true):
		for guid in by_kind.prefab:
			_convert_scene_file(guid, false)
	if opts.get("scenes", true):
		for guid in by_kind.scene:
			_convert_scene_file(guid, true)
	for guid in by_kind.model:
		_write_model_import(guid)
	for guid in normal_maps:
		if out_paths.has(guid):
			Mat.write_normal_map_import(out_paths[guid], false)


func _read_docs(guid: String) -> Array:
	return Yaml.parse_documents(U.read_text(assets[guid].src))


# --- textures, audio, models --------------------------------------------------

func _import_texture(guid: String) -> void:
	var a: Dictionary = assets[guid]
	if a.ext in U.CONVERTIBLE_TEXTURE_EXTS:
		var dst := _out_path_for(a.path, "png")
		var err := Mat.convert_to_png(a.src, U.globalize(dst))
		if err != "":
			report.warn(err)
			report.hint("Install ImageMagick so PSD/TIFF textures can be converted.")
			return
		out_paths[guid] = dst
	else:
		var dst2 := _out_path_for(a.path)
		if U.copy_file(a.src, dst2) != OK:
			report.warn("could not copy " + a.path)
			return
		out_paths[guid] = dst2
	report.file(out_paths[guid])
	report.stat("textures")
	var ti: Dictionary = _meta(guid).get("TextureImporter", {})
	if str(ti.get("textureType", "0")) == "1":
		normal_maps[guid] = true


func _copy_plain(guid: String, stat_key: String) -> void:
	var a: Dictionary = assets[guid]
	var dst := _out_path_for(a.path)
	if U.copy_file(a.src, dst) == OK:
		out_paths[guid] = dst
		report.file(dst)
		report.stat(stat_key)


func _copy_model(guid: String) -> void:
	var a: Dictionary = assets[guid]
	var dst := _out_path_for(a.path)
	if U.copy_file(a.src, dst) != OK:
		report.warn("could not copy " + a.path)
		return
	out_paths[guid] = dst
	report.file(dst)
	report.stat("models")
	if a.ext in U.PROBE_MODEL_EXTS:
		var info := Probe.probe(U.globalize(dst))
		if info.ok:
			model_info[guid] = info
		else:
			report.warn("%s: %s" % [a.path, info.error])
	elif a.ext == "blend":
		report.hint("Godot imports .blend files only when Blender's path is set in Editor Settings (filesystem/import/blender).")


## Material remaps follow Unity's own rules: the model's externalObjects
## first, then a .mat with the same name next to the model or in a
## Materials/ folder, then a unique project-wide name match.
func _write_model_import(guid: String) -> void:
	if not model_info.has(guid) or not out_paths.has(guid):
		return
	var mi: Dictionary = _meta(guid).get("ModelImporter", {})
	var scale := Yaml.num(mi.get("globalScale"), 1.0)
	Mat.write_model_import(out_paths[guid], model_material_map(guid), model_meshes.get(guid, {}), scale, model_anims.get(guid, {}))


## Which converted material each of the model's own materials becomes.
func model_material_map(guid: String) -> Dictionary:
	if _material_maps.has(guid):
		return _material_maps[guid]
	var info: Dictionary = model_info[guid]
	var a: Dictionary = assets[guid]
	var mi: Dictionary = _meta(guid).get("ModelImporter", {})
	var external := {}
	var ext_objs = mi.get("externalObjects", [])
	if ext_objs is Array:
		for e in ext_objs:
			if e is Dictionary and e.get("first") is Dictionary:
				if String(e.first.get("type", "")).ends_with(":Material"):
					external[String(e.first.get("name", ""))] = Yaml.guid_of(e.get("second"))
	var material_map := {}
	for mname in info.materials:
		var mguid := ""
		if external.has(mname):
			mguid = external[mname]
		else:
			mguid = _find_material_by_name(mname, a.path.get_base_dir())
		if mguid != "" and out_paths.has(mguid) and assets.has(mguid) and assets[mguid].ext == "mat":
			material_map[mname] = out_paths[mguid]
		elif not a.path.get_file().contains("@"):
			report.warn("%s: no Unity material found for '%s'; keeping the model's own material" % [a.path, mname])
	_material_maps[guid] = material_map
	return material_map


## Builds a Godot AnimationLibrary from the clips an Animator Controller uses.
## Unity's "Model@Clip.fbx" files each become one Animation resource.
func animation_library(controller_guid: String) -> String:
	if _libraries.has(controller_guid):
		return _libraries[controller_guid]
	_libraries[controller_guid] = ""
	if not assets.has(controller_guid):
		return ""
	var clips := {}  # clip name -> res path
	var seen := {}
	for m in RegEx.create_from_string("m_Motion: \\{fileID: -?\\d+, guid: ([0-9a-f]{32})").search_all(U.read_text(assets[controller_guid].src)):
		var g := m.get_string(1)
		if seen.has(g) or not model_info.has(g):
			continue
		seen[g] = true
		var info: Dictionary = model_info[g]
		if info.animations.is_empty():
			continue
		var file: String = assets[g].path.get_file().get_basename()
		var clip := file.get_slice("@", 1) if file.contains("@") else file
		clip = U.sanitize_file_name(clip)
		var godot_anim: String = info.animations[0]
		var res := U.res_join(String(out_paths[g]).get_base_dir(), clip + ".res")
		var loop := false
		for h in LOOP_HINTS:
			if clip.to_lower().contains(h):
				loop = true
		var mi: Dictionary = _meta(g).get("ModelImporter", {})
		var ca = mi.get("animations", {}).get("clipAnimations", []) if mi.get("animations") is Dictionary else []
		if ca is Array and not ca.is_empty() and ca[0] is Dictionary:
			loop = str(ca[0].get("loopTime", "1" if loop else "0")) == "1"
		if not model_anims.has(g):
			model_anims[g] = {}
		model_anims[g][godot_anim] = {"path": res, "loop": loop}
		clips[clip] = res
	if clips.is_empty():
		return ""
	var w := TextWriter.new()
	var entries := PackedStringArray()
	var names := clips.keys()
	names.sort()
	for c in names:
		entries.append("&%s: %s" % [var_to_str(c), TextWriter.value_text(w.ext("Animation", clips[c]))])
	var lib_res := String(_out_path_for(assets[controller_guid].path, "tres")).get_basename() + "_animations.tres"
	U.write_text(lib_res, w.resource_text("AnimationLibrary", [["_data", TextWriter.raw("{\n" + ",\n".join(entries) + "\n}")]]))
	report.file(lib_res)
	report.stat("animations", clips.size())
	_libraries[controller_guid] = lib_res
	return lib_res


func _find_material_by_name(mname: String, model_dir: String) -> String:
	var cands: Array = mats_by_name.get(mname.to_lower(), [])
	if cands.is_empty():
		return ""
	for g in cands:
		var d: String = assets[g].path.get_base_dir()
		if d == model_dir or d == model_dir + "/Materials":
			return g
	return cands[0] if cands.size() == 1 else ""


# --- materials ----------------------------------------------------------------

func _convert_material(guid: String) -> void:
	var docs := _read_docs(guid)
	var md: Dictionary = {}
	for d in docs:
		if d.class_id == 21:
			md = d.data
			break
	if md.is_empty():
		report.warn("unreadable material " + assets[guid].path)
		return
	var props: Dictionary = md.get("m_SavedProperties", {})
	var texs := _prop_list(props.get("m_TexEnvs"))
	var floats := _prop_list(props.get("m_Floats"))
	var colors := _prop_list(props.get("m_Colors"))
	var keywords := String(md.get("m_ShaderKeywords", "")).split(" ", false)
	var valid = md.get("m_ValidKeywords", [])
	if valid is Array:
		for k in valid:
			keywords.append(String(k))
	var shader_ref = md.get("m_Shader", {})
	var shader_guid := Yaml.guid_of(shader_ref)
	var shader_id := Yaml.id_of(shader_ref)

	var name: String = md.get("m_Name", assets[guid].path.get_file().get_basename())
	var spec := {"name": name}
	var out_res: String = out_paths[guid]
	var mat_dir := out_res.get_base_dir()

	var albedo_slot := _first_tex(texs, ["_BaseMap", "_MainTex", "_BaseColorMap", "_Albedo", "_AlbedoMap", "_Diffuse"])
	var albedo_tex := _tex_path(texs, albedo_slot)
	if albedo_tex != "":
		spec.albedo_texture = albedo_tex
		var st: Dictionary = texs[albedo_slot]
		var sc := Yaml.vec3(st.get("m_Scale"), Vector3.ONE)
		var of := Yaml.vec3(st.get("m_Offset"))
		spec.uv_scale = Vector2(sc.x, sc.y)
		# Godot flips V on import, so the V offset is mirrored too.
		spec.uv_offset = Vector2(of.x, fposmod(1.0 - sc.y - of.y, 1.0))
	var col_key := _first_key(colors, ["_BaseColor", "_Color", "_TintColor"])
	if col_key != "":
		spec.albedo_color = Yaml.color(colors[col_key])

	var normal_slot := _first_tex(texs, ["_BumpMap", "_NormalMap", "_Normal"])
	var normal_tex := _tex_path(texs, normal_slot)
	if normal_tex != "":
		spec.normal_texture = normal_tex
		spec.normal_scale = Yaml.num(floats.get("_BumpScale", floats.get("_NormalScale", "1")), 1.0)
		normal_maps[Yaml.guid_of(texs[normal_slot].get("m_Texture"))] = true

	# Metallic / smoothness. Unity stores smoothness, Godot wants roughness.
	var smooth_scalar := Yaml.num(floats.get("_Smoothness", floats.get("_Glossiness", "0.5")), 0.5)
	var gloss_scale := Yaml.num(floats.get("_GlossMapScale", "1"), 1.0)
	var metal_tex := _tex_path(texs, "_MetallicGlossMap")
	var mask_tex := _tex_path(texs, "_MaskMap")
	var spec_tex := _tex_path(texs, "_SpecGlossMap")
	var smooth_from_albedo := str(floats.get("_SmoothnessTextureChannel", "0")) == "1"
	var is_urp := floats.has("_Surface") or texs.has("_BaseMap")
	spec.metallic = Yaml.num(floats.get("_Metallic", "0"), 0.0)
	spec.roughness = 1.0 - smooth_scalar
	var smooth_src := ""
	var smooth_mul := gloss_scale if not is_urp else smooth_scalar
	var smooth_add := 0.0
	if mask_tex != "":  # HDRP mask map: R metal, G AO, B detail, A smoothness
		spec.metallic_texture = mask_tex
		spec.metallic_channel = "r"
		spec.ao_texture = mask_tex
		spec.ao_channel = "g"
		smooth_src = mask_tex
		var lo := Yaml.num(floats.get("_SmoothnessRemapMin", "0"), 0.0)
		var hi := Yaml.num(floats.get("_SmoothnessRemapMax", "1"), 1.0)
		smooth_mul = hi - lo
		smooth_add = lo
	elif metal_tex != "":
		spec.metallic_texture = metal_tex
		spec.metallic_channel = "r"
		smooth_src = albedo_tex if smooth_from_albedo else metal_tex
	elif spec_tex != "":
		spec.metallic = 0.0
		smooth_src = albedo_tex if smooth_from_albedo else spec_tex
		report.warn("%s: specular workflow approximated as metallic/roughness" % name)
	elif smooth_from_albedo and albedo_tex != "":
		smooth_src = albedo_tex
		smooth_mul = smooth_scalar if is_urp else gloss_scale
	if smooth_src != "":
		var rough_res := U.res_join(mat_dir, U.sanitize_file_name(name) + "_roughness.png")
		var err := Mat.make_roughness(U.globalize(smooth_src), "a", smooth_mul, smooth_add, U.globalize(rough_res))
		if err == "":
			spec.roughness_texture = rough_res
			spec.roughness_channel = "r"
			report.file(rough_res)
			report.stat("generated_roughness_maps")
		else:
			report.warn("%s: %s" % [name, err])

	var occ_tex := _tex_path(texs, "_OcclusionMap")
	if occ_tex != "" and mask_tex == "":
		spec.ao_texture = occ_tex
		spec.ao_channel = "g"

	var emission_on := keywords.has("_EMISSION") or Yaml.num(floats.get("_EmissiveIntensity", "0")) > 0.0
	var emit_tex := _tex_path(texs, _first_tex(texs, ["_EmissionMap", "_EmissiveColorMap"]))
	var emit_col_key := _first_key(colors, ["_EmissionColor", "_EmissiveColor"])
	if emission_on or (emit_tex != "" and emit_col_key != ""):
		var ec := Yaml.color(colors.get(emit_col_key), Color.BLACK) if emit_col_key != "" else Color.WHITE
		if ec.r + ec.g + ec.b > 0.0:
			var m := maxf(ec.r, maxf(ec.g, ec.b))
			spec.emission = Color(ec.r / maxf(m, 1.0), ec.g / maxf(m, 1.0), ec.b / maxf(m, 1.0))
			spec.emission_energy = maxf(m, 1.0)
			if emit_tex != "":
				spec.emission_texture = emit_tex

	# Transparency
	var mode := int(Yaml.num(floats.get("_Mode", "0")))  # Built-in Standard
	var surface := int(Yaml.num(floats.get("_Surface", floats.get("_SurfaceType", "0"))))  # URP / HDRP
	var clip := Yaml.num(floats.get("_AlphaClip", floats.get("_AlphaCutoffEnable", "0"))) > 0.5
	var cutoff := Yaml.num(floats.get("_Cutoff", floats.get("_AlphaCutoff", "0.5")), 0.5)
	if mode == 1 or clip or keywords.has("_ALPHATEST_ON"):
		spec.transparency = "scissor"
		spec.alpha_cutoff = cutoff
	elif mode >= 2 or surface == 1:
		spec.transparency = "alpha"
	var cull := int(Yaml.num(floats.get("_Cull", floats.get("_CullMode", "2")), 2.0))
	if cull == 0 or Yaml.num(floats.get("_DoubleSidedEnable", "0")) > 0.5:
		spec.cull = "none"
	elif cull == 1:
		spec.cull = "front"

	var shader_name := ""
	if assets.has(shader_guid):
		shader_name = assets[shader_guid].path.get_file()
	if shader_guid == URP_UNLIT_GUID or shader_name.to_lower().contains("unlit") \
			or (shader_guid == BUILTIN_DEFAULT_GUID and int(shader_id) >= 10750 and int(shader_id) <= 10760):
		spec.unshaded = true
	if texs.has("_DetailAlbedoMap") and _tex_path(texs, "_DetailAlbedoMap") != "":
		report.warn("%s: detail maps are not converted" % name)

	if Mat.write_material(spec, out_res):
		report.file(out_res)
		report.stat("materials")
	else:
		report.error("could not write " + out_res)


## Unity stores property lists as [{_Name: value}] (or legacy {first: {name:}, second:}).
static func _prop_list(v) -> Dictionary:
	var d := {}
	if v is Array:
		for e in v:
			if e is Dictionary:
				if e.has("first"):
					var f = e.first
					var n: String = f.get("name", "") if f is Dictionary else String(f)
					d[n] = e.get("second")
				else:
					for k in e:
						d[k] = e[k]
	elif v is Dictionary:
		for k in v:
			d[k] = v[k]
	return d


static func _first_key(d: Dictionary, keys: Array) -> String:
	for k in keys:
		if d.has(k):
			return k
	return ""


func _first_tex(texs: Dictionary, keys: Array) -> String:
	for k in keys:
		if _tex_path(texs, k) != "":
			return k
	return ""


func _tex_path(texs: Dictionary, slot: String) -> String:
	if slot == "" or not texs.has(slot) or not (texs[slot] is Dictionary):
		return ""
	var g := Yaml.guid_of(texs[slot].get("m_Texture"))
	return out_paths.get(g, "")


# --- prefabs and scenes -------------------------------------------------------

## Converts a .prefab or .unity file. Returns info used by files that nest it:
## {res, root_transform, root_go, root_name, paths: {fileID: node path}}.
func _convert_scene_file(guid: String, is_scene: bool) -> Dictionary:
	if _scene_cache.has(guid):
		var c = _scene_cache[guid]
		return c if c is Dictionary else {}
	_scene_cache[guid] = "busy"
	var a: Dictionary = assets[guid]
	var res := _out_path_for(a.path, "tscn")
	var conv := _SceneConverter.new(self, a.path, is_scene)
	var info := conv.convert(_read_docs(guid))
	if info.is_empty():
		_scene_cache[guid] = {}
		return {}
	info.res = res
	if U.write_text(res, info.text):
		report.file(res)
		report.stat("scenes" if is_scene else "prefabs")
	else:
		report.error("could not write " + res)
	info.erase("text")
	_scene_cache[guid] = info
	return info


## fileID -> {cls, name} from a model's .meta.
func model_ids(guid: String) -> Dictionary:
	var mi: Dictionary = _meta(guid).get("ModelImporter", {})
	var t := {}
	var legacy = mi.get("fileIDToRecycleName", {})
	if legacy is Dictionary:
		for k in legacy:
			t[String(k)] = {"cls": int(String(k).to_int() / 100000), "name": String(legacy[k])}
	var modern = mi.get("internalIDToNameTable", [])
	if modern is Array:
		for e in modern:
			if e is Dictionary and e.get("first") is Dictionary:
				for ck in e.first:
					t[String(e.first[ck])] = {"cls": int(ck), "name": String(e.get("second", ""))}
	return t


## Resolves a Unity mesh reference to a Godot mesh resource.
## Returns {path, type} for an external file, {builtin: "BoxMesh"...}, or {}.
func resolve_mesh(ref, go_name: String) -> Dictionary:
	var g := Yaml.guid_of(ref)
	var fid := Yaml.id_of(ref)
	if g == "" or fid == "0":
		return {}
	if g == BUILTIN_EXTRA_GUID:
		match fid:
			"10202": return {"builtin": "BoxMesh", "props": [["size", Vector3.ONE]]}
			"10207": return {"builtin": "SphereMesh", "props": [["radius", 0.5], ["height", 1.0]]}
			"10206": return {"builtin": "CylinderMesh", "props": [["top_radius", 0.5], ["bottom_radius", 0.5], ["height", 2.0]]}
			"10208": return {"builtin": "CapsuleMesh", "props": [["radius", 0.5], ["height", 2.0]]}
			"10209": return {"builtin": "PlaneMesh", "props": [["size", Vector2(10, 10)]]}
			"10210": return {"builtin": "QuadMesh", "props": [["size", Vector2.ONE]]}
		return {}
	if not assets.has(g):
		report.warn("mesh from missing asset %s (object '%s')" % [g, go_name])
		return {}
	var a: Dictionary = assets[g]
	if a.ext == "obj" and out_paths.has(g):
		return {"path": out_paths[g], "type": "Mesh"}
	if not model_info.has(g):
		report.warn("%s: mesh source %s is not supported" % [go_name, a.path])
		return {}
	var ids := model_ids(g)
	var unity_name: String = ids[fid].name if ids.has(fid) else ""
	var info: Dictionary = model_info[g]
	var mesh_name := Probe.find_mesh(info, [unity_name, go_name])
	if mesh_name == "":
		report.warn("%s: cannot find mesh '%s' in %s" % [go_name, unity_name, a.path])
		return {}
	var model_res: String = out_paths[g]
	var mesh_res := U.res_join(model_res.get_basename() + "_meshes", U.sanitize_file_name(mesh_name) + ".res")
	if not model_meshes.has(g):
		model_meshes[g] = {}
	model_meshes[g][mesh_name] = mesh_res
	return {"path": mesh_res, "type": "ArrayMesh", "model": g, "mesh_name": mesh_name}


## Builds and saves a collision shape for a model mesh. Returns its res path.
func collision_shape(mesh: Dictionary, convex: bool) -> String:
	if not mesh.has("model"):
		return ""
	var info: Dictionary = model_info[mesh.model]
	var im = info.importer_meshes.get(mesh.mesh_name)
	if im == null:
		return ""
	var suffix := "_convex.res" if convex else "_trimesh.res"
	var path: String = String(mesh.path).get_basename() + suffix
	if U.is_file(path):
		return path
	var arr: ArrayMesh = im.get_mesh()
	if arr == null:
		return ""
	var shape: Shape3D = arr.create_convex_shape() if convex else arr.create_trimesh_shape()
	if shape == null:
		return ""
	U.ensure_dir(path.get_base_dir())
	if ResourceSaver.save(shape, path) != OK:
		return ""
	report.file(path)
	return path


func material_res(ref) -> String:
	var g := Yaml.guid_of(ref)
	if g == "" or g == BUILTIN_DEFAULT_GUID or g == BUILTIN_EXTRA_GUID:
		return ""
	if assets.has(g) and assets[g].ext == "mat":
		return out_paths.get(g, "")
	return ""


func script_name(ref) -> String:
	var g := Yaml.guid_of(ref)
	if assets.has(g):
		return assets[g].path.get_file().get_basename()
	return g


class _SceneConverter:
	var imp
	var rel_path: String
	var is_scene: bool
	var objs := {}        # fileID -> doc
	var comps := {}       # GameObject fileID -> [docs]
	var stripped_tf := {} # fileID -> doc (stripped transforms)
	var lod_skip := {}    # renderer fileIDs of LOD1+
	var w
	var paths := {}       # fileID -> node path ("" = root)
	var _root_tf := ""
	var _names := {}      # parent path -> {name: true}

	func _init(p_imp, p_rel: String, p_scene: bool) -> void:
		imp = p_imp
		rel_path = p_rel
		is_scene = p_scene
		w = TextWriter.new()

	func convert(docs: Array) -> Dictionary:
		for d in docs:
			objs[d.file_id] = d
			if d.stripped and (d.class_id == C_TRANSFORM or d.class_id == C_RECTTRANSFORM):
				stripped_tf[d.file_id] = d
			var go := Yaml.id_of(d.data.get("m_GameObject"))
			if go != "0" and not d.stripped:
				if not comps.has(go):
					comps[go] = []
				comps[go].append(d)
			if d.class_id == C_LODGROUP:
				var lods = d.data.get("m_LODs", [])
				if lods is Array:
					for li in range(1, lods.size()):
						var rs = lods[li].get("renderers", []) if lods[li] is Dictionary else []
						for r in rs:
							if r is Dictionary:
								lod_skip[Yaml.id_of(r.get("renderer"))] = true
		var roots := []
		for d in docs:
			if d.stripped:
				continue
			if d.class_id == C_TRANSFORM or d.class_id == C_RECTTRANSFORM:
				if Yaml.id_of(d.data.get("m_Father")) == "0":
					roots.append(d)
			elif d.class_id == C_PREFABINSTANCE:
				var mod: Dictionary = d.data.get("m_Modification", {})
				if Yaml.id_of(mod.get("m_TransformParent")) == "0":
					roots.append(d)
		if roots.is_empty():
			imp.report.warn("%s: no root objects found" % rel_path)
			return {}
		var info := {"root_transform": "", "root_go": "", "root_pos": Vector3.ZERO, "root_rot": Quaternion.IDENTITY, "root_scale": Vector3.ONE}
		var base_name := U.sanitize_node_name(rel_path.get_file().get_basename())
		if roots.size() == 1 and not is_scene:
			var r = roots[0]
			_root_tf = r.file_id
			_emit(r, null)
			info.root_transform = r.file_id if r.class_id != C_PREFABINSTANCE else ""
			info.root_go = Yaml.id_of(r.data.get("m_GameObject"))
			if r.class_id != C_PREFABINSTANCE:
				info.root_pos = Yaml.vec3(r.data.get("m_LocalPosition"))
				info.root_rot = Yaml.quat(r.data.get("m_LocalRotation"))
				info.root_scale = Yaml.vec3(r.data.get("m_LocalScale"), Vector3.ONE)
		else:
			w.node(base_name, "Node3D", null, [])
			roots.sort_custom(func(x, y): return _root_order(x) < _root_order(y))
			for r in roots:
				_emit(r, "")
		info.paths = paths
		info.text = w.scene_text()
		return info

	func _root_order(d) -> int:
		return int(Yaml.num(d.data.get("m_RootOrder", "0")))

	func _emit(d, parent_path) -> void:
		if d.class_id == C_PREFABINSTANCE:
			_emit_instance(d, parent_path)
		elif stripped_tf.has(d.file_id):
			pass  # emitted with its PrefabInstance
		else:
			_emit_transform(d, parent_path)

	## Reserves a unique node name under [param parent_path] and returns
	## [name, own path, parent attribute for the .tscn].
	func _place(raw_name: String, parent_path) -> Array:
		var key := "<root>" if parent_path == null else String(parent_path)
		if not _names.has(key):
			_names[key] = {}
		var n := U.sanitize_node_name(raw_name)
		var base := n
		var i := 2
		while _names[key].has(n):
			n = "%s_%d" % [base, i]
			i += 1
		_names[key][n] = true
		if parent_path == null:
			return [n, "", null]
		var own: String = n if parent_path == "" else String(parent_path) + "/" + n
		return [n, own, "." if parent_path == "" else parent_path]

	## A GameObject whose subtree is an unpacked skinned model (bones as
	## GameObjects + SkinnedMeshRenderers) is emitted as an instance of the
	## imported model scene, which keeps Skeleton3D and skinning intact.
	func _rig_model(t) -> String:
		var go_id := Yaml.id_of(t.data.get("m_GameObject"))
		var has_animator: bool = comps.get(go_id, []).any(func(c): return c.class_id == C_ANIMATOR)
		if not has_animator and t.file_id != _root_tf:
			return ""
		var models := {}
		var stack := [t]
		while not stack.is_empty():
			var cur = stack.pop_back()
			for c in comps.get(Yaml.id_of(cur.data.get("m_GameObject")), []):
				if c.class_id == C_SKINNEDMESHRENDERER:
					var g := Yaml.guid_of(c.data.get("m_Mesh"))
					if imp.model_info.has(g):
						models[g] = true
			var ch = cur.data.get("m_Children", [])
			if ch is Array:
				for r in ch:
					var cid := Yaml.id_of(r)
					if objs.has(cid) and not objs[cid].stripped:
						stack.append(objs[cid])
		return models.keys()[0] if models.size() == 1 else ""

	func _emit_rig(t, model_guid: String, parent_path) -> void:
		var go_id := Yaml.id_of(t.data.get("m_GameObject"))
		var go_data: Dictionary = objs[go_id].data if objs.has(go_id) else {}
		var placed := _place(String(go_data.get("m_Name", "Character")), parent_path)
		var props := []
		var xf := Yaml.to_godot_transform(Yaml.vec3(t.data.get("m_LocalPosition")), Yaml.quat(t.data.get("m_LocalRotation")), Yaml.vec3(t.data.get("m_LocalScale"), Vector3.ONE))
		if not xf.is_equal_approx(Transform3D.IDENTITY):
			props.append(["transform", xf])
		w.node(placed[0], "", placed[2], props, w.ext("PackedScene", imp.out_paths[model_guid]))
		var my_path: String = placed[1]
		paths[t.file_id] = my_path
		paths[go_id] = my_path
		imp.report.stat("rigged_models")
		for c in comps.get(go_id, []):
			if c.class_id != C_ANIMATOR:
				continue
			var lib: String = imp.animation_library(Yaml.guid_of(c.data.get("m_Controller")))
			if lib == "":
				continue
			var ap := _place("UnityAnimations", my_path)
			var lib_ref: String = TextWriter.value_text(w.ext("AnimationLibrary", lib))
			w.node(ap[0], "AnimationPlayer", ap[2], [["libraries", TextWriter.raw("{\n&\"\": %s\n}" % lib_ref)]])

	func _emit_transform(t, parent_path) -> void:
		var rig := _rig_model(t)
		if rig != "":
			_emit_rig(t, rig, parent_path)
			return
		var go_id := Yaml.id_of(t.data.get("m_GameObject"))
		var go = objs.get(go_id)
		var go_data: Dictionary = go.data if go != null else {}
		var my_comps: Array = comps.get(go_id, [])
		var name: String = go_data.get("m_Name", "Node")

		# Skip LOD1+ objects that only carry a renderer.
		var renderers := my_comps.filter(func(c): return c.class_id == C_MESHRENDERER or c.class_id == C_SKINNEDMESHRENDERER)
		var children = t.data.get("m_Children", [])
		if renderers.size() > 0 and renderers.all(func(c): return lod_skip.has(c.file_id)) and (not (children is Array) or children.is_empty()):
			imp.report.stat("lod_levels_skipped")
			return

		var placed := _place(name, parent_path)
		var my_path: String = placed[1]
		var props := []
		var xf := Yaml.to_godot_transform(Yaml.vec3(t.data.get("m_LocalPosition")), Yaml.quat(t.data.get("m_LocalRotation")), Yaml.vec3(t.data.get("m_LocalScale"), Vector3.ONE))
		if not xf.is_equal_approx(Transform3D.IDENTITY):
			props.append(["transform", xf])
		if str(go_data.get("m_IsActive", "1")) == "0":
			props.append(["visible", false])

		var mesh_filter = null
		var renderer = null
		var colliders := []
		var rigidbody = null
		var lights := []
		var cameras := []
		var scripts := PackedStringArray()
		for c in my_comps:
			match c.class_id:
				C_MESHFILTER:
					mesh_filter = c
				C_MESHRENDERER, C_SKINNEDMESHRENDERER:
					if not lod_skip.has(c.file_id):
						renderer = c
				C_BOXCOLLIDER, C_SPHERECOLLIDER, C_CAPSULECOLLIDER, C_MESHCOLLIDER:
					colliders.append(c)
				C_RIGIDBODY:
					rigidbody = c
				C_LIGHT:
					lights.append(c)
				C_CAMERA:
					cameras.append(c)
				C_MONOBEHAVIOUR:
					scripts.append(imp.script_name(c.data.get("m_Script")))

		var mesh := {}
		var mesh_props := []
		if renderer != null:
			var mesh_ref = renderer.data.get("m_Mesh") if renderer.class_id == C_SKINNEDMESHRENDERER else (mesh_filter.data.get("m_Mesh") if mesh_filter != null else null)
			if renderer.class_id == C_SKINNEDMESHRENDERER:
				imp.report.warn("%s: skinned mesh '%s' converted as a static mesh; instance the model scene for animation" % [rel_path, name])
			mesh = imp.resolve_mesh(mesh_ref, name)
			if mesh.has("builtin"):
				mesh_props.append(["mesh", w.sub(mesh.builtin, mesh.props)])
			elif mesh.has("path"):
				mesh_props.append(["mesh", w.ext(mesh.type, mesh.path)])
			var mats = renderer.data.get("m_Materials", [])
			if mats is Array:
				for mi in mats.size():
					var mres: String = imp.material_res(mats[mi])
					if mres != "":
						mesh_props.append(["surface_material_override/%d" % mi, w.ext("Material", mres)])
			if str(renderer.data.get("m_Enabled", "1")) == "0":
				mesh_props.append(["visible", false])
			var cast := str(renderer.data.get("m_CastShadows", "1"))
			if cast == "0":
				mesh_props.append(["cast_shadow", 0])

		var node_type := "Node3D"
		var mesh_on_self := false
		if rigidbody != null:
			node_type = "CharacterBody3D" if str(rigidbody.data.get("m_IsKinematic", "0")) == "1" else "RigidBody3D"
			if node_type == "RigidBody3D":
				props.append(["mass", maxf(Yaml.num(rigidbody.data.get("m_Mass"), 1.0), 0.001)])
		elif not mesh_props.is_empty():
			node_type = "MeshInstance3D"
			mesh_on_self = true
		if mesh_on_self:
			props.append_array(mesh_props)
		if not scripts.is_empty():
			props.append(["metadata/unity_scripts", scripts])
		w.node(placed[0], node_type, placed[2], props)
		paths[t.file_id] = my_path
		paths[go_id] = my_path

		if not mesh_props.is_empty() and not mesh_on_self:
			var mp := _place("Mesh", my_path)
			w.node(mp[0], "MeshInstance3D", mp[2], mesh_props)
		if not colliders.is_empty():
			_emit_colliders(colliders, my_path, rigidbody != null, mesh, mesh_filter)
		for l in lights:
			_emit_light(l, my_path)
		for c in cameras:
			_emit_camera(c, my_path)

		if children is Array:
			for ch in children:
				var cid := Yaml.id_of(ch)
				if stripped_tf.has(cid):
					var pi_id := Yaml.id_of(stripped_tf[cid].data.get("m_PrefabInstance"))
					if objs.has(pi_id):
						_emit_instance(objs[pi_id], my_path)
				elif objs.has(cid):
					_emit(objs[cid], my_path)

	func _emit_colliders(colliders: Array, owner_path: String, owner_is_body: bool, mesh: Dictionary, mesh_filter) -> void:
		var body_path := owner_path
		var any_trigger := colliders.any(func(c): return str(c.data.get("m_IsTrigger", "0")) == "1")
		if not owner_is_body:
			var bp := _place("Area3D" if any_trigger else "StaticBody3D", owner_path)
			w.node(bp[0], "Area3D" if any_trigger else "StaticBody3D", bp[2], [])
			body_path = bp[1]
		for c in colliders:
			var shape = null
			var xf := Transform3D.IDENTITY
			var center := Yaml.to_godot_position(Yaml.vec3(c.data.get("m_Center")))
			match c.class_id:
				C_BOXCOLLIDER:
					var size := Yaml.vec3(c.data.get("m_Size"), Vector3.ONE).abs()
					shape = w.sub("BoxShape3D", [["size", size]])
					xf.origin = center
				C_SPHERECOLLIDER:
					shape = w.sub("SphereShape3D", [["radius", Yaml.num(c.data.get("m_Radius"), 0.5)]])
					xf.origin = center
				C_CAPSULECOLLIDER:
					shape = w.sub("CapsuleShape3D", [["radius", Yaml.num(c.data.get("m_Radius"), 0.5)], ["height", Yaml.num(c.data.get("m_Height"), 2.0)]])
					var dir := int(Yaml.num(c.data.get("m_Direction"), 1.0))
					if dir == 0:
						xf.basis = Basis(Vector3.FORWARD, PI / 2)
					elif dir == 2:
						xf.basis = Basis(Vector3.RIGHT, PI / 2)
					xf.origin = center
				C_MESHCOLLIDER:
					var m := mesh
					var ref = c.data.get("m_Mesh")
					if Yaml.id_of(ref) != "0":
						m = imp.resolve_mesh(ref, "collider")
					var convex := str(c.data.get("m_Convex", "0")) == "1"
					var sp: String = imp.collision_shape(m, convex)
					if sp != "":
						shape = w.ext("Shape3D", sp)
					else:
						imp.report.warn("%s: could not build mesh collider" % rel_path)
			if shape == null:
				continue
			var cp := _place("CollisionShape3D", body_path)
			var props := [["shape", shape]]
			if not xf.is_equal_approx(Transform3D.IDENTITY):
				props.push_front(["transform", xf])
			if str(c.data.get("m_Enabled", "1")) == "0":
				props.append(["disabled", true])
			w.node(cp[0], "CollisionShape3D", cp[2], props)
			imp.report.stat("colliders")

	## Unity lights and cameras look down +Z; Godot's look down -Z.
	func _emit_light(l, owner_path: String) -> void:
		var t := int(Yaml.num(l.data.get("m_Type"), 2.0))
		var ltype := "OmniLight3D"
		if t == 0:
			ltype = "SpotLight3D"
		elif t == 1:
			ltype = "DirectionalLight3D"
		elif t == 3:
			imp.report.warn("%s: area light approximated as omni light" % rel_path)
		var props := [["transform", Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)]]
		props.append(["light_color", Yaml.color(l.data.get("m_Color"))])
		props.append(["light_energy", Yaml.num(l.data.get("m_Intensity"), 1.0)])
		var shadows = l.data.get("m_Shadows", {})
		if shadows is Dictionary and str(shadows.get("m_Type", "0")) != "0":
			props.append(["shadow_enabled", true])
		if ltype == "OmniLight3D":
			props.append(["omni_range", Yaml.num(l.data.get("m_Range"), 10.0)])
		elif ltype == "SpotLight3D":
			props.append(["spot_range", Yaml.num(l.data.get("m_Range"), 10.0)])
			props.append(["spot_angle", Yaml.num(l.data.get("m_SpotAngle"), 30.0) * 0.5])
		var p := _place(ltype, owner_path)
		w.node(p[0], ltype, p[2], props)
		imp.report.stat("lights")

	func _emit_camera(c, owner_path: String) -> void:
		var props := [["transform", Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)]]
		props.append(["fov", Yaml.num(c.data.get("field of view", c.data.get("m_FieldOfView")), 60.0)])
		props.append(["near", Yaml.num(c.data.get("near clip plane"), 0.3)])
		props.append(["far", Yaml.num(c.data.get("far clip plane"), 1000.0)])
		var p := _place("Camera3D", owner_path)
		w.node(p[0], "Camera3D", p[2], props)

	## A nested prefab or a model placed in the prefab/scene.
	func _emit_instance(pi, parent_path) -> void:
		var mod: Dictionary = pi.data.get("m_Modification", {})
		var src_guid := Yaml.guid_of(pi.data.get("m_SourcePrefab"))
		if src_guid == "":
			src_guid = Yaml.guid_of(pi.data.get("m_ParentPrefab"))
		if not imp.assets.has(src_guid):
			imp.report.warn("%s: nested prefab source %s is not in the package" % [rel_path, src_guid])
			return
		var src: Dictionary = imp.assets[src_guid]
		var scene_res := ""
		var root_tf := ""
		var root_go := ""
		var default_name: String = src.path.get_file().get_basename()
		var inner_paths := {}
		var d_pos := Vector3.ZERO
		var d_rot := Quaternion.IDENTITY
		var d_scl := Vector3.ONE
		var is_model: bool = src.ext in U.MODEL_EXTS
		if is_model:
			scene_res = imp.out_paths.get(src_guid, "")
			var ids: Dictionary = imp.model_ids(src_guid)
			for fid in ids:
				var e: Dictionary = ids[fid]
				var is_root: bool = e.name == "//RootNode" or e.name == default_name
				if is_root and e.cls == C_TRANSFORM:
					root_tf = fid
				elif is_root and e.cls == C_GAMEOBJECT:
					root_go = fid
		elif src.ext == "prefab":
			var sub: Dictionary = imp._convert_scene_file(src_guid, false)
			if sub.is_empty():
				imp.report.warn("%s: cannot nest %s (circular or failed)" % [rel_path, src.path])
				return
			scene_res = sub.res
			root_tf = sub.root_transform
			d_pos = sub.root_pos
			d_rot = sub.root_rot
			d_scl = sub.root_scale
			root_go = sub.root_go
			inner_paths = sub.paths
		if scene_res == "":
			imp.report.warn("%s: unsupported nested source %s" % [rel_path, src.path])
			return

		# Group overrides by target object.
		var by_target := {}
		var mods = mod.get("m_Modifications", [])
		if mods is Array:
			for m in mods:
				if not (m is Dictionary):
					continue
				var tid := Yaml.id_of(m.get("target"))
				if not by_target.has(tid):
					by_target[tid] = {}
				by_target[tid][String(m.get("propertyPath", ""))] = m
		if root_tf == "" or not by_target.has(root_tf):
			root_tf = _guess_root_target(by_target)
		if root_go == "" or not by_target.has(root_go):
			for tid in by_target:
				if by_target[tid].has("m_Name"):
					root_go = tid
					break

		var tf_mods: Dictionary = by_target.get(root_tf, {})
		var pos := Vector3(_mod_num(tf_mods, "m_LocalPosition.x", d_pos.x), _mod_num(tf_mods, "m_LocalPosition.y", d_pos.y), _mod_num(tf_mods, "m_LocalPosition.z", d_pos.z))
		var rot := Quaternion(_mod_num(tf_mods, "m_LocalRotation.x", d_rot.x), _mod_num(tf_mods, "m_LocalRotation.y", d_rot.y), _mod_num(tf_mods, "m_LocalRotation.z", d_rot.z), _mod_num(tf_mods, "m_LocalRotation.w", d_rot.w))
		var scl := Vector3(_mod_num(tf_mods, "m_LocalScale.x", d_scl.x), _mod_num(tf_mods, "m_LocalScale.y", d_scl.y), _mod_num(tf_mods, "m_LocalScale.z", d_scl.z))
		var go_mods: Dictionary = by_target.get(root_go, {})
		var name: String = String(go_mods["m_Name"].get("value", default_name)) if go_mods.has("m_Name") else default_name

		var placed := _place(name, parent_path)
		var props := []
		var xf := Yaml.to_godot_transform(pos, rot, scl)
		if not xf.is_equal_approx(Transform3D.IDENTITY):
			props.append(["transform", xf])
		if go_mods.has("m_IsActive") and str(go_mods["m_IsActive"].get("value", "1")) == "0":
			props.append(["visible", false])
		w.node(placed[0], "", placed[2], props, w.ext("PackedScene", scene_res))
		var my_path: String = placed[1]
		paths[pi.file_id] = my_path
		imp.report.stat("prefab_instances")

		# Material overrides on renderers inside the instance.
		var overrides := {}  # inner node path -> props
		for tid in by_target:
			for prop_path in by_target[tid]:
				if not prop_path.begins_with("m_Materials.Array.data["):
					continue
				var idx: int = prop_path.trim_prefix("m_Materials.Array.data[").trim_suffix("]").to_int()
				var mres: String = imp.material_res(by_target[tid][prop_path].get("objectReference"))
				if mres == "":
					continue
				var inner = _inner_path(is_model, src_guid, tid, inner_paths)
				if inner == null:
					imp.report.warn("%s: material override on unknown object in %s" % [rel_path, src.path])
					continue
				if not overrides.has(inner):
					overrides[inner] = []
				overrides[inner].append(["surface_material_override/%d" % idx, w.ext("Material", mres)])
		for inner in overrides:
			var full: String = my_path if inner == "" else (my_path + "/" + inner if my_path != "" else inner)
			if inner == "":
				imp.report.warn("%s: material override on instance root ignored" % rel_path)
				continue
			var parent_attr: String = full.get_base_dir() if full.get_base_dir() != "" else "."
			w.node(full.get_file(), "", parent_attr, overrides[inner])
			if my_path != "":
				w.editable(my_path)

		# Objects added as children of nodes inside the instance.
		for sid in stripped_tf:
			var st = stripped_tf[sid]
			if Yaml.id_of(st.data.get("m_PrefabInstance")) != pi.file_id:
				continue
			var src_id := Yaml.id_of(st.data.get("m_CorrespondingSourceObject"))
			var inner = "" if src_id == root_tf else _inner_path(is_model, src_guid, src_id, inner_paths)
			if inner == null:
				inner = ""
				imp.report.warn("%s: added object parent inside %s not found; attached to instance root" % [rel_path, src.path])
			var host: String = my_path if inner == "" else (my_path + "/" + inner if my_path != "" else inner)
			for d in objs.values():
				if d.stripped or not (d.class_id == C_TRANSFORM or d.class_id == C_RECTTRANSFORM):
					continue
				if Yaml.id_of(d.data.get("m_Father")) == sid:
					if inner != "" and my_path != "":
						w.editable(my_path)
					_emit_transform(d, host)
		# Components added to the instance's GameObjects (e.g. colliders on a model).
		for d in objs.values():
			if not d.stripped or d.class_id != C_GAMEOBJECT:
				continue
			if Yaml.id_of(d.data.get("m_PrefabInstance")) != pi.file_id:
				continue
			var added: Array = comps.get(d.file_id, [])
			var cols := added.filter(func(c): return c.class_id in [C_BOXCOLLIDER, C_SPHERECOLLIDER, C_CAPSULECOLLIDER, C_MESHCOLLIDER])
			if cols.is_empty():
				continue
			var src_go := Yaml.id_of(d.data.get("m_CorrespondingSourceObject"))
			var inner2 = "" if src_go == root_go else _inner_path(is_model, src_guid, src_go, inner_paths)
			var host2: String = my_path if inner2 == null or inner2 == "" else (my_path + "/" + inner2 if my_path != "" else inner2)
			var mesh := {}
			if is_model:
				var ids2: Dictionary = imp.model_ids(src_guid)
				var gname: String = ids2[src_go].name if ids2.has(src_go) else default_name
				var info: Dictionary = imp.model_info.get(src_guid, {})
				if not info.is_empty():
					var mn: String = Probe.find_mesh(info, [gname])
					if mn != "":
						mesh = {"model": src_guid, "mesh_name": mn, "path": U.res_join(String(imp.out_paths[src_guid]).get_basename() + "_meshes", U.sanitize_file_name(mn) + ".res")}
			_emit_colliders(cols, host2, false, mesh, null)

	func _inner_path(is_model: bool, src_guid: String, file_id: String, inner_paths: Dictionary):
		if is_model:
			var ids: Dictionary = imp.model_ids(src_guid)
			if not ids.has(file_id):
				return null
			var info: Dictionary = imp.model_info.get(src_guid, {})
			if info.is_empty():
				return null
			return info.node_paths.get(ids[file_id].name)
		return inner_paths.get(file_id)

	static func _guess_root_target(by_target: Dictionary) -> String:
		var best := ""
		var best_score := -1
		for tid in by_target:
			var props: Dictionary = by_target[tid]
			var score := 0
			for k in props:
				if k.begins_with("m_LocalPosition") or k.begins_with("m_LocalRotation"):
					score += 1
				if k == "m_RootOrder":
					score += 10
			if score > best_score:
				best_score = score
				best = tid
		return best if best_score > 0 else ""

	static func _mod_num(mods: Dictionary, key: String, def: float) -> float:
		if mods.has(key):
			return Yaml.num(mods[key].get("value"), def)
		return def
