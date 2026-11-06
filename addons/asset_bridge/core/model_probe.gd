@tool
extends RefCounted
## Reads node, mesh and material names of a model with Godot's runtime
## FBX/glTF loaders, before the editor imports it. The names match the keys the
## scene importer uses in a .import file's _subresources.

const U = preload("util.gd")


static func probe(abs_path: String) -> Dictionary:
	var ext := U.ext_of(abs_path)
	var doc
	var state
	if ext == "fbx":
		if not ClassDB.class_exists("FBXDocument"):
			return {"ok": false, "error": "FBX probing needs Godot 4.3+"}
		doc = ClassDB.instantiate("FBXDocument")
		state = ClassDB.instantiate("FBXState")
	elif ext == "gltf" or ext == "glb":
		doc = GLTFDocument.new()
		state = GLTFState.new()
	else:
		return {"ok": false, "error": "cannot probe ." + ext}
	var err: int = doc.append_from_file(abs_path, state)
	if err != OK:
		return {"ok": false, "error": "load failed: " + error_string(err)}

	var meshes := []
	var importer_meshes := {}
	var material_names := []
	for gm in state.get_meshes():
		var im = gm.mesh
		if im == null:
			meshes.append({"name": "", "materials": []})
			continue
		var mname: String = im.get_name()
		var mats := []
		for s in im.get_surface_count():
			var m = im.get_surface_material(s)
			var n: String = m.resource_name if m != null else ""
			mats.append(n)
			if n != "" and not material_names.has(n):
				material_names.append(n)
		meshes.append({"name": mname, "materials": mats})
		importer_meshes[mname] = im

	var animations := []
	for ga in state.get_animations():
		animations.append(String(ga.resource_name))
	var textured := []
	for gm in state.get_meshes():
		if gm.mesh == null:
			continue
		for s in gm.mesh.get_surface_count():
			var m = gm.mesh.get_surface_material(s)
			if m is BaseMaterial3D and m.albedo_texture != null and not textured.has(m.resource_name):
				textured.append(m.resource_name)

	var nodes: Array = state.get_nodes()
	var paths := {}
	for idx in nodes.size():
		_path_of(idx, nodes, ext == "fbx", paths)
	var node_list := []
	var node_to_mesh := {}
	var node_paths := {}
	for idx in nodes.size():
		var n = nodes[idx]
		var godot_name: String = n.resource_name
		var orig: String = n.original_name if "original_name" in n else godot_name
		var mesh_name := ""
		if n.mesh >= 0 and n.mesh < meshes.size():
			mesh_name = meshes[n.mesh].name
		node_list.append({"name": godot_name, "original_name": orig, "path": paths[idx], "mesh": mesh_name})
		for key in [orig, godot_name]:
			if key == "":
				continue
			if not node_paths.has(key):
				node_paths[key] = paths[idx]
			if mesh_name != "" and not node_to_mesh.has(key):
				node_to_mesh[key] = mesh_name
	return {
		"ok": true,
		"meshes": meshes,
		"materials": material_names,
		"nodes": node_list,
		"node_to_mesh": node_to_mesh,
		"node_paths": node_paths,
		"importer_meshes": importer_meshes,
		"animations": animations,
		"textured_materials": textured,
	}


## Path of a node relative to the imported scene's root. For FBX the file's
## RootNode becomes the scene root itself.
static func _path_of(idx: int, nodes: Array, skip_root: bool, paths: Dictionary) -> String:
	if paths.has(idx):
		return paths[idx]
	var n = nodes[idx]
	var p := ""
	if n.parent < 0:
		p = "" if skip_root else String(n.resource_name)
	else:
		var pp := _path_of(n.parent, nodes, skip_root, paths)
		p = (pp + "/" if pp != "" else "") + String(n.resource_name)
	paths[idx] = p
	return p


## Finds the Godot mesh name for a Unity mesh/object name.
static func find_mesh(info: Dictionary, names: Array) -> String:
	for n in names:
		if n == "":
			continue
		if info.node_to_mesh.has(n):
			return info.node_to_mesh[n]
		for m in info.meshes:
			if m.name == n:
				return n
	# Case-insensitive pass.
	for n in names:
		var ln := String(n).to_lower()
		if ln == "":
			continue
		for k in info.node_to_mesh:
			if String(k).to_lower() == ln:
				return info.node_to_mesh[k]
	if info.meshes.size() == 1:
		return info.meshes[0].name
	return ""
