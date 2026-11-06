@tool
extends RefCounted
## Parser for the YAML subset Unity writes (.meta, .mat, .prefab, .unity, ...).
##
## All scalars stay strings (fileIDs are 64-bit, GUIDs can look numeric);
## convert with num(). Documents come back as
## { class_id:int, file_id:String, stripped:bool, type:String, data:Dictionary }.


static func parse_documents(text: String) -> Array:
	var docs := []
	var header = null
	var lines := []
	var started := false
	for raw in text.split("\n"):
		var line: String = raw.trim_suffix("\r")
		if line.begins_with("%"):
			continue
		if line.begins_with("---"):
			if started or _has_content(lines):
				docs.append(_make_doc(header, lines))
			header = line
			lines = []
			started = true
			continue
		lines.append(line)
	if started or _has_content(lines):
		docs.append(_make_doc(header, lines))
	return docs


## Parses a single-document YAML file (e.g. .meta) into a Dictionary.
static func parse(text: String) -> Dictionary:
	var docs := parse_documents(text)
	if docs.is_empty():
		return {}
	var d: Dictionary = docs[0]
	if d.type != "":
		return {d.type: d.data}
	return d.data


static func _has_content(lines: Array) -> bool:
	for l in lines:
		var s: String = l.strip_edges()
		if s != "" and not s.begins_with("#"):
			return true
	return false


static func _make_doc(header, lines: Array) -> Dictionary:
	var doc := {"class_id": -1, "file_id": "", "stripped": false, "type": "", "data": {}}
	if header != null:
		for part in String(header).substr(3).strip_edges().split(" ", false):
			if part.begins_with("!u!"):
				doc.class_id = int(part.substr(3))
			elif part.begins_with("&"):
				doc.file_id = part.substr(1)
			elif part == "stripped":
				doc.stripped = true
	var p := _Parser.new(lines)
	var root = p.parse_node(0)
	if root is Dictionary:
		if header != null and root.size() == 1:
			doc.type = root.keys()[0]
			var inner = root[doc.type]
			doc.data = inner if inner is Dictionary else {}
		else:
			doc.data = root
	return doc


# --- value helpers ------------------------------------------------------------

static func num(v, def := 0.0) -> float:
	if v is String and v.is_valid_float():
		return v.to_float()
	if v is float or v is int:
		return float(v)
	return def


static func guid_of(ref) -> String:
	if ref is Dictionary:
		return String(ref.get("guid", ""))
	return ""


static func id_of(ref) -> String:
	if ref is Dictionary:
		return String(ref.get("fileID", "0"))
	return "0"


static func vec3(v, def := Vector3.ZERO) -> Vector3:
	if not (v is Dictionary):
		return def
	return Vector3(num(v.get("x"), def.x), num(v.get("y"), def.y), num(v.get("z"), def.z))


static func quat(v) -> Quaternion:
	if not (v is Dictionary):
		return Quaternion.IDENTITY
	return Quaternion(num(v.get("x")), num(v.get("y")), num(v.get("z")), num(v.get("w"), 1.0))


static func color(v, def := Color.WHITE) -> Color:
	if not (v is Dictionary):
		return def
	return Color(num(v.get("r"), def.r), num(v.get("g"), def.g), num(v.get("b"), def.b), num(v.get("a"), def.a))


## Converts a Unity (left-handed) local transform to Godot (right-handed) by
## mirroring the X axis, matching how both engines import the same FBX.
static func to_godot_transform(pos: Vector3, rot: Quaternion, scale: Vector3) -> Transform3D:
	var p := Vector3(-pos.x, pos.y, pos.z)
	var q := Quaternion(rot.x, -rot.y, -rot.z, rot.w)
	if q.length_squared() < 0.000001:
		q = Quaternion.IDENTITY
	q = q.normalized()
	return Transform3D(Basis(q) * Basis.from_scale(scale), p)


static func to_godot_position(pos: Vector3) -> Vector3:
	return Vector3(-pos.x, pos.y, pos.z)


# --- block parser -------------------------------------------------------------

class _Parser:
	var ind := PackedInt32Array()
	var txt := PackedStringArray()
	var i := 0
	var _fs := ""
	var _fp := 0

	func _init(lines: Array) -> void:
		for l in lines:
			var s: String = l
			var st := s.strip_edges(true, false)
			if st == "" or st.begins_with("#"):
				continue
			ind.append(s.length() - st.length())
			txt.append(st.strip_edges(false, true))

	func at_end() -> bool:
		return i >= txt.size()

	func parse_node(min_indent: int):
		if at_end() or ind[i] < min_indent:
			return null
		var my := ind[i]
		if _is_seq_item(txt[i]):
			return parse_seq(my)
		return parse_map(my)

	func parse_map(indent: int) -> Dictionary:
		var d := {}
		while not at_end() and ind[i] == indent and not _is_seq_item(txt[i]):
			var kv := _split_key(txt[i])
			if kv.is_empty():
				i += 1
				continue
			var key: String = kv[0]
			var rest: String = kv[1]
			i += 1
			if rest == "":
				if not at_end() and ind[i] > indent:
					d[key] = parse_node(ind[i])
				elif not at_end() and ind[i] == indent and _is_seq_item(txt[i]):
					d[key] = parse_seq(indent)
				else:
					d[key] = ""
			else:
				d[key] = _value(rest, indent)
		return d

	func parse_seq(indent: int) -> Array:
		var a := []
		while not at_end() and ind[i] == indent and _is_seq_item(txt[i]):
			var line := txt[i]
			var rest := line.substr(1).strip_edges(true, false)
			if rest == "":
				i += 1
				if not at_end() and ind[i] > indent:
					a.append(parse_node(ind[i]))
				else:
					a.append("")
				continue
			var col := indent + (line.length() - rest.length())
			var inline_map := (not _starts_flow_or_quote(rest)) and not _split_key(rest).is_empty()
			if _is_seq_item(rest) or inline_map:
				# Re-anchor the item's content at its own column and parse it as a block.
				ind[i] = col
				txt[i] = rest
				a.append(parse_node(col))
			else:
				i += 1
				a.append(_value(rest, indent))
		return a

	func _value(rest: String, indent: int):
		var s := rest
		if s.begins_with("|") or s.begins_with(">"):
			var parts := PackedStringArray()
			while not at_end() and ind[i] > indent:
				parts.append(txt[i])
				i += 1
			return "\n".join(parts)
		var c := s[0]
		if c == "{" or c == "[":
			while not at_end() and ind[i] > indent and not _balanced(s):
				s += " " + txt[i]
				i += 1
			return _flow(s)
		if c == "'" or c == "\"":
			while not at_end() and ind[i] > indent and not _quote_closed(s):
				s += " " + txt[i]
				i += 1
			return _unquote(s)
		while not at_end() and ind[i] > indent:
			s += " " + txt[i]
			i += 1
		return s

	static func _is_seq_item(t: String) -> bool:
		return t == "-" or t.begins_with("- ")

	static func _starts_flow_or_quote(t: String) -> bool:
		return t.begins_with("{") or t.begins_with("[") or t.begins_with("'") or t.begins_with("\"")

	static func _split_key(t: String) -> Array:
		if _starts_flow_or_quote(t):
			return []
		var idx := t.find(": ")
		if idx > 0:
			return [t.substr(0, idx).strip_edges(), t.substr(idx + 2).strip_edges()]
		if t.ends_with(":"):
			return [t.substr(0, t.length() - 1).strip_edges(), ""]
		return []

	static func _balanced(s: String) -> bool:
		var depth := 0
		var q := ""
		for ch in s:
			if q != "":
				if ch == q:
					q = ""
				continue
			if ch == "'" or ch == "\"":
				q = ch
			elif ch == "{" or ch == "[":
				depth += 1
			elif ch == "}" or ch == "]":
				depth -= 1
		return depth <= 0

	static func _quote_closed(s: String) -> bool:
		return s.length() > 1 and s.ends_with(s[0])

	static func _unquote(s: String) -> String:
		var t := s.strip_edges()
		if t.length() >= 2 and t.begins_with("'") and t.ends_with("'"):
			return t.substr(1, t.length() - 2).replace("''", "'")
		if t.length() >= 2 and t.begins_with("\"") and t.ends_with("\""):
			return t.substr(1, t.length() - 2).c_unescape()
		return t

	# --- flow collections: {a: b, c: [1, 2]} ---

	func _flow(s: String):
		_fs = s
		_fp = 0
		return _fval()

	func _fws() -> void:
		while _fp < _fs.length() and (_fs[_fp] == " " or _fs[_fp] == "\t"):
			_fp += 1

	func _fval():
		_fws()
		if _fp >= _fs.length():
			return ""
		var c := _fs[_fp]
		if c == "{":
			_fp += 1
			var d := {}
			while _fp < _fs.length():
				_fws()
				if _fp >= _fs.length():
					break
				if _fs[_fp] == "}":
					_fp += 1
					break
				if _fs[_fp] == ",":
					_fp += 1
					continue
				var k := _fscalar(true)
				_fws()
				if _fp < _fs.length() and _fs[_fp] == ":":
					_fp += 1
					d[k] = _fval()
				else:
					d[k] = ""
			return d
		if c == "[":
			_fp += 1
			var a := []
			while _fp < _fs.length():
				_fws()
				if _fp >= _fs.length():
					break
				if _fs[_fp] == "]":
					_fp += 1
					break
				if _fs[_fp] == ",":
					_fp += 1
					continue
				a.append(_fval())
			return a
		return _fscalar(false)

	func _fscalar(is_key: bool) -> String:
		_fws()
		if _fp < _fs.length() and (_fs[_fp] == "'" or _fs[_fp] == "\""):
			var q := _fs[_fp]
			var qstart := _fp
			_fp += 1
			while _fp < _fs.length():
				if _fs[_fp] == q:
					if q == "'" and _fp + 1 < _fs.length() and _fs[_fp + 1] == "'":
						_fp += 2
						continue
					_fp += 1
					break
				_fp += 1
			return _unquote(_fs.substr(qstart, _fp - qstart))
		var start := _fp
		while _fp < _fs.length():
			var ch := _fs[_fp]
			if ch == "," or ch == "}" or ch == "]":
				break
			if is_key and ch == ":":
				break
			_fp += 1
		return _fs.substr(start, _fp - start).strip_edges()
