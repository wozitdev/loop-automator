extends RefCounted
class_name KeyStrokes
## SendKeys text, read as keystrokes: how ~Keys types it one press at a
## time. `split` cuts the text into strokes (a combo stays one stroke);
## `parse` turns a stroke into the keys to hold down for it, so a press can
## have real timing (modifiers first, the key held a moment, then let go).

## SendKeys key names (upper case) and their Windows virtual-key codes,
## plus a few names of ours for keys SendKeys cannot send (see EXTRA).
const NAMED := {
	"ENTER": 0x0D, "TAB": 0x09, "ESC": 0x1B, "ESCAPE": 0x1B,
	"BACKSPACE": 0x08, "BS": 0x08, "BKSP": 0x08,
	"DELETE": 0x2E, "DEL": 0x2E, "INSERT": 0x2D, "INS": 0x2D,
	"HOME": 0x24, "END": 0x23, "PGUP": 0x21, "PGDN": 0x22,
	"UP": 0x26, "DOWN": 0x28, "LEFT": 0x25, "RIGHT": 0x27,
	"CAPSLOCK": 0x14, "NUMLOCK": 0x90, "SCROLLLOCK": 0x91,
	"PRTSC": 0x2C, "BREAK": 0x03, "HELP": 0x2F,
	"ADD": 0x6B, "SUBTRACT": 0x6D, "MULTIPLY": 0x6A, "DIVIDE": 0x6F,
	"F1": 0x70, "F2": 0x71, "F3": 0x72, "F4": 0x73, "F5": 0x74, "F6": 0x75,
	"F7": 0x76, "F8": 0x77, "F9": 0x78, "F10": 0x79, "F11": 0x7A, "F12": 0x7B,
	"F13": 0x7C, "F14": 0x7D, "F15": 0x7E, "F16": 0x7F,
	"SUPER": 0x5B, "WIN": 0x5B, "LWIN": 0x5B, "RWIN": 0x5C,
	"CTRL": 0x11, "CONTROL": 0x11, "SHIFT": 0x10, "ALT": 0x12, "SPACE": 0x20,
}
## Virtual keys SendKeys has no name for: the Windows key, a modifier on
## its own (SendKeys knows Ctrl only as the ^ in front of another key), and
## Space by name. A stroke with one of these is always pressed by the
## helper (see helper_only); everything else may go to SendKeys as text.
const EXTRA := [0x5B, 0x5C, 0x11, 0x10, 0x12, 0x20]
const VK_ENTER := 0x0D


## `text` cut into the keystrokes it stands for: a plain character, a
## braced key ("{ENTER}", "{F4 3}", "{{}", "{}}"), or a group "(abc)", each
## with the ^ + % $ modifiers in front of it kept attached ("^c", "+(ab)",
## "%{F4}", "$r" stay one stroke, so a combo is pressed as one). "$" is the
## Windows key as a modifier, a name of ours (SendKeys has none): a stroke
## with it is always pressed by the helper (see helper_only).
static func split(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var mods := ""
	var i := 0
	var n := text.length()
	while i < n:
		var ch := text[i]
		if ch == "^" or ch == "+" or ch == "%" or ch == "$":
			mods += ch
			i += 1
			continue
		var end := i + 1
		if ch == "{":
			# "{}}" is a literal "}"; otherwise the token runs to the next "}".
			if i + 2 < n and text[i + 1] == "}" and text[i + 2] == "}":
				end = i + 3
			else:
				var close := text.find("}", i + 1)
				end = n if close < 0 else close + 1
		elif ch == "(":
			var close := text.find(")", i + 1)
			end = n if close < 0 else close + 1
		out.append(mods + text.substr(i, end - i))
		mods = ""
		i = end
	if not mods.is_empty():
		out.append(mods)
	return out


## One stroke as keys to press: {"mods": letters of c (Ctrl), s (Shift),
## a (Alt), w (Win) to hold throughout; "keys": the keys in order, "c<code>" for a
## character (the helper finds its key on the keyboard layout) or "v<vk>"
## for a named key; "repeat": how many times}. Empty when the stroke is not
## something a key press expresses (an unknown name, an odd group), and
## SendKeys itself should send it.
static func parse(stroke: String) -> Dictionary:
	var mods := ""
	var i := 0
	while i < stroke.length() and stroke[i] in "^+%$":
		mods += {"^": "c", "+": "s", "%": "a", "$": "w"}[stroke[i]]
		i += 1
	var rest := stroke.substr(i)
	var keys := PackedStringArray()
	var repeat := 1
	if rest.is_empty():
		return {}
	if rest.begins_with("{") and rest.ends_with("}") and rest.length() >= 3:
		var inner := rest.substr(1, rest.length() - 2)
		if inner.length() == 1:
			keys.append("c%d" % inner.unicode_at(0))   # {{} {}} {+} {~} …
		else:
			var parts := inner.split(" ", false)
			if parts.is_empty() or parts.size() > 2:
				return {}
			var name := parts[0].to_upper()
			if name.length() == 1:
				keys.append("c%d" % parts[0].unicode_at(0))
			elif NAMED.has(name):
				keys.append("v%d" % NAMED[name])
			else:
				return {}
			if parts.size() == 2:
				if not parts[1].is_valid_int() or int(parts[1]) < 1:
					return {}
				repeat = int(parts[1])
	elif rest.begins_with("(") and rest.ends_with(")"):
		for ch in rest.substr(1, rest.length() - 2):
			if ch in "{}()^+%$":
				return {}   # nested syntax inside a group: leave it to SendKeys
			keys.append("v%d" % VK_ENTER if ch == "~" else "c%d" % ch.unicode_at(0))
		if keys.is_empty():
			return {}
	elif rest.length() == 1:
		keys.append("v%d" % VK_ENTER if rest == "~" else "c%d" % rest.unicode_at(0))
	else:
		return {}
	return {"mods": mods, "keys": keys, "repeat": repeat}


## `text` cut into pieces of at most `max_bytes` (UTF-8), each a whole
## number of keystrokes (see split; the pieces joined are the text again),
## so a piece can be sent - or stopped after - on its own. A single
## keystroke bigger than that is a piece of its own.
static func pieces(text: String, max_bytes: int) -> PackedStringArray:
	var out := PackedStringArray()
	var piece := ""
	var piece_bytes := 0
	for stroke in split(text):
		var bytes := stroke.to_utf8_buffer().size()
		if piece_bytes + bytes > max_bytes and not piece.is_empty():
			out.append(piece)
			piece = ""
			piece_bytes = 0
		piece += stroke
		piece_bytes += bytes
	if not piece.is_empty():
		out.append(piece)
	return out


## Whether `press` (a parse result) has a key SendKeys cannot type (see
## EXTRA) or the Win modifier, so the stroke must go through the helper
## even where the rest of the text is left to SendKeys.
static func helper_only(press: Dictionary) -> bool:
	if press.is_empty():
		return false
	if String(press["mods"]).contains("w"):
		return true
	for k in press["keys"]:
		if k.begins_with("v") and int(k.substr(1)) in EXTRA:
			return true
	return false
