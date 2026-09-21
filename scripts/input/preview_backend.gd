extends "res://scripts/input/input_backend.gd"
class_name PreviewBackend
## A safe, do-nothing backend. It never touches the real OS; it only records
## a virtual cursor position so the overlay / status can visualise the loop.
## Use this while you build and test a loop.

var virtual_cursor: Vector2i = Vector2i.ZERO
## Set by interrupt(): a captured action's dwell under way ends now - or
## one about to start (the worker thread not yet running) does not start.
## `_cut_short_at` is when: a flag nobody consumed (the dwell had just
## ended) is forgotten after CUT_SHORT_MS rather than cutting a later run's
## action short, as the real backend does.
var _cut_short := false
var _cut_short_at: int = 0
const CUT_SHORT_MS := 2000

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

func scroll(_dir: int, _notches: int, _ms: int = 0, _uneven: bool = false) -> void:
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
	# The dwell is waited in slices so a stop (or a quit, which joins this
	# thread) is not held up for the rest of it. An interrupt from before
	# this thread got going counts (the flag is consumed at the end, not
	# cleared here); a stale one is forgotten.
	var now := Time.get_ticks_msec()
	if _cut_short and now - _cut_short_at > CUT_SHORT_MS:
		_cut_short = false
	var until := now + ms
	while Time.get_ticks_msec() < until and not _cut_short:
		OS.delay_msec(mini(10, maxi(1, until - Time.get_ticks_msec())))
	virtual_cursor = saved
	var cut := _cut_short
	_cut_short = false
	# Cut short is no result, as for the real backend.
	return [] if cut else [saved, saved]


func interrupt() -> void:
	_cut_short_at = Time.get_ticks_msec()
	_cut_short = true
