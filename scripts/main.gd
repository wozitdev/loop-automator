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
const LoopProjectT := preload("res://scripts/model/loop_project.gd")
const RecorderT := preload("res://scripts/input/recorder.gd")
const RecordingT := preload("res://scripts/model/recording.gd")
const KeyStrokesT := preload("res://scripts/model/key_strokes.gd")

## Record (the Rec button): what the user does is recorded by a helper
## that listens system-wide (see Recorder) until F8, then turned into actions
## (see Recording) and appended to the layer whose actions are shown.
var rec_btn: Button
var _recorder := RecorderT.new()
var _recording: bool = false
## Bumped when a recording starts or stops, so a countdown still running
## for an earlier one does nothing.
var _record_gen: int = 0
## The layer (and its loop) a recording was asked about and goes into.
var _record_layer = null
var _record_loop_id: int = -1
## The Rec dot: grey until pressed, then red with a slow breath while the
## recording is on.
const REC_IDLE_COLOR := Color(0.5, 0.5, 0.5)
const REC_ON_COLOR := Color(0.86, 0.22, 0.22)
const REC_ON_BRIGHT_COLOR := Color(1.0, 0.4, 0.4)
const REC_BREATH_SEC := 1.1
var _rec_pulse: Tween
## True while the recording keeps what lands on Loop Automator itself (~Self
## on): the click or Esc that ends it is then trimmed off the end.
var _record_unguarded: bool = false
## True once the countdown is over and the helper listens: what it saw
## before that (it is started first, so its start-up hides in the countdown)
## is not part of the recording.
var _record_armed: bool = false

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
var layer_solo_check: CheckBox
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
## The action selected when the pick began (what its callback edits): kept
## to the editor's limits once the pick lands.
var _pick_action: LoopActionT = null
var _pick_rect_cb: Callable = Callable()
## The builder is got out of the way (~Edit unchecked) so the desktop it
## covers is visible: minimised when a run or a recording starts - the
## taskbar brings it back whenever the user wants it, and the end of the
## run un-minimises it if it still is - or, for a pick, moved off-screen
## (`_builder_parked`) and back when the pick ends. Off-screen rather than
## minimised there so it keeps the keyboard focus: the pick window must
## never be focused (see PickOverlay), and Esc arrives here.
var _builder_hidden_for_pick: bool = false
var _builder_parked: bool = false
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
	# Closing asks first while loops have changes not saved (see _notification).
	get_tree().set_auto_accept_quit(false)
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
	_warn_points_unsure.call_deferred()
	if not ProjectData.store_notice.is_empty():
		(func(): status_label.text = ProjectData.store_notice).call_deferred()


## How long the splash stays before it fades, and how long the fade takes.
const SPLASH_HOLD_SEC := 0.9
const SPLASH_FADE_SEC := 0.5


## A splash over the builder at launch: the icon and the name on the icon's
## own dark, fading out once the window is up. Nothing under it is
## clickable meanwhile (it is gone in under two seconds).
func _show_splash() -> void:
	var splash := ColorRect.new()
	splash.color = Color("343c4e")
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
	# One width for "Run?" and "Run!": the button (and the toolbar
	# after it) no longer shifts when the mode changes or a run starts.
	play_btn.custom_minimum_size = Vector2(_button_width(play_btn, ["Run?", "Run!"]), 0)
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
	share_btn.icon = UiIconsT.share()
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
	# Duplicate sits right before Delete, as every Duplicate does.
	duplicate_loop_btn = _icon_button(UiIconsT.copy(), "Duplicate this loop", _on_duplicate_loop)
	hb.add_child(duplicate_loop_btn)
	delete_loop_btn = _icon_button(UiIconsT.trash(), "Delete this loop (its file too)", _confirm_delete_loop)
	hb.add_child(delete_loop_btn)

	hb.add_child(_vsep())

	# --- Timing -----------------------------------------------------------
	# The delay's label is a checkbox, "~Delay ms": checked, the delay is
	# waited before every action instead of once a round.
	var delay_tip := "Pause before each round of the loop (ms). Saved with the loop."
	delay_each_check = CheckBox.new()
	delay_each_check.text = "~Delay"
	delay_each_check.focus_mode = Control.FOCUS_NONE
	delay_each_check.tooltip_text = "%s\nChecked: wait it before every action instead." % delay_tip
	delay_each_check.button_pressed = ProjectData.project.delay_after_each_action
	delay_each_check.toggled.connect(func(v: bool): ProjectData.set_delay_after_each_action(v))
	hb.add_child(delay_each_check)
	# A RangePair like the editor fields: "~" expands it to a min - max pause.
	# The controls sit in the toolbar row at a fixed width (no expand).
	_delay_pair = RangePair.new()
	_delay_pair.build(hb, ProjectData.project.loop_delay_ms, ProjectData.project.loop_delay_ms_max, 0, LoopProjectT.LOOP_DELAY_MS_MAX, func(l: int, h: int):
		ProjectData.set_loop_delay(l, h))
	_delay_pair.set_suffix("ms")
	# Wide enough for the biggest value, 60000 ms, to show whole.
	for sp in [_delay_pair.lo, _delay_pair.hi]:
		sp.size_flags_horizontal = Control.SIZE_FILL
		sp.custom_minimum_size = Vector2(_spin_box_width(sp, "60000 ms"), 0)
	_delay_pair.single_tip = delay_tip
	if not _delay_pair.ranged:
		_delay_pair.lo.tooltip_text = delay_tip

	# --- Self-interaction toggles (right-aligned) ---------------------------
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(spacer)
	# ~Edit: unchecked = the builder is moved out of the way while you pick on
	# screen, record, or a loop runs (the stored setting keeps the "lower on
	# edit" sense).
	stay_on_edit_check = CheckBox.new()
	stay_on_edit_check.text = "~Edit"
	stay_on_edit_check.focus_mode = Control.FOCUS_NONE
	stay_on_edit_check.button_pressed = not _load_bool_setting("lower_on_edit", true)
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
	feedback_check.tooltip_text = "Checked: a running loop may interact with Loop Automator itself (clicks and keys can land on this window, like a feedback loop), and Rec records what you do on it.\nUnchecked: clicks and keys that would land on Loop Automator are skipped, so the loop cannot affect the app running it, and Rec leaves them out."
	feedback_check.button_pressed = _load_bool_setting("feedback", false)
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
	hotkey_check.tooltip_text = "Checked: F8 starts and stops the loop from any window while Loop Automator is open (other programs do not get F8 meanwhile; while a loop runs, F8 with Shift, Ctrl, Alt or Win stops it too), and this window moves out of the way while a loop runs.\nUnchecked: F8 only works while this window has the focus."
	hotkey_check.button_pressed = _load_bool_setting("global_hotkey", true)
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
		ProjectData.notify_layer_modified()
		ProjectData.emit_signal("overlay_view_changed"))
	vb.add_child(layer_visible_check)

	# Enabled and Solo side by side. Solo runs this layer alone: the others
	# are treated as off without their Enabled changing (nothing is saved),
	# and Enabled is greyed out meanwhile since it has no say.
	var run_row := HBoxContainer.new()
	layer_enabled_check = CheckBox.new()
	layer_enabled_check.text = "Enabled (runs in loop)"
	layer_enabled_check.toggled.connect(func(v):
		var l := ProjectData.active_layer()
		if l: l.enabled = v
		ProjectData.notify_layer_modified())
	run_row.add_child(layer_enabled_check)
	layer_solo_check = CheckBox.new()
	layer_solo_check.text = "Solo"
	layer_solo_check.focus_mode = Control.FOCUS_NONE
	layer_solo_check.tooltip_text = "Run only this layer; the other layers' settings are not changed."
	layer_solo_check.toggled.connect(func(v):
		ProjectData.set_solo(ProjectData.active_layer_index if v else -1))
	run_row.add_child(layer_solo_check)
	vb.add_child(run_row)

	var color_row := HBoxContainer.new()
	var cl := Label.new()
	cl.text = "Colour:"
	color_row.add_child(cl)
	layer_color_btn = ColorPickerButton.new()
	layer_color_btn.custom_minimum_size = Vector2(60, 0)
	# Opaque, as a load keeps it: a see-through layer would draw its name
	# and its guides as nothing.
	layer_color_btn.edit_alpha = false
	layer_color_btn.color_changed.connect(func(c):
		var l := ProjectData.active_layer()
		if l: l.color = LoopLayerT.readable(c)   # kept readable, as a load keeps it
		ProjectData.notify_layer_modified()
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
	# Cut to the panel with an ellipsis: a long layer name (a file may give
	# one of 200 wide characters) would otherwise push the action editor off
	# the window.
	actions_header.clip_text = true
	actions_header.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	actions_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions_header.custom_minimum_size.x = 0
	vb.add_child(actions_header)

	action_list = ItemList.new()
	action_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	action_list.allow_reselect = true
	action_list.item_selected.connect(func(i): ProjectData.set_selected_action(i))
	# Rows are fitted to the list's width (see _row_text): again when that changes.
	action_list.resized.connect(func():
		# Once the width has settled (a drag of the window's edge, a panel
		# that flickers a few pixels and back): a list of tens of thousands.
		if not _refit_queued and int(action_list.size.x) != _rows_fit_width:
			_refit_queued = true
			get_tree().create_timer(0.25).timeout.connect(_refit_rows))
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
	btns.add_child(_icon_button(UiIconsT.up(), "Move the selected action up", func(): ProjectData.move_action(ProjectData.selected_action_index, -1)))
	btns.add_child(_icon_button(UiIconsT.down(), "Move the selected action down", func(): ProjectData.move_action(ProjectData.selected_action_index, 1)))
	var dup_btn := _icon_button(UiIconsT.copy(), "Duplicate the selected action", func(): ProjectData.duplicate_action(ProjectData.selected_action_index))
	dup_btn.text = "Duplicate"
	btns.add_child(dup_btn)
	var delete_btn := _icon_button(UiIconsT.trash(), "Delete the selected action", _confirm_delete_action)
	delete_btn.text = "Delete"
	btns.add_child(delete_btn)
	# Rec at the far right: what you do next becomes actions of this layer,
	# until F8.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btns.add_child(spacer)
	rec_btn = _icon_button(UiIconsT.record(), "", _on_rec_pressed)
	rec_btn.text = "Rec"
	rec_btn.custom_minimum_size = Vector2(_button_width(rec_btn, ["Rec", "Stop"]), 0)
	_set_rec_icon_color(REC_IDLE_COLOR)
	if OS.get_name() == "Windows":
		rec_btn.tooltip_text = "Record what you do with the mouse and keyboard into this layer, until you press F8.\nEverything you type is kept in the loop as plain text - stop before typing a password."
	else:
		rec_btn.tooltip_text = "Recording works on Windows only."
		rec_btn.disabled = true
	btns.add_child(rec_btn)
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
	ProjectData.limit_reached.connect(func(message: String): status_label.text = message)
	ProjectData.notice.connect(func(message: String): status_label.text = message)
	ProjectData.layers_changed.connect(_refresh_layers)
	ProjectData.layers_changed.connect(_refresh_layer_props)
	ProjectData.layers_changed.connect(_refresh_actions_for_layers)
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
		# The on-screen keyboard is a window of its own, outside the edit
		# lock: closed for the run, so nothing edits the loop while it runs.
		_close_key_capture()
		# A field being edited lets go of the focus: the Keys field shows its
		# text marked for right-to-left letters only once it is left, and what
		# is on screen while the loop runs is to be read the way it types.
		var focused := get_viewport().gui_get_focus_owner()
		if focused != null:
			focused.release_focus()
		# An open list or colour picker outlives the edit lock (disabling its
		# button leaves the popup up): closed, so nothing edits the loop - a
		# running detect's colour, an action added to the running layer -
		# while it runs.
		for p in _open_popups():
			p.hide()
		_stop_cooldown_token += 1
		_stop_cooldown_active = false
		play_btn.icon = UiIconsT.stop()
		play_btn.text = "Run!"
		_refresh_edit_lock()
		# ~Edit unchecked: this window is minimised for the run (the taskbar
		# brings it back; F8 stops the loop from anywhere with ~F8 on). Not
		# a Live run without the global F8, though: its stop keys work only
		# while this window has the focus, and its Stop button would be
		# out of sight while the loop drives the real mouse and keyboard.
		if Playback.backend != null and Playback.backend.is_real() and not Playback.global_hotkey_armed():
			return
		_lower_builder())
	Playback.playback_stopped.connect(func():
		var was_real := Playback.backend != null and Playback.backend.is_real()
		if was_real:
			_switch_to_safe_backend_if_needed()
		# Not while a pick or a sample is under way (a Safe run ending in the
		# middle of one): it brings the builder back itself once it has read
		# the screen - before, the read would be of the builder.
		if not _pick_active and not _sample_pending:
			_restore_builder_after_pick()
		await _animate_stop_feedback(was_real))
	Playback.action_executing.connect(_on_action_executing)
	# The global F8 while idle (~F8): a start, as the Run button (a pick in
	# progress keeps the screen; the button's own cooldown after a stop holds).
	Playback.hotkey_pressed.connect(func():
		if _recording:
			_stop_recording()
		elif not _pick_active and not _dialog_open():
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
	# Another loop open (picked, stepped to, the last one deleted): back to
	# Safe, as after an import - with Live left on, one press of Run or an
	# idle ~F8 from any window would drive the real mouse and keyboard with
	# a loop that was not the one Live was chosen for.
	if not Playback.is_running:
		_switch_to_safe_backend_if_needed()
	_delay_pair.set_values(ProjectData.project.loop_delay_ms, ProjectData.project.loop_delay_ms_max)
	delay_each_check.set_pressed_no_signal(ProjectData.project.delay_after_each_action)
	_refresh_layers()
	_refresh_actions()
	_refresh_layer_props()
	_rebuild_editor()
	_refresh_overlay_label()
	_refresh_loop_stack_ui()
	_warn_points_unsure(false)


## The loop's points may be off (see LoopProject.points_unsure): said on
## the status line, after whatever it says already.
func _warn_points_unsure(after: bool = true) -> void:
	var off: Vector2i = ProjectData.project.points_unsure if ProjectData.project != null else Vector2i.ZERO
	if off == Vector2i.ZERO:
		return
	var warn := "This loop is from an older version, which counted points from the main screen: some of its points may be off by (%d, %d) - check them on the overlay before a Live run." % [off.x, off.y]
	status_label.text = warn if status_label.text.is_empty() or not after else status_label.text + " " + warn


## The tint behind the step (and the layer) a run is on. The selection is
## left alone: what you picked stays picked and the editor keeps showing it.
const RUNNING_TINT := Color(0.25, 0.55, 1.0, 0.28)


func _on_action_executing(_layer_index: int, _action_index: int) -> void:
	_refresh_running_marks()


## Tints the row of the step a run is on in the action list (when its layer
## is the one shown) and of its layer in the layer list; clears both when
## nothing runs.
## Only the rows that change are touched (the one tinted last and the one
## now): a run steps through every action, and a loop may have tens of
## thousands. (A list rebuilt meanwhile starts untinted.)
func _refresh_running_marks() -> void:
	var li := Playback.current_layer_index if Playback.is_running else -1
	var ai := Playback.current_action_index if Playback.is_running else -1
	var ai_shown := ai if li == _shown_layer_index else -1
	_tint_row(action_list, _tinted_action, false)
	_tint_row(action_list, ai_shown, true)
	_tint_row(layer_list, _tinted_layer, false)
	_tint_row(layer_list, li, true)
	_tinted_action = ai_shown
	_tinted_layer = li


var _tinted_action := -1
var _tinted_layer := -1


static func _tint_row(list: ItemList, i: int, on: bool) -> void:
	if i >= 0 and i < list.item_count:
		list.set_item_custom_bg_color(i, RUNNING_TINT if on else Color(0, 0, 0, 0))


# ======================================================================
#  Refresh helpers
# ======================================================================
func _refresh_layers() -> void:
	layer_list.clear()
	var solo := ProjectData.solo_layer != null
	for i in ProjectData.project.layers.size():
		var l: LoopLayerT = ProjectData.project.layers[i]
		# Two marks in front of the name: runs / does not run (Solo counts),
		# drawn / not drawn on the overlay (the same check and cross as the
		# action list).
		var runs := ProjectData.layer_runs(i)
		layer_list.add_item(l.name, UiIconsT.layer_marks(runs, l.visible))
		layer_list.set_item_custom_fg_color(i, l.color)
		var tip := "Runs in the loop"
		if not runs:
			tip = "Does not run (another layer is solo)" if solo else "Does not run (off)"
		elif solo:
			tip = "Runs alone (solo)"
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
	# Enabled has no say while a layer is solo.
	layer_enabled_check.disabled = ProjectData.solo_layer != null
	layer_solo_check.set_pressed_no_signal(ProjectData.solo_layer == l)
	layer_color_btn.color = l.color


func _refresh_actions() -> void:
	action_list.clear()
	_rows_fit_width = int(action_list.size.x)
	var l := ProjectData.active_layer()
	if l != null:
		actions_header.text = "Actions — %s" % _quoted(l.name)
		for i in l.actions.size():
			var a: LoopActionT = l.actions[i]
			action_list.add_item(_row_text(i, a), UiIconsT.mark(a.enabled))
			if not a.comment.is_empty():
				action_list.set_item_tooltip(i, a.comment)
	else:
		actions_header.text = "Actions"
	# Remember which layer is shown so selection_changed knows when to repopulate.
	_shown_layer_index = ProjectData.active_layer_index
	_shown_layer = l
	_refresh_actions_selection()
	_refresh_running_marks()


var _shown_layer: LoopLayerT = null


## Action `a`'s row (number `i`) in the list, fitted to the list's width,
## measured: the list would otherwise cut it at its right edge - a Key
## text's end, what it types last (Win+R, Enter), or a detect's "no skip",
## gone behind an ellipsis that reads like the rest of a long harmless row.
## Too wide, it is cut in the middle of what it describes, both ends kept
## (see _fit_described).
func _row_text(i: int, a: LoopActionT) -> String:
	var number := "%d. " % (i + 1)
	var described := a.describe()
	# The icon, the margins and the scroll bar take some of the width.
	var max_px := action_list.size.x - 64.0
	if action_list.get_theme_font("font") == null or max_px <= 0.0:
		return number + described
	var room := max_px - _px(number)
	var key := "%d\n%s" % [int(room), described]
	if not _fit_cache.has(key):
		if _fit_cache.size() > FIT_CACHE_MAX:
			_fit_cache.clear()
		_fit_cache[key] = _fit_described(described, room, a)
	return number + _fit_cache[key]


## Fitted rows by room and text (not by row number: a row inserted near the
## top would miss every one below it), and each piece's width.
var _fit_cache := {}
var _px_cache := {}
const FIT_CACHE_MAX := 100000
## The list's width its rows were last fitted to (see _refit_rows).
var _rows_fit_width := -1


## `text`'s width in the list's font, from a cache (the same keys, digits
## and words come back row after row).
func _px(text: String) -> float:
	if _px_cache.has(text):
		return _px_cache[text]
	if _px_cache.size() > FIT_CACHE_MAX:
		_px_cache.clear()
	var w := action_list.get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, action_list.get_theme_font_size("font_size")).x
	_px_cache[text] = w
	return w


## `described` (see LoopAction.describe) as it is if it is at most `room`
## wide, else cut in the middle: a Key's kind ("Key hold 500 ms: \"") and
## closing quote are never cut, and its text is cut only between keystrokes
## (KeyStrokes.split, what typing goes by: "$r" is never an "r", "{ENTER}"
## never "TER}"); anything else between characters. As much of the start
## and of the end as fits, by width.
func _fit_described(described: String, room: float, a: LoopActionT) -> String:
	var key := a.type == LoopActionT.Type.KEY
	var head := ""
	var tail := ""
	var pieces := PackedStringArray()
	if key and described.ends_with("\"") and described.find("\"") < described.length() - 1:
		head = described.left(described.find("\"") + 1)
		tail = "\""
		# The text before its direction marks (they would read as keys), a
		# cut describe made kept as one piece between its two ends: neither
		# end is split again across it.
		var parts := a.described_key_parts()
		for i in parts.size():
			if i > 0:
				pieces.append(" … ")
			pieces.append_array(KeyStrokesT.split(parts[i]))
	else:
		key = false
		for c in described:
			pieces.append(c)
	var widths := PackedFloat32Array()
	var total := _px(head) + _px(tail)
	for p in pieces:
		widths.append(_px(p))
		total += widths[widths.size() - 1]
	if total <= room:
		return described
	# Direction marks either side: a right-to-left letter the cut leaves
	# last would otherwise take the joiner - and what follows it - its way.
	var joiner := char(0x200E) + " … " + char(0x200E)
	var left := room - _px(head) - _px(tail) - _px(joiner)
	var n := pieces.size()
	# A keystroke at either end wider than half the room (a long group) is
	# shown squeezed - its start, where its modifiers are, and its end, what
	# it types last - rather than left out, which would hide a modifier or
	# the whole end; that end then takes nothing more.
	var used := 0.0
	var lo := 0
	var hi := n
	var start := ""
	var end := ""
	var start_done := false
	var end_done := false
	if n > 0 and widths[0] > left / 2.0 and (widths[0] > left or pieces[0].length() > SQUEEZE_CHARS):
		start = _squeezed(pieces[0], left / 2.0)
		used += _px(start)
		lo = 1
		start_done = true
	if hi > lo and widths[hi - 1] > left / 2.0 and (widths[hi - 1] > left or pieces[hi - 1].length() > SQUEEZE_CHARS):
		end = _squeezed(pieces[hi - 1], left / 2.0)
		used += _px(end)
		hi -= 1
		end_done = true
	# Two end keystrokes that do not fit together (short, but wide): each
	# over half the room is squeezed to its share - both to half, or one to
	# what the other leaves.
	if not start_done and not end_done and hi - lo >= 2 and widths[lo] + widths[hi - 1] > left:
		var half := left / 2.0
		if widths[hi - 1] > half:
			end = _squeezed(pieces[hi - 1], half if widths[lo] > half else left - widths[lo])
			used += _px(end)
			hi -= 1
			end_done = true
		if widths[lo] > half:
			start = _squeezed(pieces[lo], left - used if widths[hi] <= half else half)
			used += _px(start)
			lo += 1
			start_done = true
	# Then a keystroke from each end in turn, while one fits: neither end is
	# left out for the other's sake (a wide "{ENTER}" last, a wide start).
	var first := lo
	var last := hi
	var grew := true
	while grew and first < last:
		grew = false
		if not start_done and used + widths[first] <= left:
			used += widths[first]
			first += 1
			grew = true
		if not end_done and first < last and used + widths[last - 1] <= left:
			used += widths[last - 1]
			last -= 1
			grew = true
	# An end left empty (its keystroke wider than the half left to it, the
	# other end squeezed) gets what room is left, squeezed, rather than
	# nothing: the end first, what is typed last.
	if not end_done and last == hi and last > first and left - used > _px("…"):
		end = _squeezed(pieces[last - 1], left - used)
		used += _px(end)
		last -= 1
		end_done = true
	if not start_done and first == lo and first < last and left - used > _px("…"):
		start = _squeezed(pieces[first], left - used)
		used += _px(start)
		first += 1
		start_done = true
	if not start_done:
		start = "".join(pieces.slice(0, first))
	if not end_done:
		end = "".join(pieces.slice(last))
	if key:
		start = LoopActionT.ltr_marked(start)
		end = LoopActionT.ltr_marked(end)
	return head + start + joiner + end + tail


## A keystroke this long (a group) is squeezed rather than kept whole at a
## row's end when it takes more than half the room; a key's name ("{ENTER}")
## only when it does not fit at all.
const SQUEEZE_CHARS := 12


## `text` in at most `px`: as much of its start and of its end as fits,
## "…" between (all of it if it fits).
func _squeezed(text: String, px: float) -> String:
	if _px(text) <= px:
		return text
	var half := maxf(0.0, (px - _px("…")) / 2.0)
	return _part_fitting(text, half) + "…" + _end_fitting(text, half)


## As much of `text`'s end as is at most `px` wide.
func _end_fitting(text: String, px: float) -> String:
	var lo := 0
	var hi := text.length()
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if _px(text.right(mid)) <= px:
			lo = mid
		else:
			hi = mid - 1
	return text.right(lo)

## As much of `text`'s start as is at most `px` wide.
func _part_fitting(text: String, px: float) -> String:
	var lo := 0
	var hi := text.length()
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if _px(text.left(mid)) <= px:
			lo = mid
		else:
			hi = mid - 1
	return text.left(lo)


## The list's rows again when its width has changed since they were last
## fitted (a height change, or a width back to what they were fitted to,
## changes nothing).
func _refit_rows() -> void:
	_refit_queued = false
	var width := int(action_list.size.x)
	if width == _rows_fit_width:
		return
	var l := ProjectData.active_layer()
	if l == null or l != _shown_layer or l.actions.size() != action_list.item_count:
		return
	_rows_fit_width = width
	for i in l.actions.size():
		action_list.set_item_text(i, _row_text(i, l.actions[i]))


var _refit_queued := false


## A layer change (a rename, a colour, Visible / Enabled / Solo - a colour
## picker sends one per step of a drag) rebuilds the action list only when
## its rows are no longer the shown layer's: a list of tens of thousands
## takes seconds to build.
func _refresh_actions_for_layers() -> void:
	var l := ProjectData.active_layer()
	if l == null or l != _shown_layer or l.actions.size() != action_list.item_count:
		_refresh_actions()
		return
	actions_header.text = "Actions — %s" % _quoted(l.name)


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
	action_list.set_item_text(index, _row_text(index, a))
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
			# The button and how it is pressed first, then whether the click goes
			# to its point; the point and duration rows are greyed out when it
			# does not. Captures goes with a plain click at a point (see
			# Playback._execute_action): greyed out otherwise, not hidden.
			_add_button_field(a)
			_add_hold_field(a)
			_add_move_to_field(a)
			var rows := _add_point_fields(a, false)
			rows.append(_add_duration_field(a))
			for r in rows:
				_set_controls_locked(r, not a.move_to)
			var captures := _add_captures_field(a)
			if a.press_mode != LoopActionT.PressMode.TAP or not a.move_to:
				_set_controls_locked(captures, true)
		LoopActionT.Type.DRAG:
			_add_button_field(a)
			_add_point_fields(a, true)
			_add_duration_field(a)
			_add_captures_field(a)
		LoopActionT.Type.SCROLL:
			_add_scroll_fields(a)
			_add_duration_field(a, "How long the scroll takes: the notches are spread over it (0 = as fast as a wheel goes).\nChecked: the gaps between notches vary a little, like a hand's.")
		LoopActionT.Type.KEY:
			_add_keys_field(a)
		LoopActionT.Type.WAIT:
			_add_range_field("Delay", a.wait_ms, a.wait_ms_max, 0, LoopActionT.WAIT_MS_MAX, func(lo: int, hi: int):
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
## Kept inside COORD_MIN .. COORD_MAX (shifted, not cut): past them the box
## would show its end while the loop ran the value itself.
static func _recentre_range(lo: int, hi: int, centre: int) -> Vector2i:
	var span := mini(absi(hi - lo), LoopActionT.COORD_MAX - LoopActionT.COORD_MIN)
	var new_lo := clampi(centre - span / 2, LoopActionT.COORD_MIN, LoopActionT.COORD_MAX - span)
	return Vector2i(new_lo, new_lo + span)


## A point's X / Y ranges with two picks under them: "Pick" keeps the range's
## width and re-centres it on the point clicked; "Pick area" is a dragged
## box, and the ranges become that box (the click can land anywhere in it),
## which is how a loop gets its random spread without typing numbers.
## Returns the rows it added (a Click greys them out with "Move to the
## point first" off).
func _add_point_fields(a: LoopActionT, second: bool) -> Array:
	var rows: Array = []
	editor_box.add_child(_section_label("Point" + (" A" if second else "")))
	rows.append(_add_range_field("X", a.x, a.x_max, LoopActionT.COORD_MIN, LoopActionT.COORD_MAX, func(lo: int, hi: int):
		a.x = lo
		a.x_max = hi).lo.get_parent())
	rows.append(_add_range_field("Y", a.y, a.y_max, LoopActionT.COORD_MIN, LoopActionT.COORD_MAX, func(lo: int, hi: int):
		a.y = lo
		a.y_max = hi).lo.get_parent())
	rows.append(_add_point_picks(a, "", func(g: Vector2i):
		var rx := _recentre_range(a.x, a.x_max, g.x)
		var ry := _recentre_range(a.y, a.y_max, g.y)
		a.x = rx.x
		a.x_max = rx.y
		a.y = ry.x
		a.y_max = ry.y, func(r: Rect2i):
		a.x = r.position.x
		a.x_max = maxi(a.x, r.end.x - 1)
		a.y = r.position.y
		a.y_max = maxi(a.y, r.end.y - 1)))
	if second:
		editor_box.add_child(_section_label("Point B"))
		_add_range_field("X2", a.x2, a.x2_max, LoopActionT.COORD_MIN, LoopActionT.COORD_MAX, func(lo: int, hi: int):
			a.x2 = lo
			a.x2_max = hi)
		_add_range_field("Y2", a.y2, a.y2_max, LoopActionT.COORD_MIN, LoopActionT.COORD_MAX, func(lo: int, hi: int):
			a.y2 = lo
			a.y2_max = hi)
		_add_point_picks(a, " B", func(g: Vector2i):
			var rx := _recentre_range(a.x2, a.x2_max, g.x)
			var ry := _recentre_range(a.y2, a.y2_max, g.y)
			a.x2 = rx.x
			a.x2_max = rx.y
			a.y2 = ry.x
			a.y2_max = ry.y, func(r: Rect2i):
			a.x2 = r.position.x
			a.x2_max = maxi(a.x2, r.end.x - 1)
			a.y2 = r.position.y
			a.y2_max = maxi(a.y2, r.end.y - 1))
	return rows


## The two pick buttons of a point, side by side: a point pick (`on_point`)
## and an area pick (`on_rect`). `which` names the point ("", " B").
## Returns the row.
func _add_point_picks(_a: LoopActionT, which: String, on_point: Callable, on_rect: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	var point := _grab_button(UiIconsT.target(), "Pick%s on screen" % which, func(): _begin_point_pick(on_point))
	point.tooltip_text = "Click where it should land (a range keeps its size and moves there)."
	row.add_child(point)
	var area := _grab_button(UiIconsT.target(), "Pick%s area" % which, func(): _begin_rect_pick(on_rect))
	area.tooltip_text = "Drag a box; it lands anywhere inside it."
	row.add_child(area)
	editor_box.add_child(row)
	return row


func _add_rect_fields(a: LoopActionT) -> void:
	editor_box.add_child(_section_label("Detection rect"))
	# X / Y are unused while the rect follows the mouse, so grey them out.
	var x_pair := _add_range_field("X", a.x, a.x_max, LoopActionT.COORD_MIN, LoopActionT.COORD_MAX, func(lo: int, hi: int):
		a.x = lo
		a.x_max = hi)
	var y_pair := _add_range_field("Y", a.y, a.y_max, LoopActionT.COORD_MIN, LoopActionT.COORD_MAX, func(lo: int, hi: int):
		a.y = lo
		a.y_max = hi)
	var set_xy_editable := func(editable: bool):
		x_pair.set_editable(editable)
		y_pair.set_editable(editable)
	set_xy_editable.call(not a.follow_cursor)
	_add_range_field("Width", a.w, a.w_max, 1, LoopActionT.COORD_MAX, func(lo: int, hi: int):
		a.w = lo
		a.w_max = hi)
	_add_range_field("Height", a.h, a.h_max, 1, LoopActionT.COORD_MAX, func(lo: int, hi: int):
		a.h = lo
		a.h_max = hi)
	# The pick and Follow Cursor side by side.
	var row := HBoxContainer.new()
	row.add_child(_grab_button(UiIconsT.target(), "Pick Area", func():
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
	row.add_child(follow)
	editor_box.add_child(row)


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
## rebuilds the editor, since Hold has a row of its own. A Click switched
## to Up loses its ~Move: letting go is done where the cursor is (a move
## first would drag whatever is held); it can be ticked back.
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
		if a.type == LoopActionT.Type.CLICK and a.press_mode == LoopActionT.PressMode.UP:
			a.move_to = false
		_after_edit()
		_rebuild_editor.call_deferred())
	return opt


## A Click's "Move to the point first" box, under its button row: checked
## (the default) the click goes to X / Y first; unchecked it presses
## wherever the cursor is, and the point and duration rows under it are
## greyed out (the editor is rebuilt for that).
func _add_move_to_field(a: LoopActionT) -> void:
	var cb := CheckBox.new()
	cb.text = "Move to the point first"
	cb.tooltip_text = "Unchecked: the click happens wherever the cursor is, with no move."
	cb.focus_mode = Control.FOCUS_NONE
	cb.button_pressed = a.move_to
	cb.toggled.connect(func(v: bool):
		a.move_to = v
		_after_edit()
		_rebuild_editor.call_deferred())
	editor_box.add_child(cb)


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
	nrow.tooltip_text = "How many clicks of the wheel (the program under the cursor gets them)."
	_add_range_field_in(nrow, a.notches, a.notches_max, 1, LoopActionT.NOTCHES_MAX, func(lo: int, hi: int):
		a.notches = lo
		a.notches_max = hi)


## A Hold's time, when the press is set to Hold.
func _add_hold_field(a: LoopActionT) -> void:
	if a.press_mode != LoopActionT.PressMode.HOLD:
		return
	_add_range_field("Hold", a.hold_ms, a.hold_ms_max, 0, LoopActionT.HOLD_MS_MAX, func(lo: int, hi: int):
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
	# Room for the left-to-right marks shown around SendKeys characters (see
	# LoopAction.ltr_marked); the text itself is cut to KEYS_MAX_CHARS by
	# clean_keys, and the field then shows the cut text.
	le.max_length = LoopActionT.KEYS_MAX_CHARS * 3
	# Left to right whatever it holds: SendKeys text is read in the order it
	# is typed, and a right-to-left run would show "%{F4}" as "{F4}%".
	le.text_direction = Control.TEXT_DIRECTION_LTR
	le.text = LoopActionT.ltr_marked(a.keys)
	le.placeholder_text = "e.g. abc, {ENTER}, ^c"
	le.text_changed.connect(func(t: String):
		# Single line of what shows, always (a paste could carry line breaks
		# or invisible control characters, which would be typed as keys).
		# (The marks the field is shown with are not part of the text.)
		var typed := t.replace(char(0x200E), "")
		a.keys = LoopActionT.clean_keys(typed)
		# The field shows what is kept: a pasted bidi override or invisible
		# character would otherwise go on showing the text in another order,
		# or with more in it, than the action holds and types. Written back
		# without the display marks while it is being edited (they would move
		# the caret off the characters it was between); they come back when
		# the field is left.
		if a.keys != typed:
			var caret := LoopActionT.clean_keys(t.left(le.caret_column).replace(char(0x200E), "")).length()
			le.text = a.keys
			le.caret_column = mini(caret, a.keys.length())
		_after_edit())
	le.focus_exited.connect(func():
		var shown := LoopActionT.ltr_marked(a.keys)
		if le.text != shown:
			le.text = shown)
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
	hint.text = "Windows SendKeys format: {ENTER} or ~ (Enter) {TAB} {ESC} ^c (Ctrl+C) +a (Shift+A) %{F4} (Alt+F4) $r (Win+R) {SUPER} (Windows key alone) {CTRL} (Ctrl alone) {^} {$} {~} {+} {%} (the character)"
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
			# The field shows what the action keeps (cleaned: a layout can
			# type a bidi mark or a zero-width joiner as a key of its own).
			var clean := LoopActionT.clean_keys(t)
			if is_instance_valid(_key_capture_field):
				_key_capture_field.text = LoopActionT.ltr_marked(clean)
			if _key_capture_action != null:
				_key_capture_action.keys = clean
				_after_edit()
				status_label.text = "Keys set to %s" % _quoted(LoopActionT.ltr_marked(clean)))
		# The window is resizable; the size it was last closed at is kept.
		var saved: Variant = _load_setting("key_capture_size", Vector2i.ZERO)
		if saved is Vector2i and saved.x >= _key_capture.min_size.x and saved.y >= _key_capture.min_size.y:
			# No bigger than the screen it opens on: the file is the user's to edit.
			_key_capture.size = saved.min(DisplayServer.screen_get_size(DisplayServer.window_get_current_screen()))
		_key_capture.visibility_changed.connect(func():
			if not _key_capture.visible:
				_save_setting("key_capture_size", _key_capture.size))
		add_child(_key_capture)
	_key_capture_field = le
	_key_capture_action = a
	_key_capture.open(a.keys)


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


## A detect's condition over four rows: "~If [not found / found]" (the "~If"
## checkbox is the Safe walk-through), "~Wait [check every … ms]" (re-check
## until it clears), its "~Timeout [… ms]", and "~Skip" (skip the rest of
## the layer while it holds). Wait and Skip are independent: one detect can
## wait and then skip, wait and carry on, skip at once, or just look.
func _add_on_fail_field(a: LoopActionT) -> void:
	var target := "image" if a.type == LoopActionT.Type.IMAGE_DETECT else "colour"
	var row := _row_toggle("If", a.safe_continue,
		"The condition: the %s is not there — or, with \"found\", it is.\nChecked: in Safe mode nothing is skipped or waited for, so you can walk through the whole loop; Live keeps to the choice." % target,
		func(v: bool):
			a.safe_continue = v
			_after_edit())
	# "not found" is the usual guard; "found" turns the same detect into its
	# opposite (skip while the colour is there, wait till it goes).
	var when := _compact_option()
	when.add_item("not found", 0)
	when.add_item("found", 1)
	when.select(1 if a.if_found else 0)
	when.item_selected.connect(func(i):
		a.if_found = i == 1
		_after_edit()
		# The Delay / Skip tooltips read "appears" / "goes" from this.
		_rebuild_editor.call_deferred())
	row.add_child(when)
	editor_box.add_child(row)
	# ~Wait: re-check the same spot on this interval until the condition
	# clears (F8 / Esc / a Stop action still end the loop). The interval and
	# the timeout are greyed out while it is off.
	var wrow := _row_toggle("Delay", a.wait,
		"Checked: keep checking this spot every so often until the %s %s." % [target, "goes" if a.if_found else "appears"],
		func(v: bool):
			a.wait = v
			_after_edit())
	var wpair := _add_range_field_in(wrow, a.wait_ms, a.wait_ms_max, 0, LoopActionT.WAIT_MS_MAX, func(lo: int, hi: int):
		a.wait_ms = lo
		a.wait_ms_max = hi, "ms")
	wpair.set_editable(a.wait)
	# ~Timeout: give up waiting after this long (a range, like every number);
	# ~Skip then decides what happens.
	var trow := _row_toggle("Timeout", a.wait_timeout,
		"Checked: stop waiting after this long.",
		func(v: bool):
			a.wait_timeout = v
			_after_edit())
	var tpair := _add_range_field_in(trow, a.wait_timeout_ms, a.wait_timeout_ms_max, 0, LoopActionT.TIMEOUT_MS_MAX, func(lo: int, hi: int):
		a.wait_timeout_ms = lo
		a.wait_timeout_ms_max = hi, "ms")
	var timeout_check := trow.get_child(0) as CheckBox
	timeout_check.disabled = not a.wait
	tpair.set_editable(a.wait and a.wait_timeout)
	(wrow.get_child(0) as CheckBox).toggled.connect(func(v: bool):
		wpair.set_editable(v)
		timeout_check.disabled = not v
		tpair.set_editable(v and a.wait_timeout))
	timeout_check.toggled.connect(func(v: bool): tpair.set_editable(a.wait and v))
	# Skip: skip the rest of the layer while the condition holds (at once,
	# or still after the wait). Off, the layer carries on either way.
	var skip := CheckBox.new()
	skip.text = "Skip rest of layer"
	skip.tooltip_text = "Checked: skip the rest of the layer while the %s is %s.\nUnchecked: carry on either way." % [target, "there" if a.if_found else "not there"]
	skip.focus_mode = Control.FOCUS_NONE
	skip.button_pressed = a.skip
	skip.toggled.connect(func(v: bool):
		a.skip = v
		_after_edit())
	editor_box.add_child(skip)


func _add_capture_mode_field(a: LoopActionT) -> void:
	var row := _row("Mode")
	var opt := _compact_option()
	opt.add_item("Mouse", LoopActionT.CaptureMode.MOUSE)
	opt.add_item("Detect", LoopActionT.CaptureMode.DETECT)
	opt.select(opt.get_item_index(a.capture_mode))
	opt.item_selected.connect(func(i):
		a.capture_mode = opt.get_item_id(i)
		_after_edit())
	row.add_child(opt)
	editor_box.add_child(row)
	_add_duration_field(a)
	var hint := Label.new()
	hint.text = "Mouse moves the cursor to where your own mouse is: where it was when the run started, plus whatever you have moved it since (the loop's own moves do not count). Detect moves it to where the last Pixel or Image Detect found its target."
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
	sp.max_value = LoopActionT.STOP_AFTER_MAX
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


## Returns the row (a Click greys it out when Captures does not apply).
func _add_captures_field(a: LoopActionT) -> HBoxContainer:
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
	return row


func _add_comment_field(a: LoopActionT) -> void:
	editor_box.add_child(HSeparator.new())
	var row := _row("Comment")
	var le := LineEdit.new()
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.max_length = LoopActionT.COMMENT_MAX_CHARS
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
func _add_duration_field(a: LoopActionT, tip: String = "How long the cursor takes to get there.\nChecked: it wanders a little on the way, like a hand would; where it starts and lands stays exact.") -> HBoxContainer:
	var row := _row_toggle("Duration", a.wiggle, tip,
		func(v: bool):
			a.wiggle = v
			_after_edit())
	_add_range_field_in(row, a.duration_ms, a.duration_ms_max, 0, LoopActionT.DURATION_MS_MAX, func(lo: int, hi: int):
		a.duration_ms = lo
		a.duration_ms_max = hi, "ms")
	return row


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
	_pick_action = ProjectData.selected_action()
	_start_pick(PickOverlayT.PickKind.POINT, sample_colors)


## Start picking a screen rectangle; `cb` receives a Rect2i (global coords).
func _begin_rect_pick(cb: Callable) -> void:
	if _pick_active:
		return
	_pick_rect_cb = cb
	_pick_point_cb = Callable()
	_pick_action = ProjectData.selected_action()
	_start_pick(PickOverlayT.PickKind.RECT)


func _start_pick(kind: int, sample_colors: bool = false) -> void:
	_pick_active = true
	_pick_was_overlay_visible = overlay.visible
	# Show the guides underneath while placing, so existing points are visible.
	if not overlay.visible:
		overlay.show_overlay()
	status_label.text = "Pick on screen — left-click to set, right-click / Esc to cancel."
	picker.begin_pick(kind, sample_colors)
	_lower_builder(true)
	if sample_colors:
		_start_hover_sampling()


## Gets the builder out of the way (~Edit unchecked) so the desktop it was
## covering is visible. For a run or a recording it is minimised: the
## taskbar brings it back whenever the user wants it, and the end of the
## run un-minimises it if it still is. With `park`, for a pick, it is moved
## just off-screen instead, where it keeps the focus (Esc still reaches it)
## and comes back when the pick ends. Put back by
## _restore_builder_after_pick.
func _lower_builder(park: bool = false) -> void:
	_refresh_stay_on_edit_check()
	if _builder_hidden_for_pick:
		# Minimised for a run and brought back by the user meanwhile: it is
		# theirs again (a pick started from it may park it).
		var win := get_window()
		if _builder_parked or win.mode == Window.MODE_MINIMIZED:
			return
		_builder_hidden_for_pick = false
	var lower := not stay_on_edit_check.button_pressed
	if lower and Engine.is_embedded_in_editor():
		status_label.text += "  (Lowering the window is unavailable while embedded in the editor.)"
	if lower and not Engine.is_embedded_in_editor():   # (not the box's disabled: a Live run locks it too)
		var win := get_window()
		_builder_hidden_for_pick = true
		_builder_prev_mode = win.mode
		_builder_prev_pos = win.position
		# A maximised window cannot be moved aside: it is minimised for a
		# pick as well (Esc is then unavailable; right-click still cancels).
		_builder_parked = park and win.mode == Window.MODE_WINDOWED
		if _builder_parked:
			var desktop := OverlayT.virtual_desktop_rect()
			win.position = Vector2i(desktop.end.x + 64, win.position.y)
		else:
			win.mode = Window.MODE_MINIMIZED


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


## Lowering the builder (~Edit unchecked) can't work while the game
## runs embedded in the editor's Game tab: moving the (child) window just
## blanks that panel, and the editor keeps covering the desktop anyway. Grey
## the option out in that case.
func _refresh_stay_on_edit_check() -> void:
	var embedded := Engine.is_embedded_in_editor()
	# (Locked during a Live run like every other control but Run.)
	var off := embedded or _is_interaction_locked()
	if stay_on_edit_check.disabled == off and not stay_on_edit_check.tooltip_text.is_empty():
		return
	stay_on_edit_check.disabled = off
	if embedded:
		stay_on_edit_check.tooltip_text = "Unavailable while the game is embedded in the Godot editor (Game tab → turn off Embed Game on Next Play)."
	else:
		stay_on_edit_check.tooltip_text = "Unchecked: this window is minimised when a loop or a recording starts (the taskbar brings it back) and moved aside while you pick on screen.\nChecked: it stays where it is."


## Brings the builder back (if it was got out of the way) and refocuses
## it. One the user brought back themselves meanwhile is left as they
## have it.
func _restore_builder_after_pick() -> void:
	var win := get_window()
	if _builder_hidden_for_pick:
		_builder_hidden_for_pick = false
		if win.mode == Window.MODE_MINIMIZED:
			win.mode = _builder_prev_mode
		# A parked window is put back by position too, whatever happened
		# meanwhile: one the user minimised from the taskbar while parked
		# came back un-minimised but still off-screen, unreachable.
		if _builder_parked and win.mode == Window.MODE_WINDOWED:
			win.position = _builder_prev_pos
		_builder_parked = false
	_keep_builder_on_screen()
	win.grab_focus()


## A windowed builder that is off every display (parked there and never
## brought back, or the display it was on is gone) is centred on the
## primary one: an off-screen window cannot be reached to fix it.
func _keep_builder_on_screen() -> void:
	var win := get_window()
	if win.mode != Window.MODE_WINDOWED or _builder_hidden_for_pick:
		return
	var desktop := OverlayT.virtual_desktop_rect()
	var shown := Rect2i(win.position, win.size).intersection(desktop)
	if shown.size.x >= 64 and shown.size.y >= 64:
		return
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.get_primary_screen())
	win.position = usable.position + (usable.size - win.size) / 2


# ======================================================================
#  Record
# ======================================================================
func _on_rec_pressed() -> void:
	if _recording:
		_stop_recording("", true)
	elif not Playback.is_running and not _pick_active and not _dialog_open():
		var layer := ProjectData.active_layer()
		if layer == null:
			return
		# Asked first: the helper sees every window, and what is typed lands in
		# the loop file readable - a password too.
		_confirm("Record what you do with the mouse and keyboard into this layer until you press F8?\n    %s\nEverything you type is kept in the loop as plain text - stop before typing a password." % _quoted(layer.name),
			_start_recording, "Record")


## Rec: the builder moves out of the way, a short countdown on the status
## line, then the recording is on until F8 (or the button, or Esc here).
func _start_recording() -> void:
	if ProjectData.active_layer() == null:
		return
	_commit_pending_edits()
	_close_key_capture()
	# What was asked about is where it goes (see _stop_recording).
	_record_layer = ProjectData.active_layer()
	_record_loop_id = ProjectData.active_loop_id
	_recording = true
	_record_armed = false
	_record_gen += 1
	var gen := _record_gen
	rec_btn.text = "Stop"
	_lower_builder()
	# The helper is started before the countdown: it takes a second or two
	# to come up (PowerShell compiles it), which the countdown hides - so the
	# first click after "Recording…" is not lost to a helper not yet in. What
	# it sees meanwhile is dropped below.
	# ~Self on: what lands on Loop Automator itself is recorded too.
	_record_unguarded = feedback_check.button_pressed
	_recorder.start(0 if _record_unguarded else OS.get_process_id())
	for n in [3, 2, 1]:
		status_label.text = "Recording in %d… (F8 stops it)" % n
		await get_tree().create_timer(1.0).timeout
		if gen != _record_gen:
			return
	# Still coming up (a slow machine): say so rather than record nothing.
	# A helper that fails meanwhile ends the recording from _process.
	while _recorder.state == RecorderT.State.STARTING:
		status_label.text = "Starting the recorder…"
		await get_tree().process_frame
		if gen != _record_gen:
			return
	_recorder.events.clear()
	_record_armed = true
	# The dot goes red now, not at the button: red means it is recording.
	_start_rec_pulse()
	if _recorder.f8_taken and not Playback.global_hotkey_armed():
		# Another program holds F8 as its hotkey, so its press never reaches
		# the recorder (with ~F8 on, the run's helper holds it and ends the
		# recording itself). The builder comes back, then: minimised, the one
		# way to stop a recording that sees every key typed would be out of
		# sight, and so would the line saying so.
		_restore_builder_after_pick()
		status_label.text = "Recording… F8 is taken by another program: stop with the button or Esc here."
	else:
		status_label.text = "Recording… press F8 to stop."


## Ends the recording; the events become actions on the end of the active
## layer. `reason` (a helper failure) is what the status line says instead.
## `from_builder`: the button or Esc here ended it - with ~Self on that
## gesture was recorded too, so it is trimmed off the end.
func _stop_recording(reason: String = "", from_builder: bool = false) -> void:
	if not _recording:
		return
	_recording = false
	_record_gen += 1
	rec_btn.text = "Rec"
	_stop_rec_pulse()
	var events := _recorder.stop()
	if not _record_armed:
		events = []   # ended during the countdown: nothing was being recorded yet
	elif from_builder and _record_unguarded:
		events = RecordingT.without_stop_gesture(events)
	# Not in the middle of a pick or a sample (which bring it back themselves
	# once they have read the screen).
	if not _pick_active and not _sample_pending:
		_restore_builder_after_pick()
	if not reason.is_empty():
		status_label.text = reason
		return
	var actions := RecordingT.to_actions(events)
	if actions.is_empty():
		status_label.text = "Recorded nothing."
		return
	# Into the layer the recording was asked about, not whichever is open
	# now (the builder stays usable with ~Edit) - without switching to it.
	var added := ProjectData.append_actions(_record_loop_id, _record_layer, actions)
	if added < 0:
		status_label.text = "Recording not kept: the layer it was for is gone."
		return
	status_label.text = "Recorded %d action%s into %s." % [added, "" if added == 1 else "s", _quoted(_record_layer.name)]
	if added < actions.size():
		status_label.text += " The loop is full (%d actions): the rest was not kept." % ProjectData.LOOP_ACTIONS_MAX
	if _recorder.limit_reached:
		status_label.text += " The recording limit was reached, so it ended there."


## The Rec dot goes red and breathes slowly (a shade brighter and back)
## while the recording is on: lit, not flashing.
func _start_rec_pulse() -> void:
	_stop_rec_pulse()
	_set_rec_icon_color(REC_ON_COLOR)
	_rec_pulse = create_tween().set_loops()
	_rec_pulse.tween_method(_set_rec_icon_color, REC_ON_COLOR, REC_ON_BRIGHT_COLOR, REC_BREATH_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_rec_pulse.tween_method(_set_rec_icon_color, REC_ON_BRIGHT_COLOR, REC_ON_COLOR, REC_BREATH_SEC).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


func _stop_rec_pulse() -> void:
	if _rec_pulse != null and _rec_pulse.is_valid():
		_rec_pulse.kill()
	_rec_pulse = null
	_set_rec_icon_color(REC_IDLE_COLOR)


## The dot is a white circle tinted through the button's icon colours, in
## every state (hovered, pressed) alike.
func _set_rec_icon_color(c: Color) -> void:
	for name in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_hover_pressed_color", "icon_focus_color", "icon_disabled_color"]:
		rec_btn.add_theme_color_override(name, c)


func _on_point_picked(g: Vector2i) -> void:
	if not _still_selected(_pick_action):
		_finish_pick()
		return
	if _pick_point_cb.is_valid():
		_pick_point_cb.call(g)
	# Within what the editor's boxes take (a pick far off every screen, or
	# a range re-centred near an end), as a load would keep it.
	if _pick_action != null:
		_pick_action.keep_to_limits()
	status_label.text = "Set point (%d, %d)." % [g.x, g.y]
	_finish_pick()
	_after_edit()
	_rebuild_editor()


func _on_rect_picked(r: Rect2i) -> void:
	if not _still_selected(_pick_action):
		_finish_pick()
		return
	if _pick_rect_cb.is_valid():
		_pick_rect_cb.call(r)
	# Within what the editor's boxes take (a pick far off every screen, or
	# a range re-centred near an end), as a load would keep it.
	if _pick_action != null:
		_pick_action.keep_to_limits()
	status_label.text = "Set rect [%d, %d, %d×%d]." % [r.position.x, r.position.y, r.size.x, r.size.y]
	_finish_pick()
	_after_edit()
	_rebuild_editor()


## Whether `a` (the action a pick or sample was started for) is still the
## selected action of the open loop: one that is not (another was chosen,
## or another loop opened, while it was under way) does not get the result,
## which the list and the editor would not show against it. Says so on the
## status line.
func _still_selected(a: LoopActionT) -> bool:
	if a != null and a == ProjectData.selected_action():
		return true
	status_label.text = "Pick dropped: another action was selected while it was under way."
	return false


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
	if not _still_selected(a):
		return
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
	if not _still_selected(a):
		return
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
		# Within the boxes' limits (see _on_rect_picked, which ran before this).
		a.keep_to_limits()
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
	if _recording and _recorder.state != RecorderT.State.OFF:
		if _recorder.poll():
			_stop_recording()
		elif _recorder.state == RecorderT.State.UNAVAILABLE:
			_stop_recording("Recording failed: %s." % _recorder.reason)
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


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_on_close_requested()


## Closing the window: edits live in memory until Save, so with any loop
## changed and not saved the user is asked first (Cancel keeps the app open
## to save them). A recording in progress counts too: it would be lost.
var _quit_dialog: ConfirmationDialog = null
func _on_close_requested() -> void:
	if _quit_dialog != null and is_instance_valid(_quit_dialog):
		_quit_dialog.grab_focus()
		return
	_commit_pending_edits()
	var n := ProjectData.pending_loop_count()
	if n == 0 and not _recording:
		get_tree().quit()
		return
	var what := "%d loop%s ha%s changes that are not saved" % [n, "" if n == 1 else "s", "s" if n == 1 else "ve"]
	if _recording:
		what = "A recording is in progress" if n == 0 else what + ", and a recording is in progress"
	_quit_dialog = ConfirmationDialog.new()
	_quit_dialog.title = "Quit"
	_quit_dialog.exclusive = false
	_quit_dialog.dialog_text = "%s. Quit anyway and lose %s?" % [what, "them" if n > 1 or (n == 1 and _recording) else "it"]
	_quit_dialog.ok_button_text = "Quit without saving"
	_quit_dialog.confirmed.connect(func(): get_tree().quit())
	_quit_dialog.canceled.connect(func():
		_quit_dialog.queue_free()
		_quit_dialog = null)
	add_child(_quit_dialog)
	_quit_dialog.popup_centered()


func _exit_tree() -> void:
	# A Thread must be joined before it is freed.
	if _hover_thread != null:
		_hover_thread.wait_to_finish()
		_hover_thread = null
	# Closing mid-recording: the listening goes with the helper.
	_recorder.stop()


# ------------------------------------------------------- UI preferences
func _load_setting(key: String, default: Variant) -> Variant:
	return _settings().get_value("ui", key, default)


## The settings file, read. Godot's format can say Object(…) and Resource(…),
## which reading alone builds - a script's code run, from a file anyone may
## drop in the data folder - and its parser skips comments and control
## characters where a check for those words would not look. So the file is
## read only if every line is one this app writes: "[ui]", or a name set to
## true, false, a whole number or a Vector2i. Anything else, and it is not
## read at all (the defaults stand; the next change of a setting writes a
## clean one).
func _settings() -> ConfigFile:
	var cfg := ConfigFile.new()
	var text := FileAccess.get_file_as_string(SETTINGS_PATH)
	if text.is_empty():
		return cfg
	if _plain_setting == null:
		_plain_setting = RegEx.create_from_string("^[ \\t]*(\\[ui\\]|[A-Za-z0-9_]+[ \\t]*=[ \\t]*(true|false|-?[0-9]{1,10}|Vector2i\\([ \\t]*-?[0-9]{1,10}[ \\t]*,[ \\t]*-?[0-9]{1,10}[ \\t]*\\)))?[ \\t]*$")
	for line in text.replace("\r\n", "\n").split("\n"):
		if _plain_setting.search(line) == null:
			push_warning("Settings file not read: it holds more than plain values.")
			return cfg
	if cfg.parse(text) != OK:
		return ConfigFile.new()
	return cfg
static var _plain_setting: RegEx = null

## A yes / no setting. The file is the user's to edit, so a value that is
## not one (a word, a number) is the default, not a type error at start-up.
func _load_bool_setting(key: String, default: bool) -> bool:
	var v: Variant = _load_setting(key, default)
	return v if v is bool else default


func _save_setting(key: String, value: Variant) -> void:
	var cfg := _settings()  # missing (or refused) is fine: start empty
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
			text_short = "View: %d/%d - %s" % [idx + 1, layers.size(), _quoted(layers[idx].name)]
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
		loop_picker.add_item("%d. %s%s" % [loop_picker.item_count + 1, _quoted(name), dirty_mark], id)
		if id == previous_id:
			active_idx = loop_picker.item_count - 1
	if active_idx >= 0:
		loop_picker.select(active_idx)
	var total := ProjectData.loop_stack.size()
	_refresh_loop_nav()
	if save_btn != null:
		# An unsaved change shows as a "*" beside the icon.
		save_btn.text = "*" if ProjectData.active_loop_is_pending() else ""
	var loop_name := _quoted(ProjectData.active_loop_display_name())
	var pending_text := " (unsaved)" if ProjectData.active_loop_is_pending() else ""
	status_label.text = "Loop %d/%d · %s%s" % [_active_loop_number(), maxi(1, total), loop_name, pending_text]


## The open loop's number as the picker and the status line show it: its
## place in the list, 1 up (not its store id, which only ever grows).
func _active_loop_number() -> int:
	return maxi(0, ProjectData.active_loop_stack_index()) + 1


func _on_play_pressed() -> void:
	if _stop_cooldown_active or _recording:
		return
	# A pick or a screen sample under way brings the builder back and takes
	# the focus when it lands: not in the middle of a run it would start.
	if not Playback.is_running and (_pick_active or _sample_pending or _hover_thread != null):
		status_label.text = "Not started: a pick or a screen read is still under way."
		return
	_commit_pending_edits()
	# A Live run of a loop whose points may be off (see _warn_points_unsure)
	# is asked about first; confirmed, its points count as checked.
	if not Playback.is_running and Playback.backend != null and Playback.backend.is_real() and ProjectData.project.points_unsure != Vector2i.ZERO:
		var off: Vector2i = ProjectData.project.points_unsure
		_confirm("This loop is from an older version, which counted points from the main screen. With your screens as they are, some of its points may be off by (%d, %d) - clicks landing somewhere else.\n\nRun it Live anyway? Its points will count as checked from now on." % [off.x, off.y], func():
			ProjectData.project.points_unsure = Vector2i.ZERO
			ProjectData.notify_layer_modified()
			Playback.toggle(), "Run")
		return
	Playback.toggle()


func _on_loop_picker_selected(i: int) -> void:
	if loop_picker == null:
		return
	var id := loop_picker.get_item_id(i)
	# A number still being typed belongs to the loop being left.
	_commit_pending_edits()
	ProjectData.open_loop(id)


## The ◀ ▶ loop buttons are greyed out while there is no other loop to go
## to. Called again after an unlock, which enables every button.
func _refresh_loop_nav() -> void:
	var alone := ProjectData.loop_stack.size() <= 1
	if loop_prev_btn != null:
		loop_prev_btn.disabled = alone
	if loop_next_btn != null:
		loop_next_btn.disabled = alone


func _switch_loop(delta: int) -> void:
	_commit_pending_edits()
	ProjectData.step_loop(delta)


func _on_backend_selected(i: int) -> void:
	Playback.set_backend(backend_option.get_item_id(i))
	_refresh_edit_lock()
	_refresh_run_label()


## "Run?" while nothing runs; the button reads "Run!" (with the stop icon)
## while the loop is going. Left alone during a run or while the button is
## counting down after one.
func _refresh_run_label() -> void:
	if play_btn == null or Playback.is_running or _stop_cooldown_active:
		return
	play_btn.icon = UiIconsT.play()
	play_btn.text = _run_label()


func _run_label() -> String:
	return "Run?"


var _was_locked := false


func _refresh_edit_lock() -> void:
	var locked := _is_interaction_locked()
	# The window dims while a Live loop runs, ~Self or not. A Pixel Detect
	# reading Loop Automator's own window (~Self on) then reads the dimmed
	# colours — the user accounts for that shift; the dim cue is kept.
	var tint := Color(1, 1, 1, 0.65) if locked else Color(1, 1, 1, 1)
	# Only when the lock comes on or goes: unlocking re-enables every control
	# (and rebuilds the editor to grey its own again), which in the middle of
	# an edit - a Safe run ending, a stop's cooldown - would tear it down.
	if _ui_root != null and locked != _was_locked:
		_was_locked = locked
		_set_controls_locked(_ui_root, locked)
		_ui_root.modulate = tint
		if not locked:
			_refresh_loop_nav()   # the unlock enabled the ◀ ▶ buttons too
			_refresh_layer_props()   # and Enabled, which Solo may keep greyed
			_rebuild_editor()   # and the editor's rows its own settings keep greyed
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
	status_label.text = "Duplicated %s as loop %d, %s." % [_quoted(from), _active_loop_number(), _quoted(ProjectData.active_loop_display_name())]


func _confirm_delete_loop() -> void:
	var id := ProjectData.active_loop_id
	if id < 0 or ProjectData.project == null:
		return
	var layers := ProjectData.project.layers.size()
	var name := ProjectData.active_loop_display_name()
	_confirm("Delete this loop and its %d layer(s)? Its file is removed too.
    %s" % [layers, _quoted(name)],
		func():
			if ProjectData.delete_loop(id):
				status_label.text = "Deleted loop %s." % _quoted(name))


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
		dlg.queue_free()
		# A loop file is shared as it is: what Rec recorded (passwords too,
		# as plain text) and every Image Detect's template, a piece of the
		# screen it was captured from.
		var peek := ProjectData.peek_loop(ProjectData.project)
		var templates := 0
		for layer in ProjectData.project.layers:
			for a in layer.actions:
				if a.type == LoopActionT.Type.IMAGE_DETECT and not a.image_png.is_empty():
					templates += 1
		var note := ""
		if not (peek["keys"] as Array).is_empty() or templates > 0:
			note = "Whoever gets the file can read all of it: the text of its %d Key action(s) (anything Rec recorded you typing, passwords included) and %d Image Detect template(s), each a piece of your screen.\n\n" % [(peek["keys"] as Array).size(), templates]
		if not path.to_lower().ends_with(".loop"):
			path += ".loop"
			# The dialog asked about the name as typed, not this one.
			if FileAccess.file_exists(path):
				note += "A file of that name already exists and will be replaced.\n"
		var write := func():
			var err := ProjectData.export_to(path)
			status_label.text = "Exported to %s" % path if err == OK else "Export failed (%d)." % err
		if note.is_empty():
			write.call()
		else:
			(func(): _confirm(note + "Export to this file?\n    %s" % _quoted(LoopActionT.plain_text(path.get_file(), LoopLayerT.NAME_MAX_CHARS)), write, "Export")).call_deferred())
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
	# Read once: the question describes this copy and Import brings in this
	# copy, never whatever the file holds by the time Import is pressed.
	var source := ProjectData.read_import(path)
	if source == null:
		status_label.text = "Import failed: %s is not a readable .loop file, or holds more than a loop may (%d layers, %d actions, %d MP of Image Detect templates)." % [_quoted(LoopActionT.plain_text(path.get_file(), LoopLayerT.NAME_MAX_CHARS)), ProjectData.LOOP_LAYERS_MAX, ProjectData.LOOP_ACTIONS_MAX, ProjectData.LOOP_TEMPLATE_PIXELS_MAX / (1024 * 1024)]
		return
	var peek := ProjectData.peek_loop(source)
	var keys: Array = peek["keys"]
	# Everything from the file is quoted (a name could otherwise go on as
	# the question's own sentence) and set left to right, as it is typed.
	# A name goes on a line of its own, indented (_wrap_lines never breaks
	# those): split across lines, its isolate would end with the line, and
	# look-alike quotes (“ ”) in it could carry on as the question's text.
	var text := "Import this file as a new loop?\n    %s\n\n" % _quoted(LoopActionT.plain_text(path.get_file(), LoopLayerT.NAME_MAX_CHARS))
	text += "Its first layer is named:\n    %s\n\n" % _quoted(String(peek["name"]))
	text += "A loop is like a script: run in Live mode it can type anything and click anywhere. "
	text += "This one has %d layer(s) and %d action(s)" % [peek["layers"], peek["actions"]]
	if keys.is_empty():
		text += ", none of them Key actions (nothing in it types).\n"
	else:
		# The ones that press more than characters come first: they are the
		# ones that can run a command (Win+R, then Enter).
		var special := RegEx.create_from_string("[~^+%${}()]")
		var pressing: Array = []
		var plain: Array = []
		for k in keys:
			(pressing if special.search(k) != null else plain).append(k)
		text += ", including %d Key action(s)" % keys.size()
		if not pressing.is_empty():
			text += ", %d of them pressing more than characters" % pressing.size()
		text += ". In their text ~ is Enter, ^ Ctrl, + Shift, % Alt, $ the Windows key and {…} a key by name. They type:\n"
		var shown := pressing + plain
		for i in mini(shown.size(), IMPORT_KEYS_SHOWN):
			var k: String = shown[i]
			var line := _quoted(LoopActionT.ltr_marked(k))
			if k.length() > IMPORT_KEY_CHARS:
				# Its start and its end, and how long it is: what runs last
				# in a long text is as much a part of it as what runs first.
				# Cut between keystrokes (see LoopAction.stroke_ends): "$r" is never an "r".
				var ends := LoopActionT.stroke_ends(k, IMPORT_KEY_CHARS / 2, IMPORT_KEY_CHARS / 2)
				line = "%s … %s  (%d characters)" % [_quoted(LoopActionT.ltr_marked(ends[0])), _quoted(LoopActionT.ltr_marked(ends[1])), k.length()]
			text += "    •  %s\n" % line
		if shown.size() > IMPORT_KEYS_SHOWN:
			text += "    •  … and %d more\n" % (shown.size() - IMPORT_KEYS_SHOWN)
	text += "\nIt opens in Safe mode. Read its actions there and dry-run it before you ever run it Live."
	var do_import := func():
		# As the question says: with Live chosen, an idle ~F8 or one press of
		# Run would drive the real mouse and keyboard with a loop nobody has
		# read yet.
		_switch_to_safe_backend_if_needed()
		ProjectData.import_loop(source)
		status_label.text = "Imported %s as loop %d." % [_quoted(ProjectData.active_loop_display_name()), _active_loop_number()]
		_warn_points_unsure()
	_confirm(text, do_import, "Import")


## `s` in quotes (JSON's: a quote inside it is \") and isolated left to
## right, so neither a quote nor right-to-left letters in it can change how
## the sentence around it reads.
## A long one shows its start and end and how long it is: a line the dialog
## does not wrap would otherwise run off the screen, its end unseen.
static func _quoted(s: String) -> String:
	# Measured and cut without the left-to-right marks a Key's text is
	# shown with (they are put back on each half).
	var real := s.replace(char(0x200E), "")
	if real.length() > QUOTED_MAX_CHARS:
		var half := QUOTED_MAX_CHARS / 2
		var marked := real != s
		var head := LoopActionT.ltr_marked(real.left(half)) if marked else real.left(half)
		var tail := LoopActionT.ltr_marked(real.right(half)) if marked else real.right(half)
		return "%s … %s  (%d characters)" % [_quoted(head), _quoted(tail), real.length()]
	return char(0x2066) + JSON.stringify(s) + char(0x2069)
const QUOTED_MAX_CHARS := 64


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
		_inform("This is the loop's only layer, and a loop needs at least one:\n    %s\nDelete its actions instead, add another layer first, or delete the whole loop (trash icon in the toolbar)." % _quoted(layer.name))
		return
	_confirm("Delete this layer and its %d action(s)?
    %s" % [layer.actions.size(), _quoted(layer.name)],
		func(): ProjectData.remove_layer(index))


func _confirm_delete_action() -> void:
	var index := ProjectData.selected_action_index
	var layer := ProjectData.active_layer()
	if layer == null or index < 0 or index >= layer.actions.size():
		return
	var action: LoopActionT = layer.actions[index]
	_confirm("Delete action %d?
    %s" % [index + 1, _quoted(action.describe())],
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
	dlg.dialog_text = _dialog_text(text)
	dlg.confirmed.connect(func(): dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


## Asks before something happens; `on_ok` runs only if the user confirms
## with the button labelled `ok_text`.
func _confirm(text: String, on_ok: Callable, ok_text: String = "Delete") -> void:
	var dlg := ConfirmationDialog.new()
	dlg.title = "Confirm"
	# Each indented line (a name or a Key's text, from a file) kept to what
	# fits the screen, measured, not counted: a line of very wide characters
	# would otherwise make the dialog wider than the screen - its end, what
	# a Key types last, off it - and wrapping it would set its rest on the
	# margin the dialog's own sentences start at.
	dlg.dialog_text = _dialog_text(text)
	dlg.ok_button_text = ok_text
	dlg.confirmed.connect(func():
		on_ok.call()
		dlg.queue_free())
	dlg.canceled.connect(func(): dlg.queue_free())
	add_child(dlg)
	dlg.popup_centered()


const DIALOG_LINE_MAX_PX := 1000


## `text` for a dialog: wrapped (see _wrap_lines), each indented line (a
## name or a Key's text from a file) fitted to the screen (see _fit_line).
func _dialog_text(text: String) -> String:
	var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	var fit_px := mini(DIALOG_LINE_MAX_PX, screen.size.x - 80)
	var lines := _wrap_lines(text).split("\n")
	for i in lines.size():
		if lines[i].begins_with(" "):
			lines[i] = _fit_line(lines[i], fit_px)
	return "\n".join(lines)


## `line` as it is if it is at most `max_px` wide in a dialog's font, else
## with each quoted part (see _quoted: file text) cut to its start and end,
## as much of both as fits - the app's own words around them never cut.
func _fit_line(line: String, max_px: int) -> String:
	var font := get_theme_font("font", "Label")
	var size := get_theme_font_size("font_size", "Label")
	if font == null or font.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_px:
		return line
	var longest := 0
	for part in _quoted_parts(line):
		longest = maxi(longest, (part as String).length())
	var lo := 1
	var hi := longest
	while lo < hi:
		var mid := (lo + hi + 1) / 2
		if font.get_string_size(_cut_quoted(line, mid), HORIZONTAL_ALIGNMENT_LEFT, -1, size).x <= max_px:
			lo = mid
		else:
			hi = mid - 1
	return _cut_quoted(line, lo)


## The text inside each quote of `line` (between _quoted's isolate marks
## and quote marks).
static func _quoted_parts(line: String) -> Array:
	var parts := []
	var at := line.find(char(0x2066))
	while at >= 0:
		var end := line.find(char(0x2069), at)
		if end < 0:
			break
		var raw: Variant = JSON.parse_string(line.substr(at + 1, end - at - 1))
		parts.append(raw if typeof(raw) == TYPE_STRING else "")
		at = line.find(char(0x2066), end)
	return parts


## `line` with every quoted part longer than 2 × `keep` characters cut to
## its first and last `keep` - the text itself, not its escaped form, so a
## cut never splits a \" - each half in quotes of its own, with the " … "
## and the part's length outside them, where file text cannot put words.
static func _cut_quoted(line: String, keep: int) -> String:
	var counted := line.ends_with(" characters)")
	var out := ""
	var from := 0
	var at := line.find(char(0x2066))
	while at >= 0:
		var end := line.find(char(0x2069), at)
		if end < 0:
			break
		var segment := line.substr(at, end - at + 1)
		var raw: Variant = JSON.parse_string(line.substr(at + 1, end - at - 1))
		if typeof(raw) == TYPE_STRING and (raw as String).length() > 2 * keep + 1:
			var text: String = raw
			segment = "%s … %s" % [
				char(0x2066) + JSON.stringify(text.left(keep)) + char(0x2069),
				char(0x2066) + JSON.stringify(text.right(keep)) + char(0x2069)]
			# Its length, unless the line gives the whole text's already (a
			# part that is itself the start or end of a longer one, see _quoted).
			if not counted:
				segment += "  (%d characters)" % text.replace(char(0x200E), "").length()
		out += line.substr(from, at - from) + segment
		from = end + 1
		at = line.find(char(0x2066), from)
	return out + line.substr(from)


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
	# The on-screen keyboard too: F8 pressed there is a key being captured.
	if _key_capture != null and _key_capture.visible:
		return true
	# ...and an open list or colour picker (see playback_started).
	if not _open_popups().is_empty():
		return true
	return _image_preview != null and _image_preview.visible


## Every popup of the builder that is open (a dropdown's list, a colour
## picker, the Add action menu).
func _open_popups() -> Array:
	var open: Array = []
	for p in find_children("*", "Popup", true, false):
		if (p as Window).visible:
			open.append(p)
	return open


func _is_editing_text() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit or f is TextEdit or f is SpinBox


func _input(event: InputEvent) -> void:
	# While picking on screen the pick window is unfocusable, so its Esc
	# arrives here. No other hotkey should fire mid-pick, and no key (its
	# repeats neither) reaches the builder - an arrow key would move the
	# action list's selection away from the action the pick is for; nor
	# while a sample is being read.
	if (_pick_active or _sample_pending) and event is InputEventKey:
		if _pick_active and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
			picker.cancel_pick()
		get_viewport().set_input_as_handled()
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return


	# While recording, this window's F8 and Esc end it (the helper leaves
	# out keys that land on Loop Automator itself, unless ~Self; an Esc
	# recorded that way is trimmed). Nothing else here should fire meanwhile.
	if _recording:
		if event.keycode == KEY_F8 or event.keycode == KEY_ESCAPE:
			_stop_recording("", event.keycode == KEY_ESCAPE)
			get_viewport().set_input_as_handled()
		return

	if _stop_cooldown_active and not Playback.is_running:
		return

	# Global controls that should always work.
	match event.keycode:
		KEY_F5:
			# As the Run button: the same checks before a start.
			_on_play_pressed()
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


## The width `btn` needs to show the widest of `samples` in full: the
## text, its icon (if any) with the gap after it, and the button's margins.
func _button_width(btn: Button, samples: Array[String]) -> float:
	var font := btn.get_theme_font("font")
	var size := btn.get_theme_font_size("font_size")
	var text_w := 0.0
	for s in samples:
		text_w = maxf(text_w, font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
	var icon_w := 0.0
	if btn.icon != null:
		icon_w = btn.icon.get_width() + btn.get_theme_constant("h_separation")
	var margins := btn.get_theme_stylebox("normal").get_minimum_size().x
	return ceilf(text_w + icon_w + margins)


## The width `sp` needs to show `sample` (the number and its suffix) in
## full: the text, the field's margins and the up / down buttons beside it,
## plus a little slack so the text never scrolls under the caret.
func _spin_box_width(sp: SpinBox, sample: String) -> float:
	var le := sp.get_line_edit()
	var font := le.get_theme_font("font")
	var text_w := font.get_string_size(sample, HORIZONTAL_ALIGNMENT_LEFT, -1, le.get_theme_font_size("font_size")).x
	var margins := le.get_theme_stylebox("normal").get_minimum_size().x
	var buttons := sp.get_theme_constant("buttons_width") + sp.get_theme_constant("field_and_buttons_separation")
	return ceilf(text_w + margins + buttons + 4.0)


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
