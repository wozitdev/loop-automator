extends RefCounted
class_name MousePath
## The route the cursor takes from one point to another over an action's
## duration: a list of screen points spaced evenly in time, the first at
## `from` and the last exactly at `to`. Playback steps through it (the real
## cursor in the helper, the preview cursor and the overlay tracker here).

## Points per second of travel, and the most points one path may hold (a
## long travel then steps a little further each time).
const POINTS_PER_SECOND := 250
const MAX_POINTS := 400


## The path from `from` to `to` taking `ms`: straight, easing in and out
## like a hand does. A duration of 0 (or the same point) is just the two
## ends, which playback treats as a jump.
static func make(from: Vector2i, to: Vector2i, ms: int) -> PackedVector2Array:
	var path := PackedVector2Array()
	if ms <= 0 or from == to:
		path.append(Vector2(from))
		path.append(Vector2(to))
		return path
	var steps := clampi(ms * POINTS_PER_SECOND / 1000, 2, MAX_POINTS)
	var a := Vector2(from)
	var b := Vector2(to)
	for i in steps + 1:
		var t := float(i) / float(steps)
		path.append(a.lerp(b, _ease(t)))
	# The ends are exact whatever the easing rounds to.
	path[0] = a
	path[steps] = b
	return path


## Where along `path` the cursor is at `t` (0 = start, 1 = end), between
## points included, for drawing it at any frame rate.
static func at(path: PackedVector2Array, t: float) -> Vector2:
	if path.is_empty():
		return Vector2.ZERO
	if path.size() == 1 or t <= 0.0:
		return path[0]
	if t >= 1.0:
		return path[path.size() - 1]
	var pos := t * float(path.size() - 1)
	var i := int(floor(pos))
	return path[i].lerp(path[i + 1], pos - float(i))


## The path as the helper reads it: "x,y;x,y;…" with whole pixels.
static func encode(path: PackedVector2Array) -> String:
	var parts := PackedStringArray()
	for p in path:
		parts.append("%d,%d" % [roundi(p.x), roundi(p.y)])
	return ";".join(parts)


## Smooth start and stop (0 → 1, flat at both ends).
static func _ease(t: float) -> float:
	return t * t * (3.0 - 2.0 * t)
