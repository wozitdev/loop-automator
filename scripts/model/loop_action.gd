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
	CAPTURE,       ## Save the mouse position, or move back to the saved one
	STOP,          ## Stop the loop (or end this layer), now or after N passes
	IMAGE_DETECT,  ## Look for a small screenshot anywhere in a screen rect
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

## How PIXEL_DETECT influences the rest of the layer when the colour is NOT
## found. CONTINUE and STOP_LOOP are no longer offered as settings (a file
## that has either is read as SKIP_LAYER): keep running is the found case,
## and stopping the loop is the Stop action's job. CONTINUE is still what
## playback returns for a found colour and for a Safe walk-through.
enum OnFail {
	CONTINUE,     ## Keep running
	SKIP_LAYER,   ## Skip the remaining actions in this layer this iteration
	STOP_LOOP,    ## (retired) Stop playback entirely
	WAIT_FOUND,   ## Re-check the same spot until the colour appears, then go on
}

## A STOP action ends either the whole loop or just this layer's pass.
enum StopScope {
	LOOP,   ## Stop playback
	LAYER,  ## Skip the rest of this layer this pass
}

## What a CAPTURE action does with the saved mouse position.
enum CaptureMode {
	SAVE,  ## Remember where the mouse is right now
	LOAD,  ## Move the mouse back to the remembered position
}

var type: int = Type.MOVE
var enabled: bool = true
var comment: String = ""
## MOVE / CLICK / DRAG: save the mouse position before the action runs and
## move back to it afterwards, plus whatever the user moved the mouse
## meanwhile (same saved slot a CAPTURE action uses).
var captures: bool = false
## With `captures`: hide the real cursor while it is off doing the action and
## show a ghost cursor that keeps following the user instead.
var ghost_cursor: bool = false
var capture_mode: int = CaptureMode.SAVE
## PIXEL_DETECT / IMAGE_DETECT: centre the rect on the mouse (and keep it there as the mouse
## moves) instead of using the stored x / y.
var follow_cursor: bool = false
## MOVE / DRAG: wander a little on the way (see MousePath), the way a hand
## does; where the travel starts and lands is not affected.
var wiggle: bool = false
## KEY: send the keys one at a time with a random pause between them, the
## way typing goes, instead of all at once (see KeyStrokes for what "one
## at a time" keeps together).
var keys_paced: bool = false
## STOP: what it ends (the loop, or just this layer's pass).
var stop_scope: int = StopScope.LOOP
## STOP: fire on this pass that reaches it (1 = the first). PIXEL_DETECT
## reuses wait_ms as its "wait till found" re-check gap.
var stop_after: int = 1
## Detects' "wait till found": give up after `wait_timeout_ms` (a range,
## rolled once per wait) and skip the rest of the layer, instead of waiting
## forever.
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
var on_fail: int = OnFail.SKIP_LAYER
## PIXEL_DETECT / IMAGE_DETECT: in Safe mode a colour or image that is not
## found changes nothing (no skip, no stop), so a whole loop can be walked
## through; Live keeps to `on_fail`.
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
		img = Image.new()
		if img.load_png_from_buffer(png) != OK or img.is_empty() \
				or img.get_width() > IMAGE_MAX_SIDE or img.get_height() > IMAGE_MAX_SIDE:
			return false
	image_png = png
	_image = img
	_image_texture = null
	return true


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
		Type.WAIT: return "Wait"
		Type.PIXEL_DETECT: return "Pixel Detect"
		Type.CAPTURE: return "Capture Mouse"
		Type.STOP: return "Stop"
		Type.IMAGE_DETECT: return "Image Detect"
	return "Action"


## True for the mouse actions that offer the "Captures" option.
static func supports_captures(t: int) -> bool:
	return t == Type.MOVE or t == Type.CLICK or t == Type.DRAG


## True for the action types that sit at a screen position (drawn on the
## overlay as a point or rect and joined by the ordered path).
static func has_position(t: int) -> bool:
	return t == Type.MOVE or t == Type.CLICK or t == Type.DRAG or is_detect(t)


## True for the two detects: a screen rect scanned for a colour (PIXEL_DETECT)
## or a template image (IMAGE_DETECT). They share the rect, Follow Cursor,
## If-not-found and ~Self handling.
static func is_detect(t: int) -> bool:
	return t == Type.PIXEL_DETECT or t == Type.IMAGE_DETECT


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
			a.on_fail = OnFail.SKIP_LAYER
		Type.CAPTURE:
			a.capture_mode = CaptureMode.SAVE
		Type.STOP:
			a.stop_scope = StopScope.LOOP
			a.stop_after = 1
		Type.IMAGE_DETECT:
			a.tolerance = 16
			a.tolerance_max = 16
			a.on_fail = OnFail.SKIP_LAYER
	return a


## Short, human readable line for the action list.
func describe() -> String:
	var suffix := " ↩" if captures and supports_captures(type) else ""
	var xs := range_text(x, x_max)
	var ys := range_text(y, y_max)
	match type:
		Type.MOVE:
			return "Move → (%s, %s)%s" % [xs, ys, suffix]
		Type.CLICK:
			return "%s click @ (%s, %s)%s" % [button_name(button), xs, ys, suffix]
		Type.DRAG:
			return "%s drag (%s, %s) → (%s, %s)%s" % [button_name(button), xs, ys, range_text(x2, x2_max), range_text(y2, y2_max), suffix]
		Type.KEY:
			return "Key: \"%s\"" % keys
		Type.WAIT:
			return "Wait %s ms" % range_text(wait_ms, wait_ms_max)
		Type.PIXEL_DETECT:
			var ws := range_text(w, w_max)
			var hs := range_text(h, h_max)
			if follow_cursor:
				return "Detect %s in %s×%s @ cursor" % [color.to_html(false), ws, hs]
			return "Detect %s in [%s, %s, %s×%s]" % [color.to_html(false), xs, ys, ws, hs]
		Type.CAPTURE:
			return "Capture: %s mouse position" % ("Save" if capture_mode == CaptureMode.SAVE else "Load")
		Type.STOP:
			var what := "loop" if stop_scope == StopScope.LOOP else "layer"
			if stop_after > 1:
				return "Stop %s on pass %d" % [what, stop_after]
			return "Stop %s" % what
		Type.IMAGE_DETECT:
			var size := image_size()
			var what := "%d×%d image" % [size.x, size.y] if size.x > 0 else "image (none)"
			if follow_cursor:
				return "Find %s in %s×%s @ cursor" % [what, range_text(w, w_max), range_text(h, h_max)]
			return "Find %s in [%s, %s, %s×%s]" % [what, xs, ys, range_text(w, w_max), range_text(h, h_max)]
	return "Action"


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
		"on_fail": on_fail,
		"safe_continue": safe_continue,
		"captures": captures,
		"ghost_cursor": ghost_cursor,
		"capture_mode": capture_mode,
		"follow_cursor": follow_cursor,
		"wiggle": wiggle,
		"keys_paced": keys_paced,
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


static func from_dict(d: Dictionary) -> Self:
	var a := Self.new()
	a.type = int(d.get("type", Type.MOVE))
	a.enabled = bool(d.get("enabled", true))
	a.comment = String(d.get("comment", ""))
	# A missing "<name>_max" (files from before ranges) means a fixed value.
	a.x = int(d.get("x", 0))
	a.x_max = int(d.get("x_max", a.x))
	a.y = int(d.get("y", 0))
	a.y_max = int(d.get("y_max", a.y))
	a.x2 = int(d.get("x2", 0))
	a.x2_max = int(d.get("x2_max", a.x2))
	a.y2 = int(d.get("y2", 0))
	a.y2_max = int(d.get("y2_max", a.y2))
	a.w = int(d.get("w", 100))
	a.w_max = int(d.get("w_max", a.w))
	a.h = int(d.get("h", 60))
	a.h_max = int(d.get("h_max", a.h))
	a.button = int(d.get("button", BUTTON_LEFT))
	# One line of SendKeys text; a file cannot smuggle line breaks into it.
	a.keys = String(d.get("keys", "")).replace("\r", "").replace("\n", "")
	a.wait_ms = int(d.get("wait_ms", 100))
	a.wait_ms_max = int(d.get("wait_ms_max", a.wait_ms))
	a.duration_ms = int(d.get("duration_ms", 0))
	a.duration_ms_max = int(d.get("duration_ms_max", a.duration_ms))
	a.color = Color.html(String(d.get("color", "ffffffff")))
	a.tolerance = int(d.get("tolerance", 16))
	a.tolerance_max = int(d.get("tolerance_max", a.tolerance))
	a.on_fail = int(d.get("on_fail", OnFail.SKIP_LAYER))
	# CONTINUE and the retired STOP_LOOP are no longer selectable: read either
	# as SKIP_LAYER (see OnFail). SKIP_LAYER and WAIT_FOUND are kept.
	if a.on_fail != OnFail.SKIP_LAYER and a.on_fail != OnFail.WAIT_FOUND:
		a.on_fail = OnFail.SKIP_LAYER
	a.stop_scope = int(d.get("stop_scope", StopScope.LOOP))
	# 1-based: the old 0 ("first pass") reads the same as 1 now.
	a.stop_after = maxi(1, int(d.get("stop_after", 1)))
	a.wait_timeout = bool(d.get("wait_timeout", false))
	a.wait_timeout_ms = maxi(0, int(d.get("wait_timeout_ms", 5000)))
	a.wait_timeout_ms_max = maxi(0, int(d.get("wait_timeout_ms_max", a.wait_timeout_ms)))
	a.ignore_colour = bool(d.get("ignore_colour", false))
	a.mismatch = int(d.get("mismatch", 0))
	a.mismatch_max = int(d.get("mismatch_max", a.mismatch))
	a.safe_continue = bool(d.get("safe_continue", true))
	a.captures = bool(d.get("captures", false))
	# "lag_compensation" is the pre-release name of the same option.
	a.ghost_cursor = bool(d.get("ghost_cursor", d.get("lag_compensation", false)))
	a.capture_mode = int(d.get("capture_mode", CaptureMode.SAVE))
	a.follow_cursor = bool(d.get("follow_cursor", false))
	a.wiggle = bool(d.get("wiggle", false))
	a.keys_paced = bool(d.get("keys_paced", false))
	# A template that does not decode (or is too big) is dropped, not kept.
	a.set_image_png(Marshalls.base64_to_raw(String(d.get("image", ""))))
	return a


func duplicate_action() -> Self:
	return Self.from_dict(to_dict())
