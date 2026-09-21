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

## 2: "$" in a Key's text is the Windows key as a modifier (see KeyStrokes);
## a literal "$" is "{$}". Version 1 files are rewritten on load.
const FILE_VERSION := 2

var name: String = "Untitled Loop"
## Pause before each pass of the loop (the first one too): a random value from
## loop_delay_ms .. loop_delay_ms_max each time (equal ends = fixed).
var loop_delay_ms: int = 250
var loop_delay_ms_max: int = 250
## Wait a (freshly rolled) loop delay before every action instead of once
## a pass: the toolbar's "~Delay ms" checkbox.
var delay_after_each_action: bool = false
var layers: Array[LoopLayerT] = []


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
	p.loop_delay_ms = maxi(0, LoopActionT.read_int(d, "loop_delay_ms", 250))
	p.loop_delay_ms_max = maxi(0, LoopActionT.read_int(d, "loop_delay_ms_max", p.loop_delay_ms))
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
	if LoopActionT.read_int(d, "version", 1) < 2:
		# "$" used to be a plain character; it is the Win modifier now.
		for layer in p.layers:
			for a in layer.actions:
				if a.type == LoopActionT.Type.KEY:
					a.keys = a.keys.replace("{$}", char(1)).replace("$", "{$}").replace(char(1), "{$}")
	return p


func to_json() -> String:
	return JSON.stringify(to_dict(), "\t")


## The pause to insert after this iteration: random within the range.
func roll_loop_delay_ms() -> int:
	return maxi(0, randi_range(mini(loop_delay_ms, loop_delay_ms_max), maxi(loop_delay_ms, loop_delay_ms_max)))
