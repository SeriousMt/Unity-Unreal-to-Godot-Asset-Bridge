@tool
extends VBoxContainer
## Editor dock: pick a source, choose an output folder, import.

const Pipeline = preload("core/pipeline.gd")
const U = preload("core/util.gd")

var _source: LineEdit
var _out: LineEdit
var _prefabs: CheckBox
var _scenes: CheckBox
var _normals: OptionButton
var _prefer: OptionButton
var _log: RichTextLabel
var _dialog: EditorFileDialog


func _ready() -> void:
	add_theme_constant_override("separation", 6)

	add_child(_label("Source (.unitypackage, .zip, Unity folder, FBX/OBJ/glTF folder)"))
	var row := HBoxContainer.new()
	_source = LineEdit.new()
	_source.size_flags_horizontal = SIZE_EXPAND_FILL
	_source.placeholder_text = "/path/to/download.zip"
	_source.text_changed.connect(_on_source_changed)
	row.add_child(_source)
	row.add_child(_button("File…", _browse.bind(EditorFileDialog.FILE_MODE_OPEN_FILE)))
	row.add_child(_button("Folder…", _browse.bind(EditorFileDialog.FILE_MODE_OPEN_DIR)))
	add_child(row)

	add_child(_label("Output folder"))
	_out = LineEdit.new()
	_out.text = "res://imported/"
	add_child(_out)

	_prefabs = _check("Convert prefabs to scenes", true)
	_scenes = _check("Convert Unity scenes (.unity)", true)
	add_child(_prefabs)
	add_child(_scenes)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_child(_label("Normal maps (loose textures)"))
	_normals = OptionButton.new()
	for t in ["auto", "opengl", "directx"]:
		_normals.add_item(t)
	grid.add_child(_normals)
	grid.add_child(_label("If Unity + FBX both present"))
	_prefer = OptionButton.new()
	_prefer.add_item("auto")
	_prefer.add_item("all")
	_prefer.add_item("unreal")
	grid.add_child(_prefer)
	add_child(grid)

	var buttons := HBoxContainer.new()
	buttons.add_child(_button("Inspect", _on_inspect))
	var imp := _button("Import", _on_import)
	imp.size_flags_horizontal = SIZE_EXPAND_FILL
	buttons.add_child(imp)
	add_child(buttons)

	_log = RichTextLabel.new()
	_log.size_flags_vertical = SIZE_EXPAND_FILL
	_log.custom_minimum_size = Vector2(0, 240)
	_log.selection_enabled = true
	_log.scroll_following = true
	add_child(_log)


func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


func _button(t: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.pressed.connect(cb)
	return b


func _check(t: String, on: bool) -> CheckBox:
	var c := CheckBox.new()
	c.text = t
	c.button_pressed = on
	return c


func _browse(mode: int) -> void:
	if _dialog == null:
		_dialog = EditorFileDialog.new()
		_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
		_dialog.file_selected.connect(_on_picked)
		_dialog.dir_selected.connect(_on_picked)
		add_child(_dialog)
	_dialog.file_mode = mode
	_dialog.clear_filters()
	if mode == EditorFileDialog.FILE_MODE_OPEN_FILE:
		_dialog.add_filter("*.unitypackage,*.zip,*.fbx,*.glb,*.gltf,*.obj", "Assets")
	_dialog.popup_file_dialog()


func _on_picked(path: String) -> void:
	_source.text = path
	_on_source_changed(path)


func _on_source_changed(path: String) -> void:
	if _out.text == "res://imported/" or _out.text.begins_with("res://imported/"):
		var stem := path.trim_suffix("/").get_file().get_basename()
		_out.text = "res://imported/" + U.sanitize_file_name(stem).replace(" ", "_")


func _options() -> Dictionary:
	return {
		"prefabs": _prefabs.button_pressed,
		"scenes": _scenes.button_pressed,
		"normal_convention": _normals.get_item_text(_normals.selected),
		"prefer": _prefer.get_item_text(_prefer.selected),
	}


func _on_inspect() -> void:
	_log.clear()
	_print_report(Pipeline.inspect(_source.text.strip_edges(), _options()))


func _on_import() -> void:
	_log.clear()
	_log.append_text("Importing…\n")
	await get_tree().process_frame
	var report := Pipeline.import_source(_source.text.strip_edges(), _out.text.strip_edges(), _options())
	_print_report(report)
	var fs := EditorInterface.get_resource_filesystem()
	fs.scan()
	_log.append_text("\n[i]Godot is importing the new files…[/i]\n")
	while fs.is_scanning():
		await get_tree().process_frame
	_log.append_text("[color=green]Done.[/color] Output: %s\n" % _out.text)


func _print_report(r: Dictionary) -> void:
	for u in r.get("units", []):
		_log.append_text("[b]%s[/b] %s — %s\n" % [u.get("kind", ""), u.get("name", ""), u.get("status", "")])
		if u.has("reason"):
			_log.append_text("    %s\n" % u.reason)
	var stats: Dictionary = r.get("stats", {})
	if not stats.is_empty():
		var parts := PackedStringArray()
		for k in stats:
			parts.append("%s: %s" % [k, stats[k]])
		_log.append_text("\n" + ", ".join(parts) + "\n")
	for e in r.get("errors", []):
		_log.append_text("[color=red]error:[/color] %s\n" % e)
	for w in r.get("warnings", []):
		_log.append_text("[color=yellow]warning:[/color] %s\n" % w)
	for h in r.get("hints", []):
		_log.append_text("[color=cyan]hint:[/color] %s\n" % h)
