# Loop Automator

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Godot 4.7](https://img.shields.io/badge/Godot-4.7-478cbf?logo=godotengine&logoColor=white)](https://godotengine.org)
[![Build](https://github.com/wozitdev/loop-automator/actions/workflows/build.yml/badge.svg)](https://github.com/wozitdev/loop-automator/actions/workflows/build.yml)
[![Latest release](https://img.shields.io/github/v/release/wozitdev/loop-automator)](https://github.com/wozitdev/loop-automator/releases/latest)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

A Godot **4.7** tool for visually building automated **mouse + keyboard loops** —
think a TAS you assemble in a UI — together with an **on-screen overlay** that
draws what each action does (detection rects, click points, movement paths).

The whole project runs as a single, endlessly repeating **loop**. The loop is
split into **layers** so automators can organise it into separate "screens" that
can be flipped through and viewed individually in the overlay.

---

## Download

Prebuilt binaries are on the
[Releases](https://github.com/wozitdev/loop-automator/releases) page:

| Platform | File | Notes |
|----------|------|-------|
| Windows 10/11 (64-bit) | `loop-automator-<version>-windows-x86_64.zip` | The supported platform: real input backend + overlay click-through. |
| Linux (64-bit) | `loop-automator-<version>-linux-x86_64.tar.gz` | Experimental: Safe mode only, overlay behaviour untested. |

Unzip and run `Loop Automator.exe` — nothing to install. Windows SmartScreen may
warn that the app is unrecognised because the binary is not code-signed; choose
**More info → Run anyway**. Every release ships a `SHA256SUMS.txt` so you can
verify what you downloaded.

Prefer running from source? Open the folder in Godot 4.7 and press **F5** — see
[Building](#building).

---

## Core concepts

| Concept    | Meaning |
|------------|---------|
| **Project / Loop** | The full automation. Runs forever, top to bottom, then repeats. |
| **Layer**  | A named group of actions. *All enabled layers run every iteration.* Layers exist purely to organise a loop into flip-through "screens" with their own colour + overlay view. |
| **Action** | One step: Move, Click, Drag, Key, Wait, Pixel Detect, Image Detect, Capture Mouse, or Stop. |

So a loop with `Layer 1` and `Layer 2` runs **Layer 1's actions, then Layer 2's
actions, then repeats** — exactly as described: layer 2 runs in the same loop as
layer 1, just broken out so you can view each layer's visuals separately.

---

## Action types

- **Move** — move the cursor to `(x, y)`; with a duration the cursor travels
  there over that time instead of jumping (`~Duration` adds a little
  hand-like wander on the way; start and end stay exact).
- **Click** — move to `(x, y)` and click Left / Right / Middle.
- **Drag** — press at A, move to B over the duration, release.
- **Key** — send keystrokes. In Live mode this uses the
  [`SendKeys`](https://learn.microsoft.com/dotnet/api/system.windows.forms.sendkeys)
  format, e.g. `abc`, `{ENTER}`, `^c` (Ctrl+C), `%{F4}` (Alt+F4). You can
  type the text by hand, or press the **⌨ button** next to the field: an
  on-screen keyboard opens, and whatever you type on your real keyboard
  while it has the focus — or click on it — is added to the SendKeys text
  shown at the top (`Ctrl+S` → `^s`, `Shift+Tab` → `+{TAB}`, `{` → `{{}`…).
  Nothing touches the Keys field until you press **Send**; **Cancel** (or
  closing the window) drops the capture. The on-screen Shift / Ctrl / Alt
  keys stay pressed for the next key; **Undo** removes the last captured
  key, **Clear** starts from an empty field. The window can be resized - the
  keys scale with it - and the size you leave it at is remembered. The
  Windows key cannot be sent by `SendKeys`, so it is ignored. Check the
  **~Keys** box to type the text one key at a time with random pauses, the
  way a person types, each key held a moment; a combo such as `^c` or
  `+(abc)` stays one press (Ctrl down, `c` pressed and held, Ctrl up).
- **Wait** — pause N milliseconds.
- **Pixel Detect** — look for an expected colour (± tolerance) anywhere in a screen rect.
  The whole rect is scanned (the centre first). **Pick & sample** centres the
  rect on the point you click and reads its colour; **Just sample** reads the
  colour of the point you click without moving the rect. While either is
  picking, a swatch next to the cursor previews the colour under it. Tick
  **Follow Cursor** and the rect is centred on the mouse instead of X / Y — it
  moves with the mouse on the overlay and is scanned wherever the mouse is when
  the action runs. When the colour is *not* found the loop **skips the rest
  of the layer**, or set **If not found** to **Wait till found** and it
  re-checks the same spot on an interval until the colour appears. With **~If
  not found** checked (the default) a Safe run carries on regardless, so the
  whole loop can be walked through. With **~Self** on, a detect may match on
  Loop Automator's own window; off (default) it ignores it. The overlay is
  never read.
- **Image Detect** — look for a small screenshot anywhere in a screen rect: every
  pixel of it within ± tolerance of the screen, at any offset the image fits.
  **Just capture** grabs the area you drag over as the image and leaves the
  rect alone; **Capture & place** also makes that area the rect, so the action
  checks that the image is still right there. Click the thumbnail (or the
  eye) to see the image full size. An image can be up to 512×512 and is
  stored inside the loop file; it must match pixel for pixel — tolerance 0 is
  an exact match, higher lets each pixel's channels differ by up to that much
  — so a change of scale, theme or font breaks the match. An image bigger
  than the rect can never be found; the editor says so under it. Rect,
  **Follow Cursor**, **If not found**, **Wait till found** and **~Self** work
  as for Pixel Detect. The scan runs in the helper, so a whole screen is
  checked in a few tens of milliseconds.
- **Stop** — stop the loop, or **This layer** to just end the current layer's
  pass, when reached. Set **after N passes** to stop only once it has been
  reached that many times (0 = the first time) — a run limiter.
- **Capture Mouse** — **Save** remembers where the mouse is right now; **Load** moves
  it back to the last saved position. There is one saved position per run (it is
  cleared when you press Play). A Load that runs before anything was saved does
  nothing and switches itself off.
  Move, Click and Drag also have a **Captures** checkbox: the action saves the
  mouse position, runs, then moves the mouse back where it was — plus whatever
  you moved it meanwhile, so your own movement is never lost. Handy for
  clicking something without losing your place. On the Windows backend a
  captured action runs as a single helper call, so the cursor is only away for
  a few milliseconds. Tick **Ghost Cursor** too and the real cursor is hidden
  while it works: a ghost cursor (same shape) keeps following your hand and
  the real cursor reappears on it afterwards — so from where you sit the
  cursor never jumps at all.

Every action stores screen coordinates, so the overlay can draw it at the right
place over your other applications.

### Ranges: random values

**Every number can be a min – max range**: X / Y, X2 / Y2, width / height,
durations, waits, the tolerance, and the loop delay in the toolbar. Each
numeric input has a **`~`** in front of it. Click it and the `~` moves
between two inputs — min and max — and each time the action runs, a random
integer between the two is used: a click can land anywhere in a small box,
a wait can vary from pass to pass, a detect rect can wander. Click the `~`
again to collapse the pair back to a single value (the max is dropped and
linked to the min). Editing one end past the other drags the other along,
so min never exceeds max. A loop file that holds a range opens with the
pair expanded.

- **Pick on screen** keeps a range's *width* and re-centres it on the point
  you click: a 20-pixel jitter stays a 20-pixel jitter around the new spot
  (a fixed point simply moves). A dragged **rect** is exact: fixed position
  and size. **Pick & sample** fixes the rect's position so the sampled pixel
  is inside every size the range allows.
- The action list and the overlay show ranges as `min–max`; on the overlay a
  point with a range is drawn at the middle of a dashed box covering where
  it can land, and a Pixel Detect frames the extent every possible rect
  lies in (that whole area stays see-through, so the read is never tinted).
- Loop files from before ranges load unchanged, as fixed values.

### The loop delay

**~Delay ms** in the toolbar is the pause after the loop's last action, before
it starts over. It is also a checkbox: tick it and the same delay is waited
after every action, a fresh random value each time when it is a range — a
quick way to slow a whole loop down without adding a Wait after every step
(the last action's wait then leads into the next round; there is no second
one). Both are saved with the loop.

---

## Using it

1. Run the [downloaded binary](#download), or open the folder in Godot 4.7 and
   press **Run** (F5).
2. Pick a **layer** on the left (add / reorder / rename / duplicate / remove / recolour).
3. Add **actions** in the middle column, edit them on the right.
   - Use the **🎯 Pick on screen** buttons to place a point/rect *interactively*:
     the overlay takes over the screen, you move the mouse to the real target and
     **left-click** to set it (drag for a detection rect). **Right-click / Esc**
     cancels. This replaces the old "grab current mouse" approach, which captured
     the button's own position. While you pick, the builder window moves off-screen so
     the desktop it was covering is visible, and comes back when the pick ends —
     tick **~Edit** (right end of the toolbar) to keep it put. (Lowering is
     unavailable while the game runs embedded in the Godot editor's Game tab;
     turn off *Embed Game on Next Play* there to try it from the editor.)
   - **~Self** (next to ~Edit, off by default) decides whether a running
     loop may interact with Loop Automator itself. Off: clicks and keys that
     would land on this window are skipped, so the loop cannot affect the app
     running it. On: the loop can drive Loop Automator like any other program
     (a feedback loop). The overlay is never a target either way: it is
     click-through, and Pixel Detect never reads what the overlay draws.
4. Toggle **Overlay: ON** to see the visuals drawn full-screen, always on top.
   - The arrow buttons under **Overlay** (or **←/→**, **PgUp/PgDn**, `[` / `]`) flip through
     layers; the toolbar shows the current view (e.g. `View: 2/3 · Layer 2`).
     Flipping also selects that layer for editing.
   - Number keys **1–9** jump straight to a layer.
   - **Show All** (or `\`) toggles drawing every visible layer at once.
5. Choose a **Mode** and press **Run?** (Safe) or **Run!** (Live), or **F5**.

> The status line lives in the **bottom bar**; the toolbar scrolls horizontally
> if the window is too narrow to show every control.

### Hotkeys
| Key | Action |
|-----|--------|
| F5  | Start / stop the loop |
| F8 / Esc | Stop the loop |
| ← / → · PgUp / PgDn · `[` / `]` | Flip to previous / next layer |
| 1–9 | Jump to layer N |
| `\` | Toggle Show All layers |

> Navigation keys are ignored while typing in a text field, so editing names,
> keys, and comments still works normally.

While a loop runs in **Live** mode, **F8 stops it from any
window** — the loop clicks other programs and takes the keyboard focus with
it, so the builder's own hotkeys would not reach it. A small helper holds F8
as a system-wide hotkey for exactly as long as the loop runs (other programs
don't see F8 meanwhile); the status line says whether it is armed. If another
program already owns F8, the status line tells you and F8 / Esc still work
whenever the builder has the focus.

### Loops

The toolbar keeps a stack of loops. **New** starts one: its first layer gets
a random name from the Bible (`Moses`, then `Moses 2` if that is taken), and
**a loop is named after its first layer** — rename or reorder the layers and
the loop's name in the picker follows. The **Loop** picker and the arrows beside it flip
between loops, **Save** writes the current one to its file (a `*` marks
unsaved changes), the two-sheets icon duplicates it as a new, unsaved loop
named `<name> copy`, and the trash icon deletes it, file included. A layer has
the same two icons under the layer list. A loop cannot lose its last layer:
deleting it just tells you so.

**Share** moves loops in and out as `.loop` JSON files: *Import* adds a file
to the stack as a new loop, *Export* writes the current loop out — see
[examples/](examples/) for a starter loop. Before a file is imported you are
shown what it holds — layers, actions, and the text every Key action types —
and what a loop can do; nothing is loaded until you press **Import** (see
[Responsible use](#responsible-use)). Layer names are kept to one line of
printable text, whatever a file holds.

---

## Backends (how input is actually sent)

Godot cannot synthesize OS-wide input on its own, so input is sent through a
pluggable `InputBackend`:

- **Safe** — *default*. Touches nothing on your OS; it only feeds the
  overlay/status so you can design and dry-run a loop safely. Pixel and
  Image Detect still read the real screen (a read touches nothing), so a Safe run takes
  the same turns a Live one would.
- **Live** — *experimental*. Drives the real cursor/keyboard and reads
  screen pixels via a small generated PowerShell helper (`input_helper.ps1`,
  see [Generated helpers](#generated-helpers))
  using `SetCursorPos`, `mouse_event`, `SendKeys`, and `CopyFromScreen`.
  All of it — input actions and screen reads (Pixel / Image Detect, colour sampling,
  cursor position) — goes to one long-running helper process, so an action or
  a check costs a few milliseconds and a follow-cursor Pixel Detect keeps up
  with the mouse (~50 checks/s). The helper starts when you pick Live mode
  (about 1.5 s, in the background); if it ever dies it is restarted on the
  next action.
  Switching the mode while a loop is running
  stops the loop first; a preview never carries on with the real backend.

> For high-speed real automation, replace `WindowsBackend` with a native
> **GDExtension** that implements the same `InputBackend` API — nothing else in
> the app needs to change.

---

## Project layout

```
.github/workflows/build.yml # CI: headless exports on every push/PR, draft releases on tags
export_presets.cfg         # Godot export presets (Windows Desktop, Linux)
project.godot              # autoloads, renderer, transparency + native-subwindow settings
icon.svg
scenes/
  main.tscn                # builder window (UI built in code)
  overlay.tscn             # transparent overlay Window
scripts/
  main.gd                  # the builder GUI
  overlay.gd               # overlay Window: borderless, on-top, click-through
  overlay_canvas.gd        # draws rects / points / paths / current action
  capture_hole.gdshader    # keeps sampled pixels transparent so screen reads see the desktop
  overlay_native.gd        # Windows helper: real click-through (WS_EX_LAYERED|TRANSPARENT)
  powershell_host.gd       # runs the generated PowerShell helpers (full path, rewritten per launch)
  pick_overlay.gd          # interactive full-screen window for "Pick on screen"
  key_capture.gd           # on-screen keyboard that captures keys as SendKeys text
  ui_icons.gd              # the trash-can and duplicate glyphs for icon buttons (SVG, rendered at runtime)
  autoload/
    project_data.gd        # current project + selection state + signals + IO
    playback_engine.gd     # the endless loop runner
  model/
    loop_action.gd         # one step (+ JSON)
    loop_layer.gd          # a layer of actions (+ JSON)
    loop_project.gd        # the whole loop (+ JSON)
    layer_names.gd         # random Bible names for a new loop's first layer
  input/
    input_backend.gd       # backend interface
    preview_backend.gd     # safe, no-OS backend
    windows_backend.gd     # experimental real Windows input
    stop_hotkey.gd         # system-wide F8 while a real loop runs
```

## Notes / limitations

- The overlay is a native borderless, always-on-top, transparent, click-through
  window. `display/window/subwindows/embed_subwindows` is **off** so child
  `Window` nodes become real OS windows.
- Per-pixel transparency requires
  `display/window/per_pixel_transparency/allowed = true` (already set) **and a
  renderer that can composite transparent windows**. On Windows the Forward+ and
  Mobile (Vulkan) renderers usually can't (the overlay shows up as an opaque
  black window), so the project runs on the **Compatibility** renderer. If you
  switch renderers and the overlay goes black, that's why — the status line
  will tell you.
- Godot's `Window.FLAG_MOUSE_PASSTHROUGH` only lets clicks through to windows of
  the *same application*. On Windows the overlay therefore applies the real
  thing (`WS_EX_LAYERED | WS_EX_TRANSPARENT`) through a small generated
  PowerShell helper (`overlay_helper.ps1`) right after it is shown; the
  status line / overlay HUD report when click-through is active. On other
  platforms the Godot flag is used as-is. A companion watchdog
  (`overlay_watchdog.ps1`) notes any later loss of the topmost / click-through
  styles in `user://logs/overlay_watchdog.log` — window *classes* only, never
  window titles, and the log is capped at 256 KB (one older copy is kept).
- "Pick on screen" uses a separate, *non*-click-through window so the click that
  places a point or rect is captured and never reaches the program underneath.
- The real Windows backend is best-effort; a GDExtension is the path to fast,
  robust global input.

### Generated helpers

Everything that touches the OS goes through small PowerShell scripts the app
writes itself (`input_helper.ps1`, `overlay_helper.ps1`,
`overlay_watchdog.ps1`, `stop_hotkey.ps1`). They live in the local profile,
`%LOCALAPPDATA%\Godot\app_userdata\Loop Automator\`, and are rewritten from
the built-in text immediately before every launch, so what runs is always the
copy this build generated — editing them has no effect. `powershell.exe` is
always started by its full `System32` path. Action data never becomes script
text: the helpers take numbers, and the Key text travels base64-encoded as a
single argument.

---

## Building

Development needs no build step — open the project in Godot 4.7 and press F5.
Binaries are produced by Godot's headless exporter from the presets in
`export_presets.cfg` (single-file builds with the PCK embedded):

```sh
godot --headless --import
godot --headless --export-release "Windows Desktop" "build/Loop Automator.exe"
godot --headless --export-release "Linux" build/loop-automator.x86_64
```

The matching **export templates** must be installed (Editor → Manage Export
Templates). With [rcedit](https://github.com/electron/rcedit) on your `PATH`
(or set in Editor Settings → Export → Windows) the Windows exe also gets the
project icon and version info.

### Releases

[GitHub Actions](.github/workflows/build.yml) exports both platforms on every
push and pull request; the builds hang off the workflow run as artifacts.
Pushing a version tag turns a build into a release:

```sh
git tag v1.0.0
git push origin v1.0.0
```

The workflow stamps the version into the build, packages the archives plus
`SHA256SUMS.txt`, and creates a **draft** GitHub Release. Download and test the
binaries, then press *Publish release* on GitHub to make them public. Tags with
a suffix (`v1.1.0-rc1`) are marked as pre-releases.

## Contributing

Contributions are very welcome — especially native input backends, new action
types, and cross-platform testing. See [CONTRIBUTING.md](CONTRIBUTING.md) to
get started.

## Responsible use

Loop Automator sends real mouse/keyboard input when a real backend is selected.
Use it only on systems and software you're permitted to automate; automating
online games or third-party services may violate their terms of service.

**Treat `.loop` files like scripts.** In Live mode a loop can type
anything (`SendKeys` text) and click anywhere, which is enough to open a
terminal and run commands — so a loop from someone else deserves the same
caution as a script from them. Open it, read its Key actions (the action
list shows their full text), and dry-run it in **Safe** mode before
you ever run it Live. The app keeps you in control either way: it starts in
Safe, switches back to Safe whenever a Live run stops, locks the
editor while a loop runs Live, and **F8 stops a Live loop from any
window**.

## License

[MIT](LICENSE) © 2026 wozitdev

