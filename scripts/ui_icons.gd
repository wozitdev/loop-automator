extends RefCounted
class_name UiIcons
## Small glyphs for icon buttons and list rows, rendered from SVG at runtime
## so the project needs no imported images (the keyboard glyph lives in
## KeyCapture.icon()). Every glyph is 16 px tall and drawn in the same light
## grey, so a row of them reads as one set.

const INK := "#e6e6e6"

## A trash can: lid with a handle, tapered body, two slots.
const TRASH_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<g fill="#e6e6e6"><rect x="5" y="0.5" width="4" height="1.8" rx="0.6"/><rect x="1" y="2.6" width="12" height="1.8" rx="0.6"/>
<rect x="5" y="7.2" width="1.3" height="5.6" rx="0.4"/><rect x="7.7" y="7.2" width="1.3" height="5.6" rx="0.4"/></g>
<path d="M2.6 5.6 L3.4 14.3 Q3.5 15.2 4.4 15.2 L9.6 15.2 Q10.5 15.2 10.6 14.3 L11.4 5.6 Z" fill="none" stroke="#e6e6e6" stroke-width="1.4" stroke-linejoin="round"/>
</svg>"""

## Two overlapping sheets: the back one outlined, the front one filled.
const DUPLICATE_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<path d="M1.2 11.3 V1.9 Q1.2 0.9 2.2 0.9 H8.6" fill="none" stroke="#e6e6e6" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"/>
<rect x="4.4" y="4.2" width="8.4" height="10.6" rx="1.2" fill="#e6e6e6"/>
</svg>"""

## Save: a floppy disk - the shutter at the top, the label at the bottom.
const SAVE_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<path d="M1.6 1.6 H10.4 L12.4 3.6 V14.4 H1.6 Z" fill="none" stroke="#e6e6e6" stroke-width="1.4" stroke-linejoin="round"/>
<rect x="4" y="1.8" width="5.4" height="3.4" rx="0.5" fill="#e6e6e6"/>
<rect x="3.4" y="8.6" width="7.2" height="5" rx="0.6" fill="#e6e6e6"/>
</svg>"""

## Play: a triangle pointing right.
const PLAY_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<path d="M3 2.2 L12 8 L3 13.8 Z" fill="#e6e6e6" stroke="#e6e6e6" stroke-width="1" stroke-linejoin="round"/>
</svg>"""

## Stop: a square.
const STOP_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<rect x="2.5" y="3" width="10" height="10" rx="1.5" fill="#e6e6e6"/>
</svg>"""

## Arrows: solid triangles pointing left, right, up and down.
const LEFT_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="12" height="16" viewBox="0 0 12 16">
<path d="M9.5 2.5 L2.5 8 L9.5 13.5 Z" fill="#e6e6e6" stroke="#e6e6e6" stroke-width="1" stroke-linejoin="round"/>
</svg>"""
const RIGHT_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="12" height="16" viewBox="0 0 12 16">
<path d="M2.5 2.5 L9.5 8 L2.5 13.5 Z" fill="#e6e6e6" stroke="#e6e6e6" stroke-width="1" stroke-linejoin="round"/>
</svg>"""
## Share: three dots joined by two links.
const SHARE_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<path d="M3.6 8 L10.4 4.2 M3.6 8 L10.4 11.8" fill="none" stroke="#e6e6e6" stroke-width="1.4"/>
<circle cx="11" cy="3.4" r="2.1" fill="#e6e6e6"/>
<circle cx="3" cy="8" r="2.1" fill="#e6e6e6"/>
<circle cx="11" cy="12.6" r="2.1" fill="#e6e6e6"/>
</svg>"""
const UP_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<path d="M2 11.5 L7 4.5 L12 11.5 Z" fill="#e6e6e6" stroke="#e6e6e6" stroke-width="1" stroke-linejoin="round"/>
</svg>"""
const DOWN_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<path d="M2 4.5 L7 11.5 L12 4.5 Z" fill="#e6e6e6" stroke="#e6e6e6" stroke-width="1" stroke-linejoin="round"/>
</svg>"""

## Plus: two bars.
const PLUS_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<g fill="#e6e6e6"><rect x="6" y="2" width="2" height="12" rx="0.7"/><rect x="1" y="7" width="12" height="2" rx="0.7"/></g>
</svg>"""

## Target: a ring with four ticks and a dot (picking a point on screen).
const TARGET_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
<circle cx="8" cy="8" r="5" fill="none" stroke="#e6e6e6" stroke-width="1.4"/>
<g stroke="#e6e6e6" stroke-width="1.4" stroke-linecap="round"><path d="M8 0.8 V3.2"/><path d="M8 12.8 V15.2"/><path d="M0.8 8 H3.2"/><path d="M12.8 8 H15.2"/></g>
<circle cx="8" cy="8" r="1.6" fill="#e6e6e6"/>
</svg>"""

## Dropper: a pipette with its tip at the bottom left (sampling a colour).
const DROPPER_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
<path d="M10.2 1.6 Q11.5 0.3 12.8 1.6 L14.4 3.2 Q15.7 4.5 14.4 5.8 L12.6 7.6 L8.4 3.4 Z" fill="#e6e6e6"/>
<path d="M9.2 4.2 L11.8 6.8 L5.6 13 L3.4 13.6 L2.4 12.6 L3 10.4 Z" fill="none" stroke="#e6e6e6" stroke-width="1.4" stroke-linejoin="round"/>
</svg>"""

## Check and cross: an action or layer that runs / does not run.
const CHECK_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<path d="M2.2 8.6 L5.6 12 L12 4.4" fill="none" stroke="#8fd98f" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>
</svg>"""
const CROSS_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<path d="M3 4 L11 12 M11 4 L3 12" fill="none" stroke="#e08080" stroke-width="2.2" stroke-linecap="round"/>
</svg>"""

## Eye, open and struck through: a layer that is / is not drawn on the overlay.
const EYE_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
<path d="M1.2 8 Q8 -0.5 14.8 8 Q8 16.5 1.2 8 Z" fill="none" stroke="#e6e6e6" stroke-width="1.4" stroke-linejoin="round"/>
<circle cx="8" cy="8" r="2.4" fill="#e6e6e6"/>
</svg>"""
const EYE_OFF_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
<path d="M1.2 8 Q8 -0.5 14.8 8 Q8 16.5 1.2 8 Z" fill="none" stroke="#8a8a8a" stroke-width="1.4" stroke-linejoin="round"/>
<circle cx="8" cy="8" r="2.4" fill="#8a8a8a"/>
<path d="M2.5 14 L13.5 2" fill="none" stroke="#e08080" stroke-width="1.8" stroke-linecap="round"/>
</svg>"""

## Record: a dot, white so the Rec button can tint it (grey, or red while
## recording).
const RECORD_SVG := """<svg xmlns="http://www.w3.org/2000/svg" width="14" height="16" viewBox="0 0 14 16">
<circle cx="7" cy="8" r="4.5" fill="#ffffff"/>
</svg>"""

static var _cache: Dictionary = {}


## The trash-can icon for every "delete" button.
static func trash() -> Texture2D:
	return _icon("trash", TRASH_SVG)


## The two-sheets icon for every "duplicate" button. (Not `duplicate()`:
## called on the script itself that is `Resource.duplicate()`, which
## clones the script.)
static func copy() -> Texture2D:
	return _icon("copy", DUPLICATE_SVG)


static func save() -> Texture2D:
	return _icon("save", SAVE_SVG)


static func play() -> Texture2D:
	return _icon("play", PLAY_SVG)


static func stop() -> Texture2D:
	return _icon("stop", STOP_SVG)


static func left() -> Texture2D:
	return _icon("left", LEFT_SVG)


static func right() -> Texture2D:
	return _icon("right", RIGHT_SVG)


static func share() -> Texture2D:
	return _icon("share", SHARE_SVG)


static func up() -> Texture2D:
	return _icon("up", UP_SVG)


static func down() -> Texture2D:
	return _icon("down", DOWN_SVG)


static func plus() -> Texture2D:
	return _icon("plus", PLUS_SVG)


static func target() -> Texture2D:
	return _icon("target", TARGET_SVG)


static func record() -> Texture2D:
	return _icon("record", RECORD_SVG)


static func dropper() -> Texture2D:
	return _icon("dropper", DROPPER_SVG)


static func check() -> Texture2D:
	return _icon("check", CHECK_SVG)


static func cross() -> Texture2D:
	return _icon("cross", CROSS_SVG)


static func eye() -> Texture2D:
	return _icon("eye", EYE_SVG)


static func eye_off() -> Texture2D:
	return _icon("eye_off", EYE_OFF_SVG)


## The check / cross for `on`.
static func mark(on: bool) -> Texture2D:
	return check() if on else cross()


## A layer row's two marks side by side: runs / does not run, then drawn /
## not drawn on the overlay.
static func layer_marks(enabled: bool, visible: bool) -> Texture2D:
	var key := "layer_%s_%s" % [enabled, visible]
	if not _cache.has(key):
		var img := Image.create(34, 16, false, Image.FORMAT_RGBA8)
		var a := (mark(enabled) as ImageTexture).get_image()
		var b := ((eye() if visible else eye_off()) as ImageTexture).get_image()
		img.blit_rect(a, Rect2i(Vector2i.ZERO, a.get_size()), Vector2i.ZERO)
		img.blit_rect(b, Rect2i(Vector2i.ZERO, b.get_size()), Vector2i(18, 0))
		_cache[key] = ImageTexture.create_from_image(img)
	return _cache[key]


static func _icon(key: String, svg: String) -> Texture2D:
	if not _cache.has(key):
		_cache[key] = _from_svg(svg)
	return _cache[key]


static func _from_svg(svg: String) -> Texture2D:
	var img := Image.new()
	if img.load_svg_from_string(svg, 1.0) != OK:
		return null
	return ImageTexture.create_from_image(img)
