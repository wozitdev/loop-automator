extends Window
class_name KeyCapture
## An on-screen keyboard that captures keystrokes for a Key action and turns
## them into Windows SendKeys text: type on the real keyboard while this
## window has the focus, or click the keys. Letters, digits and punctuation
## become themselves (SendKeys' own special characters escaped in braces),
## named keys become their {CODE}, and Ctrl / Alt / Shift / Win become the
## ^ % + $ prefixes ($ is a name of ours: the helper presses Win, SendKeys
## has none). The on-screen modifiers are sticky: press one, then the key
## it applies to. The physical Win key is ignored, since Windows opens
## Start on it and takes the focus away.
##
## Nothing reaches the Keys field until Send is pressed: the window keeps
## its own copy of the text (the field's text when it was opened plus what
## was captured since) and hands it over as `sent(text)`. Cancel, or
## closing the window, drops it.

signal sent(text: String)

## SendKeys reserves these (and $ is our Win prefix); each is sent literally as {c}.
const ESCAPED := "+^%~(){}[]$"

## Godot keycode -> SendKeys code for keys that are not printable characters.
const NAMED := {
	KEY_ENTER: "{ENTER}", KEY_KP_ENTER: "{ENTER}", KEY_TAB: "{TAB}", KEY_ESCAPE: "{ESC}",
	KEY_BACKSPACE: "{BACKSPACE}", KEY_DELETE: "{DELETE}", KEY_INSERT: "{INSERT}",
	KEY_HOME: "{HOME}", KEY_END: "{END}", KEY_PAGEUP: "{PGUP}", KEY_PAGEDOWN: "{PGDN}",
	KEY_UP: "{UP}", KEY_DOWN: "{DOWN}", KEY_LEFT: "{LEFT}", KEY_RIGHT: "{RIGHT}",
	KEY_F1: "{F1}", KEY_F2: "{F2}", KEY_F3: "{F3}", KEY_F4: "{F4}", KEY_F5: "{F5}", KEY_F6: "{F6}",
	KEY_F7: "{F7}", KEY_F8: "{F8}", KEY_F9: "{F9}", KEY_F10: "{F10}", KEY_F11: "{F11}", KEY_F12: "{F12}",
	KEY_F13: "{F13}", KEY_F14: "{F14}", KEY_F15: "{F15}", KEY_F16: "{F16}",
	KEY_CAPSLOCK: "{CAPSLOCK}", KEY_NUMLOCK: "{NUMLOCK}", KEY_SCROLLLOCK: "{SCROLLLOCK}",
	KEY_PRINT: "{PRTSC}", KEY_PAUSE: "{BREAK}", KEY_HELP: "{HELP}",
	KEY_KP_ADD: "{ADD}", KEY_KP_SUBTRACT: "{SUBTRACT}", KEY_KP_MULTIPLY: "{MULTIPLY}", KEY_KP_DIVIDE: "{DIVIDE}",
	KEY_SPACE: " ",
}

## The on-screen layout: rows of [label, keycode] (the keycode gives the
## SendKeys text via token_for and lets a typed key light its button up);
## ["", units] is a gap that wide. Every row of the main block adds up to
## MAIN_UNITS key units, so the keys line up and the whole board scales
## with the window: keys stretch in proportion to their width in units.
## The modifier keys are handled by name.
const MAIN_UNITS := 15.0
const MAIN_ROWS := [
	[["Esc", KEY_ESCAPE], ["", 1.0], ["F1", KEY_F1], ["F2", KEY_F2], ["F3", KEY_F3], ["F4", KEY_F4], ["", 0.5], ["F5", KEY_F5], ["F6", KEY_F6], ["F7", KEY_F7], ["F8", KEY_F8], ["", 0.5], ["F9", KEY_F9], ["F10", KEY_F10], ["F11", KEY_F11], ["F12", KEY_F12]],
	[["`", KEY_QUOTELEFT], ["1", KEY_1], ["2", KEY_2], ["3", KEY_3], ["4", KEY_4], ["5", KEY_5], ["6", KEY_6], ["7", KEY_7], ["8", KEY_8], ["9", KEY_9], ["0", KEY_0], ["-", KEY_MINUS], ["=", KEY_EQUAL], ["Backspace", KEY_BACKSPACE]],
	[["Tab", KEY_TAB], ["q", KEY_Q], ["w", KEY_W], ["e", KEY_E], ["r", KEY_R], ["t", KEY_T], ["y", KEY_Y], ["u", KEY_U], ["i", KEY_I], ["o", KEY_O], ["p", KEY_P], ["[", KEY_BRACKETLEFT], ["]", KEY_BRACKETRIGHT], ["\\", KEY_BACKSLASH]],
	[["Caps", KEY_CAPSLOCK], ["a", KEY_A], ["s", KEY_S], ["d", KEY_D], ["f", KEY_F], ["g", KEY_G], ["h", KEY_H], ["j", KEY_J], ["k", KEY_K], ["l", KEY_L], [";", KEY_SEMICOLON], ["'", KEY_APOSTROPHE], ["Enter", KEY_ENTER]],
	[["Shift", KEY_SHIFT], ["z", KEY_Z], ["x", KEY_X], ["c", KEY_C], ["v", KEY_V], ["b", KEY_B], ["n", KEY_N], ["m", KEY_M], [",", KEY_COMMA], [".", KEY_PERIOD], ["/", KEY_SLASH], ["Shift", KEY_SHIFT]],
	[["Ctrl", KEY_CTRL], ["Win", KEY_META], ["Alt", KEY_ALT], ["Space", KEY_SPACE], ["Alt", KEY_ALT], ["Ctrl", KEY_CTRL]],
]
## The navigation block: six rows like the main block, so its keys are the
## same height. Ins / Del sit level with the number and Tab rows, and the
## arrow cluster is at the bottom, level with Shift and Ctrl - where the
## hand expects it. Its keys are NAV_KEY units wide (a little wider than a
## letter key: the labels are longer).
const NAV_KEY := 1.25
const NAV_UNITS := 3.0 * NAV_KEY
const NAV_ROWS := [
	[["", 3.0]],
	[["Ins", KEY_INSERT], ["Home", KEY_HOME], ["PgUp", KEY_PAGEUP]],
	[["Del", KEY_DELETE], ["End", KEY_END], ["PgDn", KEY_PAGEDOWN]],
	[["", 3.0]],
	[["", 1.0], ["↑", KEY_UP], ["", 1.0]],
	[["←", KEY_LEFT], ["↓", KEY_DOWN], ["→", KEY_RIGHT]],
]
## Widths in key units for the wide keys (default 1).
const WIDE := {"Backspace": 2.0, "Tab": 1.5, "\\": 1.5, "Caps": 1.75, "Enter": 2.25, "Shift": 2.5, "Ctrl": 1.5, "Win": 1.5, "Alt": 1.5, "Space": 7.5}
## Smallest key size (one unit); the board grows from there with the window.
const MIN_UNIT := 24.0
const GAP := 5.0
## Default and smallest window sizes; the size chosen by resizing is kept.
const DEFAULT_SIZE := Vector2i(980, 440)
const SMALLEST_SIZE := Vector2i(760, 360)

## Key-cap colours: plain keys, the named / editing keys, and the sticky
## modifiers (which turn the accent colour while they are held).
const CAP_PLAIN := Color("3b414b")
const CAP_SPECIAL := Color("2f343c")
const CAP_MOD := Color("34405a")
const CAP_ACCENT := Color("3d7bd9")
const CAP_EDGE := Color("1b1e24")
const BOARD_BG := Color("22252b")
const PREVIEW_BG := Color("15171b")

## A small keyboard glyph for the button that opens this window (rendered
## from SVG at runtime, so the project needs no imported image).
const ICON_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="20" height="14" viewBox="0 0 20 14">
<rect x="0.75" y="0.75" width="18.5" height="12.5" rx="2" fill="none" stroke="#e6e6e6" stroke-width="1.5"/>
<g fill="#e6e6e6"><rect x="3" y="3" width="2" height="2"/><rect x="6.5" y="3" width="2" height="2"/><rect x="10" y="3" width="2" height="2"/><rect x="13.5" y="3" width="2" height="2"/>
<rect x="3" y="6" width="2" height="2"/><rect x="6.5" y="6" width="2" height="2"/><rect x="10" y="6" width="2" height="2"/><rect x="13.5" y="6" width="2" height="2"/>
<rect x="5" y="9" width="10" height="2" rx="0.5"/></g></svg>"""

static var _icon: Texture2D


## The keyboard icon for the button that opens the capture window.
static func icon() -> Texture2D:
	if _icon == null:
		var img := Image.new()
		if img.load_svg_from_string(ICON_SVG, 1.0) == OK:
			_icon = ImageTexture.create_from_image(img)
	return _icon


## The SendKeys text for one key press. `shift` / `ctrl` / `alt` / `win` add
## the + ^ % $ prefixes; `unicode` (the typed character, if any) wins over the
## keycode for printable keys so the keyboard layout is respected.
static func token_for(keycode: int, unicode: int, shift: bool, ctrl: bool, alt: bool, win: bool = false) -> String:
	var base := ""
	var prefix := ""
	if keycode in NAMED:
		base = NAMED[keycode]
		if shift:
			prefix += "+"
	elif not ctrl and not alt and unicode >= 32 and unicode != 127:
		# A typed character: shift is already folded into it.
		base = _escape(char(unicode))
	elif keycode >= 32 and keycode < 127:
		# A key held with Ctrl / Alt (or clicked with a sticky modifier): the
		# unshifted character of that key, lower case.
		base = _escape(char(keycode).to_lower())
		if shift:
			prefix += "+"
	elif keycode >= KEY_KP_0 and keycode <= KEY_KP_9:
		base = str(keycode - KEY_KP_0)
		if shift:
			prefix += "+"
	elif keycode == KEY_KP_PERIOD:
		base = "."
	else:
		return ""  # a modifier on its own, or unknown
	if ctrl:
		prefix += "^"
	if alt:
		prefix += "%"
	if win:
		prefix += "$"
	return prefix + base


static func _escape(c: String) -> String:
	return "{" + c + "}" if c in ESCAPED else c


var _base := ""                   # the field's text when opened
var _tokens: Array[String] = []   # what was captured since, in order
var _sticky_shift := false
var _sticky_ctrl := false
var _sticky_alt := false
var _sticky_win := false
var _preview: LineEdit
var _count: Label
var _shift_buttons: Array[Button] = []
var _ctrl_buttons: Array[Button] = []
var _alt_buttons: Array[Button] = []
var _win_buttons: Array[Button] = []
var _key_buttons: Dictionary = {}  # keycode -> Array[Button]
var _all_keys: Array[Button] = []  # every key cap, for the font scaling


func _init() -> void:
	title = "Capture keys"
	transient = true
	exclusive = false
	unresizable = false
	min_size = SMALLEST_SIZE
	size = DEFAULT_SIZE
	visible = false
	close_requested.connect(hide)
	size_changed.connect(_on_size_changed)
	_build()
	_on_size_changed()


## Key labels grow and shrink with the window (a key is about a sixth of
## the board's height).
func _on_size_changed() -> void:
	var font := clampi(int(size.y * 0.036), 11, 26)
	for b in _all_keys:
		b.add_theme_font_size_override("font_size", font if b.text.length() == 1 else maxi(11, font - 2))


## Shows the keyboard for a field whose current text is `current`. The text
## is handed back through `sent` only when Send is pressed.
func open(current: String) -> void:
	_base = current
	_tokens.clear()
	_set_sticky(false, false, false, false)
	_refresh_preview()
	popup_centered()
	grab_focus()


func _input(event: InputEvent) -> void:
	# Physical keys while this window has the focus.
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	get_viewport().set_input_as_handled()
	if key.keycode in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:   # the physical Win key opens Start and takes the focus: the on-screen one is the way
		return
	var token := token_for(key.keycode, key.unicode, key.shift_pressed or _sticky_shift, key.ctrl_pressed or _sticky_ctrl, key.alt_pressed or _sticky_alt, key.meta_pressed or _sticky_win)
	if token.is_empty():
		return
	_flash(key.keycode)
	_append(token)


func _append(token: String) -> void:
	_tokens.append(token)
	_set_sticky(false, false, false, false)
	_refresh_preview()


func _text() -> String:
	return _base + "".join(_tokens)


func _refresh_preview() -> void:
	_preview.text = _text()
	_preview.caret_column = _preview.text.length()
	var n := _tokens.size()
	_count.text = "%d key%s captured" % [n, "" if n == 1 else "s"]


func _send() -> void:
	sent.emit(_text())
	hide()


# ------------------------------------------------------------------ layout
func _build() -> void:
	var back := PanelContainer.new()
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.add_theme_stylebox_override("panel", _flat(BOARD_BG, 0, Color.TRANSPARENT))
	add_child(back)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	back.add_child(margin)
	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	margin.add_child(root)

	# Preview of the text that Send will put in the field: one slim row.
	var preview_box := PanelContainer.new()
	preview_box.add_theme_stylebox_override("panel", _flat(PREVIEW_BG, 6, CAP_EDGE))
	var preview_margin := MarginContainer.new()
	for side in ["margin_left", "margin_right"]:
		preview_margin.add_theme_constant_override(side, 8)
	for side in ["margin_top", "margin_bottom"]:
		preview_margin.add_theme_constant_override(side, 2)
	preview_box.add_child(preview_margin)
	var preview_row := HBoxContainer.new()
	preview_row.add_theme_constant_override("separation", 8)
	preview_margin.add_child(preview_row)
	_preview = LineEdit.new()
	_preview.editable = false
	_preview.focus_mode = Control.FOCUS_NONE
	_preview.placeholder_text = "SendKeys text"
	_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview.add_theme_font_size_override("font_size", 15)
	_preview.add_theme_stylebox_override("normal", _flat(Color.TRANSPARENT, 0, Color.TRANSPARENT))
	_preview.add_theme_stylebox_override("read_only", _flat(Color.TRANSPARENT, 0, Color.TRANSPARENT))
	preview_row.add_child(_preview)
	# The top bar: the preview with the actions in line with it, to its
	# right, so both sit above the help text and the keys.
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	preview_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(preview_box)
	top.add_child(_action_button("Undo", "Remove the last captured key", CAP_SPECIAL, func():
		if _tokens.is_empty():
			return
		_tokens.pop_back()
		_refresh_preview()))
	top.add_child(_action_button("Clear", "Start from an empty field", CAP_SPECIAL, func():
		_base = ""
		_tokens.clear()
		_refresh_preview()))
	top.add_child(_action_button("Cancel", "Close without changing the field", CAP_SPECIAL, hide))
	top.add_child(_action_button("Send", "Put this text in the Keys field and close", CAP_ACCENT, _send))
	root.add_child(top)

	# The help line, between the preview and the keys, with the count of
	# captured keys at its end. One line, always (the help is trimmed rather
	# than wrapped if the window is narrower than it).
	var help_row := HBoxContainer.new()
	help_row.add_theme_constant_override("separation", 12)
	var hint := Label.new()
	hint.text = "Type or click the keys · on-screen Shift / Ctrl / Alt / Win stick to the next key · Send fills the field"
	hint.modulate = Color(1, 1, 1, 0.55)
	hint.add_theme_font_size_override("font_size", 12)
	hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	help_row.add_child(hint)
	_count = Label.new()
	_count.add_theme_font_size_override("font_size", 12)
	_count.modulate = Color(1, 1, 1, 0.55)
	help_row.add_child(_count)
	root.add_child(help_row)

	# The keys, filling whatever height is left.
	var keys := HBoxContainer.new()
	keys.add_theme_constant_override("separation", 18)
	keys.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var main_block := _block(MAIN_ROWS)
	main_block.size_flags_stretch_ratio = MAIN_UNITS
	keys.add_child(main_block)
	var nav_block := _block(NAV_ROWS, NAV_KEY)
	nav_block.size_flags_stretch_ratio = NAV_UNITS
	keys.add_child(nav_block)
	root.add_child(keys)


## A rounded, flat key-cap look with a darker bottom edge.
static func _cap(bg: Color) -> StyleBoxFlat:
	var sb := _flat(bg, 7, CAP_EDGE)
	sb.border_width_bottom = 3
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	return sb


static func _flat(bg: Color, radius: int, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.border_color = border
	return sb


static func _style_key(b: Button, bg: Color, pressed_bg: Color) -> void:
	b.add_theme_stylebox_override("normal", _cap(bg))
	b.add_theme_stylebox_override("hover", _cap(bg.lightened(0.12)))
	b.add_theme_stylebox_override("pressed", _cap(pressed_bg))
	b.add_theme_stylebox_override("hover_pressed", _cap(pressed_bg.lightened(0.1)))
	b.add_theme_stylebox_override("focus", _flat(Color.TRANSPARENT, 7, Color.TRANSPARENT))
	b.add_theme_stylebox_override("disabled", _cap(bg.darkened(0.3)))
	b.add_theme_color_override("font_color", Color(0.92, 0.93, 0.95))
	b.add_theme_color_override("font_hover_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)


func _action_button(text: String, tip: String, bg: Color, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	# As tall as the preview box next to it, so the top row reads as one bar.
	b.custom_minimum_size = Vector2(70, 0)
	b.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_style_key(b, bg, bg.lightened(0.2))
	b.pressed.connect(on_pressed)
	return b


## A block of key rows. Rows share the block's height equally, and within a
## row every key (and gap) takes its share of the width by units, so the
## block scales with the window while keys keep their proportions.
func _block(rows: Array, key_scale: float = 1.0) -> Control:
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", int(GAP))
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	for row in rows:
		var hb := HBoxContainer.new()
		hb.add_theme_constant_override("separation", int(GAP))
		hb.size_flags_vertical = Control.SIZE_EXPAND_FILL
		for key in row:
			var label: String = key[0]
			if label.is_empty():
				var gap := Control.new()
				_span(gap, float(key[1]) * key_scale)
				hb.add_child(gap)
				continue
			hb.add_child(_key_button(label, key[1], key_scale))
		vb.add_child(hb)
	return vb


## Sizes a key or gap to `units`: its share of the row, and a floor so the
## board cannot collapse below MIN_UNIT per unit.
static func _span(c: Control, units: float) -> void:
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	c.size_flags_stretch_ratio = units
	c.custom_minimum_size = Vector2(MIN_UNIT * units + GAP * (units - 1.0), MIN_UNIT)


func _key_button(label: String, keycode: int, key_scale: float = 1.0) -> Button:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_NONE
	b.clip_text = true
	_span(b, float(WIDE.get(label, 1.0)) * key_scale)
	_all_keys.append(b)
	var is_modifier := keycode in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]
	var is_special := label.length() > 1 or keycode in NAMED
	match keycode:
		KEY_SHIFT:
			b.toggle_mode = true
			b.tooltip_text = "Shift (+) for the next key"
			b.toggled.connect(func(on: bool): _set_sticky(on, _sticky_ctrl, _sticky_alt, _sticky_win))
			_shift_buttons.append(b)
		KEY_CTRL:
			b.toggle_mode = true
			b.tooltip_text = "Ctrl (^) for the next key"
			b.toggled.connect(func(on: bool): _set_sticky(_sticky_shift, on, _sticky_alt, _sticky_win))
			_ctrl_buttons.append(b)
		KEY_ALT:
			b.toggle_mode = true
			b.tooltip_text = "Alt (%) for the next key"
			b.toggled.connect(func(on: bool): _set_sticky(_sticky_shift, _sticky_ctrl, on, _sticky_win))
			_alt_buttons.append(b)
		KEY_META:
			b.toggle_mode = true
			b.tooltip_text = "Win ($) for the next key"
			b.toggled.connect(func(on: bool): _set_sticky(_sticky_shift, _sticky_ctrl, _sticky_alt, on))
			_win_buttons.append(b)
		_:
			var plain := token_for(keycode, 0, false, false, false)
			b.tooltip_text = "(space)" if plain == " " else plain
			b.pressed.connect(func():
				var token := token_for(keycode, 0, _sticky_shift, _sticky_ctrl, _sticky_alt, _sticky_win)
				if not token.is_empty():
					_append(token))
			if not _key_buttons.has(keycode):
				_key_buttons[keycode] = []
			_key_buttons[keycode].append(b)
	if is_modifier:
		_style_key(b, CAP_MOD, CAP_ACCENT)
	elif is_special:
		_style_key(b, CAP_SPECIAL, CAP_ACCENT)
	else:
		_style_key(b, CAP_PLAIN, CAP_ACCENT)
	return b


## Sets the sticky modifiers and shows the state on their buttons (both
## Shift keys, both Ctrl keys, both Alt keys move together).
func _set_sticky(shift: bool, ctrl: bool, alt: bool, win: bool) -> void:
	_sticky_shift = shift
	_sticky_ctrl = ctrl
	_sticky_alt = alt
	_sticky_win = win
	for b in _shift_buttons:
		b.set_pressed_no_signal(shift)
	for b in _ctrl_buttons:
		b.set_pressed_no_signal(ctrl)
	for b in _alt_buttons:
		b.set_pressed_no_signal(alt)
	for b in _win_buttons:
		b.set_pressed_no_signal(win)


## Lights the on-screen key(s) for a typed keycode up for a moment.
func _flash(keycode: int) -> void:
	for b in _key_buttons.get(keycode, []):
		var tween := create_tween()
		b.modulate = Color(0.6, 0.85, 1.0)
		tween.tween_property(b, "modulate", Color.WHITE, 0.25)
