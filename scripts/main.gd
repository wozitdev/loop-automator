extends Control
## Builder window: toolbar, layer panel, action list, and a dynamic action
## editor. Talks to the ProjectData / Playback autoloads and drives the overlay.

const OverlayScene := preload("res://scenes/overlay.tscn")
const OverlayT := preload("res://scripts/overlay.gd")
const PickOverlayT := preload("res://scripts/pick_overlay.gd")
const KeyCaptureT := preload("res://scripts/key_capture.gd")
const UiIconsT := preload("res://scripts/ui_icons.gd")

## Preload model scripts so all type/enum references resolve regardless of
## script import order (the global `class_name` registry may lag on first import).
const LoopActionT := preload("res://scripts/model/loop_action.gd")
const LoopLayerT := preload("res://scripts/model/loop_layer.gd")

# --- top-level UI refs ----------------------------------------------------
var status_label: Label
var play_btn: Button
var loop_prev_btn: Button
var loop_next_btn: Button
var loop_picker: OptionButton
var overlay_btn: Button
var overlay_label: Label
var show_all_btn: Button
var backend_option: OptionButton
## The loop delay in the toolbar (a RangePair, see below).
var _delay_pair: RangePair
var new_btn: Button
var save_btn: Button
var delete_loop_btn: Button
var duplicate_loop_btn: Button
var share_btn: MenuButton
var stay_on_edit_check: CheckBox
## "~Delay ms": checked, the delay is also waited after every action
## (saved with the loop).
var delay_each_check: CheckBox
var feedback_check: CheckBox
var hotkey_check: CheckBox
var _ui_root: VBoxContainer
var _main_split: HSplitContainer
var _edit_lock_blocker: ColorRect
var _stop_cooldown_active: bool = false
var _stop_cooldown_token: int = 0

const STOP_COOLDOWN_STEP_SEC := 0.18

## Per-user UI preferences (not part of any loop file).
const SETTINGS_PATH := "user://settings.cfg"

# --- layer panel ----------------------------------------------------------
var layer_list: ItemList
var layer_visible_check: CheckBox
var layer_enabled_check: CheckBox
var layer_color_btn: ColorPickerButton

# --- action panel ---------------------------------------------------------
var actions_header: Label
var action_list: ItemList
## Which layer's actions the action_list currently shows (-1 = none/stale).
var _shown_layer_index: int = -1

# --- editor ---------------------------------------------------------------
var editor_box: VBoxContainer
var _loading_editor: bool = false
## The action the editor shows and where it sits (layer, index). A SpinBox
## commits typed text when it loses the focus, which happens *as* another
## action or layer is clicked — by then the selection may already have
## moved, so the change is written to this action's list item, not the
## selected one's.
var _editing_action: LoopActionT
var _editing_layer_index: int = -1
var _editing_action_index: int = -1

# --- overlay --------------------------------------------------------------
var overlay: OverlayT

# --- on-screen picking ----------------------------------------------------
var picker: PickOverlayT
var _pick_active: bool = false
var _pick_was_overlay_visible: bool = false
var _pick_point_cb: Callable = Callable()
var _pick_rect_cb: Callable = Callable()
## The builder is moved off-screen for the duration of a pick (when enabled in
## the toolbar) so the desktop underneath is visible; moved back when the pick
## ends. Off-screen rather than minimised so it keeps keyboard focus: the pick
## window must never be focused (see PickOverlay), and Esc arrives here.
var _builder_hidden_for_pick: bool = false
var _builder_prev_pos: Vector2i = Vector2i.ZERO
var _builder_prev_mode: int = Window.MODE_WINDOWED
## A colour read is in flight after a pick: keep the builder out of the way
## until it has finished, otherwise the read would hit the builder itself.
var _sample_pending: bool = false
## Live colour-under-cursor preview during a colour pick. Each read spawns a
## PowerShell process (~0.2 s), so it runs on a worker thread.
var _hover_sampling: bool = false
var _hover_thread: Thread
var _hover_last_pos: Vector2i = Vector2i.ZERO
var _hover_has_last: bool = false

# --- key capture ----------------------------------------------------------
## The on-screen keyboard (created on first use) and the Keys field / action
## it is currently filling.
var _key_capture: KeyCaptureT
var _key_capture_field: LineEdit
var _key_capture_action: LoopActionT
## The Image Detect editor's "bigger than the rect" label, and the action it
## is about (null when the editor shows something else).
var _image_fit_warning: Label
var _image_fit_action: LoopActionT
## The Image Detect full-size view (see _show_image_preview), made on first use.
var _image_preview: AcceptDialog


func _ready() -> void:
	_configure_window()
	_build_ui()
	_connect_signals()
	_refresh_layers()
	_refresh_actions()
	_refresh_layer_props()
	_rebuild_editor()
	_create_overlay()
	_refresh_edit_lock()
	_show_splash()


## How long the splash stays before it fades, and how long the fade takes.
const SPLASH_HOLD_SEC := 0.9
const SPLASH_FADE_SEC := 0.5


## A splash over the builder at launch: the icon and the name on the icon's
## own dark, fading out once the window is up. Nothing under it is
## clickable meanwhile (it is gone in under two seconds).
func _show_splash() -> void:
	var splash := ColorRect.new()
	splash.color = Color("1f2430")
	splash.set_anchors_preset(Control.PRESET_FULL_RECT)
	splash.mouse_filter = Control.MOUSE_FILTER_STOP
	var centre := CenterContainer.new()
	centre.set_anchors_preset(Control.PRESET_FULL_RECT)
	splash.add_child(centre)
	var column := VBoxContainer.new()
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 14)
	centre.add_child(column)
	var icon := TextureRect.new()
	icon.texture = load("res://icon.svg")
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.custom_minimum_size = Vector2(112, 112)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	column.add_child(icon)
	var name_lbl := Label.new()
	name_lbl.text = "Loop Automator"
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_lbl.add_theme_font_size_override("font_size", 30)
	name_lbl.add_theme_color_override("font_color", Color("e8edf5"))
	column.add_child(name_lbl)
	var sub := Label.new()
	sub.text = "mouse + keyboard loops, with an overlay"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_color_override("font_color", Color("4dd0e1"))
	column.add_child(sub)
	add_child(splash)
	var tween := create_tween()
	tween.tween_interval(SPLASH_HOLD_SEC)
	tween.tween_property(splash, "modulate:a", 0.0, SPLASH_FADE_SEC)
	tween.tween_callback(splash.queue_free)


func _configure_window() -> void:
	var win := get_window()
	if win == null:
		return
	# Keep the builder comfortably sized on launch while still scaling on small
	# displays and preserving user resize behavior afterward.
	win.min_size = Vector2i(960, 620)
	var screen := maxi(0, win.current_screen)
	var usable := DisplayServer.screen_get_usable_rect(screen)
	var target := Vector2i(mini(usable.size.x - 40, 1240), mini(usable.size.y - 56, 760))
	target.x = maxi(target.x, win.min_size.x)
	target.y = maxi(target.y, win.min_size.y)
	win.size = target
	win.position = usable.position + (usable.size - target) / 2
	# Keep control sizes stable while resizing (no automatic UI zoom).
	win.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED


# ======================================================================
#  UI construction
# ======================================================================
## Breathing room between the window edges and the UI.
const UI_MARGIN := 8

func _build_ui() -> void:
	# A small margin around everything so nothing touches the window edges.
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, UI_MARGIN)
	add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	margin.add_child(root)
	_ui_root = root

	root.add_child(_build_toolbar())

	# The panels sit in a plain Control (not a container) so the lock
	# blocker can lie over them: a container would lay the blocker out as
	# one more pane and squeeze it to nothing.
	var stage := Control.new()
	stage.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stage.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(stage)
	var split := HSplitContainer.new()
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	split.split_offset = 280
	stage.add_child(split)
	_main_split = split

	split.add_child(_build_layer_panel())

	# Actions get more room than the editor (3 : 2).
	var right_split := HSplitContainer.new()
	right_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(right_split)

	var action_panel := _build_action_panel()
	action_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	action_panel.size_flags_stretch_ratio = 3.0
	right_split.add_child(action_panel)
	var editor_panel := _build_editor_panel()
	editor_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor_panel.size_flags_stretch_ratio = 2.0
	right_split.add_child(editor_panel)

	# Over the panels while a Live run locks the builder: dims them and
	# swallows every click (the toolbar above stays usable: Run / Stop).
	_edit_lock_blocker = ColorRect.new()
	_edit_lock_blocker.set_anchors_preset(Control.PRESET_FULL_RECT)
	_edit_lock_blocker.color = Color(0.0, 0.0, 0.0, 0.20)
	_edit_lock_blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	_edit_lock_blocker.visible = false
	stage.add_child(_edit_lock_blocker)

	root.add_child(_build_status_bar())


func _build_status_bar() -> Control:
	var bar := PanelContainer.new()
	var hb := HBoxContainer.new()
	bar.add_child(hb)
	status_label = Label.new()
	status_label.text = "Ready."
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_label.clip_text = true
	hb.add_child(status_label)
	return bar


func _build_toolbar() -> Control:
	var bar := PanelContainer.new()
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 6)

	# --- Playback ---------------------------------------------------------
	play_btn = _icon_button(UiIconsT.play(), "", _on_play_pressed)
	play_btn.text = _run_label()
	hb.add_child(play_btn)

	var backend_lbl := Label.new()
	backend_lbl.text = "Mode"
	hb.add_child(backend_lbl)
	backend_option = OptionButton.new()
	backend_option.add_item("Safe", Playback.BackendKind.PREVIEW)
	backend_option.add_item("Live", Playback.BackendKind.WINDOWS)
	backend_option.item_selected.connect(_on_backend_selected)
	hb.add_child(backend_option)

	hb.add_child(_vsep())

	# --- Loop management --------------------------------------------------
	new_btn = _tool_button("New", _on_new)
	new_btn.tooltip_text = "Start a new loop (its first layer, and so the loop, gets a random name)"
	hb.add_child(new_btn)
	var loop_lbl := Label.new()
	loop_lbl.text = "Loop"
	hb.add_child(loop_lbl)
	loop_prev_btn = _icon_button(UiIconsT.left(), "Previous loop", func(): _switch_loop(-1))
	hb.add_child(loop_prev_btn)
	loop_picker = OptionButton.new()
	# One width whatever the loop is called: room for "1. @@@@@@@@ *", a
	# longer name is cut with "…" (the list that drops down shows it whole).
	loop_picker.fit_to_longest_item = false
	loop_picker.clip_text = true
	loop_picker.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	loop_picker.custom_minimum_size = Vector2(_option_button_width(loop_picker, "1. @@@@@@@@ *"), 0)
	loop_picker.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	loop_picker.item_selected.connect(_on_loop_picker_selected)
	hb.add_child(loop_picker)
	loop_next_btn = _icon_button(UiIconsT.right(), "Next loop", func(): _switch_loop(1))
	hb.add_child(loop_next_btn)

	save_btn = _icon_button(UiIconsT.save(), "Save: write this loop to its file", _on_save)
	hb.add_child(save_btn)
	# Share: a .loop file in or out.
	share_btn = MenuButton.new()
	share_btn.text = "Share"
	share_btn.flat = false
	share_btn.focus_mode = Control.FOCUS_NONE
	share_btn.tooltip_text = "Import a .loop file as a new loop, or export this loop to one"
	var share_menu := share_btn.get_popup()
	share_menu.add_item("Import a .loop file…", 0)
	share_menu.add_item("Export this loop…", 1)
	share_menu.id_pressed.connect(func(id: int):
		if id == 0:
			_on_import()
		else:
			_on_export())
	hb.add_child(share_btn)
	duplicate_loop_btn = _icon_button(UiIconsT.copy(), "Duplicate this loop", _on_duplicate_loop)
	hb.add_child(duplicate_loop_btn)
	delete_loop_btn = _icon_button(UiIconsT.trash(), "Delete this loop (its file too)", _confirm_delete_loop)
	hb.add_child(delete_loop_btn)

	hb.add_child(_vsep())

	# --- Timing -----------------------------------------------------------
	# The delay's label is a checkbox, "~Delay ms": checked, the delay is
	# also waited after every action.
	var delay_tip := "Pause after the loop's last action, before it starts over (ms). Saved with the loop."
	delay_each_check = CheckBox.new()
	delay_each_check.text = "~Delay"
	delay_each_check.focus_mode = Control.FOCUS_NONE
	delay_each_check.tooltip_text = "%s\nChecked: also wait it after every action." % delay_tip
	delay_each_check.button_pressed = ProjectData.project.delay_after_each_action
	delay_each_check.toggled.connect(func(v: bool): ProjectData.set_delay_after_each_action(v))
	hb.add_child(delay_each_check)
	# A RangePair like the editor fields: "~" expands it to a min - max pause.
	# The controls sit in the toolbar row at a fixed width (no expand).
	_delay_pair = RangePair.new()
	_delay_pair.build(hb, ProjectData.project.loop_delay_ms, ProjectData.project.loop_delay_ms_max, 0, 60000, func(l: int, h: int):
		ProjectData.set_loop_delay(l, h))
	for sp in [_delay_pair.lo, _delay_pair.hi]:
		sp.size_flags_horizontal = Control.SIZE_FILL
		sp.custom_minimum_size = Vector2(96, 0)
	_delay_pair.set_suffix("ms")
	_delay_pair.single_tip = delay_tip
	if not _delay_pair.ranged:
		_delay_pair.lo.tooltip_text = delay_tip

	# --- Self-interaction toggles (right-aligned) ---------------------------
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)
	# ~Edit: unchecked = the builder is moved out of the way while you pick on
	# screen (the stored setting keeps the "lower on edit" sense).
	stay_on_edit_check = CheckBox.new()
	stay_on_edit_check.text = "~Edit"
	stay_on_edit_check.focus_mode = Control.FOCUS_NONE
	stay_on_edit_check.button_pressed = not _load_setting("lower_on_edit", true)
	stay_on_edit_check.toggled.connect(func(v): _save_setting("lower_on_edit", not v))
	hb.add_child(stay_on_edit_check)
	# Embedding is only reported once the window has been parented, so check
	# again a moment after startup (and at every pick).
	_refresh_stay_on_edit_check.call_deferred()
	# ~Self: may a running loop act on Loop Automator itself? (The setting
	# keeps its original "feedback" key.)
	feedback_check = CheckBox.new()
	feedback_check.text = "~Self"
	feedback_check.focus_mode = Control.FOCUS_NONE
	feedback_check.tooltip_text = "Checked: a running loop may interact with Loop Automator itself (clicks and keys can land on this window, like a feedback loop).\nUnchecked: clicks and keys that would land on Loop Automator are skipped, so the loop cannot affect the app running it."
	feedback_check.button_pressed = _load_setting("feedback", false)
	Playback.set_feedback(feedback_check.button_pressed)
	feedback_check.toggled.connect(func(v):
		_save_setting("feedback", v)
		Playback.set_feedback(v))
	hb.add_child(feedback_check)
	# ~F8: the global F8 is held the whole time the app is open, so a loop
	# can be started and stopped from any window. Off, F8 is left to other
	# programs and only works in this window.
	hotkey_check = CheckBox.new()
	hotkey_check.text = "~F8"
	hotkey_check.focus_mode = Control.FOCUS_NONE
	hotkey_check.tooltip_text = "Checked: F8 starts and stops the loop from any window while Loop Automator is open (other programs do not get F8 meanwhile).\nUnchecked: F8 only works while this window has the focus."
	hotkey_check.button_pressed = _load_setting("global_hotkey", true)
	Playback.set_global_hotkey(hotkey_check.button_pressed)
	hotkey_check.toggled.connect(func(v):
		_save_setting("global_hotkey", v)
		Playback.set_global_hotkey(v))
	hb.add_child(hotkey_check)

	# Let the toolbar scroll horizontally instead of pushing items off-screen
	# on narrow windows.
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(0, 34)
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(hb)
	bar.add_child(scroll)

	return bar


func _build_layer_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(260, 0)
	var vb := VBoxContainer.new()
	panel.add_child(vb)

	vb.add_child(_section_label("Layers"))

	layer_list = ItemList.new()
	layer_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layer_list.allow_reselect = true
	layer_list.item_selected.connect(func(i):
		ProjectData.set_active_layer(i)
		# Keep the overlay focused on the layer you're editing (unless showing all).
		if not ProjectData.overlay_show_all:
			ProjectData.set_overlay_layer(i))
	layer_list.item_activated.connect(func(i): _rename_layer_dialog(i))
	vb.add_child(layer_list)

	var btns := HBoxContainer.new()
	btns.add_child(_icon_button(UiIconsT.plus(), "Add a layer", func(): ProjectData.add_layer()))
	btns.add_child(_icon_button(UiIconsT.up(), "Move this layer up", func(): ProjectData.move_layer(ProjectData.active_layer_index, -1)))
	btns.add_child(_icon_button(UiIconsT.down(), "Move this layer down", func(): ProjectData.move_layer(ProjectData.active_layer_index, 1)))
	btns.add_child(_tool_button("Rename", func(): _rename_layer_dialog(ProjectData.active_layer_index)))
	btns.add_child(_icon_button(UiIconsT.copy(), "Duplicate this layer", func(): ProjectData.duplicate_layer(ProjectData.active_layer_index)))
	btns.add_child(_icon_button(UiIconsT.trash(), "Delete this layer", _confirm_delete_layer))
	vb.add_child(btns)

	vb.add_child(HSeparator.new())
	vb.add_child(_section_label("Overlay view"))

	var ov_row := HBoxContainer.new()
	overlay_btn = Button.new()
	overlay_btn.text = "Overlay"
	overlay_btn.toggle_mode = true
	overlay_btn.focus_mode = Control.FOCUS_NONE
	overlay_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overlay_btn.toggled.connect(_on_overlay_toggle)
	ov_row.add_child(overlay_btn)
	show_all_btn = Button.new()
	show_all_btn.text = "All"
	show_all_btn.toggle_mode = true
	show_all_btn.focus_mode = Control.FOCUS_NONE
	show_all_btn.tooltip_text = "Draw every visible layer at once (\\)"
	show_all_btn.toggled.connect(func(v): ProjectData.set_overlay_show_all(v))
	ov_row.add_child(show_all_btn)
	vb.add_child(ov_row)

	var nav_row := HBoxContainer.new()
	var prev_layer_btn := _icon_button(UiIconsT.left(), "Previous layer", func(): _go_overlay_layer(-1))
	nav_row.add_child(prev_layer_btn)
	overlay_label = Label.new()
	overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	overlay_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	overlay_label.clip_text = true
	overlay_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nav_row.add_child(overlay_label)
	var next_layer_btn := _icon_button(UiIconsT.right(), "Next layer", func(): _go_overlay_layer(1))
	nav_row.add_child(next_layer_btn)
	vb.add_child(nav_row)

	vb.add_child(HSeparator.new())
	vb.add_child(_section_label("Layer properties"))

	layer_visible_check = CheckBox.new()
	layer_visible_check.text = "Visible in overlay"
	layer_visible_check.toggled.connect(func(v):
		var l := ProjectData.active_layer()
		if l: l.visible = v
		ProjectData.emit_signal("layers_changed")
		ProjectData.emit_signal("overlay_view_changed"))
	vb.add_child(layer_visible_check)

	layer_enabled_check = CheckBox.new()
	layer_enabled_check.text = "Enabled (runs in loop)"
	layer_enabled_check.toggled.connect(func(v):
		var l := ProjectData.active_layer()
		if l: l.enabled = v
		ProjectData.emit_signal("layers_changed"))
	vb.add_child(layer_enabled_check)

	var color_row := HBoxContainer.new()
	var cl := Label.new()
	cl.text = "Colour:"
	color_row.add_child(cl)
	layer_color_btn = ColorPickerButton.new()
	layer_color_btn.custom_minimum_size = Vector2(60, 0)
	layer_color_btn.color_changed.connect(func(c):
		var l := ProjectData.active_layer()
		if l: l.color = c
		ProjectData.emit_signal("layers_changed")
		ProjectData.emit_signal("overlay_view_changed"))
	color_row.add_child(layer_color_btn)
	vb.add_child(color_row)

	return panel


func _build_action_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(320, 0)
	var vb := VBoxContainer.new()
	panel.add_child(vb)

	actions_header = _section_label("Actions")
	vb.add_child(actions_header)

	action_list = ItemList.new()
	action_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	action_list.allow_reselect = true
	action_list.item_selected.connect(func(i): ProjectData.set_selected_action(i))
	vb.add_child(action_list)

	var btns := HBoxContainer.new()
	var add_btn := MenuButton.new()
	add_btn.text = "Add Action"
	add_btn.icon = UiIconsT.plus()
	add_btn.flat = false
	var pm := add_btn.get_popup()
	for t in [LoopActionT.Type.MOVE, LoopActionT.Type.CLICK, LoopActionT.Type.DRAG,
			LoopActionT.Type.SCROLL, LoopActionT.Type.KEY, LoopActionT.Type.WAIT, LoopActionT.Type.PIXEL_DETECT,
			LoopActionT.Type.IMAGE_DETECT, LoopActionT.Type.CAPTURE, LoopActionT.Type.STOP]:
		pm.add_item(LoopActionT.type_name(t), t)
	pm.id_pressed.connect(func(id): ProjectData.add_action(id))
	btns.add_child(add_btn)
	var dup_btn := _icon_button(UiIconsT.copy(), "Duplicate the selected action", func(): ProjectData.duplicate_action(ProjectData.selected_action_index))
	dup_btn.text = "Duplicate"
	btns.add_child(dup_btn)
	btns.add_child(_icon_button(UiIconsT.up(), "Move the selected action up", func(): ProjectData.move_action(ProjectData.selected_action_index, -1)))
	btns.add_child(_icon_button(UiIconsT.down(), "Move the selected action down", func(): ProjectData.move_action(ProjectData.selected_action_index, 1)))
	var delete_btn := _icon_button(UiIconsT.trash(), "Delete the selected action", _confirm_delete_action)
	delete_btn.text = "Delete"
	btns.add_child(delete_btn)
	vb.add_child(btns)

	return panel


func _build_editor_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(320, 0)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(scroll)
	editor_box = VBoxContainer.new()
	editor_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(editor_box)
	return panel


# ======================================================================
#  Signals
# ======================================================================
func _connect_signals() -> void:
	ProjectData.layers_changed.connect(_refresh_layers)
	ProjectData.layers_changed.connect(_refresh_actions)
	ProjectData.layers_changed.connect(_refresh_overlay_label)
	ProjectData.actions_changed.connect(func(_i): _refresh_actions())
	ProjectData.selection_changed.connect(_on_selection_changed)
	ProjectData.overlay_view_changed.connect(_refresh_overlay_label)
	ProjectData.project_replaced.connect(_on_project_replaced)
	ProjectData.loop_stack_changed.connect(_refresh_loop_stack_ui)
	ProjectData.active_loop_changed.connect(func(_id): _refresh_loop_stack_ui())
	ProjectData.pending_changed.connect(func(_p): _refresh_loop_stack_ui())

	Playback.status.connect(func(m): status_label.text = m)
	Playback.playback_started.connect(func():
		_stop_cooldown_token += 1
		_stop_cooldown_active = false
		play_btn.icon = UiIconsT.stop()
		play_btn.text = "Stop"
		_refresh_edit_lock())
	Playback.playback_stopped.connect(func():
		var was_real := Playback.backend != null and Playback.backend.is_real()
		if was_real:
			_switch_to_safe_backend_if_needed()
		await _animate_stop_feedback(was_real))
	Playback.action_executing.connect(_on_action_executing)
	# The global F8 while idle (~F8): a start, as the Run button (a pick in
	# progress keeps the screen; the button's own cooldown after a stop holds).
	Playback.hotkey_pressed.connect(func():
		if not _pick_active and not _dialog_open():
			_on_play_pressed())
	_refresh_overlay_label()
	_refresh_loop_stack_ui()


func _on_selection_changed() -> void:
	# A number still being typed belongs to the action that *was* selected.
	_commit_pending_edits()
	_refresh_layers_selection()
	# If the active layer changed, repopulate the action list with that layer's
	# actions; otherwise just move the selection highlight.
	if _shown_layer_index != ProjectData.active_layer_index:
		_refresh_actions()
	else:
		_refresh_actions_selection()
	_refresh_layer_props()
	_rebuild_editor()


func _on_project_replaced() -> void:
	_delay_pair.set_values(ProjectData.project.loop_delay_ms, ProjectData.project.loop_delay_ms_max)
	delay_each_check.set_pressed_no_signal(ProjectData.project.delay_after_each_action)
	_refresh_layers()
	_refresh_actions()
	_refresh_layer_props()
	_rebuild_editor()
	_refresh_overlay_label()
	_refresh_loop_stack_ui()


## The tint behind the step (and the layer) a run is on. The selection is
## left alone: what you picked stays picked and the editor keeps showing it.
const RUNNING_TINT := Color(0.25, 0.55, 1.0, 0.28)


func _on_action_executing(_layer_index: int, _action_index: int) -> void:
	_refresh_running_marks()


## Tints the row of the step a run is on in the action list (when its layer
## is the one shown) and of its layer in the layer list; clears both when
## nothing runs.
func _refresh_running_marks() -> void:
	var li := Playback.current_layer_index if Playback.is_running else -1
	var ai := Playback.current_action_index if Playback.is_running else -1
	for i in action_list.item_count:
		var on := li == _shown_layer_index and i == ai
		action_list.set_item_custom_bg_color(i, RUNNING_TINT if on else Color(0, 0, 0, 0))
	for i in layer_list.item_count:
		layer_list.set_item_custom_bg_color(i, RUNNING_TINT if i == li else Color(0, 0, 0, 0))


# ======================================================================
#  Refresh helpers
# ======================================================================
func _refresh_layers() -> void:
	layer_list.clear()
	for i in ProjectData.project.layers.size():
		var l: LoopLayerT = ProjectData.project.layers[i]
		# Two marks in front of the name: runs / does not run, drawn / not
		# drawn on the overlay (the same check and cross as the action list).
		layer_list.add_item(l.name, UiIconsT.layer_marks(l.enabled, l.visible))
		layer_list.set_item_custom_fg_color(i, l.color)
		var tip := "Runs in the loop" if l.enabled else "Does not run (off)"
		tip += ", drawn on the overlay" if l.visible else ", not drawn on the overlay"
		layer_list.set_item_tooltip(i, tip)
	_refresh_layers_selection()
	_refresh_running_marks()


func _refresh_layers_selection() -> void:
	var idx := ProjectData.active_layer_index
	if idx >= 0 and idx < layer_list.item_count:
		layer_list.select(idx)


func _refresh_layer_props() -> void:
	var l := ProjectData.active_layer()
	if l == null:
		return
	layer_visible_check.set_pressed_no_signal(l.visible)
	layer_enabled_check.set_pressed_no_signal(l.enabled)
	layer_color_btn.color = l.color


func _refresh_actions() -> void:
	action_list.clear()
	var l := ProjectData.active_layer()
	if l != null:
		actions_header.text = "Actions — %s" % l.name
		for i in l.actions.size():
			var a: LoopActionT = l.actions[i]
			action_list.add_item("%d. %s" % [i + 1, a.describe()], UiIconsT.mark(a.enabled))
			if not a.comment.is_empty():
				action_list.set_item_tooltip(i, a.comment)
	else:
		actions_header.text = "Actions"
	# Remember which layer is shown so selection_changed knows when to repopulate.
	_shown_layer_index = ProjectData.active_layer_index
	_refresh_actions_selection()
	_refresh_running_marks()


func _refresh_actions_selection() -> void:
	var idx := ProjectData.selected_action_index
	if idx >= 0 and idx < action_list.item_count:
		action_list.select(idx)


## Rewrites one item of the action list from the model (the list shows the
## active layer; an item of another layer is refreshed when that layer is
## shown again).
func _update_list_item(layer_index: int, index: int) -> void:
	if layer_index != _shown_layer_index or index < 0 or index >= action_list.item_count:
		return
	var a: LoopActionT = ProjectData.project.layers[layer_index].actions[index]
	action_list.set_item_text(index, "%d. %s" % [index + 1, a.describe()])
	action_list.set_item_icon(index, UiIconsT.mark(a.enabled))


## True while the action the editor was built for is still at the place it
## was built for (not removed, moved, or left behind by a loop switch).
func _editing_action_is_current() -> bool:
	if _editing_action == null or ProjectData.project == null:
		return false
	var layers := ProjectData.project.layers
	if _editing_layer_index < 0 or _editing_layer_index >= layers.size():
		return false
	var actions: Array = layers[_editing_layer_index].actions
	return _editing_action_index >= 0 and _editing_action_index < actions.size() \
			and actions[_editing_action_index] == _editing_action


## Writes any number a SpinBox is still holding as typed text into the model
## (what losing the focus would do, deferred), so nothing typed is lost or
## misfiled when the editor is rebuilt, the loop changes, is saved, or runs.
func _commit_pending_edits() -> void:
	var boxes: Array = []
	if editor_box != null:
		boxes = editor_box.find_children("*", "SpinBox", true, false)
	if _delay_pair != null:
		boxes.append(_delay_pair.lo)
		boxes.append(_delay_pair.hi)
	for sp in boxes:
		if sp.get_meta(&"typed", false) and not sp.is_queued_for_deletion():
			(sp as SpinBox).apply()
			sp.set_meta(&"typed", false)


# ======================================================================
#  Dynamic action editor
# ======================================================================
func _rebuild_editor() -> void:
	_commit_pending_edits()
	_loading_editor = true
	_close_key_capture()
	for c in editor_box.get_children():
		c.queue_free()
	_image_fit_warning = null
	_image_fit_action = null

	var a := ProjectData.selected_action()
	_editing_action = a
	_editing_layer_index = ProjectData.active_layer_index
	_editing_action_index = ProjectData.selected_action_index
	if a == null:
		var hint := Label.new()
		hint.text = "Select or add an action to edit it."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		editor_box.add_child(hint)
		_loading_editor = false
		return

	editor_box.add_child(_section_label("Edit: %s" % LoopActionT.type_name(a.type)))

	var en := CheckBox.new()
	en.text = "Enabled"
	en.button_pressed = a.enabled
	en.toggled.connect(func(v):
		a.enabled = v
		_after_edit())
	editor_box.add_child(en)

	match a.type:
		LoopActionT.Type.MOVE:
			_add_point_fields(a, false)
			_add_duration_field(a)
			_add_captures_field(a)
		LoopActionT.Type.CLICK:
			_add_point_fields(a, false)
			_add_button_field(a)
			_add_hold_field(a)
			# Captures goes with a plain click (see Playback._execute_action).
			if a.press_mode == LoopActionT.PressMode.TAP:
				_add_captures_field(a)
		LoopActionT.Type.DRAG:
			_add_point_fields(a, true)
			_add_button_field(a)
			_add_duration_field(a)
			_add_captures_field(a)
		LoopActionT.Type.SCROLL:
			_add_point_fields(a, false)
			_add_scroll_fields(a)
			_add_duration_field(a, "How long the scroll takes: the notches are spread over it (0 = as fast as a wheel goes).\nChecked: the gaps between notches vary a little, like a hand's.")
		LoopActionT.Type.KEY:
			_add_keys_field(a)
		LoopActionT.Type.WAIT:
			_add_range_field("Wait", a.wait_ms, a.wait_ms_max, 0, 600000, func(lo: int, hi: int):
				a.wait_ms = lo
				a.wait_ms_max = hi, "ms")
		LoopActionT.Type.PIXEL_DETECT:
			_add_rect_fields(a)
			_add_color_field(a)
			_add_tolerance_field(a, "How far each colour channel may differ from the expected colour (0 = exact),")
			_add_on_fail_field(a)
		LoopActionT.Type.IMAGE_DETECT:
			_add_rect_fields(a)
			_add_image_field(a)
			_add_image_tolerance_fields(a)
			_add_on_fail_field(a)
		LoopActionT.Type.CAPTURE:
			_add_capture_mode_field(a)
		LoopActionT.Type.STOP:
			_add_stop_field(a)

	_add_comment_field(a)
	# Built during a Live run (the engine can switch an action off): locked
	# like everything else.
	if _is_interaction_locked():
		_set_controls_locked(editor_box, true)
	_loading_editor = false


func _after_edit() -> void:
	if _loading_editor or not _editing_action_is_current():
		return
	ProjectData.notify_action_modified()
	_update_list_item(_editing_layer_index, _editing_action_index)
	if _image_fit_action != null:
		_refresh_image_fit_warning(_image_fit_action)


## A range moved so that it is centred on `centre`, keeping its width: what
## a picked point does to an X / Y range (a fixed point simply moves there).
static func _recentre_range(lo: int, hi: int, centre: int) -> Vector2i:
	var span := absi(hi - lo)
	var new_lo := centre - span / 2
	return Vector2i(new_lo, new_lo + span)


func _add_point_fields(a: LoopActionT, second: bool) -> void:
	editor_box.add_child(_section_label("Point" + (" A" if second else "")))
	_add_range_field("X", a.x, a.x_max, -20000, 20000, func(lo: int, hi: int):
		a.x = lo
		a.x_max = hi)
	_add_range_field("Y", a.y, a.y_max, -20000, 20000, func(lo: int, hi: int):
		a.y = lo
		a.y_max = hi)
	editor_box.add_child(_grab_button(UiIconsT.target(), "Pick on screen", func():
		_begin_point_pick(func(g: Vector2i):
			var rx := _recentre_range(a.x, a.x_max, g.x)
			var ry := _recentre_range(a.y, a.y_max, g.y)
			a.x = rx.x
			a.x_max = rx.y
			a.y = ry.x
			a.y_max = ry.y)))
	if second:
		editor_box.add_child(_section_label("Point B"))
		_add_range_field("X2", a.x2, a.x2_max, -20000, 20000, func(lo: int, hi: int):
			a.x2 = lo
			a.x2_max = hi)
		_add_range_field("Y2", a.y2, a.y2_max, -20000, 20000, func(lo: int, hi: int):
			a.y2 = lo
			a.y2_max = hi)
		editor_box.add_child(_grab_button(UiIconsT.target(), "Pick B on screen", func():
			_begin_point_pick(func(g: Vector2i):
				var rx := _recentre_range(a.x2, a.x2_max, g.x)
				var ry := _recentre_range(a.y2, a.y2_max, g.y)
				a.x2 = rx.x
				a.x2_max = rx.y
				a.y2 = ry.x
				a.y2_max = ry.y)))


func _add_rect_fields(a: LoopActionT) -> void:
	editor_box.add_child(_section_label("Detection rect"))
	# X / Y are unused while the rect follows the mouse, so grey them out.
	var x_pair := _add_range_field("X", a.x, a.x_max, -20000, 20000, func(lo: int, hi: int):
		a.x = lo
		a.x_max = hi)
	var y_pair := _add_range_field("Y", a.y, a.y_max, -20000, 20000, func(lo: int, hi: int):
		a.y = lo
		a.y_max = hi)
	var set_xy_editable := func(editable: bool):
		x_pair.set_editable(editable)
		y_pair.set_editable(editable)
	set_xy_editable.call(not a.follow_cursor)
	_add_range_field("Width", a.w, a.w_max, 1, 20000, func(lo: int, hi: int):
		a.w = lo
		a.w_max = hi)
	_add_range_field("Height", a.h, a.h_max, 1, 20000, func(lo: int, hi: int):
		a.h = lo
		a.h_max = hi)
	editor_box.add_child(_grab_button(UiIconsT.target(), "Pick detection rect on screen", func():
		_begin_rect_pick(func(r: Rect2i):
			# A dragged rect is exact: fixed position and size.
			a.x = r.position.x
			a.x_max = a.x
			a.y = r.position.y
			a.y_max = a.y
			a.w = maxi(1, r.size.x)
			a.w_max = a.w
			a.h = maxi(1, r.size.y)
			a.h_max = a.h)))
	var follow := CheckBox.new()
	follow.text = "Follow Cursor"
	follow.tooltip_text = "Centre the rect on the mouse and move it with the mouse, instead of using X / Y."
	follow.focus_mode = Control.FOCUS_NONE
	follow.button_pressed = a.follow_cursor
	follow.toggled.connect(func(v):
		a.follow_cursor = v
		set_xy_editable.call(not v)
		_after_edit())
	editor_box.add_child(follow)


func _add_button_field(a: LoopActionT) -> void:
	var row := _row("Button")
	var opt := _compact_option()
	opt.add_item("Left", LoopActionT.BUTTON_LEFT)
	opt.add_item("Right", LoopActionT.BUTTON_RIGHT)
	opt.add_item("Middle", LoopActionT.BUTTON_MIDDLE)
	opt.select(a.button)
	opt.item_selected.connect(func(i):
		a.button = opt.get_item_id(i)
		_after_edit())
	row.add_child(opt)
	if a.type == LoopActionT.Type.CLICK:
		row.add_child(_press_mode_option(a, "Click"))
	editor_box.add_child(row)


## The press dropdown of a Click or Key: `tap` is what the plain press is
## called there ("Click" / "Tap"), then Hold, Down and Up. Changing it
## rebuilds the editor, since Hold has a row of its own.
func _press_mode_option(a: LoopActionT, tap: String) -> OptionButton:
	var opt := _compact_option(false)
	opt.add_item(tap, LoopActionT.PressMode.TAP)
	opt.add_item("Hold", LoopActionT.PressMode.HOLD)
	opt.add_item("Down", LoopActionT.PressMode.DOWN)
	opt.add_item("Up", LoopActionT.PressMode.UP)
	opt.tooltip_text = "Hold: keep it pressed for a while, then let go.\nDown: press and leave it pressed for the actions after it.\nUp: let go of it. Stopping the loop lets go of everything."
	opt.select(opt.get_item_index(a.press_mode))
	opt.item_selected.connect(func(i):
		a.press_mode = opt.get_item_id(i)
		_after_edit()
		_rebuild_editor.call_deferred())
	return opt


## A Scroll's direction and how many notches of the wheel.
func _add_scroll_fields(a: LoopActionT) -> void:
	var row := _row("Scroll")
	var opt := _compact_option()
	opt.add_item("Up", LoopActionT.ScrollDir.UP)
	opt.add_item("Down", LoopActionT.ScrollDir.DOWN)
	opt.add_item("Left", LoopActionT.ScrollDir.LEFT)
	opt.add_item("Right", LoopActionT.ScrollDir.RIGHT)
	opt.select(opt.get_item_index(a.scroll_dir))
	opt.item_selected.connect(func(i):
		a.scroll_dir = opt.get_item_id(i)
		_after_edit())
	row.add_child(opt)
	editor_box.add_child(row)
	var nrow := _row("Notches")
	nrow.tooltip_text = "How many clicks of the wheel (the program under the point gets them)."
	_add_range_field_in(nrow, a.notches, a.notches_max, 1, 200, func(lo: int, hi: int):
		a.notches = lo
		a.notches_max = hi)


## A Hold's time, when the press is set to Hold.
func _add_hold_field(a: LoopActionT) -> void:
	if a.press_mode != LoopActionT.PressMode.HOLD:
		return
	_add_range_field("Hold", a.hold_ms, a.hold_ms_max, 0, 600000, func(lo: int, hi: int):
		a.hold_ms = lo
		a.hold_ms_max = hi, "ms")


func _add_keys_field(a: LoopActionT) -> void:
	# The label is the "~Keys" checkbox: checked, the keys are typed
	# one at a time with random pauses, like a hand (a combo stays together).
	var row := _row_toggle("Keys", a.keys_paced,
		"What to type, in SendKeys format.\nChecked: typed one key at a time with random pauses between them, like a person would; combos such as ^c stay one press.",
		func(v: bool):
			a.keys_paced = v
			_after_edit())
	# Tap / Hold / Down / Up; the paced typing is a tap's.
	(row.get_child(0) as CheckBox).disabled = a.press_mode != LoopActionT.PressMode.TAP
	row.add_child(_press_mode_option(a, "Tap"))
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text = a.keys
	le.placeholder_text = "e.g. abc, {ENTER}, ^c"
	le.text_changed.connect(func(t: String):
		# Single line, always (a paste could carry line breaks).
		a.keys = t.replace("\r", "").replace("\n", "")
		_after_edit())
	row.add_child(le)
	# Capture: an icon-only button that opens the on-screen keyboard; what is
	# typed or clicked there lands in the field as SendKeys text.
	var capture := Button.new()
	capture.icon = KeyCaptureT.icon()
	capture.tooltip_text = "Capture keys: type them, or click them on an on-screen keyboard, and the SendKeys text is filled in."
	capture.focus_mode = Control.FOCUS_NONE
	capture.pressed.connect(func(): _open_key_capture(le, a))
	row.add_child(capture)
	editor_box.add_child(row)
	_add_hold_field(a)
	var hint := Label.new()
	hint.text = "Windows SendKeys format: {ENTER} {TAB} {ESC} ^c (Ctrl+C) %{F4} (Alt+F4)"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.7)
	editor_box.add_child(hint)


## Opens the on-screen keyboard for the Keys field `le` of action `a`. The
## field is only written when Send is pressed there. One window is kept and
## re-targeted; it closes when the editor is rebuilt (the field it was
## filling is gone then).
func _open_key_capture(le: LineEdit, a: LoopActionT) -> void:
	if _key_capture == null:
		_key_capture = KeyCaptureT.new()
		_key_capture.sent.connect(func(t: String):
			if is_instance_valid(_key_capture_field):
				_key_capture_field.text = t
			if _key_capture_action != null:
				_key_capture_action.keys = t
				_after_edit()
				status_label.text = "Keys set to %s" % JSON.stringify(t))
		# The window is resizable; the size it was last closed at is kept.
		var saved: Variant = _load_setting("key_capture_size", Vector2i.ZERO)
		if saved is Vector2i and saved.x >= _key_capture.min_size.x and saved.y >= _key_capture.min_size.y:
			_key_capture.size = saved
		_key_capture.visibility_changed.connect(func():
			if not _key_capture.visible:
				_save_setting("key_capture_size", _key_capture.size))
		add_child(_key_capture)
	_key_capture_field = le
	_key_capture_action = a
	_key_capture.open(le.text)


func _close_key_capture() -> void:
	if _key_capture != null and _key_capture.visible:
		_key_capture.hide()
	_key_capture_field = null
	_key_capture_action = null


func _add_color_field(a: LoopActionT) -> void:
	var row := _row("Expected colour")
	var cp := ColorPickerButton.new()
	cp.custom_minimum_size = Vector2(60, 0)
	cp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cp.color = a.color
	cp.color_changed.connect(func(c):
		a.color = c
		_after_edit())
	row.add_child(cp)
	editor_box.add_child(row)
	# The two sample buttons on their own row, so the editor never needs to
	# scroll sideways.
	var buttons := HBoxContainer.new()
	var just := _grab_button(UiIconsT.dropper(), "Just sample", func():
		# Pick a point and read its colour only; the rect stays where it is.
		_begin_point_pick(func(g: Vector2i):
			_sample_color_into(a, g), true))
	just.tooltip_text = "Sample a colour on screen without moving the rect."
	buttons.add_child(just)
	var pick := _grab_button(UiIconsT.target(), "Sample & place", func():
		_begin_point_pick(func(g: Vector2i):
			# Centre the (smallest) rect on the picked point, so the pixel
			# sampled here is inside every rect playback can scan (and is the
			# first pixel the smallest one tries). The position becomes fixed.
			a.x = g.x - mini(a.w, a.w_max) / 2
			a.x_max = a.x
			a.y = g.y - mini(a.h, a.h_max) / 2
			a.y_max = a.y
			# Read the *true* screen colour (overlay hidden) into a.color.
			_sample_color_into(a, g), true))
	pick.tooltip_text = "Centre the rect on a point and sample its colour."
	buttons.add_child(pick)
	editor_box.add_child(buttons)


## IMAGE_DETECT's template: a thumbnail of it (or "No image yet") with its
## size and a button that shows it full size, a warning when it cannot fit
## the rect, and the two sample buttons, which mirror Pixel Detect's:
## "Just sample" grabs the dragged area as the image and leaves the rect
## alone; "Sample & place" also makes that area the rect, so the action
## checks that the image is still right there.
func _add_image_field(a: LoopActionT) -> void:
	var row := _row("Image")
	var tex := a.image_texture()
	if tex != null:
		var thumb := TextureRect.new()
		thumb.texture = tex
		thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		# Shown no bigger than it is, and at most a few rows tall; a click on
		# it (or the eye) shows it full size.
		var size := a.image_size()
		var fit := minf(1.0, minf(160.0 / size.x, 64.0 / size.y))
		thumb.custom_minimum_size = Vector2(size) * fit
		thumb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		thumb.tooltip_text = "Click to see the image full size."
		thumb.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
				_show_image_preview(a))
		row.add_child(thumb)
		var dims := Label.new()
		dims.text = "%d×%d" % [size.x, size.y]
		dims.modulate = Color(1, 1, 1, 0.7)
		row.add_child(dims)
		row.add_child(_icon_button(UiIconsT.eye(), "See the image full size.", func(): _show_image_preview(a)))
	else:
		var none := Label.new()
		none.text = "No image yet"
		none.modulate = Color(1, 1, 1, 0.7)
		row.add_child(none)
	editor_box.add_child(row)
	# An image wider or taller than the smallest rect can never be found. The
	# label follows Width / Height edits (see _refresh_image_fit_warning).
	_image_fit_warning = Label.new()
	_image_fit_warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_image_fit_warning.modulate = Color(1.0, 0.75, 0.4)
	editor_box.add_child(_image_fit_warning)
	_image_fit_action = a
	_refresh_image_fit_warning(a)
	var buttons := HBoxContainer.new()
	var just := _grab_button(UiIconsT.dropper(), "Just sample", func():
		_begin_rect_pick(func(r: Rect2i): _capture_image_into(a, r, false)))
	just.tooltip_text = "Drag over what to look for; it is sampled as the image. The rect stays where it is."
	buttons.add_child(just)
	var place := _grab_button(UiIconsT.target(), "Sample & place", func():
		_begin_rect_pick(func(r: Rect2i): _capture_image_into(a, r, true)))
	place.tooltip_text = "Drag over what to look for; it is sampled as the image and the rect is set to that spot."
	buttons.add_child(place)
	editor_box.add_child(buttons)


## Shows or hides the "bigger than the rect" label for `a` (an image wider
## or taller than the smallest rect the ranges allow can never be found).
func _refresh_image_fit_warning(a: LoopActionT) -> void:
	if not is_instance_valid(_image_fit_warning):
		return
	var need := a.image_size()
	var fits := need.x <= mini(a.w, a.w_max) and need.y <= mini(a.h, a.h_max)
	_image_fit_warning.visible = need.x > 0 and not fits
	if _image_fit_warning.visible:
		_image_fit_warning.text = "Bigger than the rect, so it can't be found: make the rect at least %d×%d." % [need.x, need.y]


## Opens `a`'s image at full size (pixel for pixel, shrunk only if it would
## not fit the screen) in its own window. One window is kept and re-used.
func _show_image_preview(a: LoopActionT) -> void:
	var tex := a.image_texture()
	if tex == null:
		return
	if _image_preview == null:
		_image_preview = AcceptDialog.new()
		_image_preview.ok_button_text = "Close"
		var view := TextureRect.new()
		view.name = "View"
		view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_image_preview.add_child(view)
		add_child(_image_preview)
	var size := a.image_size()
	_image_preview.title = "Image %d×%d" % [size.x, size.y]
	(_image_preview.get_node("View") as TextureRect).texture = tex
	# Room for the image plus the dialog's own margins and button; never
	# more than the screen has.
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen()).size
	_image_preview.size = Vector2i(mini(size.x + 24, screen.x - 40), mini(size.y + 70, screen.y - 40))
	_image_preview.popup_centered()


## A detect's condition, read as a sentence over two rows: "~If [not found /
## found]", "Then [Skip rest of layer / Wait till found (gone)]". The "~If"
## checkbox is the Safe walk-through.
func _add_on_fail_field(a: LoopActionT) -> void:
	var target := "image" if a.type == LoopActionT.Type.IMAGE_DETECT else "colour"
	var row := _row_toggle("If", a.safe_continue,
		"What happens when the %s is not there — or, with \"found\", when it is.\nChecked: in Safe mode nothing is skipped or waited for, so you can walk through the whole loop; Live keeps to the choice." % target,
		func(v: bool):
			a.safe_continue = v
			_after_edit())
	# "not found" is the usual guard; "found" turns the same detect into its
	# opposite (skip while the colour is there, wait till it goes).
	var when := _compact_option()
	when.add_item("not found", 0)
	when.add_item("found", 1)
	when.select(1 if a.if_found else 0)
	row.add_child(when)
	editor_box.add_child(row)
	# Stopping the loop is the Stop action's job now, not a Pixel Detect's.
	var then_row := _row("Then")
	var opt := _compact_option()
	opt.add_item("Skip rest of layer", LoopActionT.OnFail.SKIP_LAYER)
	opt.add_item("Wait till gone" if a.if_found else "Wait till found", LoopActionT.OnFail.WAIT_FOUND)
	opt.select(maxi(0, opt.get_item_index(a.on_fail)))
	opt.item_selected.connect(func(i):
		a.on_fail = opt.get_item_id(i)
		_after_edit()
		# Show or hide the re-check interval for "Wait till found".
		_rebuild_editor.call_deferred())
	when.item_selected.connect(func(i):
		a.if_found = i == 1
		opt.set_item_text(opt.get_item_index(LoopActionT.OnFail.WAIT_FOUND), "Wait till gone" if a.if_found else "Wait till found")
		_after_edit())
	then_row.add_child(opt)
	editor_box.add_child(then_row)
	if a.on_fail == LoopActionT.OnFail.WAIT_FOUND:
		# "Wait till found / gone" re-checks the same spot on this interval
		# until the colour appears / goes (F8 / Esc / a Stop action still
		# ends the loop).
		_add_range_field("Check every", a.wait_ms, a.wait_ms_max, 0, 600000, func(lo: int, hi: int):
			a.wait_ms = lo
			a.wait_ms_max = hi, "ms")
		# ~Timeout: give up after this long (a range, like every number) and
		# skip the rest of the layer. The range is greyed out while unchecked.
		var trow := _row_toggle("Timeout", a.wait_timeout,
			"Checked: stop waiting after this long and skip the rest of the layer.",
			func(v: bool):
				a.wait_timeout = v
				_after_edit())
		var tpair := _add_range_field_in(trow, a.wait_timeout_ms, a.wait_timeout_ms_max, 0, 3600000, func(lo: int, hi: int):
			a.wait_timeout_ms = lo
			a.wait_timeout_ms_max = hi, "ms")
		tpair.set_editable(a.wait_timeout)
		(trow.get_child(0) as CheckBox).toggled.connect(func(v: bool): tpair.set_editable(v))


func _add_capture_mode_field(a: LoopActionT) -> void:
	var row := _row("Mode")
	var opt := _compact_option()
	opt.add_item("Save", LoopActionT.CaptureMode.SAVE)
	opt.add_item("Load", LoopActionT.CaptureMode.LOAD)
	opt.select(a.capture_mode)
	opt.item_selected.connect(func(i):
		a.capture_mode = opt.get_item_id(i)
		_after_edit())
	row.add_child(opt)
	editor_box.add_child(row)
	var hint := Label.new()
	hint.text = "Save remembers where the mouse is; Load moves it back there. A Load with nothing saved yet does nothing and disables itself."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.7)
	editor_box.add_child(hint)


## The Stop action: what it ends (the loop, or just this layer's pass) and,
## inline, which pass it fires on — pass 1 the first time it is reached, N
## on the Nth pass.
func _add_stop_field(a: LoopActionT) -> void:
	var row := _row("Stop")
	var opt := _compact_option(false)
	opt.add_item("The loop", LoopActionT.StopScope.LOOP)
	opt.add_item("This layer", LoopActionT.StopScope.LAYER)
	opt.select(opt.get_item_index(a.stop_scope))
	opt.item_selected.connect(func(i):
		a.stop_scope = opt.get_item_id(i)
		_after_edit())
	row.add_child(opt)
	# "on pass N" inside the box, so the row fits the panel.
	var sp := SpinBox.new()
	sp.min_value = 1
	sp.max_value = 1000000
	sp.step = 1
	sp.value = a.stop_after
	sp.prefix = "on pass"
	sp.custom_minimum_size = Vector2(72, 0)
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sp.tooltip_text = "1 = stop the first time this action is reached.\nN = stop on the Nth pass that reaches it (a run limiter)."
	sp.get_line_edit().text_changed.connect(func(_t: String): sp.set_meta(&"typed", true))
	sp.value_changed.connect(func(v: float):
		sp.set_meta(&"typed", false)
		a.stop_after = int(v)
		_after_edit())
	row.add_child(sp)
	editor_box.add_child(row)
	var hint := Label.new()
	hint.text = "Stops the whole loop, or ends just this layer for the pass, when reached. Pass N makes it a run limiter."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.7)
	editor_box.add_child(hint)


func _add_captures_field(a: LoopActionT) -> void:
	var row := HBoxContainer.new()
	var cb := CheckBox.new()
	cb.text = "Captures"
	cb.tooltip_text = "Save the mouse position before this action and move back to it afterwards (plus anything you moved meanwhile)."
	cb.button_pressed = a.captures
	row.add_child(cb)
	var ghost := CheckBox.new()
	ghost.text = "Ghost Cursor"
	ghost.tooltip_text = "Hide the real cursor while this action runs and show a ghost cursor that keeps following you, so nothing appears to jump. Live mode only."
	ghost.button_pressed = a.ghost_cursor
	ghost.disabled = not a.captures
	ghost.toggled.connect(func(v):
		a.ghost_cursor = v
		_after_edit())
	row.add_child(ghost)
	cb.toggled.connect(func(v):
		a.captures = v
		ghost.disabled = not v
		_after_edit())
	editor_box.add_child(row)


func _add_comment_field(a: LoopActionT) -> void:
	editor_box.add_child(HSeparator.new())
	var row := _row("Comment")
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text = a.comment
	le.text_changed.connect(func(t):
		a.comment = t
		_after_edit())
	row.add_child(le)
	editor_box.add_child(row)


## A numeric setting as a "~" toggle plus one or two SpinBoxes. Collapsed
## (the default for a fixed value) only the first input shows, with the
## hidden second one linked to it; clicking the "~" in front of it expands
## the pair — the "~" moves between the two inputs and the second appears —
## and a random value between the two is then used each time the action
## runs. Clicking "~" again collapses the pair back to a single value.
## Whichever end is edited past the other drags the other along.
class RangePair:
	const TIP_COLLAPSED := "~ Make this a range: a second value appears, and a random number between the two is used each time the action runs."
	const TIP_EXPANDED := "~ Back to a single value (the second value is dropped)."
	const TIP_LO := "Minimum: a random value between this and the maximum is used each time."
	const TIP_HI := "Maximum: a random value between the minimum and this is used each time."

	var lo: SpinBox
	var hi: SpinBox
	var tilde: Button
	var ranged := false
	var single_tip := ""   # tooltip of the value while it is not a range
	var _row: Container
	var _setter: Callable   # (lo, hi) after every change made by the user
	var _syncing := false   # set while code moves a SpinBox (no re-entry)

	## Builds the three controls into `row` (after whatever is there already).
	func build(row: Container, lo_v: int, hi_v: int, min_v: int, max_v: int, setter: Callable) -> void:
		_row = row
		_setter = setter
		tilde = Button.new()
		tilde.text = "~"
		tilde.toggle_mode = true
		tilde.focus_mode = Control.FOCUS_NONE
		lo = _spin(lo_v, min_v, max_v)
		hi = _spin(hi_v, min_v, max_v)
		row.add_child(tilde)
		row.add_child(lo)
		row.add_child(hi)
		lo.value_changed.connect(_on_lo)
		hi.value_changed.connect(_on_hi)
		tilde.toggled.connect(func(on: bool): _set_ranged(on, true))
		_set_ranged(lo_v != hi_v, false)

	## Shows `lo_v` / `hi_v` from the model without reporting a change.
	func set_values(lo_v: int, hi_v: int) -> void:
		_syncing = true
		lo.value = lo_v
		hi.value = hi_v
		_syncing = false
		_set_ranged(lo_v != hi_v, false)

	func set_editable(editable: bool) -> void:
		lo.editable = editable
		hi.editable = editable
		tilde.disabled = not editable

	## The unit ("ms", "%") shown inside the boxes, after the number.
	func set_suffix(unit: String) -> void:
		lo.suffix = unit
		hi.suffix = unit

	func _spin(value: int, min_v: int, max_v: int) -> SpinBox:
		var sp := SpinBox.new()
		sp.min_value = min_v
		sp.max_value = max_v
		sp.step = 1
		sp.value = value
		sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		# A SpinBox only takes typed text as its value when the field loses
		# the focus (and then deferred), so "typed" flags text that is still
		# waiting; _commit_pending_edits applies exactly those boxes. (Never
		# every box: a hidden one keeps stale text until it is next drawn.)
		sp.get_line_edit().text_changed.connect(func(_t: String): sp.set_meta(&"typed", true))
		sp.value_changed.connect(func(_v: float): sp.set_meta(&"typed", false))
		return sp

	## Switches between the single value and the range. `apply` (a click on
	## "~", not a refresh) links the dropped maximum back to the minimum.
	func _set_ranged(on: bool, apply: bool) -> void:
		ranged = on
		tilde.set_pressed_no_signal(on)
		tilde.tooltip_text = TIP_EXPANDED if on else TIP_COLLAPSED
		hi.visible = on
		lo.tooltip_text = TIP_LO if on else single_tip
		hi.tooltip_text = TIP_HI if on else ""
		# "~" sits in front of a single value and between the two of a range.
		# (Moving it to lo's current index works both ways: removing it from
		# in front of lo shifts lo down one slot first.)
		var tilde_first := tilde.get_index() < lo.get_index()
		if on == tilde_first:
			_row.move_child(tilde, lo.get_index())
		if not on and apply and int(hi.value) != int(lo.value):
			_syncing = true
			hi.value = lo.value
			_syncing = false
			_setter.call(int(lo.value), int(lo.value))

	func _on_lo(v: float) -> void:
		if _syncing:
			return
		var l := int(v)
		if not ranged or hi.value < l:
			_syncing = true
			hi.value = l
			_syncing = false
		_setter.call(l, int(hi.value))

	func _on_hi(v: float) -> void:
		if _syncing:
			return
		var h := int(v)
		if lo.value > h:
			_syncing = true
			lo.value = h
			_syncing = false
		_setter.call(int(lo.value), h)


## Adds a labelled RangePair row to the editor and returns the pair (for
## callers that need to toggle it later). `setter` receives (lo, hi).
func _add_range_field(label: String, lo: int, hi: int, min_v: int, max_v: int, setter: Callable, unit: String = "") -> RangePair:
	return _add_range_field_in(_row(label), lo, hi, min_v, max_v, setter, unit)


## A RangePair added to `row` (which already holds its label or toggle);
## `unit` ("ms", "%") is shown inside the boxes, not on the label.
func _add_range_field_in(row: Container, lo: int, hi: int, min_v: int, max_v: int, setter: Callable, unit: String = "") -> RangePair:
	var pair := RangePair.new()
	pair.build(row, lo, hi, min_v, max_v, func(l: int, h: int):
		setter.call(l, h)
		_after_edit())
	pair.set_suffix(unit)
	editor_box.add_child(row)
	return pair


## A detect's tolerance range, with `tip` on the row saying what it allows.
func _add_tolerance_field(a: LoopActionT, tip: String) -> void:
	var row := _row("Tolerance")
	row.tooltip_text = tip + " 0-255."
	_add_range_field_in(row, a.tolerance, a.tolerance_max, 0, 255, func(lo: int, hi: int):
		a.tolerance = lo
		a.tolerance_max = hi)


## An Image Detect's two allowances. "Mismatch (%)": how much of the image
## may fail to match; its label is the "~Mismatch" checkbox: checked, pixels
## are compared by light and dark only, so a tinted copy of the image
## (hovered, pressed, another theme) is still found. Then the per-pixel
## tolerance.
func _add_image_tolerance_fields(a: LoopActionT) -> void:
	var mrow := _row_toggle("Mismatch", a.ignore_colour,
		"How much of the image may be off, as a share of its pixels (0 = every pixel must match).\nChecked: pixels are compared by light and dark only, so the image is still found when it is tinted differently (hovered, pressed, another theme).",
		func(v: bool):
			a.ignore_colour = v
			_after_edit())
	_add_range_field_in(mrow, a.mismatch, a.mismatch_max, 0, LoopActionT.MISMATCH_MAX, func(lo: int, hi: int):
		a.mismatch = lo
		a.mismatch_max = hi, "%")
	var trow := _row("Tolerance")
	trow.tooltip_text = "How far each pixel's colour channels may differ from the image, 0-255 (0 = an exact match)."
	_add_range_field_in(trow, a.tolerance, a.tolerance_max, 0, 255, func(lo: int, hi: int):
		a.tolerance = lo
		a.tolerance_max = hi)


## A Move / Drag's duration: how long the travel takes. Its label is a
## checkbox, "~Duration (ms)": checked, the cursor wanders a
## little on the way, like a hand, without moving where it starts or lands.
func _add_duration_field(a: LoopActionT, tip: String = "How long the cursor takes to get there.\nChecked: it wanders a little on the way, like a hand would; where it starts and lands stays exact.") -> void:
	var row := _row_toggle("Duration", a.wiggle, tip,
		func(v: bool):
			a.wiggle = v
			_after_edit())
	_add_range_field_in(row, a.duration_ms, a.duration_ms_max, 0, 60000, func(lo: int, hi: int):
		a.duration_ms = lo
		a.duration_ms_max = hi, "ms")


# ======================================================================
#  Overlay handling
# ======================================================================
func _create_overlay() -> void:
	overlay = OverlayScene.instantiate()
	add_child(overlay)
	overlay.hide()
	overlay.click_through_changed.connect(_on_overlay_click_through_changed)
	# Separate interactive window for on-screen picking, so the view overlay can
	# stay click-through while a pick captures the click instead.
	picker = PickOverlayT.new()
	picker.visible = false
	add_child(picker)
	picker.point_picked.connect(_on_point_picked)
	picker.rect_picked.connect(_on_rect_picked)
	picker.pick_canceled.connect(_on_pick_canceled)


func _on_overlay_toggle(pressed: bool) -> void:
	if pressed:
		overlay.show_overlay()
		if not overlay.transparency_available():
			status_label.text = "Overlay on, but window transparency is unavailable with the %s renderer — it will be opaque. Use the Compatibility renderer." % RenderingServer.get_current_rendering_method()
	else:
		overlay.hide_overlay()
		status_label.text = "Overlay off."


func _on_overlay_click_through_changed(state: int) -> void:
	if _pick_active or not overlay.transparency_available():
		return
	match state:
		OverlayT.ClickThrough.PENDING:
			status_label.text = "Overlay on — enabling click-through…"
		OverlayT.ClickThrough.NATIVE:
			status_label.text = "Overlay on — click-through active, the desktop stays usable underneath."
		OverlayT.ClickThrough.FLAG_ONLY:
			status_label.text = "Overlay on."
		OverlayT.ClickThrough.FAILED:
			status_label.text = "Overlay on — click-through helper (PowerShell) failed; the overlay blocks mouse input under it. Toggle it off to interact."


# ----------------------------------------------------------- on-screen pick
## Start picking a single screen point; `cb` receives a Vector2i (global coords).
## `sample_colors` turns on the live colour-under-cursor preview (colour picks).
func _begin_point_pick(cb: Callable, sample_colors: bool = false) -> void:
	if _pick_active:
		return
	_pick_point_cb = cb
	_pick_rect_cb = Callable()
	_start_pick(PickOverlayT.PickKind.POINT, sample_colors)


## Start picking a screen rectangle; `cb` receives a Rect2i (global coords).
func _begin_rect_pick(cb: Callable) -> void:
	if _pick_active:
		return
	_pick_rect_cb = cb
	_pick_point_cb = Callable()
	_start_pick(PickOverlayT.PickKind.RECT)


func _start_pick(kind: int, sample_colors: bool = false) -> void:
	_pick_active = true
	_pick_was_overlay_visible = overlay.visible
	# Show the guides underneath while placing, so existing points are visible.
	if not overlay.visible:
		overlay.show_overlay()
	status_label.text = "Pick on screen — left-click to set, right-click / Esc to cancel."
	picker.begin_pick(kind, sample_colors)
	# Get the builder out of the way so the desktop it was covering is visible.
	_refresh_stay_on_edit_check()
	var lower := not stay_on_edit_check.button_pressed
	if lower and stay_on_edit_check.disabled:
		status_label.text += "  (Lowering the window is unavailable while embedded in the editor.)"
	if lower and not stay_on_edit_check.disabled:
		var win := get_window()
		_builder_hidden_for_pick = true
		_builder_prev_mode = win.mode
		_builder_prev_pos = win.position
		if win.mode == Window.MODE_WINDOWED:
			# Park it just past the right edge of the virtual desktop. It stays
			# focused there, so Esc (handled in _input) keeps working.
			var desktop := OverlayT.virtual_desktop_rect()
			win.position = Vector2i(desktop.end.x + 64, win.position.y)
		else:
			# A maximised window can't be moved; minimise instead (Esc is then
			# unavailable, right-click still cancels).
			win.mode = Window.MODE_MINIMIZED
	if sample_colors:
		_start_hover_sampling()


func _finish_pick() -> void:
	_pick_active = false
	_pick_point_cb = Callable()
	_pick_rect_cb = Callable()
	_stop_hover_sampling()
	picker.end_pick()
	# If the overlay was only shown for picking, hide it again.
	if not _pick_was_overlay_visible and not overlay_btn.button_pressed:
		overlay.hide_overlay()
	# A colour read scheduled by the pick brings the builder back itself once
	# it has the pixel; bringing it back now could put it over the target.
	if not _sample_pending:
		_restore_builder_after_pick()


## Lowering the builder for a pick (~Edit unchecked) can't work while the game
## runs embedded in the editor's Game tab: moving the (child) window just
## blanks that panel, and the editor keeps covering the desktop anyway. Grey
## the option out in that case.
func _refresh_stay_on_edit_check() -> void:
	var embedded := Engine.is_embedded_in_editor()
	if stay_on_edit_check.disabled == embedded and not stay_on_edit_check.tooltip_text.is_empty():
		return
	stay_on_edit_check.disabled = embedded
	if embedded:
		stay_on_edit_check.tooltip_text = "Unavailable while the game is embedded in the Godot editor (Game tab → turn off Embed Game on Next Play)."
	else:
		stay_on_edit_check.tooltip_text = "Unchecked: this window is moved out of the way while you pick on screen.\nChecked: it stays where it is."


## Bring the builder back (if it was moved away for the pick) and refocus it.
func _restore_builder_after_pick() -> void:
	var win := get_window()
	if _builder_hidden_for_pick:
		_builder_hidden_for_pick = false
		if win.mode == Window.MODE_MINIMIZED:
			win.mode = _builder_prev_mode
		else:
			win.position = _builder_prev_pos
	win.grab_focus()


func _on_point_picked(g: Vector2i) -> void:
	if _pick_point_cb.is_valid():
		_pick_point_cb.call(g)
	status_label.text = "Set point (%d, %d)." % [g.x, g.y]
	_finish_pick()
	_after_edit()
	_rebuild_editor()


func _on_rect_picked(r: Rect2i) -> void:
	if _pick_rect_cb.is_valid():
		_pick_rect_cb.call(r)
	status_label.text = "Set rect [%d, %d, %d×%d]." % [r.position.x, r.position.y, r.size.x, r.size.y]
	_finish_pick()
	_after_edit()
	_rebuild_editor()


func _on_pick_canceled() -> void:
	status_label.text = "Pick canceled."
	_finish_pick()


## Sample the true screen colour under `g` into `a.color`. The overlay is hidden
## first so its dim tint / crosshair isn't captured by the screen read. Called
## from a pick callback: it runs synchronously up to the first await, so
## `_sample_pending` is already set when _finish_pick() runs right after it.
func _sample_color_into(a: LoopActionT, g: Vector2i) -> void:
	var sampler := Playback.get_screen_sampler()
	if sampler == null:
		status_label.text = "Colour sampling needs Live mode (no real screen reader on this OS)."
		return
	_sample_pending = true
	var restore_overlay := overlay_btn.button_pressed
	# Hide the overlay window and give the OS compositor a moment to repaint the
	# desktop without it, so we read the real pixel and not our own overlay.
	overlay.hide_overlay()
	await get_tree().process_frame
	await get_tree().create_timer(0.06).timeout
	var c := sampler.get_pixel(g)
	if restore_overlay:
		overlay.show_overlay()
	# Only now bring the builder back / raise it: it may cover `g`.
	_sample_pending = false
	_restore_builder_after_pick()
	if c.a > 0.0:
		a.color = c
		status_label.text = "Sampled #%s at (%d, %d)." % [c.to_html(false), g.x, g.y]
		_after_edit()
		_rebuild_editor()
	else:
		status_label.text = "Couldn't read a pixel at (%d, %d)." % [g.x, g.y]


## Capture the screen inside `r` as `a`'s image (Image Detect), the overlay
## hidden first as for a colour sample. With `place` the rect becomes `r`
## too. Called from a rect-pick callback, like _sample_color_into.
func _capture_image_into(a: LoopActionT, r: Rect2i, place: bool) -> void:
	var sampler := Playback.get_screen_sampler()
	if sampler == null:
		status_label.text = "Capturing an image needs Live mode (no real screen reader on this OS)."
		return
	var side := LoopActionT.IMAGE_MAX_SIDE
	if r.size.x > side or r.size.y > side:
		status_label.text = "That is %d×%d; an image can be at most %d×%d. Drag over just the thing to look for." % [r.size.x, r.size.y, side, side]
		return
	_sample_pending = true
	var restore_overlay := overlay_btn.button_pressed
	overlay.hide_overlay()
	await get_tree().process_frame
	await get_tree().create_timer(0.06).timeout
	var img := sampler.read_rect(r)
	if restore_overlay:
		overlay.show_overlay()
	_sample_pending = false
	_restore_builder_after_pick()
	if img == null or not a.set_image_png(img.save_png_to_buffer()):
		status_label.text = "Couldn't read the screen at [%d, %d, %d×%d]." % [r.position.x, r.position.y, r.size.x, r.size.y]
		return
	if place:
		a.x = r.position.x
		a.x_max = a.x
		a.y = r.position.y
		a.y_max = a.y
		a.w = maxi(1, r.size.x)
		a.w_max = a.w
		a.h = maxi(1, r.size.y)
		a.h_max = a.h
		a.follow_cursor = false
	var size := a.image_size()
	status_label.text = "Sampled a %d×%d image at (%d, %d)." % [size.x, size.y, r.position.x, r.position.y]
	_after_edit()
	_rebuild_editor()


# ------------------------------------------------- live colour preview
## While a colour pick is active, keep reading the pixel under the cursor on a
## worker thread and show it in the swatch next to the picker's readout.
func _start_hover_sampling() -> void:
	if Playback.get_screen_sampler() == null:
		return
	_hover_sampling = true
	_hover_has_last = false


func _stop_hover_sampling() -> void:
	_hover_sampling = false
	# An in-flight read is collected (and discarded) by _process when it ends.


func _process(_dt: float) -> void:
	if _hover_thread != null:
		if _hover_thread.is_alive():
			return
		var c: Color = _hover_thread.wait_to_finish()
		_hover_thread = null
		if _hover_sampling:
			picker.set_hover_color(c)
	if not _hover_sampling:
		return
	var p := DisplayServer.mouse_get_position()
	if _hover_has_last and p == _hover_last_pos:
		return
	_hover_last_pos = p
	_hover_has_last = true
	_hover_thread = Thread.new()
	_hover_thread.start(_read_pixel_threaded.bind(Playback.get_screen_sampler(), p))


## Runs on the worker thread: one synchronous PowerShell pixel read.
func _read_pixel_threaded(sampler: InputBackend, p: Vector2i) -> Color:
	return sampler.get_pixel(p)


func _exit_tree() -> void:
	# A Thread must be joined before it is freed.
	if _hover_thread != null:
		_hover_thread.wait_to_finish()
		_hover_thread = null


# ------------------------------------------------------- UI preferences
func _load_setting(key: String, default: Variant) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return default
	return cfg.get_value("ui", key, default)


func _save_setting(key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)  # missing file is fine: start empty
	cfg.set_value("ui", key, value)
	cfg.save(SETTINGS_PATH)


## Flip the overlay to the previous/next layer AND make it the active (edited)
## layer, so navigating "screens" also moves the editor to that screen.
func _go_overlay_layer(delta: int) -> void:
	ProjectData.step_overlay_layer(delta)
	ProjectData.set_active_layer(ProjectData.overlay_layer_index)


## Jump straight to a specific layer index in both the overlay and the editor.
func _go_to_layer(index: int) -> void:
	if index < 0 or index >= ProjectData.project.layers.size():
		return
	ProjectData.set_overlay_layer(index)
	ProjectData.set_overlay_show_all(false)
	ProjectData.set_active_layer(index)


## Keep the toolbar indicator + Show All toggle in sync with the overlay view.
func _refresh_overlay_label() -> void:
	if overlay_label == null:
		return
	var layers := ProjectData.project.layers
	var text_full := ""
	var text_short := ""
	if ProjectData.overlay_show_all:
		text_full = "View: All (%d)" % layers.size()
		text_short = text_full
	else:
		var idx := clampi(ProjectData.overlay_layer_index, 0, maxi(0, layers.size() - 1))
		if idx < layers.size():
			text_full = "View: %d/%d - %s" % [idx + 1, layers.size(), layers[idx].name]
			text_short = "View: %d/%d - %s" % [idx + 1, layers.size(), _shorten_text(layers[idx].name, 26)]
		else:
			text_full = "View: -"
			text_short = text_full
	overlay_label.text = text_short
	overlay_label.tooltip_text = text_full
	if show_all_btn != null:
		show_all_btn.set_pressed_no_signal(ProjectData.overlay_show_all)


func _refresh_loop_stack_ui() -> void:
	if loop_picker == null:
		return
	var previous_id := ProjectData.active_loop_id
	var active_idx := -1
	loop_picker.clear()
	for i in ProjectData.loop_stack.size():
		var entry: Dictionary = ProjectData.loop_stack[i]
		var id := int(entry.get("id", -1))
		if id < 0:
			continue
		var name := String(entry.get("name", str(id))).strip_edges()
		if name.is_empty():
			name = str(id)
		var dirty_mark := " *" if ProjectData.loop_is_pending(id) else ""
		# Numbered by place in the list (the store id behind it only ever grows).
		loop_picker.add_item("%d. %s%s" % [loop_picker.item_count + 1, _shorten_text(name, 28), dirty_mark], id)
		if id == previous_id:
			active_idx = loop_picker.item_count - 1
	if active_idx >= 0:
		loop_picker.select(active_idx)
	var total := ProjectData.loop_stack.size()
	if loop_prev_btn != null:
		loop_prev_btn.disabled = total <= 1
	if loop_next_btn != null:
		loop_next_btn.disabled = total <= 1
	if save_btn != null:
		# An unsaved change shows as a "*" beside the icon.
		save_btn.text = "*" if ProjectData.active_loop_is_pending() else ""
	var loop_name := _shorten_text(ProjectData.active_loop_display_name(), 32)
	var pending_text := " (unsaved)" if ProjectData.active_loop_is_pending() else ""
	status_label.text = "Loop %d/%d · %s%s" % [_active_loop_number(), maxi(1, total), loop_name, pending_text]


## The open loop's number as the picker and the status line show it: its
## place in the list, 1 up (not its store id, which only ever grows).
func _active_loop_number() -> int:
	return maxi(0, ProjectData.active_loop_stack_index()) + 1


func _on_play_pressed() -> void:
	if _stop_cooldown_active:
		return
	_commit_pending_edits()
	Playback.toggle()


func _on_loop_picker_selected(i: int) -> void:
	if loop_picker == null:
		return
	var id := loop_picker.get_item_id(i)
	# A number still being typed belongs to the loop being left.
	_commit_pending_edits()
	ProjectData.open_loop(id)


func _switch_loop(delta: int) -> void:
	_commit_pending_edits()
	ProjectData.step_loop(delta)


func _on_backend_selected(i: int) -> void:
	Playback.set_backend(backend_option.get_item_id(i))
	_refresh_edit_lock()
	_refresh_run_label()


## "Run?" in Safe mode (nothing real happens), "Run!" in Live. Left alone
## while a run is going or the button is counting down after one.
func _refresh_run_label() -> void:
	if play_btn == null or Playback.is_running or _stop_cooldown_active:
		return
	play_btn.icon = UiIconsT.play()
	play_btn.text = _run_label()


func _run_label() -> String:
	var live := Playback.backend != null and Playback.backend.is_real()
	return "Run!" if live else "Run?"


func _refresh_edit_lock() -> void:
	var locked := _is_interaction_locked()
	# The window dims while a Live loop runs, ~Self or not. A Pixel Detect
	# reading Loop Automator's own window (~Self on) then reads the dimmed
	# colours — the user accounts for that shift; the dim cue is kept.
	var tint := Color(1, 1, 1, 0.65) if locked else Color(1, 1, 1, 1)
	if _ui_root != null:
		_set_controls_locked(_ui_root, locked)
		_ui_root.modulate = tint
	if play_btn != null:
		# Keep this as the only clickable control in lock mode.
		play_btn.disabled = _stop_cooldown_active
		if locked:
			play_btn.disabled = false
	if _main_split != null:
		_main_split.modulate = tint
	if _edit_lock_blocker != null:
		_edit_lock_blocker.visible = locked
		_edit_lock_blocker.color = Color(0.0, 0.0, 0.0, 0.20)
		_edit_lock_blocker.move_to_front()
	if backend_option != null:
		backend_option.disabled = locked
	if locked:
		status_label.text = "Real backend running: editor input is locked."


func _is_interaction_locked() -> bool:
	return Playback.is_running and Playback.backend != null and Playback.backend.is_real()


func _set_controls_locked(node: Node, locked: bool) -> void:
	if node == _edit_lock_blocker:
		return
	if node is LineEdit:
		(node as LineEdit).editable = not locked
	elif node is TextEdit:
		(node as TextEdit).editable = not locked
	elif node is SpinBox:
		(node as SpinBox).editable = not locked
	elif node is ItemList:
		# The lists have no disabled state: shut their input off instead, so
		# no click or arrow key moves the selection (and rebuilds the editor).
		(node as ItemList).mouse_filter = Control.MOUSE_FILTER_IGNORE if locked else Control.MOUSE_FILTER_STOP
		(node as ItemList).focus_mode = Control.FOCUS_NONE if locked else Control.FOCUS_ALL
	elif node.has_method("set_disabled"):
		node.call("set_disabled", locked)

	for child in node.get_children():
		_set_controls_locked(child, locked)


func _switch_to_safe_backend_if_needed() -> void:
	if Playback.backend == null or not Playback.backend.is_real():
		return
	Playback.set_backend(Playback.BackendKind.PREVIEW)
	if backend_option != null:
		for i in backend_option.item_count:
			if backend_option.get_item_id(i) == Playback.BackendKind.PREVIEW:
				backend_option.select(i)
				break


func _animate_safety_cooldown() -> void:
	await _animate_stop_feedback(true)


func _animate_stop_feedback(include_safety: bool) -> void:
	_stop_cooldown_token += 1
	var token := _stop_cooldown_token
	_stop_cooldown_active = true
	_refresh_edit_lock()
	if play_btn != null:
		play_btn.text = "Stopping."
	await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
	if token != _stop_cooldown_token:
		return
	if play_btn != null:
		play_btn.text = "Stopping.."
	await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
	if token != _stop_cooldown_token:
		return
	if play_btn != null:
		play_btn.text = "Stopping..."
	await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
	if token != _stop_cooldown_token:
		return
	if include_safety:
		if play_btn != null:
			play_btn.text = "Safety."
		if status_label != null:
			status_label.text = "%s Switched to Safe." % Playback.last_stop_reason
		await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
		if token != _stop_cooldown_token:
			return
		if play_btn != null:
			play_btn.text = "Safety.."
		await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
		if token != _stop_cooldown_token:
			return
		if play_btn != null:
			play_btn.text = "Safety..."
		await get_tree().create_timer(STOP_COOLDOWN_STEP_SEC).timeout
		if token != _stop_cooldown_token:
			return
	_stop_cooldown_active = false
	_refresh_run_label()
	_refresh_edit_lock()


# ======================================================================
#  File menu actions
# ======================================================================
func _on_new() -> void:
	_commit_pending_edits()
	var id := ProjectData.create_loop(true)
	status_label.text = "Opened new loop %d, \"%s\"." % [_active_loop_number(), ProjectData.active_loop_display_name()]


func _on_save() -> void:
	_commit_pending_edits()
	var err := ProjectData.save_active_loop()
	status_label.text = "Saved." if err == OK else "Save failed (%d)." % err
	_refresh_loop_stack_ui()


func _on_duplicate_loop() -> void:
	_commit_pending_edits()
	var from := ProjectData.active_loop_display_name()
	var id := ProjectData.duplicate_loop()
	if id < 0:
		return
	status_label.text = "Duplicated \"%s\" as loop %d, \"%s\"." % [from, _active_loop_number(), ProjectData.active_loop_display_name()]


func _confirm_delete_loop() -> void:
	var id := ProjectData.active_loop_id
	if id < 0 or ProjectData.project == null:
		return
	var layers := ProjectData.project.layers.size()
	var name := ProjectData.active_loop_display_name()
	_confirm("Delete loop \"%s\" and its %d layer(s)? Its file is removed too." % [name, layers],
		func():
			if ProjectData.delete_loop(id):
				status_label.text = "Deleted loop \"%s\"." % name)


func _on_export() -> void:
	_commit_pending_edits()
	var dlg := _loop_file_dialog("Export loop", FileDialog.FILE_MODE_SAVE_FILE)
	# The loop's name (an imported file's first layer, possibly) suggests the
	# file name; path characters in it become "_" so it stays a file name.
	var suggested := ProjectData.active_loop_display_name().strip_edges().validate_filename()
	if suggested.is_empty() or suggested == "-":
		suggested = "loop"
	dlg.current_file = "%s.loop" % suggested
	dlg.file_selected.connect(func(path: String):
		if not path.to_lower().ends_with(".loop"):
			path += ".loop"
		var err := ProjectData.export_to(path)
		status_label.text = "Exported to %s" % path if err == OK else "Export failed (%d)." % err
		dlg.queue_free())
	dlg.popup_centered()


## Import: pick a .loop file, see what it holds and what a loop can do,
## and only then does it become a new loop in the store.
func _on_import() -> void:
	_commit_pending_edits()
	var dlg := _loop_file_dialog("Import loop", FileDialog.FILE_MODE_OPEN_FILE)
	dlg.file_selected.connect(func(path: String):
		dlg.queue_free()
		# Deferred: file_selected fires before the file dialog hides, and two
		# exclusive dialogs cannot be up at once.
		_ask_import.call_deferred(path))
	dlg.popup_centered()


## At most this many Key actions are quoted in the import question, each
## cut to this many characters (the action list shows them in full).
const IMPORT_KEYS_SHOWN := 6
const IMPORT_KEY_CHARS := 60


## The question asked before a file is imported: what it holds — layers,
## actions, and the text of its Key actions, which is what a loop types —
## and what a loop can do. Nothing is loaded unless Import is pressed.
func _ask_import(path: String) -> void:
	var peek := ProjectData.peek_loop(path)
	if peek.is_empty():
		status_label.text = "Import failed: %s is not a readable .loop file." % path.get_file()
		return
	var keys: Array = peek["keys"]
	var text := "Import \"%s\" as a new loop?\n\n" % path.get_file()
	text += "A loop is like a script: run in Live mode it can type anything and click anywhere. "
	text += "This one, \"%s\", has %d layer(s) and %d action(s)" % [peek["name"], peek["layers"], peek["actions"]]
	if keys.is_empty():
		text += ", none of them Key actions (nothing in it types).\n"
	else:
		text += ", including %d Key action(s) that type:\n" % keys.size()
		for i in mini(keys.size(), IMPORT_KEYS_SHOWN):
			var k: String = keys[i]
			if k.length() > IMPORT_KEY_CHARS:
				k = k.substr(0, IMPORT_KEY_CHARS - 1) + "…"
			text += "    •  %s\n" % JSON.stringify(k)
		if keys.size() > IMPORT_KEYS_SHOWN:
			text += "    •  … and %d more\n" % (keys.size() - IMPORT_KEYS_SHOWN)
	text += "\nIt opens in Safe mode. Read its actions there and dry-run it before you ever run it Live."
	var do_import := func():
		var id := ProjectData.import_loop(path)
		if id < 0:
			status_label.text = "Import failed: %s is not a readable .loop file." % path.get_file()
		else:
			status_label.text = "Imported \"%s\" as loop %d." % [ProjectData.active_loop_display_name(), _active_loop_number()]
	_confirm(text, do_import, "Import")


## A file dialog for .loop files. It frees itself when cancelled; the
## caller's file_selected handler frees it after a choice.
func _loop_file_dialog(title: String, mode: int) -> FileDialog:
	var dlg := FileDialog.new()
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	dlg.file_mode = mode
	dlg.title = title
	dlg.add_filter("*.loop", "Loop files")
	dlg.size = Vector2i(720, 520)
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	return dlg


func _confirm_delete_layer() -> void:
	var index := ProjectData.active_layer_index
	if index < 0 or index >= ProjectData.project.layers.size():
		return
	var layer: LoopLayerT = ProjectData.project.layers[index]
	if ProjectData.project.layers.size() <= 1:
		_inform("\"%s\" is this loop's only layer, and a loop needs at least one.\nDelete its actions instead, add another layer first, or delete the whole loop (trash icon in the toolbar)." % layer.name)
		return
	_confirm("Delete layer \"%s\" and its %d action(s)?" % [layer.name, layer.actions.size()],
		func(): ProjectData.remove_layer(index))


func _confirm_delete_action() -> void:
	var index := ProjectData.selected_action_index
	var layer := ProjectData.active_layer()
	if layer == null or index < 0 or index >= layer.actions.size():
		return
	var action: LoopActionT = layer.actions[index]
	_confirm("Delete action %d (%s)?" % [index + 1, action.describe()],
		func(): ProjectData.remove_action(index))


## Dialog text is wrapped at this many characters per line (a dialog sizes
## itself to its longest line, so a long sentence would run off the screen).
const DIALOG_WRAP := 76


## `text` with every paragraph re-broken at word boundaries so no line is
## longer than `width` characters. Lines that start with spaces (the
## indented bullets of the import question) are left as they are.
static func _wrap_lines(text: String, width: int = DIALOG_WRAP) -> String:
	var out: PackedStringArray = []
	for paragraph in text.split("\n"):
		if paragraph.length() <= width or paragraph.begins_with(" "):
			out.append(paragraph)
			continue
		var line := ""
		for word in paragraph.split(" "):
			if line.is_empty():
				line = word
			elif line.length() + 1 + word.length() <= width:
				line += " " + word
			else:
				out.append(line)
				line = word
		out.append(line)
	return "\n".join(out)


## Tells the user something in a dialog with just an OK button.
func _inform(text: String) -> void:
	var dlg := AcceptDialog.new()
	dlg.title = "Loop Automator"
	dlg.dialog_text = _wrap_lines(text)
	dlg.confirmed.connect(func(): dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


## Asks before something happens; `on_ok` runs only if the user confirms
## with the button labelled `ok_text`.
func _confirm(text: String, on_ok: Callable, ok_text: String = "Delete") -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Confirm"
	dlg.dialog_text = _wrap_lines(text)
	dlg.ok_button_text = ok_text
	dlg.confirmed.connect(func():
		on_ok.call()
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


func _rename_layer_dialog(index: int) -> void:
	if index < 0 or index >= ProjectData.project.layers.size():
		return
	var dlg := AcceptDialog.new()
	dlg.title = "Rename layer"
	var le := LineEdit.new()
	le.text = ProjectData.project.layers[index].name
	le.custom_minimum_size = Vector2(260, 0)
	dlg.add_child(le)
	dlg.register_text_enter(le)
	dlg.confirmed.connect(func():
		ProjectData.rename_layer(index, le.text)
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()
	le.grab_focus()
	le.select_all()


# ======================================================================
#  Hotkeys
# ======================================================================
## Returns true when the user is typing, so navigation keys don't hijack input.
## True while one of the builder's dialogs (a confirmation, the import /
## export file dialog, the image preview) is up: a question should be
## answered, not run past.
func _dialog_open() -> bool:
	for c in get_children():
		if c is AcceptDialog and (c as Window).visible:
			return true
	return _image_preview != null and _image_preview.visible


func _is_editing_text() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit or f is SpinBox


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return

	# While picking on screen the pick window is unfocusable, so its Esc arrives
	# here. No other hotkey should fire mid-pick.
	if _pick_active:
		if event.keycode == KEY_ESCAPE:
			picker.cancel_pick()
			get_viewport().set_input_as_handled()
		return

	if _stop_cooldown_active and not Playback.is_running:
		return

	# Global controls that should always work.
	match event.keycode:
		KEY_F5:
			_commit_pending_edits()
			Playback.toggle()
			get_viewport().set_input_as_handled()
			return
		KEY_F8:
			# The same start / stop as the global F8 (which, when held,
			# takes the key before this window ever sees it).
			if Playback.is_running:
				Playback.stop()
			else:
				_on_play_pressed()
			get_viewport().set_input_as_handled()
			return
		KEY_ESCAPE:
			if Playback.is_running:
				Playback.stop()
				get_viewport().set_input_as_handled()
			return

	# In locked mode, only allow the global controls above.
	if _is_interaction_locked():
		return

	# Layer-flipping shortcuts are suppressed while typing in a field.
	if _is_editing_text():
		return

	match event.keycode:
		KEY_LEFT, KEY_PAGEUP, KEY_BRACKETLEFT:
			_go_overlay_layer(-1)
			get_viewport().set_input_as_handled()
		KEY_RIGHT, KEY_PAGEDOWN, KEY_BRACKETRIGHT:
			_go_overlay_layer(1)
			get_viewport().set_input_as_handled()
		KEY_BACKSLASH:
			ProjectData.set_overlay_show_all(not ProjectData.overlay_show_all)
			get_viewport().set_input_as_handled()
		_:
			if event.keycode >= KEY_1 and event.keycode <= KEY_9:
				_go_to_layer(event.keycode - KEY_1)
				get_viewport().set_input_as_handled()


# ======================================================================
#  Small UI factory helpers
# ======================================================================
func _tool_button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


## An editor button that starts a pick on screen: an icon and what it picks.
func _grab_button(icon: Texture2D, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.icon = icon
	# The editor's pick / sample buttons fill the row (two on a row share it).
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Text right next to the icon, not centred away from it.
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


## A button that is just an icon (with a tooltip saying what it does).
func _icon_button(icon: Texture2D, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.icon = icon
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	return b


## The width `btn` needs to show `sample` in full: the text, the drop-down
## arrow and the button's own margins.
func _option_button_width(btn: OptionButton, sample: String) -> float:
	var font := btn.get_theme_font("font")
	var text_w := font.get_string_size(sample, HORIZONTAL_ALIGNMENT_LEFT, -1, btn.get_theme_font_size("font_size")).x
	var arrow_w := btn.get_theme_icon("arrow").get_width() + btn.get_theme_constant("arrow_margin")
	var margins := btn.get_theme_stylebox("normal").get_minimum_size().x
	return ceilf(text_w + arrow_w + margins + 2.0 * btn.get_theme_constant("h_separation"))


## An OptionButton for the editor rows. Expanding, it shares the input
## column with the others on its row, shrinking (with an ellipsis) rather
## than pushing the row past the panel; not expanding, it is as wide as
## its longest item and leaves the rest of the row to the others.
func _compact_option(expand: bool = true) -> OptionButton:
	var opt := OptionButton.new()
	if expand:
		opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		opt.fit_to_longest_item = false
		opt.clip_text = true
		opt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return opt


func _row(label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(120, 0)
	row.add_child(l)
	return row


## A row whose label is a "~" checkbox ("~Keys"), like the toolbar's ~Delay
## ms / ~Edit / ~Self: the "~" marks a setting with a random, hand-like
## side that the box turns on. `on_toggle` gets the new state.
func _row_toggle(label: String, checked: bool, tip: String, on_toggle: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var cb := CheckBox.new()
	cb.text = "~" + label
	cb.tooltip_text = tip
	cb.focus_mode = Control.FOCUS_NONE
	cb.button_pressed = checked
	cb.custom_minimum_size = Vector2(120, 0)
	cb.clip_text = true
	cb.toggled.connect(on_toggle)
	row.add_child(cb)
	return row


func _section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 16)
	l.modulate = Color(0.7, 0.85, 1.0)
	return l


func _vsep() -> Control:
	var s := VSeparator.new()
	return s


func _shorten_text(text: String, max_chars: int) -> String:
	if max_chars <= 3 or text.length() <= max_chars:
		return text
	return text.substr(0, max_chars - 3) + "..."
