extends Control
class_name OverlayCanvas
## Draws the visual representation of the loop on the transparent overlay:
## pixel-detection rects, click/move points, drag arrows, ordered paths, and
## a highlight on the action currently being executed.

## Preload model scripts so this resolves even when loaded early (overlay.tscn
## is preloaded by main.gd), before the global `class_name` registry is ready.
const LoopProjectT := preload("res://scripts/model/loop_project.gd")
const LoopLayerT := preload("res://scripts/model/loop_layer.gd")
const LoopActionT := preload("res://scripts/model/loop_action.gd")
const CaptureHoleShader := preload("res://scripts/capture_hole.gdshader")

## Short status shown in the HUD (e.g. whether click-through is active).
var hud_note: String = ""
var _tracker_trail: Array[Vector2i] = []
const TRACKER_TRAIL_MAX := 24

## Screen position of the mouse as of the last frame, for follow-cursor Pixel
## Detect rects. `_follows_mouse` is true while any such rect exists, and is
## what keeps _process polling the mouse.
var _mouse: Vector2i = Vector2i.ZERO
var _follows_mouse: bool = false

var _font: Font


func _ready() -> void:
	# Anchor to the top-left and size the canvas explicitly (the overlay sets the
	# size to the screen). Using FULL_RECT here is unreliable for a Control that
	# is a direct child of a native Window, and can collapse to a tiny size.
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	position = Vector2.ZERO
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font
	# The detect rect playback is about to read is left transparent, so
	# it reads the desktop there rather than our guides (see
	# capture_hole.gdshader and _update_capture_holes).
	material = ShaderMaterial.new()
	material.shader = CaptureHoleShader
	ProjectData.layers_changed.connect(_redraw)
	ProjectData.actions_changed.connect(func(_i): _redraw())
	ProjectData.action_modified.connect(func(_a, _b): _redraw())
	ProjectData.selection_changed.connect(_redraw)
	ProjectData.overlay_view_changed.connect(_redraw)
	ProjectData.project_replaced.connect(_redraw)
	Playback.action_executing.connect(func(_l, _a): _redraw())
	Playback.tracker_changed.connect(_on_tracker_changed)


func _redraw() -> void:
	queue_redraw()


func _process(_dt: float) -> void:
	# Follow-cursor rects move with the mouse, so redraw whenever it moves.
	if not _follows_mouse or not is_visible_in_tree():
		return
	var p := DisplayServer.mouse_get_position()
	if p != _mouse:
		_mouse = p
		queue_redraw()


func _screen_offset() -> Vector2:
	var w := get_window()
	return Vector2(w.position) if w != null else Vector2.ZERO


func _draw() -> void:
	var project := ProjectData.project
	if project == null:
		return
	var offset := _screen_offset()
	_mouse = DisplayServer.mouse_get_position()
	_claimed.clear()
	_update_capture_holes(project, offset)

	# Editor-style viewport chrome (grid, axes, rulers) underneath everything.
	# No full-screen tint: the desktop must stay readable through the overlay.
	_draw_editor_grid(offset)

	var indices: Array[int] = []
	if ProjectData.overlay_show_all:
		for i in project.layers.size():
			if project.layers[i].visible:
				indices.append(i)
	else:
		var idx := clampi(ProjectData.overlay_layer_index, 0, project.layers.size() - 1)
		if project.layers[idx].visible:
			indices.append(idx)

	for li in indices:
		_draw_layer(li, project.layers[li], offset)

	_draw_tracker_trail(offset)
	_draw_execution_tracker(offset)

	_draw_hud(project, offset)


# --------------------------------------------------------- editor viewport
## Draws a 3D/2D-editor-style viewport: a minor/major grid in screen space
## and rulers with coordinate ticks along the top and left edges. Spacing is
## in screen pixels so coordinates read true.
const GRID_MINOR := 50
const GRID_MAJOR := 250
const RULER := 22.0

func _draw_editor_grid(offset: Vector2) -> void:
	var w := size.x
	var h := size.y

	var minor := Color(1, 1, 1, 0.10)
	var major := Color(1, 1, 1, 0.22)

	# Vertical lines (screen x). offset.x is the overlay's screen X origin.
	var start_x := int(floor(offset.x / GRID_MINOR) * GRID_MINOR)
	var gx := start_x
	while float(gx) - offset.x <= w:
		var lx := float(gx) - offset.x
		if lx >= 0.0:
			var is_major := (gx % GRID_MAJOR) == 0
			draw_line(Vector2(lx, RULER), Vector2(lx, h), major if is_major else minor, 1.0)
		gx += GRID_MINOR

	# Horizontal lines (screen y).
	var start_y := int(floor(offset.y / GRID_MINOR) * GRID_MINOR)
	var gy := start_y
	while float(gy) - offset.y <= h:
		var ly := float(gy) - offset.y
		if ly >= 0.0:
			var is_major := (gy % GRID_MAJOR) == 0
			draw_line(Vector2(RULER, ly), Vector2(w, ly), major if is_major else minor, 1.0)
		gy += GRID_MINOR

	_draw_rulers(offset)

	# Viewport border.
	draw_rect(Rect2(Vector2(RULER, RULER), Vector2(w - RULER, h - RULER)), Color(1, 1, 1, 0.18), false, 1.0)


func _draw_rulers(offset: Vector2) -> void:
	var w := size.x
	var h := size.y
	var bg := Color(0, 0, 0, 0.45)
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, RULER)), bg, true)        # top
	draw_rect(Rect2(Vector2.ZERO, Vector2(RULER, h)), bg, true)        # left
	draw_rect(Rect2(Vector2.ZERO, Vector2(RULER, RULER)), Color(0, 0, 0, 0.6), true)  # corner

	var tick := Color(1, 1, 1, 0.5)

	# Top ruler: labelled at majors, ticks at minors.
	var sx := int(floor(offset.x / GRID_MINOR) * GRID_MINOR)
	var gx := sx
	while float(gx) - offset.x <= w:
		var lx := float(gx) - offset.x
		if lx >= RULER:
			var is_major := (gx % GRID_MAJOR) == 0
			var tlen := 8.0 if is_major else 4.0
			draw_line(Vector2(lx, RULER - tlen), Vector2(lx, RULER), tick, 1.0)
			if is_major:
				_label(Vector2(lx + 2, 14), str(gx), Color(1, 1, 1, 0.8), 11)
		gx += GRID_MINOR

	# Left ruler.
	var sy := int(floor(offset.y / GRID_MINOR) * GRID_MINOR)
	var gy := sy
	while float(gy) - offset.y <= h:
		var ly := float(gy) - offset.y
		if ly >= RULER:
			var is_major := (gy % GRID_MAJOR) == 0
			var tlen := 8.0 if is_major else 4.0
			draw_line(Vector2(RULER - tlen, ly), Vector2(RULER, ly), tick, 1.0)
			if is_major:
				_label(Vector2(2, ly - 2), str(gy), Color(1, 1, 1, 0.8), 11)
		gy += GRID_MINOR


func _draw_layer(li: int, layer: LoopLayerT, offset: Vector2) -> void:
	var col: Color = layer.color
	var prev_point := Vector2(-1, -1)
	var has_prev := false  # a positioned action has been drawn (prev_point set)
	var last_anchor := Vector2(-1, -1)  # anchor for position-less actions (key/wait)
	var step := 0
	var tag_stack := 0  # stacked offset for consecutive position-less actions

	for ai in layer.actions.size():
		var action: LoopActionT = layer.actions[ai]
		if not action.enabled:
			continue
		var is_current := (Playback.current_layer_index == li and Playback.current_action_index == ai)
		var is_selected := (li == ProjectData.active_layer_index and ai == ProjectData.selected_action_index)
		var positioned := action.positioned()
		var p := action.overlay_point(_mouse)
		# Where the chips of the position-less actions that follow hang from.
		# A detect's inside is left clear so the target stays visible:
		# chips hang from its bottom-left corner, below the rect, not from its
		# top-left.
		var tag_anchor := p
		var detect_rect := Rect2i()
		if LoopActionT.is_detect(action.type):
			detect_rect = _detect_rect(action, li, ai)
			p = Vector2(detect_rect.position)
			tag_anchor = p + Vector2(0, detect_rect.size.y)
		var local := p - offset

		# Dashed path connecting ordered positioned points (execution order).
		if positioned and has_prev:
			var d := col
			d.a = 0.5
			draw_dashed_line(prev_point, local, d, 1.5, 6.0)

		# Per-type visual guide (a Click / Scroll with ~Move off has none: it
		# is a chip below). A point whose X / Y is a range is drawn at the
		# middle of the area it can land in, with that area boxed.
		match action.type if positioned else -1:
			LoopActionT.Type.PIXEL_DETECT, LoopActionT.Type.IMAGE_DETECT:
				_draw_detect_guide(action, _detect_rect(action, li, ai), offset, col, is_selected)
			LoopActionT.Type.MOVE:
				_draw_range_box(action.point_a_extent(), offset, col)
				_draw_move_guide(local, col, is_selected)
			LoopActionT.Type.CLICK:
				_draw_range_box(action.point_a_extent(), offset, col)
				_draw_click_guide(local, col, action.button, is_selected)
				# A hold / down / up says so beside the point.
				if action.press_mode != LoopActionT.PressMode.TAP:
					_draw_tag(local + Vector2(26, 4), col, action.press_text().to_upper(), false)
			LoopActionT.Type.SCROLL:
				_draw_range_box(action.point_a_extent(), offset, col)
				_draw_scroll_guide(local, col, action, is_selected)
			LoopActionT.Type.DRAG:
				var b_extent := action.point_b_extent()
				_draw_range_box(action.point_a_extent(), offset, col)
				_draw_range_box(b_extent, offset, col)
				_draw_drag_guide(local, Vector2(b_extent.get_center()) - offset, col, action.button, is_selected)

		if positioned:
			# Positioned action: ordered step badge + execution highlight. A
			# detect's badge sits above its top-left corner; with no room
			# above it goes below the rect, not inside it.
			step += 1
			var badge := local + Vector2(13, -13)
			if LoopActionT.is_detect(action.type) and badge.y - 9.0 < RULER + 2.0:
				badge.y = local.y + detect_rect.size.y + 13.0
			_draw_badge(badge, str(step), col)
			if is_current:
				draw_arc(local, 20, 0, TAU, 40, Color.WHITE, 2.5)
			prev_point = local
			has_prev = true
			last_anchor = tag_anchor - offset
			tag_stack = 0
		else:
			# Position-less action (key/wait/capture): a labelled chip anchored to the
			# last positioned action so it still reads in execution order.
			var anchor := last_anchor if has_prev else Vector2(40, 70)
			var tag_pos := anchor + Vector2(26, 18 + tag_stack * 24)
			tag_stack += 1
			var text := ""
			if action.type == LoopActionT.Type.KEY:
				var ktxt: String = action.keys if action.keys.length() <= 14 else action.keys.substr(0, 13) + "…"
				text = "KEY  " + ktxt
				if action.press_mode != LoopActionT.PressMode.TAP:
					text = "KEY %s  %s" % [action.press_text().to_upper(), ktxt]
			elif action.type == LoopActionT.Type.WAIT:
				text = "WAIT  %s ms" % LoopActionT.range_text(action.wait_ms, action.wait_ms_max)
			elif action.type == LoopActionT.Type.CLICK:
				# ~Move off: a press wherever the cursor is at the time.
				var press := action.press_text().to_upper()
				text = "%s %s  AT CURSOR" % [LoopActionT.button_name(action.button).to_upper(), press if not press.is_empty() else "CLICK"]
			elif action.type == LoopActionT.Type.SCROLL:
				text = "SCROLL %s ×%s  AT CURSOR" % [LoopActionT.scroll_dir_name(action.scroll_dir).to_upper(), LoopActionT.range_text(action.notches, action.notches_max)]
			elif action.type == LoopActionT.Type.CAPTURE:
				text = "CAPTURE  " + ["SAVE", "LOAD", "DETECT"][clampi(action.capture_mode, 0, 2)]
			elif action.type == LoopActionT.Type.STOP:
				text = ("STOP LOOP" if action.stop_scope == LoopActionT.StopScope.LOOP else "STOP LAYER")
				# While running, show which pass it is on out of its limit;
				# otherwise just the limit (nothing for a plain pass-1 stop).
				if Playback.is_running:
					text += "  pass %d/%d" % [Playback.stop_pass_count(action), maxi(1, action.stop_after)]
				elif action.stop_after > 1:
					text += "  pass %d" % action.stop_after
			# The chip may be moved to stay on screen; the link follows it.
			var chip := _draw_tag(tag_pos, col, text, is_selected)
			var link := col
			link.a = 0.35
			draw_line(anchor, chip.position + Vector2(0, 10), link, 1.0)
			if is_current:
				draw_arc(chip.position + Vector2(8, 10), 16, 0, TAU, 28, Color.WHITE, 2.5)


# ------------------------------------------------------------- guide helpers
## A white halo placed around a marker to show it is the selected action.
func _selection_ring(center: Vector2, radius: float) -> void:
	draw_arc(center, radius, 0, TAU, 40, Color(1, 1, 1, 0.95), 1.5)
	draw_arc(center, radius + 3.0, 0, TAU, 40, Color(1, 1, 1, 0.3), 1.0)


## The area a point with an X / Y range can land in: a faint fill with a
## dashed outline. Nothing is drawn for a fixed point (a 1×1 extent).
func _draw_range_box(extent: Rect2i, offset: Vector2, col: Color) -> void:
	if extent.size.x <= 1 and extent.size.y <= 1:
		return
	var rect := Rect2(Vector2(extent.position) - offset, Vector2(extent.size))
	var fill := col
	fill.a = 0.12
	draw_rect(rect, fill, true)
	var line := col
	line.a = 0.7
	var tl := rect.position
	var tr := rect.position + Vector2(rect.size.x, 0)
	var bl := rect.position + Vector2(0, rect.size.y)
	var br := rect.end
	draw_dashed_line(tl, tr, line, 1.0, 4.0)
	draw_dashed_line(tr, br, line, 1.0, 4.0)
	draw_dashed_line(br, bl, line, 1.0, 4.0)
	draw_dashed_line(bl, tl, line, 1.0, 4.0)


## PIXEL_DETECT / IMAGE_DETECT: frame the rect with an outline and corner
## ticks, with the expected colour swatch (or a thumbnail of the image) and a
## size/tolerance label above it. Everything sits *outside* the rect, so the
## target inside stays visible (and, while playback reads it, the inside is
## cut out altogether: see _update_capture_holes). With ranges the framed
## rect is the extent every possible rect lies in.
func _draw_detect_guide(action: LoopActionT, screen_rect: Rect2i, offset: Vector2, col: Color, selected: bool) -> void:
	var rect := Rect2(Vector2(screen_rect.position) - offset, Vector2(screen_rect.size))
	var frame := rect.grow(1.5)
	draw_rect(frame, col, false, 2.0)
	_draw_corner_ticks(rect.grow(3.0), col)
	# Expected colour swatch + label on a strip above the rect, to the right of
	# the step badge that sits at the top-left corner. With no room above (the
	# rect at the top of the screen) the strip goes below the rect instead.
	var is_image := action.type == LoopActionT.Type.IMAGE_DETECT
	var text := "%s  %s×%s  ±%s" % ["image" if is_image else "detect",
		LoopActionT.range_text(action.w, action.w_max), LoopActionT.range_text(action.h, action.h_max),
		LoopActionT.range_text(action.tolerance, action.tolerance_max)]
	if action.follow_cursor:
		text += "  · cursor"
	text += action.detect_suffix().replace(" · ", "  · ")
	if is_image and action.ignore_colour:
		text += "  · ignore colour"
	if is_image and maxi(action.mismatch, action.mismatch_max) > 0:
		text += "  · %s%% off" % LoopActionT.range_text(action.mismatch, action.mismatch_max)
	var strip_w := 20.0 + (_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x if _font != null else 120.0)
	var top := rect.position + Vector2(28, -22)
	if top.y < RULER + 2.0:
		top.y = rect.end.y + 8.0
	# Clear of the step badge, which is pushed right of the ruler at the edge.
	top.x = maxf(top.x, RULER + 26.0)
	top = _claim(Rect2(top, Vector2(strip_w, 16))).position
	var swatch := Rect2(top, Vector2(16, 16))
	var thumb := action.image_texture() if is_image else null
	if thumb != null:
		# The image, shrunk to fit the swatch (its shape kept) on a dark pad.
		draw_rect(swatch, Color(0, 0, 0, 0.6), true)
		var fit := 16.0 / maxf(thumb.get_width(), thumb.get_height())
		var size := Vector2(thumb.get_size()) * minf(fit, 1.0)
		draw_texture_rect(thumb, Rect2(top + (Vector2(16, 16) - size) / 2.0, size), false)
	else:
		# No image yet: an empty box, in the layer colour.
		draw_rect(swatch, action.color if not is_image else Color(col, 0.35), true)
	draw_rect(swatch, Color.BLACK, false, 1.0)
	_label(top + Vector2(20, 12), text, col)
	if selected:
		draw_rect(rect.grow(6.0), Color(1, 1, 1, 0.95), false, 1.5)


## Draw L-shaped ticks at each corner so the rect extents are unmistakable.
func _draw_corner_ticks(rect: Rect2, col: Color, length: float = 12.0) -> void:
	var p := rect.position
	var s := rect.size
	var tl := p
	var tr := p + Vector2(s.x, 0)
	var bl := p + Vector2(0, s.y)
	var br := p + s
	draw_line(tl, tl + Vector2(length, 0), col, 2.5)
	draw_line(tl, tl + Vector2(0, length), col, 2.5)
	draw_line(tr, tr - Vector2(length, 0), col, 2.5)
	draw_line(tr, tr + Vector2(0, length), col, 2.5)
	draw_line(bl, bl + Vector2(length, 0), col, 2.5)
	draw_line(bl, bl - Vector2(0, length), col, 2.5)
	draw_line(br, br - Vector2(length, 0), col, 2.5)
	draw_line(br, br - Vector2(0, length), col, 2.5)


## MOVE: a crosshair with a hollow diamond (a target with no click).
func _draw_move_guide(p: Vector2, col: Color, selected: bool) -> void:
	draw_line(p - Vector2(11, 0), p + Vector2(11, 0), col, 2.0)
	draw_line(p - Vector2(0, 11), p + Vector2(0, 11), col, 2.0)
	var diamond := PackedVector2Array([
		p + Vector2(0, -7), p + Vector2(7, 0), p + Vector2(0, 7), p + Vector2(-7, 0), p + Vector2(0, -7)
	])
	draw_polyline(diamond, col, 2.0)
	if selected:
		_selection_ring(p, 16.0)


## CLICK: concentric ripple rings + a solid centre dot + a button-letter chip.
func _draw_click_guide(p: Vector2, col: Color, button: int, selected: bool) -> void:
	draw_arc(p, 6.0, 0, TAU, 24, col, 2.0)
	var r2 := col
	r2.a = 0.5
	draw_arc(p, 11.0, 0, TAU, 28, r2, 1.5)
	var r3 := col
	r3.a = 0.25
	draw_arc(p, 16.0, 0, TAU, 32, r3, 1.0)
	draw_circle(p, 3.5, col)
	# Button chip (first letter of Left/Right/Middle), below-right of the point.
	_draw_badge(p + Vector2(13, 13), LoopActionT.button_name(button).substr(0, 1), col)
	if selected:
		_selection_ring(p, 20.0)


## SCROLL: a wheel (a ring with a notch) and an arrow the way it turns, with
## the notch count on a chip.
func _draw_scroll_guide(p: Vector2, col: Color, action: LoopActionT, selected: bool) -> void:
	draw_arc(p, 7.0, 0, TAU, 24, col, 2.0)
	draw_line(p + Vector2(0, -3), p + Vector2(0, 3), col, 2.0)
	var dir := Vector2.DOWN
	match action.scroll_dir:
		LoopActionT.ScrollDir.UP: dir = Vector2.UP
		LoopActionT.ScrollDir.LEFT: dir = Vector2.LEFT
		LoopActionT.ScrollDir.RIGHT: dir = Vector2.RIGHT
	var from := p + dir * 11.0
	var to := p + dir * 26.0
	draw_line(from, to, col, 2.0)
	_draw_arrow_head(from, to, col)
	_draw_tag(p + Vector2(14, 10), col, "×" + LoopActionT.range_text(action.notches, action.notches_max), false)
	if selected:
		_selection_ring(p, 20.0)


## DRAG: solid arrow from start→end, hollow start node, filled end node.
func _draw_drag_guide(a: Vector2, b: Vector2, col: Color, button: int, selected: bool) -> void:
	draw_line(a, b, col, 2.5)
	_draw_arrow_head(a, b, col)
	draw_circle(a, 5.0, Color(col.r, col.g, col.b, 0.45))
	draw_arc(a, 6.0, 0, TAU, 20, col, 2.0)
	draw_circle(b, 4.0, col)
	var drag_text := "%s drag" % LoopActionT.button_name(button)
	_label(_fit_label((a + b) * 0.5 + Vector2(6, -6), drag_text), drag_text, col)
	if selected:
		_selection_ring(a, 16.0)
		_selection_ring(b, 14.0)


## A small dark chip with a coloured outline, used for KEY / WAIT actions,
## at `pos` or as near it as the screen allows. Returns where it was drawn.
func _draw_tag(pos: Vector2, col: Color, text: String, selected: bool) -> Rect2:
	var tw := 16.0
	if _font != null:
		tw = _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x + 20.0
	var rect := _claim(Rect2(pos, Vector2(tw, 20.0)))
	pos = rect.position
	draw_rect(rect, Color(0, 0, 0, 0.72), true)
	draw_rect(rect, col, false, 1.5)
	draw_circle(pos + Vector2(9, 10), 3.0, col)
	_label(pos + Vector2(16, 14), text, Color.WHITE, 13)
	if selected:
		draw_rect(rect.grow(2.0), Color(1, 1, 1, 0.95), false, 1.0)
	return rect


func _draw_arrow_head(from: Vector2, to: Vector2, col: Color) -> void:
	var dir := (to - from)
	if dir.length() < 0.01:
		return
	dir = dir.normalized()
	var left := dir.rotated(deg_to_rad(150)) * 12.0
	var right := dir.rotated(deg_to_rad(-150)) * 12.0
	draw_line(to, to + left, col, 2.0)
	draw_line(to, to + right, col, 2.0)


func _draw_badge(pos: Vector2, text: String, col: Color) -> void:
	pos = _claim(Rect2(pos - Vector2(9, 9), Vector2(18, 18))).get_center()
	draw_circle(pos, 9, Color(0, 0, 0, 0.65))
	draw_arc(pos, 9, 0, TAU, 20, col, 1.5)
	_label(pos - Vector2(text.length() * 3.0, -4), text, Color.WHITE, 12)


## Markers sit exactly where their action is; what is written next to them
## (a step number, a chip, a label) is moved just enough to stay on screen
## when the action is near an edge: `rect` (canvas coordinates) pushed
## inside the canvas, clear of the rulers.
func _fit(rect: Rect2) -> Rect2:
	var lo := Vector2(RULER + 2.0, RULER + 2.0)
	var hi := size - rect.size - Vector2(2.0, 2.0)
	rect.position = Vector2(clampf(rect.position.x, lo.x, maxf(lo.x, hi.x)), clampf(rect.position.y, lo.y, maxf(lo.y, hi.y)))
	return rect


## What has been written on this frame so far (badges, chips, strips), so
## steps that share a spot do not write over one another.
var _claimed: Array[Rect2] = []
## Where a label is tried next when its place is taken: right, below, and
## on outwards, a little further each time.
const CLAIM_STEPS: Array[Vector2] = [
	Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1), Vector2(2, 0), Vector2(0, 2),
	Vector2(2, 1), Vector2(1, 2), Vector2(2, 2), Vector2(3, 0), Vector2(0, 3), Vector2(3, 1),
	Vector2(1, 3), Vector2(3, 2), Vector2(2, 3), Vector2(3, 3),
]


## `rect` fitted on screen (see _fit) and moved off anything written
## earlier this frame; claims the place it ends up at. Fresh from _draw.
func _claim(rect: Rect2) -> Rect2:
	var step := rect.size + Vector2(4.0, 4.0)
	var placed := _fit(rect)
	for offset in CLAIM_STEPS:
		var candidate := _fit(Rect2(rect.position + offset * step, rect.size))
		var free := true
		for taken in _claimed:
			if candidate.intersects(taken):
				free = false
				break
		if free:
			placed = candidate
			break
	_claimed.append(placed)
	return placed


## The baseline position for `text` so that it stays on screen (see _fit).
func _fit_label(pos: Vector2, text: String, font_size: int = 13) -> Vector2:
	if _font == null:
		return pos
	var extent := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var ascent := _font.get_ascent(font_size)
	return _fit(Rect2(pos - Vector2(0, ascent), extent)).position + Vector2(0, ascent)


func _label(pos: Vector2, text: String, col: Color, size: int = 13) -> void:
	if _font == null:
		return
	# Cheap shadow for legibility over any background.
	draw_string(_font, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.8))
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _draw_hud(project: LoopProjectT, _offset: Vector2) -> void:
	var lines: Array[String] = []
	var view := "all visible layers"
	if not ProjectData.overlay_show_all:
		var idx := clampi(ProjectData.overlay_layer_index, 0, project.layers.size() - 1)
		view = "layer %d/%d: %s" % [idx + 1, project.layers.size(), project.layers[idx].name]
	if hud_note.is_empty():
		lines.append("OVERLAY · %s" % view)
	else:
		lines.append("OVERLAY · %s · %s" % [view, hud_note])
	if Playback.is_running:
		lines.append("● RUNNING")
		if Playback.tracker_visible:
			lines.append("tracker  (%d, %d)  %s" % [Playback.tracker_pos.x, Playback.tracker_pos.y, Playback.tracker_label])
	var y := 14.0
	for l in lines:
		_label(Vector2(14, y), l, Color.WHITE, 16)
		y += 22.0


func _on_tracker_changed(pos: Vector2i, visible: bool, _label_text: String) -> void:
	if not visible:
		_tracker_trail.clear()
		queue_redraw()
		return
	if _tracker_trail.is_empty() or _tracker_trail[_tracker_trail.size() - 1] != pos:
		_tracker_trail.append(pos)
		if _tracker_trail.size() > TRACKER_TRAIL_MAX:
			_tracker_trail.pop_front()
	queue_redraw()


func _draw_tracker_trail(offset: Vector2) -> void:
	if _tracker_trail.size() < 2:
		return
	var points := PackedVector2Array()
	for p in _tracker_trail:
		points.append(Vector2(p) - offset)
	draw_polyline(points, Color(0.1, 0.95, 1.0, 0.45), 2.0)
	for i in _tracker_trail.size():
		var lp := Vector2(_tracker_trail[i]) - offset
		var alpha := 0.12 + 0.6 * (float(i + 1) / float(_tracker_trail.size()))
		draw_circle(lp, 2.0, Color(0.1, 0.95, 1.0, alpha))


func _draw_execution_tracker(offset: Vector2) -> void:
	if not Playback.is_running or not Playback.tracker_visible:
		return
	var p := Vector2(Playback.tracker_pos) - offset
	if p.x < -20.0 or p.y < -20.0 or p.x > size.x + 20.0 or p.y > size.y + 20.0:
		return
	var col := Color(0.1, 0.95, 1.0, 1.0)
	# Tracker head: bright point + rings so it's readable over any scene.
	draw_circle(p, 5.0, col)
	draw_arc(p, 11.0, 0, TAU, 32, Color(col.r, col.g, col.b, 0.8), 2.0)
	draw_arc(p, 17.0, 0, TAU, 32, Color(col.r, col.g, col.b, 0.35), 1.0)
	# Crosshair lines reinforce exact position while running in preview mode.
	draw_line(Vector2(p.x - 16.0, p.y), Vector2(p.x + 16.0, p.y), Color(col.r, col.g, col.b, 0.65), 1.5)
	draw_line(Vector2(p.x, p.y - 16.0), Vector2(p.x, p.y + 16.0), Color(col.r, col.g, col.b, 0.65), 1.5)
	_label(p + Vector2(12, -10), "tracker (%d, %d)" % [Playback.tracker_pos.x, Playback.tracker_pos.y], Color(0.85, 1.0, 1.0, 1.0), 14)


# ------------------------------------------------------------ capture holes
## A detect action is checked anywhere inside its rect (see
## PlaybackEngine._find_color / _find_image). While playback has a rect pinned for a read
## (the one frame before it reads the screen) that rect is cut out of the
## overlay by the shader, so nothing drawn here — other guides, the grid,
## the tracker — can tint the read. The rest of the time nothing is cut:
## the inside of a rect is left undecorated so the target stays visible,
## but a step that happens to lie inside another action's rect still shows.
func _update_capture_holes(project: LoopProjectT, offset: Vector2) -> void:
	var rects := PackedVector4Array()
	if Playback.detect_rect_pinned:
		var r := Playback.detect_rect
		rects.append(Vector4(r.position.x - offset.x, r.position.y - offset.y, r.size.x, r.size.y))
	material.set_shader_parameter("rect_count", rects.size())
	material.set_shader_parameter("rects", rects)
	# Follow-cursor rects move with the mouse: keep _process watching it.
	_follows_mouse = false
	for layer in project.layers:
		for a in layer.actions:
			if LoopActionT.is_detect(a.type) and a.enabled and a.follow_cursor:
				_follows_mouse = true
				return


## The screen rect a detect is drawn at. While
## playback is reading the action at (li, ai) it is the rect pinned for that
## read (see PlaybackEngine.detect_rect); otherwise it is the extent of every
## rect the ranges allow, following the mouse or at the stored position.
func _detect_rect(a: LoopActionT, li: int, ai: int) -> Rect2i:
	if Playback.detect_rect_pinned and Playback.current_layer_index == li and Playback.current_action_index == ai:
		return Playback.detect_rect
	return a.detect_extent(_mouse)
