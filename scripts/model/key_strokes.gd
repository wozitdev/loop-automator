extends RefCounted
class_name KeyStrokes
## SendKeys text, read as keystrokes: how ~Keys types it one press at a
## time. `split` cuts the text into strokes (a combo stays one stroke);
## `parse` turns a stroke into the keys to hold down for it, so a press can
## have real timing (modifiers first, the key held a moment, then let go).

## SendKeys key names (upper case) and their Windows virtual-key codes.
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
}
const VK_ENTER := 0x0D


## `text` cut into the keystrokes it stands for: a plain character, a
## braced key ("{ENTER}", "{F4 3}", "{{}", "{}}"), or a group "(abc)", each
## with the ^ + % modifiers in front of it kept attached ("^c", "+(ab)",
## "%{F4}" stay one stroke, so a combo is pressed as one).
static func split(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var mods := ""
	var i := 0
	var n := text.length()
	while i < n:
		var ch := text[i]
		if ch == "^" or ch == "+" or ch == "%":
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
## a (Alt) to hold throughout; "keys": the keys in order, "c<code>" for a
## character (the helper finds its key on the keyboard layout) or "v<vk>"
## for a named key; "repeat": how many times}. Empty when the stroke is not
## something a key press expresses (an unknown name, an odd group), and
## SendKeys itself should send it.
static func parse(stroke: String) -> Dictionary:
	var mods := ""
	var i := 0
	while i < stroke.length() and stroke[i] in "^+%":
		mods += {"^": "c", "+": "s", "%": "a"}[stroke[i]]
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
			if ch in "{}()^+%":
				return {}   # nested syntax inside a group: leave it to SendKeys
			keys.append("v%d" % VK_ENTER if ch == "~" else "c%d" % ch.unicode_at(0))
		if keys.is_empty():
			return {}
	elif rest.length() == 1:
		keys.append("v%d" % VK_ENTER if rest == "~" else "c%d" % rest.unicode_at(0))
	else:
		return {}
	return {"mods": mods, "keys": keys, "repeat": repeat}
