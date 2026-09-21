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


## `raw` as a name fit for the layer list, the loop picker and the store
## index: one line, no control characters, no invisible direction marks
## (a loop file may hold anything, and the loop is named after its first
## layer).
static func clean_name(raw: String) -> String:
	var out := ""
	for ch in raw:
		var code := ch.unicode_at(0)
		if code < 32 or (code >= 127 and code <= 159):
			continue  # C0 / C1 control characters (line breaks, tabs, …)
		if code == 0x2028 or code == 0x2029:
			continue  # line / paragraph separators
		if code == 0x200E or code == 0x200F or (code >= 0x202A and code <= 0x202E) or (code >= 0x2066 and code <= 0x2069):
			continue  # bidi marks and overrides: they can make text read differently
		out += ch
	return out.strip_edges()


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
	l.color = LoopActionT.read_color(d, "color", PALETTE[0])
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
