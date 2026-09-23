extends RefCounted
class_name LoopAction
## A single automated step inside a layer.
## Stored in a flexible way so it serialises cleanly to/from JSON.

## Self-reference via preload so our own static factories resolve even when this
## script is compiled very early (e.g. as part of an autoload dependency chain),
## before the global `class_name` registry is ready.
const Self := preload("res://scripts/model/loop_action.gd")

enum Type {
	MOVE,          ## Move the cursor to (x, y)
	CLICK,         ## Move to (x, y) then click a mouse button
	DRAG,          ## Press at (x, y), move to (x2, y2), release
	KEY,           ## Send keys (SendKeys format on Windows backend)
	WAIT,          ## Pause for wait_ms milliseconds
	PIXEL_DETECT,  ## Look for an expected colour anywhere in a screen rect
	CAPTURE,       ## Move the mouse to where the user has it, or to the last detect's spot
	STOP,          ## Stop the loop (or end this layer), now or after N passes
	IMAGE_DETECT,  ## Look for a small screenshot anywhere in a screen rect
	SCROLL,        ## Turn the mouse wheel where the cursor is
}

## Biggest template an IMAGE_DETECT keeps, on a side: any screen region, and
## only a cap on what goes in the file (a screen-sized PNG is a few hundred
## KB).
const IMAGE_MAX_SIDE := 2048
## The outermost pixels of a template are not compared (see the scans), so
## a drag that took in a sliver of whatever surrounds the target still
## matches when that changes. Templates too small to have an inside keep
## all their pixels.
const IMAGE_EDGE := 3

## Mouse button identifiers used across backends.
const BUTTON_LEFT := 0
const BUTTON_RIGHT := 1
const BUTTON_MIDDLE := 2

## What playback returns from an action to steer the layer. A detect's own
## settings are the `wait` / `skip` booleans below (files from before 0.9.6
## stored one of these values as "on_fail" and are read into them); the
## values are kept as the engine's return type.
enum OnFail {
	CONTINUE,     ## Keep running
	SKIP_LAYER,   ## Skip the remaining actions in this layer this iteration
	STOP_LOOP,    ## (retired) Stop playback entirely
	WAIT_FOUND,   ## (file value only) re-check the same spot until the colour appears
}

## A STOP action ends either the whole loop or just this layer's pass.
enum StopScope {
	LOOP,   ## Stop playback
	LAYER,  ## Skip the rest of this layer this pass
}

## Where a CAPTURE action moves the mouse.
enum CaptureMode {
	MOUSE = 1,   ## To where the user's own mouse is (see PlaybackEngine)
	DETECT = 2,  ## To where the last detect found its target
}

## CLICK / KEY: how the press goes. TAP is the plain click or keystroke;
## HOLD keeps it down for `hold_ms` and lets go; DOWN presses and leaves it
## held for later actions (hold W and click, Shift and drag); UP lets go
## of it. A stop lets go of everything still held.
enum PressMode {
	TAP,
	HOLD,
	DOWN,
	UP,
}

## SCROLL: which way the wheel turns.
enum ScrollDir {
	UP,
	DOWN,
	LEFT,
	RIGHT,
}

var type: int = Type.MOVE
var enabled: bool = true
var comment: String = ""
## MOVE / CLICK / DRAG: remember the mouse position before the action runs and
## move back to it afterwards, plus whatever the user moved the mouse
## meanwhile, so the user's own movement is never lost.
var captures: bool = false
## With `captures`: hide the real cursor while it is off doing the action and
## show a ghost cursor that keeps following the user instead.
var ghost_cursor: bool = false
var capture_mode: int = CaptureMode.MOUSE
## PIXEL_DETECT / IMAGE_DETECT: centre the rect on the mouse (and keep it there as the mouse
## moves) instead of using the stored x / y.
var follow_cursor: bool = false
## CLICK: "Move to the point first" (the default). Off, the press or
## release happens wherever the cursor is right now, and the action has no
## point of its own.
var move_to: bool = true
## MOVE / CLICK / DRAG: wander a little on the way (see MousePath), the way a hand
## does; where the travel starts and lands is not affected.
var wiggle: bool = false
## KEY: send the keys one at a time with a random pause between them, the
## way typing goes, instead of all at once (see KeyStrokes for what "one
## at a time" keeps together).
var keys_paced: bool = false
## CLICK / KEY: tap, hold, down or up (see PressMode); HOLD keeps the press
## down for `hold_ms` (a range, like every number).
var press_mode: int = PressMode.TAP
var hold_ms: int = 500
var hold_ms_max: int = 500
## SCROLL: the direction and how many notches (a range, like every number).
var scroll_dir: int = ScrollDir.DOWN
var notches: int = 3
var notches_max: int = 3
## STOP: what it ends (the loop, or just this layer's pass).
var stop_scope: int = StopScope.LOOP
## STOP: fire on this pass that reaches it (1 = the first). PIXEL_DETECT
## reuses wait_ms as its "wait till found" re-check gap.
var stop_after: int = 1
## PIXEL_DETECT / IMAGE_DETECT: the condition is "not found" (or "found", see
## if_found). ~Wait: while it holds, re-check the same spot every wait_ms
## until it clears (or ~Timeout runs out). Skip rest of layer (the default): when it holds
## - at once, or still after the wait - skip the rest of the layer. Both off
## is a plain look: the detect reports, and sets the spot Capture Mouse's
## Detect goes to, and the layer carries on either way.
var wait: bool = false
var skip: bool = true
## ~Wait's ~Timeout: give up after `wait_timeout_ms` (a range, rolled once
## per wait) instead of waiting forever; what happens then is Skip rest of layer's call.
var wait_timeout: bool = false
var wait_timeout_ms: int = 5000
var wait_timeout_ms_max: int = 5000

# Geometry / parameters (only the relevant ones are used per type). Every
# numeric setting is a range: `x` .. `x_max` and so on. Each time the action
# runs, playback draws a random integer from the range (see roll_*); equal
# ends make a fixed value, which is what the editor starts with.
var x: int = 0
var x_max: int = 0
var y: int = 0
var y_max: int = 0
var x2: int = 0
var x2_max: int = 0
var y2: int = 0
var y2_max: int = 0
var w: int = 100
var w_max: int = 100
var h: int = 60
var h_max: int = 60
var button: int = BUTTON_LEFT
var keys: String = ""
var wait_ms: int = 100
var wait_ms_max: int = 100
var duration_ms: int = 0
var duration_ms_max: int = 0
var color: Color = Color(1, 1, 1, 1)
var tolerance: int = 16
var tolerance_max: int = 16
## PIXEL_DETECT / IMAGE_DETECT: the condition holds when the colour or image
## IS there, not when it is missing — "if found, skip the rest of the layer",
## "wait till gone". The other way round from the default (see the "If"
## dropdown), so the same detect covers both halves of a condition.
var if_found: bool = false
## PIXEL_DETECT / IMAGE_DETECT: in Safe mode a colour or image that is not
## found changes nothing (no skip, no stop), so a whole loop can be walked
## through; Live keeps to ~Wait and Skip rest of layer.
var safe_continue: bool = true
## IMAGE_DETECT: the template to look for, as PNG bytes (the form it is
## stored and sent to the screen reader in); empty until one is captured.
## Set it through set_image_png so the decoded copies below stay in step.
var image_png := PackedByteArray()
## IMAGE_DETECT: compare each pixel by how light it is, not its colour, so a
## differently tinted copy (hovered, pressed, another theme) still matches.
var ignore_colour: bool = false
## IMAGE_DETECT: how much of the image may fail to match, as a percentage of
## its pixels (a range, like every number; 0 = every pixel must match). Past
## MISMATCH_MAX a "match" would mean little, and the scan grows slower the
## more is allowed (see WindowsBackend.find_image).
const MISMATCH_MAX := 50
var mismatch: int = 0
var mismatch_max: int = 0
var _image: Image = null
var _image_texture: ImageTexture = null


## Coordinates and times are kept to what the helper's [int] casts take (a
## number past that fails the command anyway; a stray 1e30 in a file would
## otherwise turn into INT64_MIN and be sent as such).
const FIELD_MIN := -2147483648
const FIELD_MAX := 2147483647
## Screen geometry (a point, a rect's size) is kept well inside that: the
## overlay and the detects add points and sizes together (Rect2i is 32-bit),
## and a file saying 2147483647 for both would wrap. No screen is anywhere
## near this many pixels.
const COORD_MIN := -16777216
const COORD_MAX := 16777216
## The most notches one Scroll turns (the editor's and the helper's limit;
## a file saying more would have the run turning the wheel for hours).
const NOTCHES_MAX := 200
## The text fields are kept to a size the list and the editor draw without
## trouble (a file may hold anything); the editor's boxes take no more.
const KEYS_MAX_CHARS := 8192
const COMMENT_MAX_CHARS := 2000


## Field `key` of a loop-file dictionary as a whole number: the number as
## written (a float cut to its whole part, a numeric string read), a boolean as 0 / 1, and
## `default` for anything else - a JSON object, list, or word where a number
## should be (int() of those is a script error that would abort the load).
## Clamped to FIELD_MIN .. FIELD_MAX.
static func read_int(d: Dictionary, key: String, default: int) -> int:
	var v: Variant = d.get(key, default)
	var n := default
	match typeof(v):
		TYPE_INT:
			n = v
		TYPE_FLOAT:
			if is_finite(v):
				n = int(clampf(v, FIELD_MIN, FIELD_MAX))
		TYPE_BOOL:
			n = 1 if v else 0
		TYPE_STRING:
			var s: String = v.strip_edges()
			if s.is_valid_int():
				n = int(s)
			elif s.is_valid_float() and is_finite(float(s)):
				n = int(clampf(float(s), FIELD_MIN, FIELD_MAX))
	return clampi(n, FIELD_MIN, FIELD_MAX)


## Field `key` as a screen coordinate or size: read_int, kept to
## COORD_MIN .. COORD_MAX.
static func read_coord(d: Dictionary, key: String, default: int) -> int:
	return clampi(read_int(d, key, default), COORD_MIN, COORD_MAX)


## `raw` as one line of plain text: no control characters (line breaks,
## tabs, …), no line / paragraph separators, and no bidi marks or overrides
## - which can make text read in another order than it is typed or stored.
## What a name, a comment or a Key's text looks like on screen is then what
## it is. `max_chars` cuts it after that.
static func plain_text(raw: String, max_chars: int) -> String:
	var out := ""
	for ch in raw.left(max_chars * 2):
		var code := ch.unicode_at(0)
		if code < 32 or (code >= 127 and code <= 159):
			continue  # C0 / C1 control characters
		if code == 0x2028 or code == 0x2029:
			continue  # line / paragraph separators
		if code == 0x200E or code == 0x200F or (code >= 0x202A and code <= 0x202E) or (code >= 0x2066 and code <= 0x2069):
			continue  # bidi marks and overrides
		out += ch
		if out.length() >= max_chars:
			break
	return out


## Field `key` as true / false: a boolean as written, a number as non-zero,
## the words true / false (or 1 / 0), and `default` for anything else.
static func read_bool(d: Dictionary, key: String, default: bool) -> bool:
	var v: Variant = d.get(key, default)
	match typeof(v):
		TYPE_BOOL:
			return v
		TYPE_INT:
			return v != 0
		TYPE_FLOAT:
			return is_finite(v) and v != 0.0
		TYPE_STRING:
			var s: String = v.strip_edges().to_lower()
			if s == "true" or s == "1":
				return true
			if s == "false" or s == "0":
				return false
	return default


## Field `key` as text: a string as written, a number or boolean spelled
## out, and `default` for anything else (an object or a list is not text).
static func read_string(d: Dictionary, key: String, default: String) -> String:
	var v: Variant = d.get(key, default)
	match typeof(v):
		TYPE_STRING:
			return v
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
			return str(v)
	return default


## Field `key` as a colour, from the "rrggbb" / "rrggbbaa" form the files
## use; `default` when it is not one.
static func read_color(d: Dictionary, key: String, default: Color) -> Color:
	var s := read_string(d, key, "")
	return Color.html(s) if Color.html_is_valid(s) else default


## A random integer in [lo, hi] (either order); lo == hi is just that value.
static func roll(lo: int, hi: int) -> int:
	return randi_range(mini(lo, hi), maxi(lo, hi))


## "42" for a fixed value, "40–60" for a range (always low to high).
static func range_text(lo: int, hi: int) -> String:
	if lo == hi:
		return str(lo)
	return "%d–%d" % [mini(lo, hi), maxi(lo, hi)]


## The screen rect every value of an (x .. x_max, y .. y_max) point lies in.
static func point_extent(px: int, px_max: int, py: int, py_max: int) -> Rect2i:
	var lo := Vector2i(mini(px, px_max), mini(py, py_max))
	var hi := Vector2i(maxi(px, px_max), maxi(py, py_max))
	return Rect2i(lo, hi - lo + Vector2i.ONE)


func roll_point() -> Vector2i:
	return Vector2i(roll(x, x_max), roll(y, y_max))


func roll_point2() -> Vector2i:
	return Vector2i(roll(x2, x2_max), roll(y2, y2_max))


func roll_size() -> Vector2i:
	return Vector2i(maxi(1, roll(w, w_max)), maxi(1, roll(h, h_max)))


func roll_wait_ms() -> int:
	return maxi(0, roll(wait_ms, wait_ms_max))


func roll_duration_ms() -> int:
	return maxi(0, roll(duration_ms, duration_ms_max))


func roll_tolerance() -> int:
	return clampi(roll(tolerance, tolerance_max), 0, 255)


func roll_mismatch() -> int:
	return clampi(roll(mismatch, mismatch_max), 0, MISMATCH_MAX)


func roll_hold_ms() -> int:
	return roll(hold_ms, hold_ms_max)


func roll_notches() -> int:
	return maxi(1, roll(notches, notches_max))


func roll_wait_timeout_ms() -> int:
	return maxi(0, roll(wait_timeout_ms, wait_timeout_ms_max))


## Where point A (MOVE / CLICK / DRAG start) can land.
func point_a_extent() -> Rect2i:
	return point_extent(x, x_max, y, y_max)


## Where point B (DRAG end) can land.
func point_b_extent() -> Rect2i:
	return point_extent(x2, x2_max, y2, y2_max)


## Sets (or clears, with empty bytes) an IMAGE_DETECT's template. Returns
## false, changing nothing, if the bytes are not a PNG or it is bigger than
## IMAGE_MAX_SIDE on a side.
func set_image_png(png: PackedByteArray) -> bool:
	var img: Image = null
	if not png.is_empty():
		# The PNG signature first, so a corrupt file is refused quietly.
		if png.size() < 8 or png.slice(0, 8) != PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
			return false
		# The size in the header, before anything is decoded: the decoder
		# takes the header's word for the pixels to make room for, so a
		# small file claiming a huge image would cost that much memory (a
		# gigabyte for what Godot lets through) just to be refused below.
		var declared := png_size(png)
		if declared.x < 1 or declared.y < 1 or declared.x > IMAGE_MAX_SIDE or declared.y > IMAGE_MAX_SIDE:
			return false
		img = Image.new()
		if img.load_png_from_buffer(png) != OK or img.is_empty() \
				or img.get_width() > IMAGE_MAX_SIDE or img.get_height() > IMAGE_MAX_SIDE:
			return false
		# Kept (and saved, and sent to the helper's decoder) as Godot writes
		# it from the decoded pixels, not as the file had it: whatever else a
		# PNG from a shared loop carried (extra chunks, text, trailing
		# bytes) never reaches another parser.
		png = img.save_png_to_buffer()
		if png.is_empty():
			return false
	image_png = png
	_image = img
	_image_texture = null
	return true


## The width and height a PNG's header declares (the IHDR chunk, which
## always comes first, right after the signature), or (0, 0) when the
## bytes do not start like a PNG.
static func png_size(png: PackedByteArray) -> Vector2i:
	# Signature (8) + chunk length (4) + "IHDR" (4) + width (4) + height (4).
	if png.size() < 24 or png.slice(12, 16).get_string_from_ascii() != "IHDR":
		return Vector2i.ZERO
	var w := (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19]
	var h := (png[20] << 24) | (png[21] << 16) | (png[22] << 8) | png[23]
	return Vector2i(w, h)


## The decoded template (IMAGE_DETECT), or null without one.
func image() -> Image:
	return _image


## The template's size in pixels, or (0, 0) without one.
func image_size() -> Vector2i:
	return _image.get_size() if _image != null else Vector2i.ZERO


## The template as a texture for the editor and overlay (built once per
## template), or null without one.
func image_texture() -> ImageTexture:
	if _image_texture == null and _image != null:
		_image_texture = ImageTexture.create_from_image(_image)
	return _image_texture


static func type_name(t: int) -> String:
	match t:
		Type.MOVE: return "Move"
		Type.CLICK: return "Click"
		Type.DRAG: return "Drag"
		Type.KEY: return "Key"
		Type.WAIT: return "Delay"
		Type.PIXEL_DETECT: return "Pixel Detect"
		Type.CAPTURE: return "Capture Mouse"
		Type.STOP: return "Stop"
		Type.IMAGE_DETECT: return "Image Detect"
		Type.SCROLL: return "Scroll"
	return "Action"


## True for the mouse actions that offer the "Captures" option.
static func supports_captures(t: int) -> bool:
	return t == Type.MOVE or t == Type.CLICK or t == Type.DRAG


## True for the action types that sit at a screen position (drawn on the
## overlay as a point or rect and joined by the ordered path).
static func has_position(t: int) -> bool:
	return t == Type.MOVE or t == Type.CLICK or t == Type.DRAG or is_detect(t)


## True when this action has a point of its own on screen: a Click that
## does not move to its point first happens wherever the cursor is, so it
## has none.
func positioned() -> bool:
	if type == Type.CLICK and not move_to:
		return false
	return has_position(type)


## True for the two detects: a screen rect scanned for a colour (PIXEL_DETECT)
## or a template image (IMAGE_DETECT). They share the rect, Follow Cursor,
## If-not-found and ~Self handling.
static func is_detect(t: int) -> bool:
	return t == Type.PIXEL_DETECT or t == Type.IMAGE_DETECT


## The press, in words, for the list and the overlay: "" for a plain tap,
## else "hold 500 ms" / "down" / "up".
func press_text() -> String:
	match press_mode:
		PressMode.HOLD: return "hold %s ms" % range_text(hold_ms, hold_ms_max)
		PressMode.DOWN: return "down"
		PressMode.UP: return "up"
	return ""


## "up" / "down" / "left" / "right".
static func scroll_dir_name(dir: int) -> String:
	match dir:
		ScrollDir.UP: return "up"
		ScrollDir.LEFT: return "left"
		ScrollDir.RIGHT: return "right"
	return "down"


static func button_name(b: int) -> String:
	match b:
		BUTTON_RIGHT: return "Right"
		BUTTON_MIDDLE: return "Middle"
		_: return "Left"


static func new_of_type(t: int) -> Self:
	var a := Self.new()
	a.type = t
	match t:
		Type.MOVE:
			a.duration_ms = 0
			a.duration_ms_max = 0
		Type.CLICK:
			a.button = BUTTON_LEFT
		Type.DRAG:
			a.x2 = 200
			a.x2_max = 200
			a.y2 = 200
			a.y2_max = 200
			a.duration_ms = 200
			a.duration_ms_max = 200
		Type.KEY:
			a.keys = ""
		Type.WAIT:
			a.wait_ms = 250
			a.wait_ms_max = 250
		Type.PIXEL_DETECT:
			a.color = Color(1, 0, 0, 1)
			a.tolerance = 16
			a.tolerance_max = 16
		Type.CAPTURE:
			a.capture_mode = CaptureMode.MOUSE
		Type.STOP:
			a.stop_scope = StopScope.LOOP
			a.stop_after = 1
		Type.IMAGE_DETECT:
			a.tolerance = 16
			a.tolerance_max = 16
		Type.SCROLL:
			a.scroll_dir = ScrollDir.DOWN
			a.notches = 3
			a.notches_max = 3
	return a


## Short, human readable line for the action list.
func describe() -> String:
	# Captures goes with a plain click at a point (see Playback._execute_action).
	var suffix := " ↩" if captures and supports_captures(type) and (type != Type.CLICK or (press_mode == PressMode.TAP and move_to)) else ""
	var xs := range_text(x, x_max)
	var ys := range_text(y, y_max)
	# A Click that does not move to its point has none: it is "at cursor".
	var at := "@ (%s, %s)" % [xs, ys] if move_to or type != Type.CLICK else "at cursor"
	var over := "" if maxi(duration_ms, duration_ms_max) == 0 else " over %s ms" % range_text(duration_ms, duration_ms_max)
	match type:
		Type.MOVE:
			return "Move → (%s, %s)%s" % [xs, ys, suffix]
		Type.CLICK:
			var press := press_text()
			return "%s %s %s%s%s" % [button_name(button), press if not press.is_empty() else "click", at, over if move_to else "", suffix]
		Type.DRAG:
			return "%s drag (%s, %s) → (%s, %s)%s" % [button_name(button), xs, ys, range_text(x2, x2_max), range_text(y2, y2_max), suffix]
		Type.SCROLL:
			return "Scroll %s ×%s%s" % [scroll_dir_name(scroll_dir), range_text(notches, notches_max), over]
		Type.KEY:
			var press := press_text()
			return "Key%s: \"%s\"" % [" " + press if not press.is_empty() else "", keys_shown()]
		Type.WAIT:
			return "Delay %s ms" % range_text(wait_ms, wait_ms_max)
		Type.PIXEL_DETECT:
			var ws := range_text(w, w_max)
			var hs := range_text(h, h_max)
			if follow_cursor:
				return "Detect %s in %s×%s @ cursor%s" % [color.to_html(false), ws, hs, detect_suffix()]
			return "Detect %s in [%s, %s, %s×%s]%s" % [color.to_html(false), xs, ys, ws, hs, detect_suffix()]
		Type.CAPTURE:
			if capture_mode == CaptureMode.DETECT:
				return "Capture: move to the last detect's spot%s" % over
			return "Capture: move to your mouse position%s" % over
		Type.STOP:
			var what := "loop" if stop_scope == StopScope.LOOP else "layer"
			if stop_after > 1:
				return "Stop %s on pass %d" % [what, stop_after]
			return "Stop %s" % what
		Type.IMAGE_DETECT:
			var size := image_size()
			var what := "%d×%d image" % [size.x, size.y] if size.x > 0 else "image (none)"
			if follow_cursor:
				return "Find %s in %s×%s @ cursor%s" % [what, range_text(w, w_max), range_text(h, h_max), detect_suffix()]
			return "Find %s in [%s, %s, %s×%s]%s" % [what, xs, ys, range_text(w, w_max), range_text(h, h_max), detect_suffix()]
	return "Action"


## The Key's text as the list and the import question show it: in the order
## it is typed. A bidi override in it (a file may hold anything) would show
## the same characters in another order, and reading a loop's Key actions
## is how a loop from someone else is checked before it runs.
func keys_shown() -> String:
	return plain_text(keys, KEYS_MAX_CHARS)


## What a detect does with its result, for the list: nothing for the
## default (not found → skip), a word for the other choices.
func detect_suffix() -> String:
	var s := ""
	if wait:
		s += " · wait till gone" if if_found else " · wait till found"
	elif if_found:
		s += " · if found"
	if not skip:
		s += " · no skip"
	return s


## The screen rect a detect (PIXEL_DETECT / IMAGE_DETECT) scans this time: a
## random position and size from the ranges. With `follow_cursor` it is centred on `cursor` (where the
## mouse is right now) instead of the stored x / y.
func roll_detect_rect(cursor: Vector2i) -> Rect2i:
	var size := roll_size()
	if follow_cursor:
		return Rect2i(cursor - size / 2, size)
	return Rect2i(roll_point(), size)


## The screen rect every possible detect rect lies inside: what the overlay
## frames and keeps see-through. A fixed rect is its own extent.
func detect_extent(cursor: Vector2i) -> Rect2i:
	var big := Vector2i(maxi(1, maxi(w, w_max)), maxi(1, maxi(h, h_max)))
	if follow_cursor:
		# Every size is centred on the cursor, so the biggest covers the rest.
		return Rect2i(cursor - big / 2, big)
	var origin := point_a_extent()
	return Rect2i(origin.position, origin.size - Vector2i.ONE + big)


## Primary anchor point used for overlay path drawing (or -1,-1 if none; see
## has_position): the middle of where point A can land, or the top-left of a
## detect's extent. `cursor` places a follow-cursor detect.
func overlay_point(cursor: Vector2i = Vector2i.ZERO) -> Vector2:
	if not positioned():
		return Vector2(-1, -1)
	match type:
		Type.MOVE, Type.CLICK, Type.DRAG:
			return Vector2(point_a_extent().get_center())
		Type.PIXEL_DETECT, Type.IMAGE_DETECT:
			# The top-left corner: the inside of the rect is kept clear on the
			# overlay (the screen read scans it), so anchor paths and badges
			# outside it.
			return Vector2(detect_extent(cursor).position)
	return Vector2(-1, -1)


func to_dict() -> Dictionary:
	var d := {
		"type": type,
		"enabled": enabled,
		"comment": comment,
		"x": x, "y": y, "x2": x2, "y2": y2, "w": w, "h": h,
		"x_max": x_max, "y_max": y_max, "x2_max": x2_max, "y2_max": y2_max, "w_max": w_max, "h_max": h_max,
		"button": button,
		"keys": keys,
		"wait_ms": wait_ms,
		"wait_ms_max": wait_ms_max,
		"duration_ms": duration_ms,
		"duration_ms_max": duration_ms_max,
		"color": color.to_html(true),
		"tolerance": tolerance,
		"tolerance_max": tolerance_max,
		"wait": wait,
		"skip": skip,
		"if_found": if_found,
		"safe_continue": safe_continue,
		"captures": captures,
		"ghost_cursor": ghost_cursor,
		"capture_mode": capture_mode,
		"follow_cursor": follow_cursor,
		"move_to": move_to,
		"wiggle": wiggle,
		"keys_paced": keys_paced,
		"press_mode": press_mode,
		"scroll_dir": scroll_dir,
		"notches": notches,
		"notches_max": notches_max,
		"hold_ms": hold_ms,
		"hold_ms_max": hold_ms_max,
		"stop_scope": stop_scope,
		"stop_after": stop_after,
		"wait_timeout": wait_timeout,
		"wait_timeout_ms": wait_timeout_ms,
		"wait_timeout_ms_max": wait_timeout_ms_max,
		"ignore_colour": ignore_colour,
		"mismatch": mismatch,
		"mismatch_max": mismatch_max,
	}
	# The template goes in only when there is one: it is the one bulky field.
	if not image_png.is_empty():
		d["image"] = Marshalls.raw_to_base64(image_png)
	return d


## Reads an action back from a loop file. Every field is read through the
## read_* helpers, so a value of the wrong kind (a file from anywhere may
## hold anything) falls back to its default instead of aborting the load,
## and every choice is checked against the values it can take.
static func from_dict(d: Dictionary) -> Self:
	var a := Self.new()
	a.type = read_int(d, "type", Type.MOVE)
	a.enabled = read_bool(d, "enabled", true)
	# A type this build does not know (a newer file, or a made-up number)
	# is kept as it is, but switched off: it must never run as something
	# else, and it can be looked at and deleted.
	if a.type < Type.MOVE or a.type > Type.SCROLL:
		a.enabled = false
	a.comment = plain_text(read_string(d, "comment", ""), COMMENT_MAX_CHARS)
	# A missing "<name>_max" (files from before ranges) means a fixed value.
	a.x = read_coord(d, "x", 0)
	a.x_max = read_coord(d, "x_max", a.x)
	a.y = read_coord(d, "y", 0)
	a.y_max = read_coord(d, "y_max", a.y)
	a.x2 = read_coord(d, "x2", 0)
	a.x2_max = read_coord(d, "x2_max", a.x2)
	a.y2 = read_coord(d, "y2", 0)
	a.y2_max = read_coord(d, "y2_max", a.y2)
	a.w = read_coord(d, "w", 100)
	a.w_max = read_coord(d, "w_max", a.w)
	a.h = read_coord(d, "h", 60)
	a.h_max = read_coord(d, "h_max", a.h)
	a.button = read_int(d, "button", BUTTON_LEFT)
	if a.button < BUTTON_LEFT or a.button > BUTTON_MIDDLE:
		a.button = BUTTON_LEFT
	# One line of SendKeys text; a file cannot smuggle line breaks into it.
	a.keys = read_string(d, "keys", "").replace("\r", "").replace("\n", "").left(KEYS_MAX_CHARS)
	a.wait_ms = read_int(d, "wait_ms", 100)
	a.wait_ms_max = read_int(d, "wait_ms_max", a.wait_ms)
	a.duration_ms = read_int(d, "duration_ms", 0)
	a.duration_ms_max = read_int(d, "duration_ms_max", a.duration_ms)
	a.color = read_color(d, "color", Color(1, 1, 1, 1))
	a.tolerance = read_int(d, "tolerance", 16)
	a.tolerance_max = read_int(d, "tolerance_max", a.tolerance)
	# Files from before 0.9.6 hold one "on_fail" choice: Wait till found is
	# ~Wait on (and it skipped on a timeout, so ~Skip stays on); Skip rest of
	# layer, and the retired Continue / Stop loop, are ~Wait off.
	var on_fail := read_int(d, "on_fail", OnFail.SKIP_LAYER)
	a.wait = read_bool(d, "wait", on_fail == OnFail.WAIT_FOUND)
	a.skip = read_bool(d, "skip", true)
	a.if_found = read_bool(d, "if_found", false)
	a.scroll_dir = read_int(d, "scroll_dir", ScrollDir.DOWN)
	if a.scroll_dir < ScrollDir.UP or a.scroll_dir > ScrollDir.RIGHT:
		a.scroll_dir = ScrollDir.DOWN
	a.notches = clampi(read_int(d, "notches", 3), 1, NOTCHES_MAX)
	a.notches_max = clampi(read_int(d, "notches_max", a.notches), 1, NOTCHES_MAX)
	a.press_mode = read_int(d, "press_mode", PressMode.TAP)
	if a.press_mode < PressMode.TAP or a.press_mode > PressMode.UP:
		a.press_mode = PressMode.TAP
	a.hold_ms = maxi(0, read_int(d, "hold_ms", 500))
	a.hold_ms_max = maxi(0, read_int(d, "hold_ms_max", a.hold_ms))
	a.stop_scope = read_int(d, "stop_scope", StopScope.LOOP)
	if a.stop_scope < StopScope.LOOP or a.stop_scope > StopScope.LAYER:
		a.stop_scope = StopScope.LOOP
	# 1-based: the old 0 ("first pass") reads the same as 1 now.
	a.stop_after = maxi(1, read_int(d, "stop_after", 1))
	a.wait_timeout = read_bool(d, "wait_timeout", false)
	a.wait_timeout_ms = maxi(0, read_int(d, "wait_timeout_ms", 5000))
	a.wait_timeout_ms_max = maxi(0, read_int(d, "wait_timeout_ms_max", a.wait_timeout_ms))
	a.ignore_colour = read_bool(d, "ignore_colour", false)
	a.mismatch = read_int(d, "mismatch", 0)
	a.mismatch_max = read_int(d, "mismatch_max", a.mismatch)
	a.safe_continue = read_bool(d, "safe_continue", true)
	a.captures = read_bool(d, "captures", false)
	# "lag_compensation" is the pre-release name of the same option.
	a.ghost_cursor = read_bool(d, "ghost_cursor", read_bool(d, "lag_compensation", false))
	a.capture_mode = read_int(d, "capture_mode", CaptureMode.MOUSE)
	if a.capture_mode != CaptureMode.DETECT:
		a.capture_mode = CaptureMode.MOUSE
	a.follow_cursor = read_bool(d, "follow_cursor", false)
	a.move_to = read_bool(d, "move_to", true)
	a.wiggle = read_bool(d, "wiggle", false)
	a.keys_paced = read_bool(d, "keys_paced", false)
	# A template that does not decode (or is too big) is dropped, not kept.
	a.set_image_png(Marshalls.base64_to_raw(read_string(d, "image", "")))
	return a


func duplicate_action() -> Self:
	return Self.from_dict(to_dict())
