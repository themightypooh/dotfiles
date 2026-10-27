extends Node3D
## Viewer: a wrist pet device sitting on a display stand. Its screen is a true
## window: the room is rendered from where the viewer's eye actually is relative
## to the glass (off-axis frustum whose near plane is the screen rectangle), at
## low resolution, and the result is mapped 1:1 onto the screen quad.
##
## Controls: one-finger drag orbits, two-finger pinch zooms, double-tap resets,
## tilting the phone (gyro) nudges the orbit so you can peek into the screen.

const SCREEN_W := 0.9
const SCREEN_H := 1.1
const PIX := Vector2i(112, 137)       # room resolution, same aspect as the glass
const ROOM_K := 3.0                  # room metres per screen unit
const ROOM_W := SCREEN_W * ROOM_K
const ROOM_H := SCREEN_H * ROOM_K
const ROOM_L := 3.4
const Y0 := -ROOM_H / 2.0            # room floor
const LAMP := Vector3(0.0, 0.7, -1.7)

const ROOM_SHADER := preload("res://room.gdshader")
const GRID_SHADER := preload("res://grid.gdshader")

const HOME := Vector3(0.3, 0.28, 4.4) # yaw, pitch, distance

var cam: Camera3D
var target := Vector3.ZERO
var screen_frame: Node3D
var room_cam: Camera3D

var yaw := HOME.x
var pitch := HOME.y
var dist := HOME.z
var gyro_yaw := 0.0
var gyro_pitch := 0.0
var touches := {}
var last_tap_ms := 0
var pinch_start := 0.0
var pinch_dist0 := 0.0

var shot_path := ""
var shot_frames := 0


func _ready() -> void:
	DisplayServer.screen_set_keep_on(true)
	_build_space()
	_build_stand_and_device()
	_parse_args()
	_update_camera(0.0)


# ---------------------------------------------------------------- viewing space

func _build_space() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.035, 0.038, 0.045)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.58, 0.65)
	env.ambient_light_energy = 0.45
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-55), deg_to_rad(35), 0)
	sun.light_energy = 0.9
	sun.shadow_enabled = true
	add_child(sun)

	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(60, 60)
	floor_mi.mesh = pm
	var gm := ShaderMaterial.new()
	gm.shader = GRID_SHADER
	floor_mi.material_override = gm
	add_child(floor_mi)

	cam = Camera3D.new()
	cam.fov = 50
	cam.near = 0.05
	cam.far = 100
	add_child(cam)


func _std(c: Color, rough := 0.7, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.metallic = metal
	return m


func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation = rot
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _build_stand_and_device() -> void:
	var metal := _std(Color(0.32, 0.33, 0.36), 0.35, 0.6)
	var felt := _std(Color(0.16, 0.15, 0.15), 0.95)

	# pedestal
	var base := CylinderMesh.new()
	base.top_radius = 0.9
	base.bottom_radius = 0.95
	base.height = 0.06
	_mesh(self, base, Vector3(0, 0.03, 0), metal)
	var col := CylinderMesh.new()
	col.top_radius = 0.1
	col.bottom_radius = 0.13
	col.height = 1.5
	_mesh(self, col, Vector3(0, 0.81, 0), metal)
	var plate := BoxMesh.new()
	plate.size = Vector3(1.7, 0.06, 1.0)
	_mesh(self, plate, Vector3(0, 1.59, 0), metal)

	# watch cushion lying across the plate
	var cush_c := Vector3(0, 1.62 + 0.42, 0)
	var cush := CapsuleMesh.new()
	cush.radius = 0.42
	cush.height = 1.6
	_mesh(self, cush, cush_c, felt, Vector3(0, 0, PI / 2))

	# strap wrapped round the cushion
	var strap := TorusMesh.new()
	strap.inner_radius = 0.42
	strap.outer_radius = 0.47
	strap.rings = 48
	var sm := _mesh(self, strap, cush_c, _std(Color(0.1, 0.09, 0.08), 0.6), Vector3(0, 0, PI / 2))
	sm.scale = Vector3(1, 14.0, 1)

	# device body, sitting on the front of the strap, tilted back
	var tilt := deg_to_rad(22)
	var depth := 0.3
	var dir := Vector3(0, sin(tilt), cos(tilt))
	var device := Node3D.new()
	device.position = cush_c + dir * (0.47 + depth / 2.0)
	device.rotation.x = -tilt
	add_child(device)
	target = device.position

	var shell := _std(Color(0.12, 0.115, 0.11), 0.45)
	var body := BoxMesh.new()
	body.size = Vector3(1.22, 1.44, depth)
	_mesh(device, body, Vector3.ZERO, shell)
	# thin raised lip around the glass
	var lip := _std(Color(0.07, 0.065, 0.06), 0.3)
	var zf := depth / 2.0
	for s in [-1, 1]:
		var lv := BoxMesh.new()
		lv.size = Vector3(0.025, SCREEN_H + 0.05, 0.02)
		_mesh(device, lv, Vector3(s * (SCREEN_W / 2 + 0.0125), 0, zf + 0.01), lip)
		var lh := BoxMesh.new()
		lh.size = Vector3(SCREEN_W + 0.05, 0.025, 0.02)
		_mesh(device, lh, Vector3(0, s * (SCREEN_H / 2 + 0.0125), zf + 0.01), lip)
	# three buttons on the right side
	var btn_m := _std(Color(0.55, 0.3, 0.05), 0.4)
	for i in 3:
		var b := CylinderMesh.new()
		b.top_radius = 0.06
		b.bottom_radius = 0.06
		b.height = 0.05
		_mesh(device, b, Vector3(0.61 + 0.02, 0.3 - i * 0.3, 0), btn_m, Vector3(0, 0, PI / 2))

	screen_frame = Node3D.new()
	screen_frame.position = Vector3(0, 0, zf + 0.001)
	device.add_child(screen_frame)

	# the room lives in its own world inside a low-res SubViewport
	var vp := SubViewport.new()
	vp.size = PIX
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.msaa_3d = Viewport.MSAA_DISABLED
	add_child(vp)
	var room := Node3D.new()
	vp.add_child(room)
	_build_room(room)
	room_cam = Camera3D.new()
	room_cam.projection = Camera3D.PROJECTION_FRUSTUM
	room_cam.keep_aspect = Camera3D.KEEP_HEIGHT
	var renv := Environment.new()
	renv.background_mode = Environment.BG_COLOR
	renv.background_color = Color.BLACK
	room_cam.environment = renv
	vp.add_child(room_cam)

	var scr := QuadMesh.new()
	scr.size = Vector2(SCREEN_W, SCREEN_H)
	var scr_m := StandardMaterial3D.new()
	scr_m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	scr_m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	scr_m.albedo_texture = vp.get_texture()
	_mesh(screen_frame, scr, Vector3.ZERO, scr_m)

	# faint glass so it reads as a pane, not a sticker
	var glass := _std(Color(1, 1, 1, 0.05), 0.08)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.metallic_specular = 1.0
	_mesh(screen_frame, scr, Vector3(0, 0, 0.006), glass)

	# the screen spills a little amber light onto the stand
	var spill := OmniLight3D.new()
	spill.light_color = Color(1.0, 0.6, 0.2)
	spill.light_energy = 0.6
	spill.omni_range = 1.6
	spill.position = Vector3(0, 0, 0.35)
	screen_frame.add_child(spill)


# ---------------------------------------------------------------------- room

func _rm(tone: float, pattern := 0, glow := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = ROOM_SHADER
	m.set_shader_parameter("tone", tone)
	m.set_shader_parameter("pattern", pattern)
	m.set_shader_parameter("glow", glow)
	m.set_shader_parameter("lamp_pos", LAMP)
	return m


## Box by its bottom-centre (furniture sits on things), size in metres.
func _bx(p: Node3D, size: Vector3, bottom: Vector3, tone: float, rot := Vector3.ZERO, pattern := 0, glow := 0.0) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.rotation = rot
	mi.position = bottom + mi.basis * Vector3(0, size.y / 2.0, 0)
	mi.material_override = _rm(tone, pattern, glow)
	p.add_child(mi)
	return mi


func _cy(p: Node3D, r_top: float, r_bot: float, h: float, bottom: Vector3, tone: float, glow := 0.0, segs := 10) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = r_top
	cm.bottom_radius = r_bot
	cm.height = h
	cm.radial_segments = segs
	cm.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.position = bottom + Vector3(0, h / 2.0, 0)
	mi.material_override = _rm(tone, 0, glow)
	p.add_child(mi)
	return mi


func _group(p: Node3D, pos: Vector3, yaw_deg := 0.0) -> Node3D:
	var g := Node3D.new()
	g.position = pos
	g.rotation.y = deg_to_rad(yaw_deg)
	p.add_child(g)
	return g


func _build_room(r: Node3D) -> void:
	var hw := ROOM_W / 2.0
	var top := ROOM_H / 2.0
	var t := 0.2  # shell thickness, all of it outside the room volume

	# shell: the opening is exactly the glass, so no edge can ever show void
	_bx(r, Vector3(ROOM_W + 2 * t, t, ROOM_L + t), Vector3(0, Y0 - t, -ROOM_L / 2 - t / 2), 0.62, Vector3.ZERO, 1)
	var ceil := _bx(r, Vector3(ROOM_W + 2 * t, t, ROOM_L + t), Vector3(0, top, -ROOM_L / 2 - t / 2), 0.4, Vector3.ZERO, 4)
	ceil.name = "Ceiling"
	_bx(r, Vector3(ROOM_W + 2 * t, ROOM_H + 2 * t, t), Vector3(0, Y0 - t, -ROOM_L - t / 2), 0.42, Vector3.ZERO, 2)
	_bx(r, Vector3(t, ROOM_H, ROOM_L), Vector3(-hw - t / 2, Y0, -ROOM_L / 2), 0.38, Vector3.ZERO, 2)

	# right wall with a doorway cut into its back half
	var dz0 := -2.0
	var dz1 := -2.85
	var dh := 2.15
	_bx(r, Vector3(t, ROOM_H, -dz0), Vector3(hw + t / 2, Y0, dz0 / 2), 0.38, Vector3.ZERO, 2)
	_bx(r, Vector3(t, ROOM_H, ROOM_L + dz1), Vector3(hw + t / 2, Y0, (dz1 - ROOM_L) / 2), 0.38, Vector3.ZERO, 2)
	_bx(r, Vector3(t, ROOM_H - dh, dz0 - dz1), Vector3(hw + t / 2, Y0 + dh, (dz0 + dz1) / 2), 0.38, Vector3.ZERO, 2)
	# dark hallway beyond it
	var hall := _group(r, Vector3(hw + 0.8, Y0, (dz0 + dz1) / 2))
	_bx(hall, Vector3(1.6, 0.05, 1.6), Vector3(0, -0.05, 0), 0.25)
	_bx(hall, Vector3(0.1, dh + 0.3, 1.6), Vector3(0.8, 0, 0), 0.18)
	_bx(hall, Vector3(1.6, dh + 0.3, 0.1), Vector3(0, 0, -0.85), 0.2)
	_bx(hall, Vector3(1.6, dh + 0.3, 0.1), Vector3(0, 0, 0.85), 0.2)
	_bx(hall, Vector3(1.6, 0.1, 1.8), Vector3(0, dh, 0), 0.15)
	# door frame trim, and the door itself swung open into the hall
	_bx(r, Vector3(0.06, dh + 0.08, 0.08), Vector3(hw - 0.02, Y0, dz0 + 0.04), 0.8)
	_bx(r, Vector3(0.06, dh + 0.08, 0.08), Vector3(hw - 0.02, Y0, dz1 - 0.04), 0.8)
	_bx(r, Vector3(0.06, 0.08, dz0 - dz1 + 0.16), Vector3(hw - 0.02, Y0 + dh, (dz0 + dz1) / 2), 0.8)
	var door := _group(r, Vector3(hw + t, Y0, dz0), -70)
	_bx(door, Vector3(0.05, dh - 0.02, dz0 - dz1 - 0.05), Vector3(0, 0, (dz1 - dz0) / 2), 0.62)
	_cy(door, 0.035, 0.035, 0.03, Vector3(-0.04, 1.0, (dz1 - dz0) * 0.85), 0.95)

	# baseboards
	_bx(r, Vector3(ROOM_W, 0.14, 0.04), Vector3(0, Y0, -ROOM_L + 0.02), 0.82)
	_bx(r, Vector3(0.04, 0.14, ROOM_L), Vector3(-hw + 0.02, Y0, -ROOM_L / 2), 0.82)
	_bx(r, Vector3(0.04, 0.14, -dz0), Vector3(hw - 0.02, Y0, dz0 / 2), 0.82)

	# ceiling beams + hanging lamp
	for z in [-0.7, -1.9, -3.0]:
		_bx(r, Vector3(ROOM_W, 0.16, 0.16), Vector3(0, top - 0.16, z), 0.42)
	_cy(r, 0.008, 0.008, top - LAMP.y - 0.12, Vector3(LAMP.x, LAMP.y + 0.12, LAMP.z), 0.2, 0.0, 4)
	_cy(r, 0.06, 0.26, 0.2, Vector3(LAMP.x, LAMP.y - 0.06, LAMP.z), 0.7, 0.0, 12)
	_cy(r, 0.07, 0.07, 0.1, Vector3(LAMP.x, LAMP.y - 0.1, LAMP.z), 0.0, 1.2, 8)

	_build_window(r)
	_build_picture(r)
	_build_bookshelf(r)
	_build_rug_table_chair(r)
	_build_floor_lamp(r)
	_build_stool(r)
	_build_plant(r)


func _build_window(r: Node3D) -> void:
	var w := _group(r, Vector3(0.55, -0.15, -ROOM_L))
	var ww := 0.85
	var wh := 1.05
	_bx(w, Vector3(ww, wh, 0.02), Vector3(0, 0, 0.01), 0.0, Vector3.ZERO, 0, 0.92)  # sky
	# moon + a couple of stars, slightly brighter than the sky
	_cy(w, 0.07, 0.07, 0.01, Vector3(0.22, 0.74, 0.03), 0.0, 1.3, 10).rotation.x = PI / 2
	_bx(w, Vector3(ww + 0.12, 0.06, 0.08), Vector3(0, -0.06, 0.04), 0.85)
	_bx(w, Vector3(ww + 0.12, 0.06, 0.08), Vector3(0, wh, 0.04), 0.85)
	_bx(w, Vector3(0.06, wh, 0.08), Vector3(-ww / 2 - 0.03, 0, 0.04), 0.85)
	_bx(w, Vector3(0.06, wh, 0.08), Vector3(ww / 2 + 0.03, 0, 0.04), 0.85)
	_bx(w, Vector3(0.035, wh, 0.05), Vector3(0, 0, 0.04), 0.7)
	_bx(w, Vector3(ww, 0.035, 0.05), Vector3(0, wh * 0.55, 0.04), 0.7)
	_bx(w, Vector3(ww + 0.25, 0.05, 0.18), Vector3(0, -0.08, 0.09), 0.9)  # sill
	_bx(w, Vector3(0.08, 0.1, 0.08), Vector3(-0.25, -0.03, 0.1), 0.75)     # little jar on the sill


func _build_picture(r: Node3D) -> void:
	var p := _group(r, Vector3(-0.75, 0.6, -ROOM_L))
	_bx(p, Vector3(0.62, 0.46, 0.04), Vector3(0, 0, 0.02), 0.85)
	_bx(p, Vector3(0.52, 0.36, 0.02), Vector3(0, 0.05, 0.04), 0.35)
	# two mountains and a sun inside the frame
	_bx(p, Vector3(0.2, 0.2, 0.01), Vector3(-0.08, 0.02, 0.05), 0.7, Vector3(0, 0, PI / 4))
	_bx(p, Vector3(0.15, 0.15, 0.01), Vector3(0.12, 0.04, 0.052), 0.55, Vector3(0, 0, PI / 4))
	_cy(p, 0.04, 0.04, 0.01, Vector3(0.15, 0.3, 0.05), 0.95).rotation.x = PI / 2


func _build_bookshelf(r: Node3D) -> void:
	var sw := 0.95
	var sh := 1.95
	var sd := 0.32
	var s := _group(r, Vector3(-0.72, Y0, -ROOM_L + sd / 2 + 0.01))
	var wood := 0.66
	_bx(s, Vector3(0.05, sh, sd), Vector3(-sw / 2 + 0.025, 0, 0), wood)
	_bx(s, Vector3(0.05, sh, sd), Vector3(sw / 2 - 0.025, 0, 0), wood)
	_bx(s, Vector3(sw, 0.05, sd), Vector3(0, sh - 0.05, 0), wood)
	_bx(s, Vector3(sw - 0.1, 0.02, 0.02), Vector3(0, 0, -sd / 2 + 0.01), 0.3)
	_bx(s, Vector3(sw - 0.1, sh, 0.02), Vector3(0, 0, -sd / 2 + 0.01), 0.3)  # back panel
	var shelves := [0.08, 0.55, 1.02, 1.48]
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in shelves.size():
		var y: float = shelves[i]
		_bx(s, Vector3(sw - 0.1, 0.04, sd - 0.02), Vector3(0, y - 0.04, 0.01), wood)
		var x := -sw / 2 + 0.07
		var limit := sw / 2 - 0.07
		var gap_at := rng.randi_range(3, 7)
		var n := 0
		while x < limit - 0.04:
			var bw := rng.randf_range(0.035, 0.075)
			var bh := rng.randf_range(0.24, 0.4)
			if x + bw > limit:
				break
			if n == gap_at:
				# one book leaning into the gap
				var lean := 0.32
				_bx(s, Vector3(bw, bh, 0.22), Vector3(x + sin(lean) * bh * 0.5, y, 0.02), rng.randf_range(0.4, 0.9), Vector3(0, 0, -lean))
				x += bh * sin(lean) + bw + 0.02
			else:
				_bx(s, Vector3(bw, bh, rng.randf_range(0.19, 0.25)), Vector3(x + bw / 2, y, 0.02), rng.randf_range(0.35, 0.95))
				x += bw + 0.004
			n += 1
	# a box and a small vase on top
	_bx(s, Vector3(0.25, 0.14, 0.2), Vector3(-0.2, sh, 0), 0.5)
	_cy(s, 0.04, 0.06, 0.18, Vector3(0.22, sh, 0), 0.85)


func _build_rug_table_chair(r: Node3D) -> void:
	var rug := _bx(r, Vector3(1.7, 0.02, 1.35), Vector3(0.15, Y0, -1.85), 0.75, Vector3.ZERO, 3)
	rug.material_override.set_shader_parameter("rug_half", Vector3(0.85, 0.01, 0.675))

	# table: top overhangs an apron on four legs
	var tb := _group(r, Vector3(0.45, Y0, -2.05))
	var tw := 1.0
	var td := 0.62
	var th := 0.74
	var wood := 0.7
	_bx(tb, Vector3(tw, 0.05, td), Vector3(0, th - 0.05, 0), 0.8)
	_bx(tb, Vector3(tw - 0.16, 0.09, td - 0.16), Vector3(0, th - 0.14, 0), 0.5)
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			_bx(tb, Vector3(0.055, th - 0.05, 0.055), Vector3(sx * (tw / 2 - 0.1), 0, sz * (td / 2 - 0.1)), wood)
	# closed book: cover, lighter page block
	var bk := _group(tb, Vector3(-0.2, th, 0.05), 18)
	_bx(bk, Vector3(0.3, 0.012, 0.22), Vector3(0, 0, 0), 0.45)
	_bx(bk, Vector3(0.28, 0.035, 0.2), Vector3(0.008, 0.012, 0), 0.95)
	_bx(bk, Vector3(0.3, 0.012, 0.22), Vector3(0, 0.047, 0), 0.45)
	# cup with handle
	_cy(tb, 0.05, 0.042, 0.11, Vector3(0.25, th, 0.08), 0.9, 0.0, 10)
	_cy(tb, 0.043, 0.043, 0.005, Vector3(0.25, th + 0.105, 0.08), 0.25, 0.0, 10)
	_bx(tb, Vector3(0.025, 0.06, 0.015), Vector3(0.315, th + 0.025, 0.08), 0.85)

	# chair pulled out in front of the table, slatted back towards us
	var ch := _group(r, Vector3(0.3, Y0, -1.35), -14)
	var sh := 0.45
	var cw := 0.44
	var cd := 0.42
	_bx(ch, Vector3(cw, 0.045, cd), Vector3(0, sh - 0.045, 0), 0.78)
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			var hgt := sh - 0.045
			if sz == 1:
				hgt = 1.0  # back legs run up into the back posts
			_bx(ch, Vector3(0.04, hgt, 0.04), Vector3(sx * (cw / 2 - 0.03), 0, sz * (cd / 2 - 0.03)), 0.62)
	_bx(ch, Vector3(cw, 0.07, 0.035), Vector3(0, 0.93, cd / 2 - 0.03), 0.75)  # top rail
	for i in 3:
		_bx(ch, Vector3(0.045, 0.45, 0.02), Vector3(-0.1 + i * 0.1, sh, cd / 2 - 0.03), 0.7)
	_bx(ch, Vector3(cw - 0.06, 0.03, 0.03), Vector3(0, 0.12, 0), 0.5)  # stretcher


func _build_floor_lamp(r: Node3D) -> void:
	var l := _group(r, Vector3(-1.05, Y0, -1.25))
	_cy(l, 0.13, 0.15, 0.04, Vector3.ZERO, 0.6)
	_cy(l, 0.017, 0.017, 1.45, Vector3(0, 0.04, 0), 0.7, 0.0, 6)
	_cy(l, 0.13, 0.22, 0.28, Vector3(0, 1.4, 0), 0.6, 0.35, 12)


func _build_stool(r: Node3D) -> void:
	var s := _group(r, Vector3(-0.72, Y0, -0.55), 20)
	_cy(s, 0.2, 0.2, 0.05, Vector3(0, 0.5, 0), 0.85, 0.0, 14)
	for i in 3:
		var a := TAU * i / 3.0
		var leg := _bx(s, Vector3(0.04, 0.52, 0.04), Vector3(cos(a) * 0.13, 0, sin(a) * 0.13), 0.6)
		leg.rotation = Vector3(-sin(a) * 0.12, 0, cos(a) * 0.12)
	_bx(s, Vector3(0.24, 0.025, 0.025), Vector3(0, 0.18, 0), 0.5)


func _build_plant(r: Node3D) -> void:
	var p := _group(r, Vector3(0.88, Y0, -0.5))
	_cy(p, 0.17, 0.11, 0.36, Vector3.ZERO, 0.72, 0.0, 12)          # tapered pot
	_cy(p, 0.19, 0.19, 0.05, Vector3(0, 0.34, 0), 0.85, 0.0, 12)    # rim
	_cy(p, 0.16, 0.16, 0.01, Vector3(0, 0.37, 0), 0.22, 0.0, 12)    # soil
	_cy(p, 0.012, 0.015, 0.3, Vector3(0, 0.37, 0), 0.4, 0.0, 5)     # stem
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 9:
		var a := TAU * i / 9.0 + rng.randf_range(-0.2, 0.2)
		var len := rng.randf_range(0.32, 0.5)
		var up := rng.randf_range(0.5, 1.0)
		var leaf := Node3D.new()
		leaf.position = Vector3(0, 0.42 + rng.randf_range(0.0, 0.2), 0)
		leaf.rotation = Vector3(0, a, 0)
		p.add_child(leaf)
		# leaf blade lies along +X, pitched up, tip drooping via a second piece
		var b1 := _bx(leaf, Vector3(len * 0.6, 0.012, 0.09), Vector3.ZERO, rng.randf_range(0.75, 1.0), Vector3(0, 0, up))
		b1.position = Vector3(cos(up) * len * 0.3, sin(up) * len * 0.3, 0)
		var tip := Vector3(cos(up) * len * 0.6, sin(up) * len * 0.6, 0)
		var b2 := _bx(leaf, Vector3(len * 0.45, 0.012, 0.06), Vector3.ZERO, rng.randf_range(0.7, 0.95), Vector3(0, 0, up - 0.9))
		b2.position = tip + Vector3(cos(up - 0.9) * len * 0.22, sin(up - 0.9) * len * 0.22, 0)


# --------------------------------------------------------------------- input

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventScreenTouch:
		if e.pressed:
			touches[e.index] = e.position
			if touches.size() == 1:
				var now := Time.get_ticks_msec()
				if now - last_tap_ms < 300:
					yaw = HOME.x
					pitch = HOME.y
					dist = HOME.z
				last_tap_ms = now
			elif touches.size() == 2:
				pinch_dist0 = _pinch_span()
				pinch_start = dist
		else:
			touches.erase(e.index)
	elif e is InputEventScreenDrag:
		touches[e.index] = e.position
		if touches.size() == 1:
			var k := 4.0 / get_viewport().get_visible_rect().size.x
			yaw -= e.relative.x * k
			pitch += e.relative.y * k
		elif touches.size() == 2 and pinch_dist0 > 1.0:
			dist = pinch_start * pinch_dist0 / max(_pinch_span(), 1.0)
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist *= 0.9
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist /= 0.9


func _pinch_span() -> float:
	var pts := touches.values()
	return (pts[0] as Vector2).distance_to(pts[1])


func _process(delta: float) -> void:
	_update_camera(delta)
	if shot_path != "":
		shot_frames += 1
		if shot_frames == 8:
			get_viewport().get_texture().get_image().save_png(shot_path)
			get_tree().quit()


func _update_camera(delta: float) -> void:
	# Gyro: Android axes, x right / y up / z out of the glass, rad/s. Turning the
	# phone's right edge away (+y) should move the eye to the right; top edge
	# away (-x) moves it up. Integrated, then leaked back so it never drifts.
	var g := Input.get_gyroscope()
	gyro_yaw += g.y * delta * 1.6
	gyro_pitch -= g.x * delta * 1.6
	var leak := exp(-delta / 2.5)
	gyro_yaw = clamp(gyro_yaw * leak, -0.7, 0.7)
	gyro_pitch = clamp(gyro_pitch * leak, -0.5, 0.5)

	pitch = clamp(pitch, -0.25, 1.25)
	yaw = clamp(yaw, -1.4, 1.4)
	dist = clamp(dist, 1.2, 8.0)
	var y := yaw + gyro_yaw
	var p := clampf(pitch + gyro_pitch, -0.3, 1.35)
	var off := Basis(Vector3.UP, y) * Basis(Vector3.RIGHT, -p) * Vector3(0, 0, dist)
	cam.position = target + off
	cam.look_at(target, Vector3.UP)
	_update_room_camera()


## Off-axis "window" projection: the room camera sits where the real eye is,
## expressed in the glass's own frame and scaled into room metres, looks straight
## down the glass normal, and its near plane is exactly the glass rectangle.
func _update_room_camera() -> void:
	var e := screen_frame.global_transform.affine_inverse() * cam.global_position
	e *= ROOM_K
	e.z = max(e.z, 0.05)  # behind the glass there is nothing sensible to show
	room_cam.position = e
	room_cam.rotation = Vector3.ZERO
	room_cam.set_frustum(ROOM_H, Vector2(-e.x, -e.y), e.z, e.z + ROOM_L + 3.0)


func _parse_args() -> void:
	# desktop QA only: --orbit=yaw,pitch,dist --shot=out.png
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--orbit="):
			var v := a.substr(8).split(",")
			yaw = float(v[0])
			pitch = float(v[1])
			dist = float(v[2])
		elif a.begins_with("--shot="):
			shot_path = a.substr(7)
