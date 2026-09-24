extends RefCounted
class_name Recording
## A recording (see Recorder: the events the helper saw, in order) turned
## into a layer's actions, the way a person would have written them: a run
## of mouse motion is one Move, a press that travels is a Drag, a press held
## still is a Click hold, keystrokes close together are one Key action typed
## with ~Keys, a key held while other things happen is a Key down … up, and
## the pauses between are Waits. Every number is exact - a TAS; ranges are
## the user's to add.

const LoopActionT := preload("res://scripts/model/loop_action.gd")
const KeyStrokesT := preload("res://scripts/model/key_strokes.gd")

## A pause shorter than this is absorbed, not a Wait.
const MIN_WAIT_MS := 40
## Motion with a pause this long inside it is two Moves.
const MOVE_GAP_MS := 150
## Motion this short (px) and quick (ms) is a hand at rest: dropped.
const JITTER_PX := 3
const JITTER_MS := 100
## A press whose up is this far (px) from its down is a Drag.
const DRAG_PX := 4
## A press or key kept down this long is a hold, not a tap.
const HOLD_MS := 250
## Keystrokes this close together are typed as one Key action.
const TYPING_GAP_MS := 400
## Wheel notches this close together are one Scroll.
const WHEEL_GAP_MS := 400
## The Esc key (a recording ended with it from the builder).
const VK_ESCAPE := 0x1B

## Virtual keys that are modifiers, and the letter each is in
## KeyStrokes' mods (a helper may report left / right codes; see _vk).
const MODIFIERS := {0x10: "s", 0x11: "c", 0x12: "a", 0x5B: "w", 0x5C: "w"}
## The virtual key of each modifier letter.
const MODIFIER_OF := {"s": 0x10, "c": 0x11, "a": 0x12, "w": 0x5B}
## US-layout characters of the OEM virtual keys, the unshifted one; Shift
## on them keeps its "+" so the shifted character is the layout's.
const OEM := {
	0xBA: ";", 0xBB: "=", 0xBC: ",", 0xBD: "-", 0xBE: ".", 0xBF: "/",
	0xC0: "`", 0xDB: "[", 0xDC: "\\", 0xDD: "]", 0xDE: "'",
}


## Keys the last to_actions left out: no character and no name to type
## them by (Pause, the menu key). Said on the status line.
static var skipped_keys := 0


## The actions for `events`.
static func to_actions(events: Array) -> Array[LoopActionT]:
	skipped_keys = 0
	return _actions(_items(events))


## `events` without the gesture that ended the recording from the builder
## (recorded with ~Self on): the press of its Stop button - the last mouse
## down (its up may have come in too) and everything after it - or the Esc,
## and the motion up to it.
static func without_stop_gesture(events: Array) -> Array:
	var out := events.duplicate()
	var cut := out.size()
	for i in range(out.size() - 1, -1, -1):
		var e: Dictionary = out[i]
		if e["kind"] == "m":
			continue
		if e["kind"] == "d" or (e["kind"] == "k" and e["vk"] == VK_ESCAPE):
			cut = i
		elif e["kind"] == "u":
			# The release of the press: cut from the press itself.
			for j in range(i - 1, -1, -1):
				if out[j]["kind"] == "d" and out[j]["button"] == e["button"]:
					cut = j
					break
		break
	out.resize(cut)
	while not out.is_empty() and out[out.size() - 1]["kind"] == "m":
		out.resize(out.size() - 1)
	return out


# ----------------------------------------------------------------- phase 1
## The events grouped into items, each with a start (t0) and end (t1):
## "move" (x, y: where it ends), "click" / "hold" / "drag" / "down" / "up"
## (button; x, y; drag: x2, y2), "scroll" (dir, n), "key" / "keyhold" /
## "keydown" / "keyup" (text: the SendKeys stroke). Sorted by t0.
static func _items(events: Array) -> Array:
	var items: Array = []
	var run := {}          # the mouse motion under way
	var buttons := {}      # button -> its down event (+ "other")
	var keys := {}         # vk -> its down event (+ "mods", "other")
	var mods := {}         # modifier vk -> {"t", "used"}
	var wheel := {}        # the wheel run under way
	var held: Array = []   # modifiers kept as a Key Down ... Up: {"letter", "t0", "t1"}
	for e in events:
		var t: int = e["t"]
		match e["kind"]:
			"m":
				if not buttons.is_empty():
					# Motion with a button down is the press's own (a drag) - and
					# other input for any key held meanwhile (W and a camera turn).
					var plain := false
					for b in buttons.values():
						b["x2"] = e["x"]
						b["y2"] = e["y"]
						plain = plain or b["other"]
					for k in keys.values():
						k["other"] = true
					# A press that became a plain down ... up (something else
					# happened while it was down) is no drag: its motion is kept
					# as Moves, as without a button.
					if not plain:
						continue
				if not run.is_empty() and t - run["t1"] > MOVE_GAP_MS:
					_flush_move(items, run, keys, mods)
					run = {}
				if run.is_empty():
					run = {"t0": t, "t1": t, "x0": e["x"], "y0": e["y"]}
				run["t1"] = t
				run["x"] = e["x"]
				run["y"] = e["y"]
			"d":
				_flush_move(items, run, keys, mods)
				run = {}
				_touch(buttons, keys, mods, true)
				# The same button pressed again with no release seen: the first
				# press is let go of here rather than lost (and left down).
				if buttons.has(e["button"]):
					var old: Dictionary = buttons[e["button"]]
					buttons.erase(e["button"])
					items.append(_item("down", old["t"], old["t"], {"button": e["button"], "x": old["x"], "y": old["y"]}))
					items.append(_item("up", t, t, {"button": e["button"], "x": old["x2"], "y": old["y2"]}))
				var d := {"t": t, "x": e["x"], "y": e["y"], "x2": e["x"], "y2": e["y"], "other": false}
				# A press while another is down makes both plain down / up.
				if not buttons.is_empty():
					d["other"] = true
				buttons[e["button"]] = d
			"u":
				if not buttons.has(e["button"]):
					continue
				# Motion so far is before the release (what comes after it is
				# not the press's: a Move ending past the drop would drag on).
				_flush_move(items, run, keys, mods)
				run = {}
				var d: Dictionary = buttons[e["button"]]
				buttons.erase(e["button"])
				var base := {"button": e["button"], "x": d["x"], "y": d["y"]}
				if d["other"]:
					items.append(_item("down", d["t"], d["t"], base))
					# Let go of where it was let go of (the end of a drag, off the
					# button it was pressed on), not wherever the cursor is.
					items.append(_item("up", t, t, {"button": e["button"], "x": e["x"], "y": e["y"]}))
				elif Vector2i(d["x"], d["y"]).distance_to(Vector2i(e["x"], e["y"])) > DRAG_PX:
					base["x2"] = e["x"]
					base["y2"] = e["y"]
					items.append(_item("drag", d["t"], t, base))
				elif t - int(d["t"]) >= HOLD_MS:
					items.append(_item("hold", d["t"], t, base))
				else:
					items.append(_item("click", d["t"], t, base))
			"w":
				_flush_move(items, run, keys, mods)
				run = {}
				_touch(buttons, keys, mods, true)
				var delta: int = e["delta"]
				var dir := LoopActionT.ScrollDir.UP if delta > 0 else LoopActionT.ScrollDir.DOWN
				if e["horizontal"]:
					dir = LoopActionT.ScrollDir.RIGHT if delta > 0 else LoopActionT.ScrollDir.LEFT
				# A notch is 120; a smooth wheel or a touchpad sends it in small
				# steps (15, 30), so the run's steps are added up and it turns
				# as many notches as they come to.
				# (A Scroll turns NOTCHES_MAX at most: a longer run is two.)
				if not wheel.is_empty() and (wheel["dir"] != dir or t - wheel["t1"] > WHEEL_GAP_MS \
						or (wheel["sum"] + absi(delta)) / 120 > LoopActionT.NOTCHES_MAX):
					_end_wheel(items, wheel)
					wheel = {}
				if wheel.is_empty():
					wheel = {"t0": t, "t1": t, "dir": dir, "n": 0, "sum": 0}
				wheel["sum"] += absi(delta)
				wheel["n"] = roundi(wheel["sum"] / 120.0)
				wheel["t1"] = t
			"k":
				var vk := _vk(e["vk"])
				if MODIFIERS.has(vk):
					if e["down"]:
						if not mods.has(vk):
							# Motion that ended before it went down is not its.
							_flush_move(items, run, keys, mods)
							run = {}
							# (Down during a press: held for the mouse, a Ctrl-drag.)
							mods[vk] = {"t": t, "used": not buttons.is_empty(), "mouse": not buttons.is_empty()}
							# Held across it, a key or button is a down ... up (so the
							# modifier lands between them as it did).
							for b in buttons.values():
								b["other"] = true
							for k in keys.values():
								k["other"] = true
					elif mods.has(vk):
						# Motion while it was held is its (Shift while steering):
						# flushed now, so it is a down ... Move ... up.
						_flush_move(items, run, keys, mods)
						run = {}
						var m: Dictionary = mods[vk]
						mods.erase(vk)
						var text := _stroke(vk, "", false)
						if m["mouse"]:
							# Held for the mouse (Shift-click, Ctrl-wheel): down … up
							# around it. Keys pressed meanwhile lose it as a prefix
							# (see the end): the Key Down holds it for them.
							items.append(_item("keydown", m["t"], m["t"], {"text": text}))
							items.append(_item("keyup", t, t, {"text": text}))
							held.append({"letter": MODIFIERS[vk], "t0": m["t"], "t1": t})
						elif not m["used"]:
							# A modifier on its own is a keystroke of its own - a
							# hold if it was held (Shift to sprint, to crouch).
							items.append(_item("keyhold" if t - int(m["t"]) >= HOLD_MS else "key", m["t"], t, {"text": text}))
					continue
				if e["down"]:
					if keys.has(vk):
						# The keyboard's own repeat: counted (a held Backspace
						# deletes a character per repeat, see the key's up).
						keys[vk]["repeats"] = int(keys[vk].get("repeats", 0)) + 1
						continue
					_flush_move(items, run, keys, mods)
					run = {}
					_touch(buttons, keys, mods, false)
					var letters := ""
					for mvk in mods:
						if not letters.contains(MODIFIERS[mvk]):
							letters += MODIFIERS[mvk]
					keys[vk] = {"t": t, "mods": letters, "other": false, "extended": e["extended"], "ch": e.get("ch", 0)}
				elif keys.has(vk):
					# Motion still under way happened during the hold: it counts.
					_flush_move(items, run, keys, mods)
					run = {}
					var k: Dictionary = keys[vk]
					keys.erase(vk)
					var text := _stroke(vk, k["mods"], e["extended"], k["ch"])
					if text.is_empty():
						skipped_keys += 1
						continue
					var st := {"vk": vk, "mods": k["mods"], "ext": e["extended"], "ch": k["ch"], "at": k["t"]}
					if k["other"]:
						items.append(_item("keydown", k["t"], k["t"], {"text": text, "stroke": st}))
						items.append(_item("keyup", t, t, {"text": text, "stroke": st}))
					elif int(k.get("repeats", 0)) > 0 and (text.ends_with("{BACKSPACE}") or text.ends_with("{DELETE}")):
						# Backspace or Delete held till it repeated (clearing a field):
						# the presses it made, counted - injected input does not
						# repeat by itself, and a hold would press it once.
						st["n"] = mini(int(k["repeats"]) + 1, KeyStrokesT.REPEAT_MAX)
						items.append(_item("key", k["t"], t, {"text": _key_text(st), "stroke": st}))
					elif t - int(k["t"]) >= HOLD_MS:
						items.append(_item("keyhold", k["t"], t, {"text": text, "stroke": st}))
					else:
						# Typed: a letter as the layout has it (Cyrillic, Greek),
						# where a held one stays the key it is (W to walk).
						# (Only plain typing: a shortcut, Ctrl+C in a Russian
						# window, is the key - it works on any layout.)
						st["typed"] = k["mods"] == "" or k["mods"] == "s"
						items.append(_item("key", k["t"], t, {"text": _key_text(st), "stroke": st}))
	_flush_move(items, run, keys, mods)
	if not wheel.is_empty():
		_end_wheel(items, wheel)
	# Still down when the recording ended: pressed, never let go.
	for b in buttons:
		var d: Dictionary = buttons[b]
		items.append(_item("down", d["t"], d["t"], {"button": b, "x": d["x"], "y": d["y"]}))
	for vk in keys:
		var k: Dictionary = keys[vk]
		var text := _stroke(vk, k["mods"], k["extended"], k["ch"])
		if not text.is_empty():
			var st := {"vk": vk, "mods": k["mods"], "ext": k["extended"], "ch": k["ch"], "at": k["t"]}
			items.append(_item("keydown", k["t"], k["t"], {"text": text, "stroke": st}))
		else:
			skipped_keys += 1
	# A modifier kept as a Key Down ... Up (held for the mouse) is already
	# down for the keys pressed inside it: their text drops its prefix, so
	# Ctrl held through ^c and a Move replays as Key Down {CTRL}, c, Move,
	# Key Up (the helper refuses "^c" while a Key Down holds Ctrl).
	for h in held:
		for it in items:
			var st: Dictionary = it.get("stroke", {})
			if not st.is_empty() and String(st["mods"]).contains(h["letter"]) \
					and int(st["at"]) >= int(h["t0"]) and int(st["at"]) <= int(h["t1"]):
				st["mods"] = String(st["mods"]).replace(h["letter"], "")
				st["stripped"] = true
	# A typed key with modifiers still left (Ctrl held for the mouse, Shift
	# pressed with the S) holds those too, as a down ... up around it: the
	# helper types nothing that presses a modifier while a Key Down holds one.
	var out: Array = []
	for it in items:
		var st: Dictionary = it.get("stroke", {})
		if not st.get("stripped", false):
			out.append(it)
			continue
		var wrap: String = st["mods"] if it["kind"] == "key" else ""
		if not wrap.is_empty():
			st = st.duplicate()
			st["mods"] = ""
		var text := _key_text(st)
		if text.is_empty():
			out.append(it)
			continue
		it["text"] = text
		for letter in wrap:
			out.append(_item("keydown", it["t0"], it["t0"], {"text": _stroke(MODIFIER_OF[letter], "", false)}))
		out.append(it)
		for letter in wrap:
			out.append(_item("keyup", it["t1"], it["t1"], {"text": _stroke(MODIFIER_OF[letter], "", false)}))
	items = out
	# By start time; the sort is not stable, so ties keep their order by hand.
	for i in items.size():
		items[i]["i"] = i
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["t0"] < b["t0"] if a["t0"] != b["t0"] else a["i"] < b["i"])
	return items


static func _item(kind: String, t0: int, t1: int, data: Dictionary) -> Dictionary:
	var it := data.duplicate()
	it["kind"] = kind
	it["t0"] = t0
	it["t1"] = t1
	return it


## The motion run as a Move item, unless it is a hand at rest. A real move
## is "other input" for every key held meanwhile (W held while the mouse
## steers is a Key down … up, not a hold).
static func _flush_move(items: Array, run: Dictionary, keys: Dictionary, mods: Dictionary = {}) -> void:
	if run.is_empty():
		return
	var dist := Vector2i(run["x0"], run["y0"]).distance_to(Vector2i(run["x"], run["y"]))
	if dist < JITTER_PX and run["t1"] - run["t0"] < JITTER_MS:
		return
	items.append(_item("move", run["t0"], run["t1"], {"x": run["x"], "y": run["y"]}))
	for k in keys.values():
		k["other"] = true
	# A modifier held while the mouse moved (Shift to sprint and look) is a
	# down ... up around the move, not a hold before it.
	for m in mods.values():
		m["used"] = true
		m["mouse"] = true


## Something happened: every button and key held right now becomes a
## down … up pair rather than a tap or hold, and the modifiers down have
## been used (so letting go of one is not a tap of it) - by the mouse, with
## `by_mouse`, which a key prefix cannot carry.
static func _touch(buttons: Dictionary, keys: Dictionary, mods: Dictionary, by_mouse: bool) -> void:
	for b in buttons.values():
		b["other"] = true
	for k in keys.values():
		k["other"] = true
	for m in mods.values():
		m["used"] = true
		if by_mouse:
			m["mouse"] = true


## A wheel run as a Scroll, unless its steps came to less than half a notch.
static func _end_wheel(items: Array, wheel: Dictionary) -> void:
	if wheel["n"] >= 1:
		items.append(_item("scroll", wheel["t0"], wheel["t1"], wheel))


## Left / right modifier codes as the plain ones.
static func _vk(vk: int) -> int:
	match vk:
		0xA0, 0xA1: return 0x10
		0xA2, 0xA3: return 0x11
		0xA4, 0xA5: return 0x12
	return vk


## The SendKeys stroke for a key: its modifier prefixes (^ + % $) and the
## key - a character (Shift and a letter is the capital), a "{NAME}", or ""
## for a key with no name (skipped).
## A key item's text from its stroke (see _items): typed as the layout has
## it when it was plain typing, with its repeat count if it has one.
static func _key_text(st: Dictionary) -> String:
	var text := _stroke(st["vk"], st["mods"], st["ext"], st["ch"], st.get("typed", false))
	if st.has("n") and not text.is_empty():
		text = text.left(text.length() - 1) + " %d}" % int(st["n"])
	return text


static func _stroke(vk: int, mods: String, _extended: bool, ch: int = 0, typed: bool = false) -> String:
	var prefix := ""
	var shift := mods.contains("s")
	for letter in mods:
		prefix += {"c": "^", "s": "+", "a": "%", "w": "$"}.get(letter, "")
	var key := ""
	# A dead key (an accent waiting for its letter) comes negated: written as
	# its accent's own character, the layout's - so a replay presses the same
	# key (Ctrl+` stays Ctrl+`, US-International's ' stays '), or plain
	# typing refuses it where it would wait for a letter; never the US
	# character its code is named for.
	if ch < 0:
		ch = -ch
		# With a modifier it was a shortcut on that key, which no replay can
		# press (the accent would be typed instead): left out, counted.
		if ch <= 0x20 or not mods.is_empty():
			return ""
	if vk >= 0x41 and vk <= 0x5A:
		key = char(vk).to_lower()
		if typed and ch > 0x20 and char(ch).to_upper() != char(vk):
			key = char(ch).to_lower()
		if shift and mods == "s":
			# Shift and a letter: the capital says it (SendKeys sends Shift).
			key = key.to_upper()
			prefix = ""
	elif vk >= 0x30 and vk <= 0x39:
		# The layout's character for the key (a French keyboard's top row is
		# "&", "é", ... unshifted), the digit where the helper said none.
		key = char(ch).to_lower() if ch > 0x20 else char(vk)
	elif vk >= 0x60 and vk <= 0x69:
		key = char(vk - 0x60 + 0x30)   # numpad digits
	elif vk == 0x6E:
		key = char(ch) if ch > 0x20 else "."   # "," on a German or French numpad
	elif vk == 0x20:
		key = " "
	elif ch > 0x20 and not (vk >= 0x60 and vk <= 0x6F):
		# A punctuation key (the OEM codes, the ISO "<" key): the character the
		# layout puts on it, not the US one (German "+" is 0xBB, US "=").
		key = char(ch).to_lower()
	elif OEM.has(vk):
		key = OEM[vk]
	else:
		# A named key: the first name KeyStrokes has for it.
		for name in KeyStrokesT.NAMED:
			if KeyStrokesT.NAMED[name] == vk:
				return prefix + "{" + name + "}"
		return ""
	# SendKeys' own characters are written braced.
	if key in "+^%~(){}[]$":
		key = "{" + key + "}"
	return prefix + key


# ----------------------------------------------------------------- phase 2
## The items as actions, Waits for the pauses between them.
static func _actions(items: Array) -> Array[LoopActionT]:
	var out: Array[LoopActionT] = []
	if items.is_empty():
		return out
	var t_done: int = items[0]["t0"]
	var typing: LoopActionT = null   # the Key action keystrokes are joining
	for it in items:
		var t0: int = it["t0"]
		var t1: int = it["t1"]
		var gap := t0 - t_done
		# (A Key's text holds KEYS_MAX_CHARS at most: typing past that goes
		# on in a Key action of its own rather than being cut on the next load.)
		if it["kind"] == "key" and typing != null and gap < TYPING_GAP_MS \
				and typing.keys.length() + String(it["text"]).length() <= LoopActionT.KEYS_MAX_CHARS:
			typing.keys += it["text"]
			t_done = maxi(t_done, t1)
			continue
		typing = null
		if gap >= MIN_WAIT_MS:
			var w := LoopActionT.new_of_type(LoopActionT.Type.WAIT)
			w.wait_ms = gap
			w.wait_ms_max = gap
			out.append(w)
		var a: LoopActionT = null
		match it["kind"]:
			"move":
				a = LoopActionT.new_of_type(LoopActionT.Type.MOVE)
				_at(a, it["x"], it["y"])
				_over(a, t1 - t0)
			"click", "hold", "down":
				a = LoopActionT.new_of_type(LoopActionT.Type.CLICK)
				a.button = it["button"]
				_at(a, it["x"], it["y"])
				if it["kind"] == "hold":
					a.press_mode = LoopActionT.PressMode.HOLD
					a.hold_ms = t1 - t0
					a.hold_ms_max = a.hold_ms
				elif it["kind"] == "down":
					a.press_mode = LoopActionT.PressMode.DOWN
			"up":
				a = LoopActionT.new_of_type(LoopActionT.Type.CLICK)
				a.button = it["button"]
				a.press_mode = LoopActionT.PressMode.UP
				# Where it was let go of, when the recording says (see _items).
				a.move_to = it.has("x")
				if a.move_to:
					_at(a, it["x"], it["y"])
			"drag":
				a = LoopActionT.new_of_type(LoopActionT.Type.DRAG)
				a.button = it["button"]
				_at(a, it["x"], it["y"])
				a.x2 = it["x2"]
				a.x2_max = a.x2
				a.y2 = it["y2"]
				a.y2_max = a.y2
				_over(a, t1 - t0)
			"scroll":
				a = LoopActionT.new_of_type(LoopActionT.Type.SCROLL)
				a.scroll_dir = it["dir"]
				a.notches = mini(it["n"], LoopActionT.NOTCHES_MAX)
				a.notches_max = a.notches
				_over(a, t1 - t0 if it["n"] > 1 else 0)
			"key":
				a = LoopActionT.new_of_type(LoopActionT.Type.KEY)
				a.keys = it["text"]
				a.keys_paced = true
				typing = a
			"keyhold":
				a = LoopActionT.new_of_type(LoopActionT.Type.KEY)
				a.keys = it["text"]
				a.press_mode = LoopActionT.PressMode.HOLD
				a.hold_ms = t1 - t0
				a.hold_ms_max = a.hold_ms
			"keydown", "keyup":
				a = LoopActionT.new_of_type(LoopActionT.Type.KEY)
				a.keys = it["text"]
				a.press_mode = LoopActionT.PressMode.DOWN if it["kind"] == "keydown" else LoopActionT.PressMode.UP
		if a != null:
			out.append(a)
		t_done = maxi(t_done, t1)
	# Held as the editor would show it (a pause or a hold longer than its box
	# takes is cut to that, as a load would cut it).
	for a in out:
		a.keep_to_limits()
	return out


static func _at(a: LoopActionT, x: int, y: int) -> void:
	a.x = x
	a.x_max = x
	a.y = y
	a.y_max = y


static func _over(a: LoopActionT, ms: int) -> void:
	a.duration_ms = maxi(0, ms)
	a.duration_ms_max = a.duration_ms
