extends SceneTree
## Prints a scene's instantiated node tree as JSON (one line, prefixed DUMP ).
##   godot --headless --path <project> --script <this> -- res://scene.tscn

func _initialize() -> void:
	var path: String = OS.get_cmdline_user_args()[0]
	var ps: PackedScene = load(path)
	var root := ps.instantiate()
	print("DUMP " + JSON.stringify(_node(root)))
	root.free()
	quit()


func _node(n: Node) -> Dictionary:
	var d := {"name": String(n.name), "type": n.get_class()}
	if n is Node3D:
		var o: Vector3 = n.global_transform.origin if n.is_inside_tree() else n.transform.origin
		d["pos"] = [snappedf(o.x, 0.001), snappedf(o.y, 0.001), snappedf(o.z, 0.001)]
		d["rot_y"] = snappedf(rad_to_deg(n.transform.basis.get_euler().y), 0.1)
	if n is MeshInstance3D:
		d["mesh"] = n.mesh.resource_path if n.mesh else null
		var mats := []
		if n.mesh:
			for i in n.mesh.get_surface_count():
				var m: Material = n.get_active_material(i)
				mats.append(m.resource_name if m else null)
		d["materials"] = mats
	if n is CollisionShape3D:
		d["shape"] = n.shape.get_class() if n.shape else null
	var kids := []
	for c in n.get_children():
		kids.append(_node(c))
	if not kids.is_empty():
		d["children"] = kids
	return d
