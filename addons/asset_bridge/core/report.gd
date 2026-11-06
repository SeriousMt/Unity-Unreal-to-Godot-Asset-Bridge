@tool
extends RefCounted
## Collects what an import did, as a JSON-friendly dictionary.

const MAX_MESSAGES := 400

var data := {
	"ok": true,
	"source": "",
	"output": "",
	"units": [],
	"stats": {},
	"files": [],
	"warnings": [],
	"errors": [],
	"hints": [],
}
var _dropped := 0


func warn(msg: String) -> void:
	_push("warnings", msg)


func error(msg: String) -> void:
	data.ok = false
	_push("errors", msg)


func hint(msg: String) -> void:
	if not data.hints.has(msg):
		data.hints.append(msg)


func file(res_path: String) -> void:
	data.files.append(res_path)


func stat(key: String, n := 1) -> void:
	data.stats[key] = int(data.stats.get(key, 0)) + n


func unit(info: Dictionary) -> void:
	data.units.append(info)


func _push(key: String, msg: String) -> void:
	var arr: Array = data[key]
	if arr.has(msg):
		return
	if arr.size() >= MAX_MESSAGES:
		_dropped += 1
		return
	arr.append(msg)


func to_dict() -> Dictionary:
	var d := data.duplicate(true)
	if _dropped > 0:
		d["dropped_messages"] = _dropped
	return d
