extends RefCounted
class_name InputBackend
## Abstract interface that turns LoopActions into real input.
## Concrete backends implement OS-specific behaviour.

## Clicks and keys that would land on a window of this process are skipped
## (0 = none). Loop Automator sets its own pid here while ~Self is off, so
## a loop cannot drive the app that is running it.
var avoid_pid: int = 0
## True when the most recent input command was skipped because of `avoid_pid`.
var last_skipped: bool:
	get: return _flag("skipped")
	set(value): _set_flag("skipped", value)
## True when the most recent input command may not have happened: it failed,
## or the helper ended without answering (a button meant to come up may
## still be down).
var last_failed: bool:
	get: return _flag("failed")
	set(value): _set_flag("failed", value)

## The two above, per thread: a run's worker finishing its piece while a
## stop's release runs on the main thread would otherwise set the release's
## outcome to its own (a failed release read as done, and not tried again).
## A worker's are the caller's once it is joined (see adopt_flags).
static var _flags := {}
static var _flags_mutex := Mutex.new()
const _FLAG_NAMES: Array[String] = ["skipped", "failed"]


static func _flag(name: String) -> bool:
	_flags_mutex.lock()
	var value: bool = _flags.get("%d %s" % [OS.get_thread_caller_id(), name], false)
	_flags_mutex.unlock()
	return value


static func _set_flag(name: String, value: bool) -> void:
	_flags_mutex.lock()
	_flags["%d %s" % [OS.get_thread_caller_id(), name]] = value
	_flags_mutex.unlock()


## Makes what the last command of thread `id` (a worker just joined) came
## to the calling thread's: the caller reads it after the join.
static func adopt_flags(id: int) -> void:
	_flags_mutex.lock()
	for name in _FLAG_NAMES:
		var key := "%d %s" % [id, name]
		_flags["%d %s" % [OS.get_thread_caller_id(), name]] = _flags.get(key, false)
		_flags.erase(key)
	_flags_mutex.unlock()
## Set when a key command was not sent at all (no way to send it safely);
## stays set until the engine clears it for a new run.
var keys_refused: bool = false
## Set by run_captured when the helper ended without answering (a stop's
## interrupt, or a timeout): it may have died with the button down.
var last_cut_off: bool = false
## Bumped by interrupt() and shutdown(): an image scan in script (find_image,
## which nothing else can cut short) that started before gives up.
var scan_generation: int = 0

func backend_name() -> String:
	return "Abstract"

## True if this backend can actually drive the OS (vs. preview-only).
func is_real() -> bool:
	return false

## Ends whatever the backend keeps running (a helper process, a worker
## thread). Called on the main thread before the backend is let go of;
## with `wait` nothing of it is still at work when this returns (the quit
## path), without it a slow start-up may be left to finish on its own.
func shutdown(_wait: bool = false) -> void:
	pass

## True once nothing of the backend is still at work after shutdown() (a
## thread joined, a helper gone). A backend that is not settled must be
## kept and asked again: a worker thread holds it alive until it is joined.
func settled() -> bool:
	return true

## True while the backend is still getting ready (a helper starting) and a
## command now would wait for that on the calling thread.
func warming() -> bool:
	return false

## True when the backend's helper is not running (it died, or a stop ended
## it) and the next command would start it on the calling thread.
func helper_down() -> bool:
	return false

## True when the backend's helper could not be started a moment ago (and
## is not tried again yet): input would go to a process started per command
## on the calling thread, a second or so each, nothing able to cut it short.
func helper_unavailable() -> bool:
	return false

## Cuts short a command the backend is in the middle of on another thread
## (a captured action runs for its whole dwell as one helper command, the
## real cursor pinned meanwhile): the call waiting on it returns with
## nothing, and the backend is usable again afterwards. Main thread.
func interrupt() -> void:
	pass

## Forgets an interrupt nothing spent (a stop between two commands of an
## action): a new run's first command is not the one it was meant for.
## Main thread, with no worker of the last run left.
func clear_interrupt() -> void:
	pass

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

## Lets go of `button` where the cursor is, without moving it: how a stop
## lets go of a button a Down or Hold left pressed.
func release_button(_button: int) -> void:
	pass

## Presses (`pressed`) or lets go of `button` where the cursor is, without
## moving it: a Click's Down / Hold / Up with ~Move off. Unlike
## release_button this is an input action, so the ~Self guard applies.
func button_here(_button: int, _pressed: bool) -> void:
	pass

## Clicks `button` where the cursor is, without moving it (~Move off).
func click_here(button: int) -> void:
	button_here(button, true)
	button_here(button, false)

func send_keys(_text: String) -> void:
	pass

## One keystroke with real timing (~Keys): the modifiers in `mods` (letters
## c / s / a / w for Ctrl / Shift / Alt / Win) go down, `lead` ms later each key in
## `keys` (see KeyStrokes.parse) is held `hold` ms, `gap` ms apart, and
## `trail` ms after the last one the modifiers come back up. Blocks for the
## whole press (callers run it off the main thread).
func hold_keys(_mods: String, _keys: PackedStringArray, _lead: int, _hold: int, _gap: int, _trail: int) -> void:
	pass


## Presses (`pressed`) or lets go of the modifiers in `mods` and the keys in
## `keys` (the same forms as hold_keys) and returns at once: what a Key
## action's Down / Up / Hold does. Letting go runs in the reverse order.
func press_keys(_mods: String, _keys: PackedStringArray, _pressed: bool) -> void:
	pass


## Turns the mouse wheel `notches` clicks in `dir` (a LoopAction.ScrollDir)
## where the cursor is, one wheel event per notch, spread over `ms` (a
## moment apart at least; `uneven` varies the gaps like a hand). Blocks for
## the whole scroll (callers run it off the main thread).
func scroll(_dir: int, _notches: int, _ms: int = 0, _uneven: bool = false) -> void:
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


## Looks for the template `png` (a PNG image, ± `tolerance` per channel on
## every pixel, or on each pixel's brightness alone with `grey`; up to
## `mismatch` % of its pixels may be off; its outermost `edge` pixels are not
## compared at all, when it is big enough to have an inside) anywhere in the
## screen rect, trying every offset it fits at.
## Returns {"hit": Vector2i} — the screen position of the template's top-left
## corner, or (-1, -1) when nothing matched — or an empty Dictionary if the
## screen could not be read. Backends that can do the scan themselves
## override this; the default reads the rect and scans it here, which is slow
## on a big rect (seconds in script for a whole screen).
func find_image(rect: Rect2i, png: PackedByteArray, tolerance: int, grey: bool = false, mismatch: int = 0, edge: int = 0) -> Dictionary:
	var tpl := Image.new()
	if tpl.load_png_from_buffer(png) != OK or tpl.is_empty():
		return {}
	var img := read_rect(rect)
	if img == null:
		return {}
	var result := {"hit": Vector2i(-1, -1)}
	var tw := tpl.get_width()
	var th := tpl.get_height()
	var w := img.get_width()
	var h := img.get_height()
	if tw > w or th > h:
		return result
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	if tpl.get_format() != Image.FORMAT_RGBA8:
		tpl.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var tdata := tpl.get_data()
	# The template's centre pixel is tried first at every offset, so most
	# offsets are ruled out on one comparison (unless mismatches are allowed:
	# the centre may then be one of them).
	var e := edge if edge > 0 and tw > 2 * edge and th > 2 * edge else 0
	var allowed := clampi(mismatch, 0, 100) * (tw - 2 * e) * (th - 2 * e) / 100
	var tc := (th / 2 * tw + tw / 2) * 4
	var tcx := tw / 2
	var tcy := th / 2
	var gen := scan_generation
	for oy in h - th + 1:
		for ox in w - tw + 1:
			# Per offset: with mismatches allowed one offset can cost a whole
			# template's worth of comparisons.
			if scan_generation != gen:
				return {}
			if allowed == 0 and not _same(data, ((oy + tcy) * w + ox + tcx) * 4, tdata, tc, tolerance, grey):
				continue
			if _template_at(data, w, ox, oy, tdata, tw, th, tolerance, grey, allowed, e):
				result["hit"] = rect.position + Vector2i(ox, oy)
				return result
	return result


## True when the template, its top-left at (ox, oy), matches the screen
## under it with at most `allowed` pixels off, its outermost `e` pixels
## left out.
static func _template_at(data: PackedByteArray, w: int, ox: int, oy: int, tdata: PackedByteArray, tw: int, th: int, tol: int, grey: bool, allowed: int, e: int) -> bool:
	var off := 0
	for ty in range(e, th - e):
		var row := ((oy + ty) * w + ox) * 4
		var trow := ty * tw * 4
		for tx in range(e, tw - e):
			if not _same(data, row + tx * 4, tdata, trow + tx * 4, tol, grey):
				off += 1
				if off > allowed:
					return false
	return true


## Pixel `i` of `a` (RGBA bytes) within `tol` of pixel `j` of `b`: on every
## channel, or with `grey` on brightness alone (the usual 30 / 59 / 11 %
## weights, so a tint that changes the colour but not how light it is
## still matches).
static func _same(a: PackedByteArray, i: int, b: PackedByteArray, j: int, tol: int, grey: bool) -> bool:
	if grey:
		var la := (a[i] * 299 + a[i + 1] * 587 + a[i + 2] * 114) / 1000
		var lb := (b[j] * 299 + b[j + 1] * 587 + b[j + 2] * 114) / 1000
		return absi(la - lb) <= tol
	return absi(a[i] - b[j]) <= tol and absi(a[i + 1] - b[j + 1]) <= tol and absi(a[i + 2] - b[j + 2]) <= tol


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
