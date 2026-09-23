extends RefCounted
class_name LoopLayer
## A named group of actions. All enabled layers run, in order, on every
## iteration of the loop. Layers exist so automators can split a loop into
## separate "screens" that can be flipped through and viewed in the overlay.

## Referenced via preload (not the global class name) so this script resolves
## even when compiled very early, e.g. as part of an autoload's dependency
## chain before the global class registry is ready.
const Self := preload("res://scripts/model/loop_layer.gd")
const LoopActionT := preload("res://scripts/model/loop_action.gd")

const PALETTE := [
	Color("4dd0e1"), Color("ffca28"), Color("ef5350"), Color("ab47bc"),
	Color("66bb6a"), Color("ff7043"), Color("42a5f5"), Color("ec407a"),
]

var name: String = "Layer"
var color: Color = PALETTE[0]
var visible: bool = true   ## Shown in the overlay
var enabled: bool = true   ## Executed during playback
var actions: Array[LoopActionT] = []


static func make(layer_name: String, index: int = 0) -> Self:
	var l := Self.new()
	l.name = layer_name
	l.color = PALETTE[index % PALETTE.size()]
	return l


## The most characters a name keeps (the list, the picker and the status
## line show it; a file may hold anything).
const NAME_MAX_CHARS := 200


## `raw` as a name fit for the layer list, the loop picker and the store
## index: one line, no control characters, no invisible direction marks,
## at most NAME_MAX_CHARS (a loop file may hold anything, and the loop is
## named after its first layer).
static func clean_name(raw: String) -> String:
	if _edge_spaces == null:
		# Any kind of space at either end (strip_edges takes only ASCII ones).
		_edge_spaces = RegEx.create_from_string("^[\\p{Z}\\s\\x{2800}]+|[\\p{Z}\\s\\x{2800}]+$")
		# ...and a run of blanks inside one space: a name padded out with
		# them would push what follows (an import's mark) out of sight.
		_blank_runs = RegEx.create_from_string("[\\p{Z}\\s\\x{2800}]+")
		_leading_marks = RegEx.create_from_string("^[\\p{M}\\x{200C}\\x{200D}\\s]+")
	# Blanks collapsed first, then cleaned (a mark after a no-break space
	# would otherwise end up on the plain space it becomes), and no mark at
	# the start, where it would sit on whatever comes before the name.
	# Until nothing changes: cleaning can join blanks an invisible character
	# kept apart (" " U+200B " "), and every pass that changes the name
	# shortens it.
	var name := raw.left(NAME_MAX_CHARS * 2)
	while true:
		var before := name
		name = _blank_runs.sub(name, " ", true)
		name = _edge_spaces.sub(LoopActionT.plain_text(name, NAME_MAX_CHARS), "", true)
		name = _leading_marks.sub(name, "", true)
		if name == before:
			break
	return name
static var _edge_spaces: RegEx = null
static var _blank_runs: RegEx = null
static var _leading_marks: RegEx = null


## The lightness a layer colour is kept to at least: its name is drawn in
## it on the dark layer list, and its guides on the overlay.
const COLOR_MIN_LUMINANCE := 0.3


## `c` light enough to read on the dark list (see COLOR_MIN_LUMINANCE):
## a layer coloured like the background ("000000") would be a row with no
## name that runs every pass all the same. Lightened toward white, so the
## hue it had is kept.
static func readable(c: Color) -> Color:
	var lum := c.get_luminance()
	if lum >= COLOR_MIN_LUMINANCE:
		return c
	var t := (COLOR_MIN_LUMINANCE - lum) / maxf(0.001, 1.0 - lum)
	var out := c.lerp(Color.WHITE, clampf(t + 0.02, 0.0, 1.0))
	out.a = 1.0
	return out


## Whether `name` shows as nothing: empty, or only spaces of any kind (a
## no-break or ideographic space, the blank Braille pattern) - strip_edges
## only takes the ASCII ones off.
static func is_blank(name: String) -> bool:
	if _blank == null:
		_blank = RegEx.create_from_string("^[\\p{Z}\\s\\x{2800}\\x{200C}\\x{200D}\\x{FE0E}\\x{FE0F}]*$")
	return _blank.search(name) != null
static var _blank: RegEx = null


func to_dict() -> Dictionary:
	var arr: Array = []
	for a in actions:
		arr.append(a.to_dict())
	return {
		"name": name,
		"color": color.to_html(true),
		"visible": visible,
		"enabled": enabled,
		"actions": arr,
	}


static func from_dict(d: Dictionary) -> Self:
	var l := Self.new()
	l.name = clean_name(LoopActionT.read_string(d, "name", "Layer"))
	l.color = readable(LoopActionT.read_color(d, "color", PALETTE[0]))
	l.visible = LoopActionT.read_bool(d, "visible", true)
	l.enabled = LoopActionT.read_bool(d, "enabled", true)
	l.actions = []
	# Anything that is not an action object is skipped rather than raising a
	# type error mid-load (the file may come from anywhere).
	var actions: Variant = d.get("actions", [])
	if typeof(actions) == TYPE_ARRAY:
		for ad in actions:
			if typeof(ad) == TYPE_DICTIONARY:
				l.actions.append(LoopActionT.from_dict(ad))
	return l
