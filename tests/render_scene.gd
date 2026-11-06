extends SceneTree
## Renders a scene to PNG for visual checks (run under xvfb-run with opengl3):
##   xvfb-run -a godot --path <project> --rendering-driver opengl3 --resolution 960x720 \
##       --script res://render_scene.gd -- res://scene.tscn out.png [yaw_degrees] [animation]

var _out := ""
var _frames := 0


func _initialize() -> void:
	pass


func _setup() -> void:
	var args := OS.get_cmdline_user_args()
	_out = args[1]
	var yaw := deg_to_rad(float(args[2])) if args.size() > 2 else deg_to_rad(35.0)
	var scene: Node3D = (load(args[0]) as PackedScene).instantiate()
	var world := Node3D.new()
	root.add_child(world)
	world.add_child(scene)
	if args.size() > 3:
		for ap in scene.find_children("*", "AnimationPlayer", true, false):
			if ap.has_animation(args[3]):
				ap.play(args[3])
				ap.seek(ap.current_animation_length * 0.4, true)
				ap.pause()
				print("ANIM ", args[3], " on ", ap.name)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.32, 0.36, 0.42)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.78, 0.85)
	e.ambient_light_energy = 0.6
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.environment = e
	world.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, -30, 0)
	sun.light_energy = 1.4
	world.add_child(sun)

	var box := _aabb(scene)
	var center := box.get_center()
	var radius := maxf(box.size.length() * 0.5, 0.01)
	var cam := Camera3D.new()
	cam.fov = 40
	cam.far = radius * 20.0 + 100.0
	cam.near = radius * 0.01
	var dir := Vector3(sin(yaw), 0.35, cos(yaw)).normalized()
	world.add_child(cam)
	cam.look_at_from_position(center + dir * radius / sin(deg_to_rad(cam.fov * 0.5)) * 1.05, center)
	cam.current = true
	print("AABB ", box)


func _aabb(n: Node) -> AABB:
	var out := AABB()
	var first := true
	for v in _visuals(n):
		var b: AABB = v.global_transform * v.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out


func _visuals(n: Node) -> Array:
	var a := []
	if n is VisualInstance3D and n.visible and not (n is Light3D):
		a.append(n)
	for c in n.get_children():
		a.append_array(_visuals(c))
	return a


func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 2:
		_setup()
	if _frames == 30:
		root.get_texture().get_image().save_png(_out)
		return true
	return false
