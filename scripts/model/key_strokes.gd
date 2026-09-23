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
	"CAPSLOCK": 0x14, "NUMLOCK": 0x90, "SCROLLLOCK": 0x91, "CLEAR": 0x0C,
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
## The most times one braced key repeats ("{ENTER 3}"). Each repeat is a
## press of its own in a run, so a file saying "{TAB 999999999}" would
## otherwise have the app build a billion presses before typing one; a
## stroke over this is left to SendKeys as it is (see parse).
const REPEAT_MAX := 1000


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
			end = _brace_end(text, i)
		elif ch == "(":
			# To the ")" that closes it: one inside a braced key ("{)}") does not.
			end = i + 1
			while end < n and text[end] != ")":
				end = _brace_end(text, end) if text[end] == "{" else end + 1
			end = mini(end + 1, n)
		out.append(mods + text.substr(i, end - i))
		mods = ""
		i = end
	if not mods.is_empty():
		out.append(mods)
	return out


## Where the braced key starting at `text[i]` ("{") ends (one past its
## "}"), read as SendKeys.ParseKeys reads it: "{}" with a "}" later on runs
## to that one ("{}}" is a "}", "{} 5}" five of them); otherwise to the
## next "}". The end of the text when nothing closes it.
static func _brace_end(text: String, i: int) -> int:
	var from := i + 1
	if i + 2 < text.length() and text[i + 1] == "}" and text.find("}", i + 2) >= 0:
		from = i + 2
	var close := text.find("}", from)
	return text.length() if close < 0 else close + 1


## Whether stroke's modifiers (^ + % $ in front) name one of them twice.
static func has_repeated_modifier(stroke: String) -> bool:
	var seen := ""
	for ch in stroke:
		if not ch in "^+%$":
			return false
		if seen.contains(ch):
			return true
		seen += ch
	return false


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
	# The same modifier twice is no key press (SendKeys refuses it too): a
	# run of forty "^" can hide a "%" among them in every cut the list
	# and the import question make of it.
	if has_repeated_modifier(stroke):
		return {}
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
				# Plain digits only, as SendKeys reads a count ("+30" is
				# refused there, so it is not a count here either).
				if parts[1].is_empty() or not parts[1].lstrip("0123456789").is_empty() \
						or parts[1].length() > 9 or int(parts[1]) < 1 or int(parts[1]) > REPEAT_MAX:
					return {}
				repeat = int(parts[1])
	elif rest.begins_with("(") and rest.ends_with(")"):
		var inner := rest.substr(1, rest.length() - 2)
		var j := 0
		while j < inner.length():
			var ch := inner[j]
			# A single braced character ("{^}", "{}}") is that character, as
			# SendKeys reads it inside a group too - read here, so the group
			# goes to the helper ("{^}" through SendKeys types Shift+6).
			if ch == "{" and j + 2 < inner.length() and inner[j + 2] == "}":
				keys.append("c%d" % inner.unicode_at(j + 1))
				j += 3
				continue
			if ch in "{}()^+%$":
				return {}   # other nested syntax inside a group: leave it to SendKeys
			keys.append("v%d" % VK_ENTER if ch == "~" else "c%d" % ch.unicode_at(0))
			j += 1
		if keys.is_empty():
			return {}
	elif rest.length() == 1:
		keys.append("v%d" % VK_ENTER if rest == "~" else "c%d" % rest.unicode_at(0))
	else:
		return {}
	# A character past U+FFFF (an emoji) is no key on any layout, and the
	# helper cannot name it: SendKeys types it.
	for k in keys:
		if k.begins_with("c") and int(k.substr(1)) > 0xFFFF:
			return {}
	return {"mods": mods, "keys": keys, "repeat": repeat}


## `text` with every braced key's repeat count kept to REPEAT_MAX ("{TAB
## 999999999}" is "{TAB 1000}"). parse leaves a stroke over the bound to
## SendKeys, which would build all of those presses in one go - a command
## a stop cannot cut short - so whatever reaches SendKeys goes through here.
## The braces are read the way SendKeys.ParseKeys reads them, not the way
## split does: "{} 9…}" is "}" repeated, and any Unicode white space (a
## no-break space, an ideographic space) goes before a count.
static func clamp_repeats(text: String) -> String:
	var out := ""
	var i := 0
	var n := text.length()
	while i < n:
		if text[i] != "{":
			out += text[i]
			i += 1
			continue
		var j := i + 1
		# "{}" followed by a "}" somewhere later: the keyword is "}".
		if j + 1 < n and text[j] == "}" and text.find("}", j + 1) >= 0:
			j += 1
		while j < n and text[j] != "}" and not _is_space(text[j]):
			j += 1
		if j >= n or not _is_space(text[j]):
			# No count (or an unclosed brace, which SendKeys refuses).
			out += text.substr(i, j - i + 1)
			i = j + 1
			continue
		var head := text.substr(i, j - i)   # "{" and the keyword
		while j < n and _is_space(text[j]):
			j += 1
		var digits := j
		while j < n and text[j] >= "0" and text[j] <= "9":
			j += 1
		var count := text.substr(digits, j - digits).lstrip("0")
		if count.length() > 4 or (not count.is_empty() and int(count) > REPEAT_MAX):
			count = str(REPEAT_MAX)
		elif count.is_empty() and j > digits:
			count = "0"
		# Anything else after the space (not a digit SendKeys takes) is left
		# as it was: SendKeys refuses the text whole.
		out += head + " " + count
		i = j
	return out


## About how many keystrokes SendKeys makes of `text`: a braced key counts
## its repeats ("{TAB 40}" is 40), anything else one per character. What
## keeps one helper command short enough for a stop to wait out (see
## pieces), whatever a group or a run of repeats packs into a few bytes.
static func events(text: String) -> int:
	var total := 0
	var i := 0
	var n := text.length()
	while i < n:
		if text[i] == "{":
			var end := _brace_end(text, i)
			total += _repeat_of(text.substr(i, end - i))
			i = end
		else:
			total += 1
			i += 1
	return total


## The repeat count of a braced key ("{TAB 40}" -> 40), 1 without one. The
## count is the digits after the last white space, as SendKeys reads it.
static func _repeat_of(token: String) -> int:
	var inner := token.substr(1, token.length() - 2) if token.ends_with("}") else token.substr(1)
	var j := inner.length()
	while j > 0 and inner[j - 1] >= "0" and inner[j - 1] <= "9":
		j -= 1
	if j == inner.length() or j == 0 or not _is_space(inner[j - 1]):
		return 1
	var digits := inner.substr(j).lstrip("0")
	if digits.is_empty():
		return 1
	return int(digits) if digits.length() <= 9 else 1000000000


## Whether `ch` is white space to .NET's Char.IsWhiteSpace, which is what
## SendKeys reads between a key's name and its repeat count.
static func _is_space(ch: String) -> bool:
	var c := ch.unicode_at(0)
	return (c >= 0x09 and c <= 0x0D) or c == 0x20 or c == 0x85 or c == 0xA0 or c == 0x1680 \
		or (c >= 0x2000 and c <= 0x200A) or c == 0x2028 or c == 0x2029 or c == 0x202F \
		or c == 0x205F or c == 0x3000


## `text` cut into pieces of at most `max_bytes` (UTF-8), each a whole
## number of keystrokes (see split; the pieces joined are the text again),
## so a piece can be sent - or stopped after - on its own. A single
## keystroke bigger than that is a piece of its own. With `max_events`, a
## piece also makes at most that many keystrokes (see events), past a
## single keystroke that makes more on its own.
static func pieces(text: String, max_bytes: int, max_events: int = 0) -> PackedStringArray:
	var out := PackedStringArray()
	var piece := ""
	var piece_bytes := 0
	var piece_events := 0
	for stroke in split(text):
		var bytes := stroke.to_utf8_buffer().size()
		var count := events(stroke) if max_events > 0 else 0
		if (piece_bytes + bytes > max_bytes or (max_events > 0 and piece_events + count > max_events)) and not piece.is_empty():
			out.append(piece)
			piece = ""
			piece_bytes = 0
			piece_events = 0
		piece += stroke
		piece_bytes += bytes
		piece_events += count
	if not piece.is_empty():
		out.append(piece)
	return out


## Whether `text` has a "$" outside braced keys (the Windows key, a name of
## ours; a literal "$" is "{$}"): what SendKeys would type as a "$".
static func has_bare_win(text: String) -> bool:
	var i := 0
	var n := text.length()
	while i < n:
		if text[i] == "{":
			i = _brace_end(text, i)
		elif text[i] == "$":
			return true
		else:
			i += 1
	return false


## Whether `text` has a braced key SendKeys would read as "^", "%" or "+" -
## with a count, after any kind of space, inside a group ("{^ 3}",
## "{^<no-break space>3}", "(a{+ 2})"). SendKeys takes these from a
## US-layout table (Shift+6, Shift+5, numpad Add): another character on
## many layouts. (A plain "{^}" is pressed by the helper, see helper_only.)
static func has_us_keyword(text: String) -> bool:
	var i := text.find("{")
	while i >= 0:
		var end := _brace_end(text, i)
		var inner := text.substr(i + 1, end - i - 2) if text.substr(end - 1, 1) == "}" else text.substr(i + 1)
		var j := 0
		# "{}}" / "{} 3}": the keyword is "}".
		if inner.begins_with("}"):
			j = 1
		while j < inner.length() and not _is_space(inner[j]):
			j += 1
		if inner.left(j) in ["^", "%", "+"]:
			return true
		i = text.find("{", end)
	return false


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
		# "^", "%" and "+" as characters ("{^}"): SendKeys looks these up in
		# a US-layout table (Shift+6, Shift+5, numpad Add), which types
		# another character on many layouts ("&", "6"...).
		if k in ["c94", "c37", "c43"]:
			return true
		# "{~}": a dead key on some layouts (US-International, Portuguese),
		# which the helper types as the character itself.
		if k == "c126":
			return true
	return false
