extends Node
## Autoload singleton holding the current project and shared UI selection
## state. Both the builder window and the overlay read from here.

## Autoloads compile before Godot's global `class_name` registry is guaranteed
## ready (notably on a project's first import, when there is no `.godot` cache
## yet). Referencing the model scripts through preload constants makes this
## autoload resolve its types directly, independent of that registry.
const LoopProjectT := preload("res://scripts/model/loop_project.gd")
const LoopLayerT := preload("res://scripts/model/loop_layer.gd")
const LoopActionT := preload("res://scripts/model/loop_action.gd")
const LayerNamesT := preload("res://scripts/model/layer_names.gd")

const STORE_VERSION := 1
const STORE_INDEX_PATH := "user://loop_store.json"
const STORE_LOOPS_DIR := "user://loops"
## What an imported loop's name starts with (see import_loop), and how much
## of the file's own name it keeps after it.
const IMPORTED_MARK := "(imported)"
const IMPORTED_BASE_CHARS := 60

signal project_replaced                  ## A whole new project was loaded/created
signal layers_changed                    ## Layers added/removed/reordered/renamed
signal actions_changed(layer_index: int) ## Action list of a layer changed
signal action_modified(layer_index: int, action_index: int)
signal selection_changed                 ## Active layer / action selection changed
signal overlay_view_changed              ## Overlay layer / show-all toggled
signal loop_stack_changed
signal active_loop_changed(loop_id: int)
signal pending_changed(is_pending: bool)

var project: LoopProjectT
var loop_stack: Array[Dictionary] = []
var active_loop_id: int = -1

# Builder selection
var active_layer_index: int = 0
var selected_action_index: int = -1

# Overlay view state
var overlay_layer_index: int = 0
var overlay_show_all: bool = false

## Solo: while set, this layer alone runs and every other layer is treated
## as off - without any layer's Enabled setting changing (nothing is saved).
## The layer itself, not its index, so moving layers about keeps it.
var solo_layer: LoopLayerT = null

var current_path: String = ""
var _next_loop_id: int = 1
var _session_projects_by_id: Dictionary = {}
var _pending_by_id: Dictionary = {}


func _ready() -> void:
	_ensure_store_dirs()
	_load_or_init_store()
	if loop_stack.is_empty():
		create_loop(true)
	elif not open_loop(active_loop_id):
		open_loop(loop_stack[0].get("id", -1))


# ---------------------------------------------------------------- selection
func set_active_layer(index: int) -> void:
	index = clampi(index, 0, maxi(0, project.layers.size() - 1))
	if index == active_layer_index:
		return
	active_layer_index = index
	selected_action_index = -1
	emit_signal("selection_changed")


func set_selected_action(index: int) -> void:
	if index == selected_action_index:
		return
	selected_action_index = index
	emit_signal("selection_changed")


func active_layer() -> LoopLayerT:
	if project.layers.is_empty():
		return null
	return project.layers[clampi(active_layer_index, 0, project.layers.size() - 1)]


func selected_action() -> LoopActionT:
	var layer := active_layer()
	if layer == null:
		return null
	if selected_action_index < 0 or selected_action_index >= layer.actions.size():
		return null
	return layer.actions[selected_action_index]


# ------------------------------------------------------------------- layers
func add_layer() -> void:
	var l := LoopLayerT.make("Layer %d" % (project.layers.size() + 1), project.layers.size())
	project.layers.append(l)
	active_layer_index = project.layers.size() - 1
	selected_action_index = -1
	_mark_pending()
	_view_follows_active()
	emit_signal("layers_changed")
	emit_signal("selection_changed")


## Solo `index` (-1: nobody). One layer at a time; the layer list and the
## run follow through layer_runs.
func set_solo(index: int) -> void:
	var l: LoopLayerT = project.layers[index] if index >= 0 and index < project.layers.size() else null
	if l == solo_layer:
		return
	solo_layer = l
	emit_signal("layers_changed")


## Whether layer `index` takes part in a run: the solo layer alone while one
## is set, otherwise whatever its Enabled says.
func layer_runs(index: int) -> bool:
	if index < 0 or index >= project.layers.size():
		return false
	if solo_layer != null:
		return project.layers[index] == solo_layer
	return project.layers[index].enabled


func remove_layer(index: int) -> void:
	if project.layers.size() <= 1:
		return
	if project.layers[index] == solo_layer:
		solo_layer = null
	project.layers.remove_at(index)
	active_layer_index = clampi(active_layer_index, 0, project.layers.size() - 1)
	selected_action_index = -1
	_mark_pending()
	_sync_loop_name()
	_view_follows_active()
	emit_signal("layers_changed")
	emit_signal("selection_changed")


## Puts a copy of layer `index` right after it and makes it the active layer:
## the same actions, colour and switches, named "<name> copy" ("<name> copy 2"
## when that is taken; a copy of a copy is numbered, not "copy copy").
func duplicate_layer(index: int) -> void:
	if index < 0 or index >= project.layers.size():
		return
	var source: LoopLayerT = project.layers[index]
	# Through the file format, so nothing is shared with the original.
	var copy := LoopLayerT.from_dict(source.to_dict())
	var taken: Array = []
	for l in project.layers:
		taken.append(l.name)
	copy.name = copy_name(source.name, taken)
	project.layers.insert(index + 1, copy)
	active_layer_index = index + 1
	selected_action_index = -1
	_mark_pending()
	_sync_loop_name()
	_view_follows_active()
	emit_signal("layers_changed")
	emit_signal("selection_changed")


func move_layer(index: int, delta: int) -> void:
	var target := index + delta
	if target < 0 or target >= project.layers.size():
		return
	var l := project.layers[index]
	project.layers.remove_at(index)
	project.layers.insert(target, l)
	active_layer_index = target
	_mark_pending()
	_sync_loop_name()
	_view_follows_active()
	emit_signal("layers_changed")
	emit_signal("selection_changed")


## Points the overlay view at the active layer (what clicking a layer in
## the list does), so the "View:" line keeps up when a layer is added,
## copied, moved or removed. Showing all layers is left as it is.
func _view_follows_active() -> void:
	if overlay_show_all or overlay_layer_index == active_layer_index:
		return
	overlay_layer_index = active_layer_index
	emit_signal("overlay_view_changed")


func rename_layer(index: int, new_name: String) -> void:
	if index < 0 or index >= project.layers.size():
		return
	var name := LoopLayerT.clean_name(new_name)
	project.layers[index].name = name if not LoopLayerT.is_blank(name) else "Layer %d" % (index + 1)
	_mark_pending()
	_sync_loop_name()
	emit_signal("layers_changed")


## A loop is named after its first layer. Keeps `project.name` and the
## store entry (what the picker and status line show) in step with it.
func _sync_loop_name() -> void:
	if project == null or project.layers.is_empty():
		return
	var name := project.layers[0].name.strip_edges()
	if name.is_empty():
		name = str(active_loop_id)
	var idx := _loop_index_from_id(active_loop_id)
	# An imported loop keeps its mark whatever its first layer is called.
	if idx >= 0 and bool(loop_stack[idx].get("imported", false)) and not name.begins_with(IMPORTED_MARK):
		name = "%s %s" % [IMPORTED_MARK, name]
	project.name = name
	if idx < 0 or String(loop_stack[idx].get("name", "")) == name:
		return
	loop_stack[idx]["name"] = name
	_save_store_index()
	emit_signal("loop_stack_changed")


## The names of every loop in the store, for picking a fresh one.
func loop_names() -> Array:
	var names: Array = []
	for e in loop_stack:
		names.append(String(e.get("name", "")))
	return names


# ------------------------------------------------------------------ actions
func add_action(type: int) -> void:
	var layer := active_layer()
	if layer == null:
		return
	layer.actions.append(LoopActionT.new_of_type(type))
	selected_action_index = layer.actions.size() - 1
	_mark_pending()
	emit_signal("actions_changed", active_layer_index)
	emit_signal("selection_changed")


## Puts `actions` on the end of the active layer (a recording) and selects
## the first of them. As many as the loop has room for (LOOP_ACTIONS_MAX: a
## loop past it would save, and export, as a file no Import takes); returns
## how many that was.
func append_actions(actions: Array) -> int:
	var layer := active_layer()
	if layer == null or actions.is_empty():
		return 0
	var total := 0
	for l in project.layers:
		total += l.actions.size()
	var room := maxi(0, LOOP_ACTIONS_MAX - total)
	if room == 0:
		return 0
	var first := layer.actions.size()
	for a in actions.slice(0, room):
		layer.actions.append(a)
	selected_action_index = first
	_mark_pending()
	emit_signal("actions_changed", active_layer_index)
	emit_signal("selection_changed")
	return mini(room, actions.size())


func remove_action(index: int) -> void:
	var layer := active_layer()
	if layer == null or index < 0 or index >= layer.actions.size():
		return
	layer.actions.remove_at(index)
	selected_action_index = mini(index, layer.actions.size() - 1)
	_mark_pending()
	emit_signal("actions_changed", active_layer_index)
	emit_signal("selection_changed")


func duplicate_action(index: int) -> void:
	var layer := active_layer()
	if layer == null or index < 0 or index >= layer.actions.size():
		return
	layer.actions.insert(index + 1, layer.actions[index].duplicate_action())
	selected_action_index = index + 1
	_mark_pending()
	emit_signal("actions_changed", active_layer_index)
	emit_signal("selection_changed")


func move_action(index: int, delta: int) -> void:
	var layer := active_layer()
	if layer == null:
		return
	var target := index + delta
	if target < 0 or target >= layer.actions.size():
		return
	var a := layer.actions[index]
	layer.actions.remove_at(index)
	layer.actions.insert(target, a)
	selected_action_index = target
	_mark_pending()
	emit_signal("actions_changed", active_layer_index)
	emit_signal("selection_changed")


## A layer's Visible, Enabled or colour was changed in place: the loop is
## unsaved, as after any other edit (an imported loop is saved on import,
## and a layer switched off there must not run again after a restart).
func notify_layer_modified() -> void:
	_mark_pending()
	emit_signal("layers_changed")


func notify_action_modified() -> void:
	_mark_pending()
	emit_signal("action_modified", active_layer_index, selected_action_index)


# ------------------------------------------------------------------ timing
## The loop delay range from the toolbar (equal ends = a fixed pause).
func set_loop_delay(lo_ms: int, hi_ms: int) -> void:
	if project == null:
		return
	project.loop_delay_ms = lo_ms
	project.loop_delay_ms_max = hi_ms
	_mark_pending()


## Whether the loop delay is also waited after every action.
func set_delay_after_each_action(on: bool) -> void:
	if project == null or project.delay_after_each_action == on:
		return
	project.delay_after_each_action = on
	_mark_pending()


# ----------------------------------------------------------- overlay view
func set_overlay_layer(index: int) -> void:
	overlay_layer_index = clampi(index, 0, maxi(0, project.layers.size() - 1))
	emit_signal("overlay_view_changed")


func step_overlay_layer(delta: int) -> void:
	if project.layers.is_empty():
		return
	overlay_show_all = false
	overlay_layer_index = wrapi(overlay_layer_index + delta, 0, project.layers.size())
	emit_signal("overlay_view_changed")


func set_overlay_show_all(value: bool) -> void:
	overlay_show_all = value
	emit_signal("overlay_view_changed")


# ----------------------------------------------------------------- file io
func new_project() -> void:
	create_loop(true)


## Adds a loop to the store: a fresh one whose first layer gets a random
## name (see LayerNames), or `source` as it is. Either way the loop is named
## after its first layer. Returns the new loop's id.
func create_loop(open_now: bool = true, source: LoopProjectT = null) -> int:
	var id := _next_loop_id
	# A file already at that number's path belongs to a loop this index does
	# not list (the index was lost or reset, and numbering started over).
	# It is never written over: the new loop takes the next free number, and
	# the old file stays where Share → Import can bring it back.
	while FileAccess.file_exists(_loop_file_path(id)) or FileAccess.file_exists(_loop_file_path(id) + ".tmp") \
			or FileAccess.file_exists(_loop_file_path(id) + ".broken"):
		id += 1
	_next_loop_id = id + 1
	var p := source
	if p == null:
		p = LoopProjectT.make_default()
		p.layers[0].name = LayerNamesT.pick(loop_names())
	var name := p.layers[0].name.strip_edges()
	p.name = name if not name.is_empty() else str(id)
	var entry := {
		"id": id,
		"name": p.name,
		"file": _loop_file_path(id),
	}
	loop_stack.append(entry)
	var key := str(id)
	_session_projects_by_id[key] = p
	_pending_by_id[key] = true
	active_loop_id = id if open_now else active_loop_id
	_save_store_index()
	emit_signal("loop_stack_changed")
	if open_now:
		_open_project_for_id(id)
	return id


## The most a .loop file may be to be read at all: room for a few dozen
## screen-sized templates, well short of what would stall the app.
const LOOP_FILE_MAX_BYTES := 64 * 1024 * 1024
## What a loop file may hold, checked before any of it is built: every
## action is an object of some seventy fields and every template is decoded
## whole, so a small file of millions of "{}" or of tiny PNGs claiming 2048²
## would otherwise take gigabytes to read. Far above any loop made here (a
## long recording is some thousands of actions).
const LOOP_LAYERS_MAX := 1000
const LOOP_ACTIONS_MAX := 50000
## Pixels of every Image Detect template together: a dozen screen-sized
## ones, or hundreds of button-sized ones.
const LOOP_TEMPLATE_PIXELS_MAX := 48 * 1024 * 1024
## Objects, lists and list entries the JSON may have before it is parsed
## at all (the parse is the first thing to cost memory per value).
const LOOP_JSON_SEPARATORS_MAX := 4000000


## The loop in a .loop file, or null if `path` is not a readable loop file.
func _read_loop_file(path: String) -> LoopProjectT:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	return _read_loop(f, true)


## The loop in the open file `f` (closed here), or null if its contents are
## not a loop (or it is too big to read). `shared`: a file from anywhere
## (Import), held to the LOOP_* limits. A loop of the store's own was built
## in this app, which does not hold edits to them: it is read whatever its
## size, rather than set aside as broken on the next launch.
func _read_loop(f: FileAccess, shared: bool) -> LoopProjectT:
	if shared and f.get_length() > LOOP_FILE_MAX_BYTES:
		f.close()
		return null
	var text := f.get_as_text()
	f.close()
	if shared and text.count("{") + text.count("[") + text.count(",") > LOOP_JSON_SEPARATORS_MAX:
		return null
	var data: Variant = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or (shared and not _within_limits(data)):
		return null
	return LoopProjectT.from_dict(data)


## Whether a parsed loop file keeps to LOOP_LAYERS_MAX, LOOP_ACTIONS_MAX and
## LOOP_TEMPLATE_PIXELS_MAX. Templates are measured by the size their PNG
## header declares, before anything is decoded.
static func _within_limits(data: Dictionary) -> bool:
	var layers: Variant = data.get("layers", [])
	if typeof(layers) != TYPE_ARRAY:
		return true
	if (layers as Array).size() > LOOP_LAYERS_MAX:
		return false
	var actions := 0
	var pixels := 0
	for layer in layers:
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		var list: Variant = (layer as Dictionary).get("actions", [])
		if typeof(list) != TYPE_ARRAY:
			continue
		actions += (list as Array).size()
		if actions > LOOP_ACTIONS_MAX:
			return false
		for a in list:
			# (Only an Image Detect keeps a template, see LoopAction.from_dict.)
			if typeof(a) != TYPE_DICTIONARY or typeof((a as Dictionary).get("image")) != TYPE_STRING \
					or LoopActionT.read_int(a, "type", -1) != LoopActionT.Type.IMAGE_DETECT:
				continue
			# The whole string, as the load decodes it (the decoder skips
			# line breaks, so the first characters are not the first bytes).
			var declared := LoopActionT.png_size(Marshalls.base64_to_raw(String(a["image"])))
			# One over the side limit is refused undecoded (see set_image_png).
			if declared.x > LoopActionT.IMAGE_MAX_SIDE or declared.y > LoopActionT.IMAGE_MAX_SIDE:
				continue
			pixels += maxi(0, declared.x) * maxi(0, declared.y)
			if pixels > LOOP_TEMPLATE_PIXELS_MAX:
				return false
	return true


## The loop in a .loop file for Import, or null if `path` is not a readable
## loop file. Nothing is added to the store: what peek_loop shows and what
## import_loop brings in is this one read, so a file changed on disk while
## the question is up is never imported unseen.
func read_import(path: String) -> LoopProjectT:
	return _read_loop_file(path)


## What a loop read for Import holds, for the question asked before it is
## imported: {"name": its first layer's name, "layers": count, "actions":
## count, "keys": the text of every Key action, in order}.
func peek_loop(p: LoopProjectT) -> Dictionary:
	var actions := 0
	var keys: Array[String] = []
	for layer in p.layers:
		actions += layer.actions.size()
		for a in layer.actions:
			if a.type == LoopActionT.Type.KEY:
				# As it is typed; the question marks it for showing (see
				# LoopAction.ltr_marked) after measuring and cutting it.
				keys.append(a.keys)   # (cleaned when it was read)
	return {"name": p.layers[0].name, "layers": p.layers.size(), "actions": actions, "keys": keys}


## Brings a loop read by read_import into the store as a new loop (written
## to the store right away, so it is there next time) and opens it. Returns
## the new loop's id.
func import_loop(source: LoopProjectT) -> int:
	# The Safe dry-run the import question asks for walks every detect
	# through (see LoopAction.safe_continue): a file that turned that off
	# could have a guard skip, in Safe, the very layer Live then runs.
	for layer in source.layers:
		for a in layer.actions:
			a.safe_continue = true
	# Never under the name of a loop already here: a stranger's file named
	# like one of the user's would sit beside it in the picker, told apart
	# by nothing but its place.
	# Compared as they look, not as they are spelled: a no-break space, a
	# decomposed accent or another case reads the same in the picker.
	var taken: Array = []
	for existing in loop_names():
		taken.append(_name_skeleton(existing))
	# Always marked as imported, not only when a name matches: a look-alike
	# letter (a Cyrillic "а") passes any comparison and reads the same.
	# In front, where a picker or status line cut to its width still shows it.
	# (Cleaned again after the cut: it can leave a joiner last.)
	var base := LoopLayerT.clean_name(source.layers[0].name.left(IMPORTED_BASE_CHARS))
	var name := "%s %s" % [IMPORTED_MARK, base]
	var n := 2
	while _name_skeleton(name) in taken:
		name = "%s %d %s" % [IMPORTED_MARK, n, base]
		n += 1
	source.layers[0].name = name
	var id := create_loop(false, source)
	# ...and remembered with the loop: it is named after whichever layer is
	# first, and a layer moved up or the first one deleted must not give it
	# an unmarked name (see _sync_loop_name).
	loop_stack[_loop_index_from_id(id)]["imported"] = true
	var key := str(id)
	if _write_project_file(_loop_file_path(id), _session_projects_by_id[key]) == OK:
		_pending_by_id[key] = false
	_open_project_for_id(id)
	return id


## `name` as it reads rather than as it is spelled, for telling two names
## apart: no accents, no case, no spaces of any kind.
static func _name_skeleton(name: String) -> String:
	if _spaces == null:
		# (Joiners and selectors too: they show as nothing.)
		_spaces = RegEx.create_from_string("[\\p{Z}\\s\\x{200C}\\x{200D}\\x{FE0E}\\x{FE0F}]+")
	var plain := TextServerManager.get_primary_interface().strip_diacritics(name).to_lower()
	return _spaces.sub(plain, "", true)
static var _spaces: RegEx = null


## Adds a copy of the current loop to the store and opens it: the same
## layers, actions and delay, under the original's name with " copy"
## after it, numbered from 2 up if that name is taken (a copy of "X copy"
## is "X copy 2", not "X copy copy"). Like a new loop, the copy is unsaved
## until Save. Returns the copy's id, or -1 if there is no loop open.
func duplicate_loop() -> int:
	if project == null or project.layers.is_empty():
		return -1
	_sync_loop_name()
	# Through the file format, so nothing is shared with the original.
	var copy := LoopProjectT.from_dict(project.to_dict())
	copy.layers[0].name = copy_name(project.layers[0].name, loop_names())
	# A copy of an imported loop is still someone else's loop: it keeps the
	# mark (see import_loop).
	var idx := _loop_index_from_id(active_loop_id)
	var imported := idx >= 0 and bool(loop_stack[idx].get("imported", false))
	var id := create_loop(false, copy)
	if imported:
		loop_stack[_loop_index_from_id(id)]["imported"] = true
		_save_store_index()
	_open_project_for_id(id)
	return id


## "<original> copy", or "<original> copy N" from 2 up when that is in `taken`.
## A trailing " copy" / " copy N" on `original` is replaced, not stacked.
static func copy_name(original: String, taken: Array) -> String:
	var copy_suffix := RegEx.create_from_string("(?i) copy( \\d+)?$")
	var base := "%s copy" % copy_suffix.sub(original.strip_edges(), "")
	var name := base
	var n := 2
	while name in taken:
		name = "%s %d" % [base, n]
		n += 1
	return name


## Removes a loop from the store, its file included, and opens the loop
## before it (or a fresh one when it was the only loop). Returns false if
## `loop_id` is not in the store.
func delete_loop(loop_id: int) -> bool:
	var idx := _loop_index_from_id(loop_id)
	if idx < 0:
		return false
	var entry := loop_stack[idx]
	loop_stack.remove_at(idx)
	var key := str(loop_id)
	_session_projects_by_id.erase(key)
	_pending_by_id.erase(key)
	var file := String(entry.get("file", ""))
	if not file.is_empty() and FileAccess.file_exists(file):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(file))
	# ...and a copy a save cut short left beside it (it can hold all of the
	# loop - what Rec recorded typing too): the question says the file goes.
	# (And one set aside as unreadable - see _read_project_file - which can
	# hold all of it too.)
	for leftover in [file + ".tmp", file + ".broken"]:
		if not file.is_empty() and FileAccess.file_exists(leftover):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(leftover))
	if loop_stack.is_empty():
		active_loop_id = -1
		create_loop(true)
	elif loop_id == active_loop_id:
		active_loop_id = -1
		_open_project_for_id(int(loop_stack[maxi(0, idx - 1)].get("id", -1)))
		emit_signal("loop_stack_changed")
	else:
		_save_store_index()
		emit_signal("loop_stack_changed")
	return true


func open_loop(loop_id: int) -> bool:
	var idx := _loop_index_from_id(loop_id)
	if idx < 0:
		return false
	_open_project_for_id(loop_id)
	return true


func step_loop(delta: int) -> bool:
	if loop_stack.is_empty():
		return false
	var current_idx := _loop_index_from_id(active_loop_id)
	if current_idx < 0:
		current_idx = 0
	var target := wrapi(current_idx + delta, 0, loop_stack.size())
	return open_loop(int(loop_stack[target].get("id", -1)))


func save_active_loop() -> Error:
	var idx := _loop_index_from_id(active_loop_id)
	if idx < 0:
		return ERR_DOES_NOT_EXIST
	var entry := loop_stack[idx]
	if project == null:
		return ERR_INVALID_DATA
	_sync_loop_name()
	var err := _write_project_file(String(entry.get("file", "")), project)
	if err != OK:
		return err
	current_path = String(entry.get("file", ""))
	_pending_by_id[str(active_loop_id)] = false
	_save_store_index()
	emit_signal("loop_stack_changed")
	emit_signal("pending_changed", false)
	return OK


func active_loop_is_pending() -> bool:
	if active_loop_id < 0:
		return false
	return bool(_pending_by_id.get(str(active_loop_id), false))


## How many loops of the list have changes not saved (see main's close).
func pending_loop_count() -> int:
	var n := 0
	for entry in loop_stack:
		if loop_is_pending(int(entry.get("id", -1))):
			n += 1
	return n


func loop_is_pending(loop_id: int) -> bool:
	if loop_id < 0:
		return false
	return bool(_pending_by_id.get(str(loop_id), false))


func active_loop_display_name() -> String:
	var idx := _loop_index_from_id(active_loop_id)
	if idx < 0:
		return "-"
	var entry := loop_stack[idx]
	var raw := String(entry.get("name", str(active_loop_id))).strip_edges()
	return raw if not raw.is_empty() else str(active_loop_id)


func active_loop_stack_index() -> int:
	return _loop_index_from_id(active_loop_id)


## Writes a copy of the current loop to `path` (Share → Export). The loop
## in the store is untouched: it keeps its name and stays saved or unsaved
## as it was.
func export_to(path: String) -> Error:
	if project == null:
		return ERR_INVALID_DATA
	_sync_loop_name()
	return _write_project_file(path, project)


func _mark_pending() -> void:
	if active_loop_id < 0:
		return
	var key := str(active_loop_id)
	_session_projects_by_id[key] = project
	if bool(_pending_by_id.get(key, false)):
		return
	_pending_by_id[key] = true
	emit_signal("pending_changed", true)
	emit_signal("loop_stack_changed")


func _open_project_for_id(loop_id: int) -> void:
	var idx := _loop_index_from_id(loop_id)
	if idx < 0:
		return
	active_loop_id = loop_id
	var key := str(loop_id)
	if not _session_projects_by_id.has(key):
		var entry := loop_stack[idx]
		var loaded := _read_project_file(String(entry.get("file", "")), String(entry.get("name", str(loop_id))))
		_session_projects_by_id[key] = loaded
		_pending_by_id[key] = bool(_pending_by_id.get(key, false))
	project = _session_projects_by_id[key]
	_sync_loop_name()
	solo_layer = null
	active_layer_index = 0
	selected_action_index = -1
	overlay_layer_index = 0
	overlay_show_all = false
	current_path = String(loop_stack[idx].get("file", ""))
	_save_store_index()
	emit_signal("project_replaced")
	emit_signal("active_loop_changed", active_loop_id)
	emit_signal("pending_changed", active_loop_is_pending())


func _ensure_store_dirs() -> void:
	var abs_dir := ProjectSettings.globalize_path(STORE_LOOPS_DIR)
	DirAccess.make_dir_recursive_absolute(abs_dir)


func _load_or_init_store() -> void:
	_recover_tmp(STORE_INDEX_PATH)
	if not FileAccess.file_exists(STORE_INDEX_PATH):
		loop_stack = []
		active_loop_id = -1
		_next_loop_id = 1
		_save_store_index()
		return
	var f := FileAccess.open(STORE_INDEX_PATH, FileAccess.READ)
	if f == null:
		loop_stack = []
		active_loop_id = -1
		_next_loop_id = 1
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		loop_stack = []
		active_loop_id = -1
		_next_loop_id = 1
		return
	var data: Dictionary = parsed
	loop_stack = []
	var loops: Variant = data.get("loops", [])
	for raw in (loops if typeof(loops) == TYPE_ARRAY else []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = raw
		var id := LoopActionT.read_int(e, "id", -1)
		if id < 0 or _loop_index_from_id(id) >= 0:
			continue
		loop_stack.append({
			"id": id,
			"name": LoopLayerT.clean_name(LoopActionT.read_string(e, "name", str(id))),
			"file": _store_loop_file(id, LoopActionT.read_string(e, "file", "")),
			"imported": LoopActionT.read_bool(e, "imported", false),
		})
	_next_loop_id = maxi(1, LoopActionT.read_int(data, "next_loop_id", 1))
	for e in loop_stack:
		_next_loop_id = maxi(_next_loop_id, int(e.get("id", 0)) + 1)
	active_loop_id = LoopActionT.read_int(data, "active_loop_id", -1)
	if _loop_index_from_id(active_loop_id) < 0 and not loop_stack.is_empty():
		active_loop_id = int(loop_stack[0].get("id", -1))


func _save_store_index() -> void:
	var payload := {
		"version": STORE_VERSION,
		"next_loop_id": _next_loop_id,
		"active_loop_id": active_loop_id,
		"loops": loop_stack,
	}
	_write_text_file(STORE_INDEX_PATH, JSON.stringify(payload, "\t"))


func _loop_index_from_id(loop_id: int) -> int:
	for i in loop_stack.size():
		if int(loop_stack[i].get("id", -1)) == loop_id:
			return i
	return -1


func _loop_file_path(loop_id: int) -> String:
	return "%s/%d.loop" % [STORE_LOOPS_DIR, loop_id]


## The file a store entry may point at: a `.loop` directly inside
## user://loops, nothing else. The index is read back from disk and its paths
## are used for both reads and writes, so an entry that names any other
## location (a different folder, a parent directory, another file type) is
## given the default path for its id instead.
static func _store_loop_file(loop_id: int, raw: String) -> String:
	var file := raw.get_file()
	if raw == "%s/%s" % [STORE_LOOPS_DIR, file] and file.is_valid_filename() \
			and file.get_extension() == "loop" and file.get_basename().length() > 0:
		return raw
	return "%s/%d.loop" % [STORE_LOOPS_DIR, loop_id]


## The loop in a store file. A file that is there but is not a loop (cut
## short by a crash while it was written, edited by hand, too big) is not
## thrown away: it is moved aside as "<name>.broken" - the next Save would
## otherwise write over it - and the loop opens empty. One that cannot be
## opened at all (held by another program) is left where it is.
func _read_project_file(path: String, fallback_name: String) -> LoopProjectT:
	_recover_tmp(path)
	if FileAccess.file_exists(path):
		var abs := ProjectSettings.globalize_path(path)
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			push_warning("ProjectData: could not open %s (error %d)." % [abs, FileAccess.get_open_error()])
		else:
			var loaded := _read_loop(f, false)
			if loaded != null:
				if loaded.name.strip_edges().is_empty():
					loaded.name = fallback_name
				return loaded
			var aside := path + ".broken"
			if DirAccess.rename_absolute(abs, ProjectSettings.globalize_path(aside)) == OK:
				push_warning("ProjectData: %s is not a readable loop file; kept as %s." % [abs, aside.get_file()])
			else:
				push_warning("ProjectData: %s is not a readable loop file." % abs)
	# Never saved: an empty loop that keeps the name it was given (the loop is
	# named after its first layer, so that is where the name goes).
	var p := LoopProjectT.make_default()
	p.name = fallback_name
	if not fallback_name.strip_edges().is_empty():
		p.layers[0].name = fallback_name
	return p


## Puts `path`'s ".tmp" in its place when `path` itself is missing: on
## Windows the rename in _write_text_file removes the old file first, so a
## crash right then leaves the whole new file as the .tmp and nothing else -
## which the next write of the same file would empty. (A .tmp beside a file
## that is there is a write cut short, and is left alone.)
static func _recover_tmp(path: String) -> void:
	var tmp := path + ".tmp"
	if FileAccess.file_exists(path) or not FileAccess.file_exists(tmp):
		return
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(tmp), ProjectSettings.globalize_path(path)) == OK:
		push_warning("ProjectData: %s was missing; restored it from %s." % [path.get_file(), tmp.get_file()])


func _write_project_file(path: String, value: LoopProjectT) -> Error:
	return _write_text_file(path, value.to_json())


## Writes `text` to `path` by way of a file beside it that is renamed into
## place once it is whole, so a crash (or the power going) mid-write leaves
## what was there (a loop, the store index) as it was, never a file cut
## short.
static func _write_text_file(path: String, text: String) -> Error:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	var err := f.get_error()
	f.close()
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	if err != OK:
		DirAccess.remove_absolute(abs_tmp)
		return err
	# (On Windows the rename removes the old file first; if it then failed,
	# the whole new file is still there as .tmp, so that is left alone.)
	err = DirAccess.rename_absolute(abs_tmp, ProjectSettings.globalize_path(path))
	if err != OK:
		push_warning("ProjectData: could not put %s in place (error %d); what was written is in %s." % [path.get_file(), err, abs_tmp])
	return err
