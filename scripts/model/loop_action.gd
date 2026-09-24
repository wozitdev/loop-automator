extends RefCounted
class_name LoopAction
## A single automated step inside a layer.
## Stored in a flexible way so it serialises cleanly to/from JSON.

## Self-reference via preload so our own static factories resolve even when this
## script is compiled very early (e.g. as part of an autoload dependency chain),
## before the global `class_name` registry is ready.
const Self := preload("res://scripts/model/loop_action.gd")
const KeyStrokesT := preload("res://scripts/model/key_strokes.gd")

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
## describe()'s Key text and the `keys` it was worked out from.
var _described_keys: String = ""
var _described_shown: String = ""


## Coordinates and times are kept to what the helper's [int] casts take (a
## number past that fails the command anyway; a stray 1e30 in a file would
## otherwise turn into INT64_MIN and be sent as such).
const FIELD_MIN := -2147483648
const FIELD_MAX := 2147483647
## Screen geometry (a point, a rect's size) is kept to what the editor's
## boxes take, well inside that: the overlay and the detects add points and
## sizes together (Rect2i is 32-bit), and a box shows a value past its end
## as the end - a file saying 99999 would show 20000 and click at 99999
## (pinned to the screen's edge, where the ~Self guard sees no window).
const COORD_MIN := -20000
const COORD_MAX := 20000
## The editor's limits for the times and counts (see keep_to_limits): a
## value past one would be shown as the limit and run as itself - a Hold of
## 2000000000 ms shown as 600000.
const WAIT_MS_MAX := 600000
const HOLD_MS_MAX := 600000
const TIMEOUT_MS_MAX := 3600000
const DURATION_MS_MAX := 60000
const STOP_AFTER_MAX := 1000000
## The most notches one Scroll turns (the editor's and the helper's limit;
## a file saying more would have the run turning the wheel for hours).
const NOTCHES_MAX := 200
## The text fields are kept to a size the list and the editor draw without
## trouble (a file may hold anything); the editor's boxes take no more.
const KEYS_MAX_CHARS := 8192
const COMMENT_MAX_CHARS := 2000
## The most of a Key's text the action list shows (see describe).
const DESCRIBE_KEYS_CHARS := 64


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
## tabs, …), no line / paragraph separators, no bidi marks or overrides
## - which can make text read in another order than it is typed or stored -
## and nothing else that is drawn as nothing but typed all the same: the
## format characters (zero-width spaces and joiners, soft hyphens, the
## invisible tag letters that can spell out a whole hidden text), the
## variation selectors and the blank Hangul fillers.
## What a name, a comment or a Key's text looks like on screen is then what
## it is. `max_chars` cuts it after that.
static func plain_text(raw: String, max_chars: int) -> String:
	if _not_plain == null:
		# Control (Cc) and format (Cf: bidi marks and overrides, zero-width
		# characters, tags, BOM, soft hyphen) characters, everything Unicode
		# calls default-ignorable (DI: drawn as nothing - the combining
		# grapheme joiner, Mongolian selectors, the rest of the tag and
		# selector blocks), unassigned code points (Cn: no glyph either), line
		# / paragraph separators, variation selectors and the Hangul fillers.
		# Not the joiners (U+200C / U+200D) nor the emoji selectors (U+FE0E /
		# U+FE0F): real text needs them - Persian "می‌خواهم", Sinhala, an
		# emoji family, "❤️" - and they are dealt with below. One RegEx pass
		# each: a file of thousands of 8K texts is read, not stepped through a
		# character at a time.
		_not_plain = RegEx.create_from_string("(?![\\x{200C}\\x{200D}\\x{FE0E}\\x{FE0F}])[\\p{Cc}\\p{Cf}\\p{DI}\\p{Cn}\\p{Zl}\\p{Zp}\\x{115F}\\x{1160}\\x{3164}\\x{FFA0}\\x{FE00}-\\x{FE0F}\\x{E0100}-\\x{E01EF}]")
		# Two or more joiners or selectors in a row: no text needs that, and
		# a run is a hidden text of its own (a joiner then only ever has a
		# visible character on either side, below).
		# (A selector then a joiner is one emoji's: "❤️‍🔥".)
		_invisible_run = RegEx.create_from_string("[\\x{200C}\\x{200D}]{2,}|[\\x{FE0E}\\x{FE0F}]{2,}|[\\x{200C}\\x{200D}][\\x{FE0E}\\x{FE0F}]")
		# A joiner is kept only where text needs one: between two characters
		# of a script whose letters join or take half forms (Arabic, Syriac,
		# Thaana, N'Ko, the Indic scripts, Tibetan, Myanmar, Khmer,
		# Mongolian - their viramas and vowel marks included), or between
		# the parts of an emoji ("👩🏽‍💻", "❤️‍🔥"). Anywhere else (Latin,
		# Cyrillic, Chinese, digits, punctuation, spaces, an end) it joins
		# nothing and would only be typed unseen.
		var joins := "\\x{0600}-\\x{08FF}\\x{0900}-\\x{0DFF}\\x{0F00}-\\x{109F}\\x{1780}-\\x{18AF}\\x{A8E0}-\\x{A8FF}\\x{FB50}-\\x{FDFF}\\x{FE70}-\\x{FEFF}"
		# Kept: either joiner between two letters or marks of those scripts
		# (not their digits or punctuation), or a ZWJ after an emoji (its
		# selector, skin tone or hair part) before another emoji. Anything
		# else is loose.
		var script_before := "(?<=[%s])(?<=[\\p{L}\\p{M}])" % joins
		var script_after := "(?=[%s])(?=[\\p{L}\\p{M}])" % joins
		var emoji_before := "(?<=[\\p{ExtPict}\\x{FE0F}\\x{1F3FB}-\\x{1F3FF}\\x{1F9B0}-\\x{1F9B3}])"
		_loose_joiner = RegEx.create_from_string("(?!%s[\\x{200C}\\x{200D}]%s)(?!%s\\x{200D}(?=\\p{ExtPict}))[\\x{200C}\\x{200D}]" % [script_before, script_after, emoji_before])
		# An emoji selector only after what it can select: an emoji symbol
		# past Latin-1 ("❤️"), or a keycap's digit, # or * with the keycap
		# after it ("1️⃣").
		_loose_selector = RegEx.create_from_string("(?<!\\p{Emoji})(?<![0-9#*])[\\x{FE0E}\\x{FE0F}]|(?<=[\\x{0}-\\x{FF}])(?<![0-9#*])[\\x{FE0E}\\x{FE0F}]|(?<=[0-9#*])[\\x{FE0E}\\x{FE0F}](?!\\x{20E3})")
		# Combining marks stacked far past any script's need (dozens on one
		# letter, drawn over the lines around it): eight are kept, counted
		# across the joiners between them.
		_stacked = RegEx.create_from_string("((?:\\p{M}[\\x{200C}\\x{200D}]?){8})[\\p{M}\\x{200C}\\x{200D}]+")
		# \A and \z: "$" would also match before a final line break.
		# A combining mark on an ASCII symbol or on a blank of any width: it hides or changes
		# what the symbol looks like (a "~" struck through reads as another
		# sign) while SendKeys reads the symbol - Enter, Ctrl, the Windows
		# key - all the same. (A keycap's selector and enclosing mark, which
		# follow the digit or # * through U+FE0F, are not on the symbol.)
		_mark_on_symbol = RegEx.create_from_string("(?<=[\\x{20}-\\x{2F}\\x{3A}-\\x{40}\\x{5B}-\\x{60}\\x{7B}-\\x{7E}\\p{Zs}\\x{2800}])(?![\\x{FE0E}\\x{FE0F}])[\\p{M}\\x{200C}\\x{200D}]+")
		_printable_ascii = RegEx.create_from_string("\\A[\\x{20}-\\x{7E}]*\\z")
		_joining = RegEx.create_from_string("[\\x{200C}\\x{200D}\\x{FE0E}\\x{FE0F}\\p{M}]")
	var head := raw.left(max_chars * 2)
	# Plain printable ASCII (most Key texts) has nothing to take out.
	if _printable_ascii.search(head) != null:
		return head.left(max_chars)
	# Cut before the joiner / selector rules below, so the end the cut makes
	# is looked at too (a joiner left last would be typed unseen).
	var clean := _not_plain.sub(head, "", true).left(max_chars)
	if _joining.search(clean) == null:
		return clean
	# Until nothing changes (a removal can leave another one loose), so that
	# cleaning a clean text changes nothing - it is cleaned again on the way
	# to every view.
	# (Every pass that changes the text shortens it, so this ends.)
	while true:
		var before := clean
		clean = _invisible_run.sub(clean, "", true)
		clean = _loose_joiner.sub(clean, "", true)
		clean = _loose_selector.sub(clean, "", true)
		clean = _stacked.sub(clean, "$1", true)
		clean = _mark_on_symbol.sub(clean, "", true)
		if clean == before:
			break
	return clean
static var _printable_ascii: RegEx = null
static var _mark_on_symbol: RegEx = null
static var _joining: RegEx = null
static var _not_plain: RegEx = null
static var _invisible_run: RegEx = null
static var _loose_joiner: RegEx = null
static var _loose_selector: RegEx = null
static var _stacked: RegEx = null


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
## Always opaque: a layer drawn in "00000000" would have its name in the
## list and its clicks and keys on the overlay drawn as nothing, and a
## detect only ever compares red, green and blue.
static func read_color(d: Dictionary, key: String, default: Color) -> Color:
	var s := read_string(d, key, "")
	var c := Color.html(s) if Color.html_is_valid(s) else default
	c.a = 1.0
	return c


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
		# Opaque: the editor draws a template's alpha, the scans compare colour
		# alone - a see-through template would show as nothing (or as another
		# picture) and match all the same.
		if img.get_format() != Image.FORMAT_RGB8:
			img.convert(Image.FORMAT_RGB8)
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
			# The list shows the start (the editor has it all): an 8K line
			# costs the list milliseconds to lay out, per action.
			# Worked out once per text (a list of tens of thousands is
			# described whole on every rebuild; comparing is far cheaper).
			if keys != _described_keys or _described_shown.is_empty():
				# Only its two ends, each blank as a plain space (see _narrow):
				# an ideographic or em space is four times as wide, and a few
				# dozen would push what follows past the row's edge unseen.
				var shown := plain_text(_narrow(keys.left(DESCRIBE_KEYS_CHARS + 1)), DESCRIBE_KEYS_CHARS)
				if keys.length() > DESCRIBE_KEYS_CHARS:
					# Its start and its end, both within a row: what runs last in a
					# long text is as much a part of it as what runs first. Cut
					# between keystrokes (KeyStrokes.split, what typing goes by):
					# "$r" cut to "r" would pass for a plain r, "{ENTER}" to
					# "TER}" for no key at all.
					var ends := stroke_ends(keys, DESCRIBE_KEYS_CHARS / 2, DESCRIBE_KEYS_CHARS / 2 - 3)
					var head: String = ends[0]
					var tail: String = ends[1]
					head = plain_text(_narrow(head), DESCRIBE_KEYS_CHARS)
					tail = plain_text(_narrow(tail), DESCRIBE_KEYS_CHARS)
					shown = head + " … " + tail
					_described_parts = [head, tail]
				else:
					_described_parts = [shown]
				_described_keys = keys
				_described_shown = ltr_marked(shown)
			return "Key%s: \"%s\"" % [" " + press if not press.is_empty() else "", _described_shown]
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


## A Key's text as its list row shows it (see describe), before the marks
## ltr_marked adds: [all of it], or [its start, its end] when describe cut
## it between them. For fitting the row further (main's _fit_described),
## which cuts it between keystrokes - the marks would read as keys there.
func described_key_parts() -> Array:
	describe()
	return _described_parts
var _described_parts: Array = []

## `text`'s start and end, at most about `head_chars` and `tail_chars`
## long, cut only between keystrokes (KeyStrokes.split, what typing goes
## by): "$r" is never an "r", "{ENTER}" never "TER}". A keystroke longer than
## that (a long group) is shown by its start, where its modifiers are, then
## "…"; the whole text one such keystroke, by its end too. The two never
## overlap: for a text longer than both together.
static func stroke_ends(text: String, head_chars: int, tail_chars: int) -> Array:
	# With no braces or groups every keystroke is its modifiers and one
	# character, so the two ends are split on their own (a text of 8K is
	# otherwise split whole to show 60 characters, per text, per list):
	# the piece at each inner edge, maybe cut short, is left out.
	if text.length() > head_chars + tail_chars + 32 and not text.contains("{") and not text.contains("("):
		var front := KeyStrokesT.split(text.left(head_chars + 16))
		front.remove_at(front.size() - 1)
		var back := KeyStrokesT.split(text.right(tail_chars + 16))
		back.remove_at(0)
		front.append_array(back)
		return _ends_of(front, head_chars, tail_chars)
	return _ends_of(KeyStrokesT.split(text), head_chars, tail_chars)


static func _ends_of(strokes: PackedStringArray, head_chars: int, tail_chars: int) -> Array:
	var head := ""
	var first := 0
	while first < strokes.size() and head.length() + strokes[first].length() <= head_chars:
		head += strokes[first]
		first += 1
	if head.is_empty() and not strokes.is_empty():
		head = strokes[0].left(head_chars) + "…"
		first = 1
	var tail := ""
	var last := strokes.size()
	while last > first and tail.length() + strokes[last - 1].length() <= tail_chars:
		tail = strokes[last - 1] + tail
		last -= 1
	if tail.is_empty() and last > first:
		# Its start and its end: what it types last as well.
		var one := strokes[last - 1]
		tail = one.left(tail_chars / 2) + "…" + one.right(tail_chars - tail_chars / 2 - 1)
	elif tail.is_empty() and strokes.size() == 1:
		tail = "…" + strokes[0].right(tail_chars - 1)
	return [head, tail]


## The Key's text as the list and the import question show it: in the order
## it is typed. A bidi override in it (a file may hold anything) would show
## the same characters in another order, and reading a loop's Key actions
## is how a loop from someone else is checked before it runs.
func keys_shown() -> String:
	return ltr_marked(plain_text(keys, KEYS_MAX_CHARS))


## `text` (a Key's, already plain) for showing only: left to right is not
## enough on its own - SendKeys' characters between two right-to-left
## letters are still laid out right to left ("ש^~ת" shows "~^", Enter then
## Ctrl, for Ctrl+Enter) - so with right-to-left letters in it each of them
## gets a left-to-right mark on either side. Lengths and cuts are taken
## before this (the marks are not part of the text).
static func ltr_marked(text: String) -> String:
	if _rtl == null:
		_rtl = RegEx.create_from_string("[\\x{0590}-\\x{08FF}\\x{FB1D}-\\x{FDFF}\\x{FE70}-\\x{FEFF}\\x{10800}-\\x{10FFF}\\x{1E800}-\\x{1EFFF}]")
		_special = RegEx.create_from_string("([~^+%$(){}\\[\\]])")
		_rtl_letter = RegEx.create_from_string("([\\x{0590}-\\x{08FF}\\x{FB1D}-\\x{FDFF}\\x{FE70}-\\x{FEFF}\\x{10800}-\\x{10FFF}\\x{1E800}-\\x{1EFFF}])")
	if _rtl.search(text) == null:
		return text
	# ...and one after each right-to-left letter, so the digits and spaces
	# that follow it attach left to right too ("ש 12 34" would show "34 12").
	var marked := _special.sub(text, char(0x200E) + "$1" + char(0x200E), true)
	return _rtl_letter.sub(marked, "$1" + char(0x200E), true)
static var _rtl: RegEx = null
static var _special: RegEx = null
static var _blank: RegEx = null


## `text` with every blank (a space of any width, the Braille blank) a plain
## space, for the action list.
static func _narrow(text: String) -> String:
	if _blank == null:
		_blank = RegEx.create_from_string("[\\p{Zs}\\x{2800}]")
	return _blank.sub(text, " ", true)

static var _rtl_letter: RegEx = null


## `raw` as a Key's text: one line with nothing in it that does not show
## (see plain_text). A control character is typed as a key of its own - a
## \u0001 is Ctrl+A, \u001b is Esc - so text that hid one would type
## something else than the list and the import question say it does.
static func clean_keys(raw: String) -> String:
	return plain_text(raw, KEYS_MAX_CHARS)


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
		# One number for every unknown type: a file's own would be kept and
		# shared again by Export with nothing showing it.
		a.type = -1
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
	# Only a Key has text: any other action's would be kept, saved and shared
	# again with nothing showing it (and nothing typing it).
	if a.type == Type.KEY:
		a.keys = clean_keys(read_string(d, "keys", ""))
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
	# Only an Image Detect has one: a template on any other action would be
	# kept, saved and shared again with nothing in the editor showing it.
	if a.type == Type.IMAGE_DETECT:
		a.set_image_png(Marshalls.base64_to_raw(read_string(d, "image", "")))
	a._reset_unused()
	a.keep_to_limits()
	return a


## The fields each type uses (what its editor shows and its run reads); the
## rest are the defaults (see _reset_unused).
const _POINT_A := ["x", "x_max", "y", "y_max"]
const _TRAVEL := ["duration_ms", "duration_ms_max", "wiggle"]
const _DETECT := ["x", "x_max", "y", "y_max", "w", "w_max", "h", "h_max", "tolerance", "tolerance_max",
	"follow_cursor", "wait", "skip", "if_found", "safe_continue", "wait_ms", "wait_ms_max",
	"wait_timeout", "wait_timeout_ms", "wait_timeout_ms_max"]
static func _used_fields(t: int) -> Array:
	match t:
		Type.MOVE: return _POINT_A + _TRAVEL + ["captures", "ghost_cursor"]
		Type.CLICK: return _POINT_A + _TRAVEL + ["captures", "ghost_cursor", "button", "move_to", "press_mode", "hold_ms", "hold_ms_max"]
		Type.DRAG: return _POINT_A + _TRAVEL + ["captures", "ghost_cursor", "button", "x2", "x2_max", "y2", "y2_max"]
		Type.KEY: return ["keys", "keys_paced", "press_mode", "hold_ms", "hold_ms_max"]
		Type.WAIT: return ["wait_ms", "wait_ms_max"]
		Type.PIXEL_DETECT: return _DETECT + ["color"]
		Type.IMAGE_DETECT: return _DETECT + ["ignore_colour", "mismatch", "mismatch_max"]
		Type.CAPTURE: return _TRAVEL + ["capture_mode"]
		Type.STOP: return ["stop_scope", "stop_after"]
		Type.SCROLL: return _TRAVEL + ["scroll_dir", "notches", "notches_max"]
	return []


## Every setting this action's type does not use back at its default: a
## file's value there would be kept, saved and shared again by Export with
## nothing in the editor showing it (a payload riding on a Move). An
## unknown type keeps none.
func _reset_unused() -> void:
	var fresh := Self.new_of_type(type)
	var used := _used_fields(type)
	for f in to_dict().keys():
		if f in ["type", "enabled", "comment", "image"] or f in used:
			continue
		set(f, fresh.get(f))
	# The Hold time only with a Hold (the editor shows it for nothing else).
	if press_mode != PressMode.HOLD:
		hold_ms = fresh.hold_ms
		hold_ms_max = fresh.hold_ms_max


## Keeps every number to the range the editor's box for it takes (a file,
## or a long recording, may hold more): what the editor shows is then what
## runs.
func keep_to_limits() -> void:
	for f in ["x", "x_max", "y", "y_max", "x2", "x2_max", "y2", "y2_max"]:
		set(f, clampi(get(f), COORD_MIN, COORD_MAX))
	for f in ["w", "w_max", "h", "h_max"]:
		set(f, clampi(get(f), 1, COORD_MAX))
	for f in ["wait_ms", "wait_ms_max"]:
		set(f, clampi(get(f), 0, WAIT_MS_MAX))
	for f in ["hold_ms", "hold_ms_max"]:
		set(f, clampi(get(f), 0, HOLD_MS_MAX))
	for f in ["wait_timeout_ms", "wait_timeout_ms_max"]:
		set(f, clampi(get(f), 0, TIMEOUT_MS_MAX))
	for f in ["duration_ms", "duration_ms_max"]:
		set(f, clampi(get(f), 0, DURATION_MS_MAX))
	for f in ["tolerance", "tolerance_max"]:
		set(f, clampi(get(f), 0, 255))
	for f in ["mismatch", "mismatch_max"]:
		set(f, clampi(get(f), 0, MISMATCH_MAX))
	stop_after = clampi(stop_after, 1, STOP_AFTER_MAX)


func duplicate_action() -> Self:
	return Self.from_dict(to_dict())
