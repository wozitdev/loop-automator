extends RefCounted
class_name LoopProject
## The whole automation: an ordered set of layers that loop forever.

## Self-reference via preload. When this script is compiled very early (as part
## of an autoload's dependency chain) the global `class_name` registry may not
## be ready, so referring to "LoopProject" by name inside our own static
## functions would fail. A self-preload const always resolves.
const Self := preload("res://scripts/model/loop_project.gd")
const LoopLayerT := preload("res://scripts/model/loop_layer.gd")
const LoopActionT := preload("res://scripts/model/loop_action.gd")
const KeyStrokesT := preload("res://scripts/model/key_strokes.gd")

## 2: "$" in a Key's text is the Windows key as a modifier (see KeyStrokes);
## a literal "$" is "{$}". Version 1 files are rewritten on load.
## 3: points are Godot's (the whole desktop's top-left is 0, 0); before, they
## went to Windows as they were (its primary screen's top-left is 0, 0).
const FILE_VERSION := 3
## The longest loop delay (the toolbar's box takes no more).
const LOOP_DELAY_MS_MAX := 60000

var name: String = "Untitled Loop"
## Pause before each pass of the loop (the first one too): a random value from
## loop_delay_ms .. loop_delay_ms_max each time (equal ends = fixed).
var loop_delay_ms: int = 250
var loop_delay_ms_max: int = 250
## Wait a (freshly rolled) loop delay before every action instead of once
## a pass: the toolbar's "~Delay ms" checkbox.
var delay_after_each_action: bool = false
var layers: Array[LoopLayerT] = []
## Not saved: read from a file older than version 3 on a desktop whose two
## ways of counting differ (a screen left of or above the primary), so its
## points may be off by that much - which of them, the file cannot tell
## (recorded ones were Windows', picked ones Godot's). The app says so.
var points_unsure := Vector2i.ZERO


static func make_default() -> Self:
	var p := Self.new()
	p.layers.append(LoopLayerT.make("Layer 1", 0))
	return p


func to_dict() -> Dictionary:
	var arr: Array = []
	for l in layers:
		arr.append(l.to_dict())
	return {
		"version": FILE_VERSION,
		"name": name,
		"loop_delay_ms": loop_delay_ms,
		"loop_delay_ms_max": loop_delay_ms_max,
		"delay_after_each_action": delay_after_each_action,
		"layers": arr,
	}


static func from_dict(d: Dictionary) -> Self:
	var p := Self.new()
	p.name = LoopLayerT.clean_name(LoopActionT.read_string(d, "name", "Untitled Loop"))
	# Kept to the toolbar's range, which would show more as its end.
	p.loop_delay_ms = clampi(LoopActionT.read_int(d, "loop_delay_ms", 250), 0, LOOP_DELAY_MS_MAX)
	p.loop_delay_ms_max = clampi(LoopActionT.read_int(d, "loop_delay_ms_max", p.loop_delay_ms), 0, LOOP_DELAY_MS_MAX)
	p.delay_after_each_action = LoopActionT.read_bool(d, "delay_after_each_action", false)
	p.layers = []
	# Skip (never crash on) entries that are not layer objects.
	var layers: Variant = d.get("layers", [])
	if typeof(layers) == TYPE_ARRAY:
		for ld in layers:
			if typeof(ld) == TYPE_DICTIONARY:
				p.layers.append(LoopLayerT.from_dict(ld))
	if p.layers.is_empty():
		p.layers.append(LoopLayerT.make("Layer 1", 0))
	# A layer with no name to show (a file may say " ") would be a row of
	# two marks in the list, easy to miss while it runs every pass.
	for i in p.layers.size():
		if LoopLayerT.is_blank(p.layers[i].name):
			p.layers[i].name = "Layer %d" % (i + 1)
	if LoopActionT.read_int(d, "version", 1) < 3:
		p.points_unsure = DisplayServer.screen_get_position(DisplayServer.get_primary_screen())
	if LoopActionT.read_int(d, "version", 1) < 2:
		# "$" used to be a plain character; it is the Win modifier now.
		for layer in p.layers:
			for a in layer.actions:
				if a.type == LoopActionT.Type.KEY:
					a.keys = _braced_dollars(a.keys)
					# Each "$" is three characters now: a text that grew past
					# KEYS_MAX_CHARS would type more than the Keys field, the
					# list and the import question can show (they stop there).
					# Cut to what they show, and off, since a cut text is not
					# the text the file meant.
					if a.keys.length() > LoopActionT.KEYS_MAX_CHARS:
						# (Cleaned again: the cut can leave a joiner last.)
						a.keys = LoopActionT.clean_keys(a.keys.left(LoopActionT.KEYS_MAX_CHARS))
						a.enabled = false
						a.comment = LoopActionT.plain_text("Switched off: its text grew past %d characters when an old file's \"$\" became \"{$}\", and was cut there. %s" % [LoopActionT.KEYS_MAX_CHARS, a.comment], LoopActionT.COMMENT_MAX_CHARS)
	return p


## An old file's Key text with every "$" outside braced keys written "{$}";
## one inside braces ("{$}", "{$ 3}": three of them) was braced already.
static func _braced_dollars(text: String) -> String:
	if not text.contains("$"):
		return text
	# In pieces, joined once: a text grown a character at a time is copied
	# whole on every step, and a file may hold thousands of 8K texts.
	var parts := PackedStringArray()
	var i := 0
	var n := text.length()
	while i < n:
		var brace := text.find("{", i)
		var stretch_end := n if brace < 0 else brace
		parts.append(text.substr(i, stretch_end - i).replace("$", "{$}"))
		if brace < 0:
			break
		var end := KeyStrokesT._brace_end(text, brace)
		parts.append(text.substr(brace, end - brace))
		i = end
	return "".join(parts)


func to_json() -> String:
	return JSON.stringify(to_dict(), "\t")


## The pause to insert after this iteration: random within the range.
func roll_loop_delay_ms() -> int:
	return maxi(0, randi_range(mini(loop_delay_ms, loop_delay_ms_max), maxi(loop_delay_ms, loop_delay_ms_max)))
