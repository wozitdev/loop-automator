extends "res://scripts/input/input_backend.gd"
class_name PreviewBackend
## A safe, do-nothing backend. It never touches the real OS; it only records
## a virtual cursor position so the overlay / status can visualise the loop.
## Use this while you build and test a loop.

var virtual_cursor: Vector2i = Vector2i.ZERO

func backend_name() -> String:
	return "Preview (no OS input)"

func is_real() -> bool:
	return false

func move_to(pos: Vector2i) -> void:
	virtual_cursor = pos

func mouse_button(_button: int, _pressed: bool, pos: Vector2i) -> void:
	virtual_cursor = pos

func send_keys(_text: String) -> void:
	pass

func get_pixel(pos: Vector2i) -> Color:
	# Cannot read foreign windows safely; sample Godot's own viewport if the
	# point happens to be inside this window, otherwise return transparent.
	return Color(0, 0, 0, 0)

func get_cursor_pos() -> Vector2i:
	return virtual_cursor

func run_captured(kind: String, _button: int, from: Vector2i, to: Vector2i, ms: int, _ghost: bool, _path: PackedVector2Array) -> Array:
	# Nobody moves the virtual cursor but us (and there is nothing to ghost), so
	# the cursor simply ends up back where it started. The travel itself is
	# drawn by playback (the tracker walks the path meanwhile).
	var saved := virtual_cursor
	virtual_cursor = to if kind == "drag" else from
	if ms > 0:
		OS.delay_msec(ms)
	virtual_cursor = saved
	return [saved, saved]
