@tool
extends RefCounted
## Writes Godot text resources (.tres) and scenes (.tscn) without loading any
## of the referenced resources, so output can be generated before import.

var _ext := []
var _ext_ids := {}
var _subs := []
var _nodes := []
var _editable := []
var _counter := 0


## Wraps literal Godot text (e.g. ExtResource("1")) so it is not quoted.
static func raw(s: String) -> Dictionary:
	return {"__raw__": s}


static func value_text(v) -> String:
	if v is Dictionary and v.has("__raw__"):
		return v["__raw__"]
	return var_to_str(v)


func ext(type: String, path: String) -> Dictionary:
	if not _ext_ids.has(path):
		_counter += 1
		var id := "%d_ext" % _counter
		_ext_ids[path] = id
		_ext.append({"type": type, "path": path, "id": id})
	return raw("ExtResource(\"%s\")" % _ext_ids[path])


func sub(type: String, props: Array) -> Dictionary:
	_counter += 1
	var id := "%s_%d" % [type, _counter]
	_subs.append({"type": type, "id": id, "props": props})
	return raw("SubResource(\"%s\")" % id)


## [param parent] is null for the root, "." for its children, "A/B" deeper.
## [param type] is "" for instanced scenes and for overrides of existing nodes.
func node(node_name: String, type: String, parent, props: Array, instance = null) -> void:
	_nodes.append({"name": node_name, "type": type, "parent": parent, "props": props, "instance": instance})


func editable(path: String) -> void:
	if not _editable.has(path):
		_editable.append(path)


func node_count() -> int:
	return _nodes.size()


func scene_text() -> String:
	var s := "[gd_scene format=3]\n\n" + _resources_text()
	for n in _nodes:
		var head := "[node name=%s" % var_to_str(n.name)
		if n.type != "":
			head += " type=\"%s\"" % n.type
		if n.parent != null:
			head += " parent=%s" % var_to_str(n.parent)
		if n.instance != null:
			head += " instance=%s" % value_text(n.instance)
		s += head + "]\n" + _props_text(n.props) + "\n"
	for e in _editable:
		s += "[editable path=%s]\n" % var_to_str(e)
	return s


func resource_text(type: String, props: Array) -> String:
	return "[gd_resource type=\"%s\" format=3]\n\n" % type + _resources_text() + "[resource]\n" + _props_text(props)


func _resources_text() -> String:
	var s := ""
	for e in _ext:
		s += "[ext_resource type=\"%s\" path=%s id=\"%s\"]\n" % [e.type, var_to_str(e.path), e.id]
	if not _ext.is_empty():
		s += "\n"
	for sr in _subs:
		s += "[sub_resource type=\"%s\" id=\"%s\"]\n" % [sr.type, sr.id] + _props_text(sr.props) + "\n"
	return s


static func _props_text(props: Array) -> String:
	var s := ""
	for p in props:
		s += "%s = %s\n" % [p[0], value_text(p[1])]
	return s
