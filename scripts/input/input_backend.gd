extends RefCounted
class_name InputBackend
## Abstract interface that turns LoopActions into real input.
## Concrete backends implement OS-specific behaviour.

## Clicks and keys that would land on a window of this process are skipped
## (0 = none). Loop Automator sets its own pid here while ~Self is off, so
## a loop cannot drive the app that is running it.
var avoid_pid: int = 0
## True when the most recent input command was skipped because of `avoid_pid`.
var last_skipped: bool = false

func backend_name() -> String:
	return "Abstract"

## True if this backend can actually drive the OS (vs. preview-only).
func is_real() -> bool:
	return false

func move_to(pos: Vector2i) -> void:
	pass

## Moves the cursor through `path` (see MousePath) over `ms`, blocking for
## the whole travel (callers run it off the main thread). The default just
## lands on the last point.
func move_path(path: PackedVector2Array, _ms: int) -> void:
	if not path.is_empty():
		move_to(Vector2i(path[path.size() - 1].round()))

func mouse_button(_button: int, _pressed: bool, _pos: Vector2i) -> void:
	pass

func click(button: int, pos: Vector2i) -> void:
	mouse_button(button, true, pos)
	mouse_button(button, false, pos)

func send_keys(_text: String) -> void:
	pass

## Returns the colour of a single screen pixel, or a transparent colour
## if the backend cannot read the screen.
func get_pixel(_pos: Vector2i) -> Color:
	return Color(0, 0, 0, 0)

## Returns the screen contents of `rect` as an image (RGB, one texel per screen
## pixel), or null if the backend cannot read the screen.
func read_rect(_rect: Rect2i) -> Image:
	return null

## Looks for `color` (± `tolerance` per channel) in the screen rect, checking
## the centre pixel first and then every `step`-th pixel. Returns
## {"hit": Vector2i, "centre": Color} — hit is (-1, -1) when nothing matched,
## centre is the colour read at the rect's centre (for diagnostics) — or an
## empty Dictionary if the screen could not be read. Backends that can do the
## scan themselves override this; the default reads the rect and scans it here.
func find_color(rect: Rect2i, color: Color, tolerance: int, step: int) -> Dictionary:
	var img := read_rect(rect)
	if img == null:
		return {}
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var w := img.get_width()
	var h := img.get_height()
	var data := img.get_data()
	var er := color.r8
	var eg := color.g8
	var eb := color.b8
	var centre := Vector2i(w / 2, h / 2)
	var result := {"hit": Vector2i(-1, -1), "centre": img.get_pixelv(centre)}
	if _matches(data, (centre.y * w + centre.x) * 4, er, eg, eb, tolerance):
		result["hit"] = rect.position + centre
		return result
	var y := 0
	while y < h:
		var row := y * w * 4
		var x := 0
		while x < w:
			if _matches(data, row + x * 4, er, eg, eb, tolerance):
				result["hit"] = rect.position + Vector2i(x, y)
				return result
			x += maxi(1, step)
		y += maxi(1, step)
	return result


static func _matches(data: PackedByteArray, i: int, r: int, g: int, b: int, tol: int) -> bool:
	return absi(data[i] - r) <= tol and absi(data[i + 1] - g) <= tol and absi(data[i + 2] - b) <= tol


## Returns where the mouse cursor is right now (screen coordinates), or
## (-1, -1) if the backend cannot tell.
func get_cursor_pos() -> Vector2i:
	return Vector2i(-1, -1)


## Runs a whole "Captures" mouse action as one unit: remember where the cursor
## is, do the action, put the cursor back where it was plus whatever the user
## moved the mouse meanwhile. Backends do this as atomically as they can so
## the cursor is away for as short a time as possible.
##   kind: "move" (travel to `from` over `ms`), "click" (`button` at `from`),
##         or "drag" (`button` down at `from`, travel to `to` over `ms`, up).
##   ghost: hide the real cursor for the duration and show a ghost cursor that
##         keeps following the user, so nothing appears to jump.
##   path: the travel (see MousePath): for a move it starts where the cursor
##         is and ends at `from`; for a drag it runs from `from` to `to`.
## Blocks for the whole action (callers run it off the main thread). Returns
## [saved_pos, restored_pos], or [] if the action could not be performed.
func run_captured(_kind: String, _button: int, _from: Vector2i, _to: Vector2i, _ms: int, _ghost: bool, _path: PackedVector2Array) -> Array:
	return []
