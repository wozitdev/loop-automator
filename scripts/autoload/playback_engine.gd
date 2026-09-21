extends Node
## Autoload that runs the project as an endless loop, driving the active
## InputBackend. Uses awaited timers so it never blocks the UI thread.

## Preload constants (see project_data.gd) so this autoload resolves its types
## without relying on the global `class_name` registry, which may not be ready
## when autoloads first compile.
const InputBackendT := preload("res://scripts/input/input_backend.gd")
const PreviewBackendT := preload("res://scripts/input/preview_backend.gd")
const WindowsBackendT := preload("res://scripts/input/windows_backend.gd")
const StopHotkeyT := preload("res://scripts/input/stop_hotkey.gd")
const LoopActionT := preload("res://scripts/model/loop_action.gd")
const LoopProjectT := preload("res://scripts/model/loop_project.gd")
const LoopLayerT := preload("res://scripts/model/loop_layer.gd")
const MousePathT := preload("res://scripts/model/mouse_path.gd")
const KeyStrokesT := preload("res://scripts/model/key_strokes.gd")

signal playback_started
signal playback_stopped
signal status(message: String)
## Emitted right before each action runs so the UI/overlay can highlight it.
signal action_executing(layer_index: int, action_index: int)
## Emitted whenever the execution tracker head changes.
signal tracker_changed(global_pos: Vector2i, visible: bool, label: String)
## The global F8 was pressed while no loop was running (~F8): the builder
## starts one, as its Run button would.
signal hotkey_pressed

enum BackendKind { PREVIEW, WINDOWS }

var is_running: bool = false
var backend: InputBackendT
var current_layer_index: int = -1
var current_action_index: int = -1
var tracker_pos: Vector2i = Vector2i.ZERO
var tracker_visible: bool = false
var tracker_label: String = ""
## ~Self: with it off (default) clicks and keys that would land on Loop
## Automator's own windows are skipped, so a loop cannot drive the app that
## runs it. With it on the loop may interact with Loop Automator like any
## other program.
var feedback: bool = false
## The rect a Pixel / Image Detect is about to read (valid while
## `detect_rect_pinned`). A follow-cursor rect moves with the mouse; the
## overlay keeps its see-through hole on *this* rect while the read happens,
## so the guides it draws around the rect never end up in the screen read.
var detect_rect: Rect2i = Rect2i()
var detect_rect_pinned: bool = false
## What the action that just ran reported (a detect's result), kept on
## the status line through the delay that follows it, so the delay does not
## hide why the loop is where it is.
var _last_event: String = ""
## Why the last run ended: "Stopped." unless an action or F8 ended it.
var last_stop_reason: String = "Stopped."

# Guard so a stop request issued mid-action breaks out cleanly.
var _generation: int = 0

# The one mouse position remembered by Capture (Save / Load) and by the
# "Captures" option on mouse actions. Cleared whenever playback starts.
var _saved_cursor: Vector2i = Vector2i.ZERO
var _has_saved_cursor: bool = false

# Where the last Pixel / Image Detect found its target (an image's middle),
# for Capture Mouse's Detect. Cleared whenever playback starts.
var _last_hit: Vector2i = Vector2i.ZERO
var _has_last_hit: bool = false

# How many times each STOP action has been reached this run (keyed by the
# action), so "stop after N passes" can count. Cleared when playback starts.
var _stop_counts: Dictionary = {}

# What a Down (or a Hold under way) has left pressed: mouse buttons by
# number (with where they went down), and key presses as {"mods", "keys"} in the
# order they went down. A stop lets go of all of it, so nothing stays stuck
# down after F8.
var _held_buttons: Dictionary = {}
var _held_keys: Array[Dictionary] = []

# The worker thread of a captured action under way (see _execute_captured):
# the helper runs the whole action as one command with the real cursor
# pinned, so a stop ends that command (see _interrupt_helper) rather than
# leaving the user without a mouse until the dwell is over.
var _captured_thread: Thread = null
# The button that action may have down in the helper (-1 for a move): let
# go of at quit if the action was cut short, since the coroutine that does
# it after a stop never resumes once the tree is going.
var _captured_button: int = -1

# Lazily-created real backend used purely for reading screen pixels (so colour
# sampling works even while the active playback backend is Preview).
var _screen_sampler: InputBackendT
# Backends let go of while their helper was still starting (see
# InputBackend.shutdown): each is asked again at the next switch, run or
# quit until it has settled, since its own thread keeps it alive till then.
var _retired: Array = []

## System-wide F8 (~F8): held the whole time the app is open, so a loop
## can be started and stopped from any window (this window's own F8 / Esc
## need the focus, which a loop clicking other programs takes away).
## Polled in _process. With ~F8 off F8 is never taken over.
var _stop_hotkey := StopHotkeyT.new()
## ~F8: the global F8 is held (on) or left to other programs (off).
var global_hotkey: bool = false


func _ready() -> void:
	set_process(false)
	set_backend(BackendKind.PREVIEW)
	# Another loop opened (switched to, created, imported…): the run ends with
	# the loop it was started for. (A Live run locks the builder, so this is
	# what stops a Safe run when the loop is changed under it.) Deferred so
	# the reason lands on the status line after the builder's own refresh.
	ProjectData.project_replaced.connect(func():
		if is_running:
			var gen := _generation
			(func():
				if is_running and gen == _generation:
					stop("Stopped: another loop was opened.")).call_deferred())


func _exit_tree() -> void:
	# Closing the app mid-run: nothing stays pressed, F8 is given back.
	var cut_short := _interrupt_helper()
	_release_held()
	# A captured click or drag cut short had its button down in the helper;
	# after a stop the action's own coroutine lets go of it, but no frame
	# comes now, so it is done here (the call waits for the killed helper to
	# be noticed, then runs on a fresh one).
	if cut_short and _captured_button >= 0 and backend != null:
		backend.release_button(_captured_button)
	_stop_hotkey.stop()
	# The backends end their helpers while the scripts are still loaded: a
	# warm-up thread still running backend code at teardown is a crash.
	if backend != null:
		backend.shutdown(true)
	if _screen_sampler != null:
		_screen_sampler.shutdown(true)
	_sweep_retired(true)
	# The thread of a captured action cut short above has nothing left to
	# do; joined here so it is not destroyed mid-flight.
	if _captured_thread != null:
		_captured_thread.wait_to_finish()
		_captured_thread = null


func _process(_dt: float) -> void:
	if _stop_hotkey.state == StopHotkeyT.State.OFF:
		set_process(false)
		return
	var before: int = _stop_hotkey.state
	if _stop_hotkey.poll():
		if is_running:
			stop("Stopped: F8 pressed.")
		else:
			emit_signal("hotkey_pressed")
		return
	if _stop_hotkey.state == before:
		return
	var running := "Running… " if is_running else ""
	match _stop_hotkey.state:
		StopHotkeyT.State.ARMED:
			if is_running:
				emit_signal("status", "Running… F8 stops the loop from any window.")
			else:
				emit_signal("status", "F8 starts and stops the loop from any window.")
		StopHotkeyT.State.UNAVAILABLE:
			emit_signal("status", "%s(global F8 unavailable: %s — F5 / F8 / Esc work while this window has the focus)" % [running, _stop_hotkey.reason])


## ~F8: the global F8 is registered while the app is open (a start and a
## stop key), or not at all.
func set_global_hotkey(on: bool) -> void:
	global_hotkey = on
	_refresh_hotkey()


## True while the global F8 is held by our helper (~F8 on and F8 was free).
func global_hotkey_armed() -> bool:
	return _stop_hotkey.state == StopHotkeyT.State.ARMED


## Holds the global F8 while ~F8 is on and lets go of it otherwise; a held
## one is left as it is.
func _refresh_hotkey() -> void:
	var wanted := global_hotkey
	if wanted and _stop_hotkey.state == StopHotkeyT.State.OFF:
		_stop_hotkey.start()
	elif not wanted and _stop_hotkey.state != StopHotkeyT.State.OFF:
		_stop_hotkey.stop()
	set_process(_stop_hotkey.state != StopHotkeyT.State.OFF)


## Returns a backend that can actually read screen pixels, or null if none is
## available on this OS. Prefers the active backend when it is real, otherwise
## spins up a dedicated (Windows) reader on demand.
func get_screen_sampler() -> InputBackendT:
	if backend != null and backend.is_real():
		return backend
	if OS.get_name() == "Windows":
		if _screen_sampler == null:
			_screen_sampler = WindowsBackendT.new()
		return _screen_sampler
	return null


## Shuts `b` down; one that could not finish at once (its helper still
## starting) is kept in `_retired` and asked again later.
func _retire(b: InputBackendT) -> void:
	b.shutdown()
	if not b.settled():
		_retired.append(b)


## Asks every retired backend to finish shutting down (joining a thread that
## has ended) and forgets the settled ones; with `wait`, all of them settle.
func _sweep_retired(wait: bool = false) -> void:
	for i in range(_retired.size() - 1, -1, -1):
		var b: InputBackendT = _retired[i]
		b.shutdown(wait)
		if b.settled():
			_retired.remove_at(i)


## Switches the backend. A running loop is stopped first: it must never carry
## on with a different backend than the one it was started with (a preview
## hot-swapped to Windows would suddenly drive the real mouse).
func set_backend(kind: int) -> void:
	if is_running:
		stop()
	_sweep_retired()
	if backend != null:
		_retire(backend)
	match kind:
		BackendKind.WINDOWS:
			if OS.get_name() == "Windows":
				backend = WindowsBackendT.new()
				# Get the helper process up now, not on the first action.
				backend.warm_up()
			else:
				backend = PreviewBackendT.new()
				emit_signal("status", "Windows backend unavailable on this OS — using Preview.")
		_:
			backend = PreviewBackendT.new()
	_apply_feedback()
	emit_signal("status", "Backend: %s" % backend.backend_name())


func set_feedback(enabled: bool) -> void:
	feedback = enabled
	_apply_feedback()


## How many times a STOP action has been reached so far this run (0 before
## its first reach; the overlay shows it against its "on pass N" threshold).
func stop_pass_count(action) -> int:
	return int(_stop_counts.get(action, 0))


func _apply_feedback() -> void:
	if backend != null:
		backend.avoid_pid = 0 if feedback else OS.get_process_id()


func toggle() -> void:
	if is_running:
		stop()
	else:
		start()


func start() -> void:
	if is_running:
		return
	if ProjectData.project == null or ProjectData.project.layers.is_empty():
		emit_signal("status", "Nothing to run.")
		return
	is_running = true
	_generation += 1
	_has_saved_cursor = false
	_has_last_hit = false
	_sweep_retired()
	_stop_counts.clear()
	_held_buttons.clear()
	_held_keys.clear()
	# A global F8 another program owned last time is tried again for this run.
	if _stop_hotkey.state == StopHotkeyT.State.UNAVAILABLE:
		_stop_hotkey.stop()
	_refresh_hotkey()
	if not backend.is_real():
		# A Safe run still reads the screen for its Pixel Detects: get the
		# reader's helper up now rather than at the first detect.
		var reader := get_screen_sampler()
		if reader != null and reader.has_method("warm_up"):
			reader.call("warm_up")
	emit_signal("playback_started")
	if _stop_hotkey.state == StopHotkeyT.State.ARMED:
		emit_signal("status", "Running… F8 stops the loop from any window.")
	elif backend.is_real() and not global_hotkey:
		emit_signal("status", "Running… (~F8 is off: F8 / Esc stop the loop while this window has the focus)")
	else:
		emit_signal("status", "Running…")
	_run_loop(_generation)


## Ends the run; `reason` is what the status line then says.
func stop(reason: String = "Stopped.") -> void:
	if not is_running:
		return
	is_running = false
	last_stop_reason = reason
	_generation += 1
	_interrupt_helper()
	_release_held()
	_refresh_hotkey()
	current_layer_index = -1
	current_action_index = -1
	detect_rect_pinned = false
	_set_tracker(Vector2i.ZERO, false, "")
	emit_signal("action_executing", -1, -1)
	emit_signal("playback_stopped")
	emit_signal("status", reason)


func _run_loop(gen: int) -> void:
	var project := ProjectData.project
	while is_running and gen == _generation:
		# With the "~" in front of the delay, it is waited after every action;
		# the pass then ends with the last action's wait, not a second one.
		var delayed_after_last := false
		for li in project.layers.size():
			if not is_running or gen != _generation:
				break
			var layer: LoopLayerT = project.layers[li]
			# Enabled, or the solo layer while one is set (see ProjectData).
			if not ProjectData.layer_runs(li):
				continue
			var skip_layer := false
			for ai in layer.actions.size():
				if not is_running or gen != _generation:
					break
				var action: LoopActionT = layer.actions[ai]
				if not action.enabled:
					continue
				current_layer_index = li
				current_action_index = ai
				_last_event = ""
				emit_signal("action_executing", li, ai)
				var result := await _execute_action(action, li, ai)
				if result == LoopActionT.OnFail.STOP_LOOP:
					stop("%s Loop stopped." % _last_event)
					return
				if result == LoopActionT.OnFail.SKIP_LAYER:
					_last_event = _last_event.trim_suffix(".") + ", skipped the rest of \"%s\"." % layer.name
					emit_signal("status", _last_event)
					skip_layer = true
				delayed_after_last = false
				if project.delay_after_each_action and is_running and gen == _generation:
					await _wait_loop_delay(project, gen, "Action delay")
					delayed_after_last = true
				if skip_layer:
					break
			if skip_layer:
				continue
		if not is_running or gen != _generation:
			break
		if not delayed_after_last:
			await _wait_loop_delay(project, gen, "Loop delay")
		# One frame per pass whatever the delay: a pass with nothing to wait
		# for (no actions, or instant ones with a 0 ms delay) would otherwise
		# spin without ever letting a frame - or a stop - through.
		await get_tree().process_frame
	# Loop ended naturally (only happens if stopped).


## Waits one (rolled) loop delay, shown on the tracker and the status line
## as `what` (after what the last action reported, if it reported anything);
## nothing happens when the delay is 0.
func _wait_loop_delay(project: LoopProjectT, gen: int, what: String) -> void:
	var delay := project.roll_loop_delay_ms()
	if delay <= 0:
		return
	var text := "%s: %d ms" % [what, delay]
	if not _last_event.is_empty():
		text = "%s %s" % [_last_event, text]
	emit_signal("status", text)
	_set_tracker(tracker_pos, tracker_visible, "DELAY %dms" % delay)
	await _sleep_ms(delay)
	if is_running and gen == _generation:
		emit_signal("status", "Running…")


## Runs one action. Returns LoopAction.OnFail.CONTINUE normally, or a
## different OnFail value to influence the loop (used by the detects).
## `layer_index` / `action_index` locate the action in the project (a Capture
## Load with nothing saved disables itself).
func _execute_action(action: LoopActionT, layer_index: int, action_index: int) -> int:
	# Captures goes with a plain click at a point (a held button put back
	# where the cursor was would be a drag; a click at the cursor goes nowhere).
	if action.captures and LoopActionT.supports_captures(action.type) \
			and (action.type != LoopActionT.Type.CLICK or (action.press_mode == LoopActionT.PressMode.TAP and action.move_to)):
		await _execute_captured(action)
		return LoopActionT.OnFail.CONTINUE
	# Every numeric setting is a range; each run draws fresh values from it.
	match action.type:
		LoopActionT.Type.MOVE:
			var p := action.roll_point()
			await _travel(_mouse_pos(), p, action.roll_duration_ms(), action.wiggle, "MOVE")
		LoopActionT.Type.CLICK:
			# ~Move: get to the point first (over the duration, like a Move);
			# off, the press is wherever the cursor is.
			var p := _mouse_pos()
			if action.move_to:
				p = action.roll_point()
				var ms := action.roll_duration_ms()
				if ms > 0:
					var gen := _generation
					await _travel(_mouse_pos(), p, ms, action.wiggle, "CLICK")
					if not is_running or gen != _generation:
						return LoopActionT.OnFail.CONTINUE
			if action.press_mode == LoopActionT.PressMode.TAP:
				_set_tracker(p, true, "CLICK")
				if action.move_to:
					backend.click(action.button, p)
				else:
					backend.click_here(action.button)
				_report_skipped(action)
			else:
				await _press_button(action, p)
		LoopActionT.Type.DRAG:
			var p := action.roll_point()
			var p2 := action.roll_point2()
			_set_tracker(p, true, "DRAG START")
			backend.mouse_button(action.button, true, p)
			if backend.last_skipped:
				_report_skipped(action)
			else:
				# The button is always released, a stop mid-drag included.
				await _travel(p, p2, action.roll_duration_ms(), action.wiggle, "DRAG")
				_set_tracker(p2, true, "DRAG END")
				backend.mouse_button(action.button, false, p2)
		LoopActionT.Type.SCROLL:
			# The wheel turns where the cursor is (a Move before it puts it
			# somewhere).
			var n := action.roll_notches()
			var ms := action.roll_duration_ms()
			_set_tracker(_mouse_pos(), true, "SCROLL")
			emit_signal("status", "Scroll %s ×%d over %d ms." % [LoopActionT.scroll_dir_name(action.scroll_dir), n, ms] if ms > 0 else "Scroll %s ×%d." % [LoopActionT.scroll_dir_name(action.scroll_dir), n])
			# The helper spreads the notches over the duration, so it runs off
			# the main thread like a paced key press - in pieces of about
			# TRAVEL_CHUNK_MS, so a stop takes effect between them (the
			# helper cannot be interrupted inside a command).
			var b := backend
			var gap := maxi(12, ms / n)
			var per_chunk := maxi(1, TRAVEL_CHUNK_MS / gap)
			var sent := 0
			var gen := _generation
			while sent < n and is_running and gen == _generation:
				var k := mini(per_chunk, n - sent)
				var thread := Thread.new()
				thread.start(func(): b.scroll(action.scroll_dir, k, k * gap, action.wiggle))
				while thread.is_alive():
					await get_tree().process_frame
				thread.wait_to_finish()
				if b.last_skipped:
					_report_skipped(action)
					break
				sent += k
				if sent < n:
					await _sleep_ms(gap)
		LoopActionT.Type.KEY:
			_set_tracker(tracker_pos, tracker_visible, "KEY")
			if action.press_mode != LoopActionT.PressMode.TAP:
				await _press_keys(action)
			elif action.keys_paced:
				await _type_paced(action)
			else:
				_type_plain(action)
		LoopActionT.Type.WAIT:
			var wait := action.roll_wait_ms()
			emit_signal("status", "Wait: %d ms" % wait)
			_set_tracker(tracker_pos, tracker_visible, "WAIT")
			await _sleep_ms(wait)
		LoopActionT.Type.PIXEL_DETECT, LoopActionT.Type.IMAGE_DETECT:
			var gen := _generation
			var is_image := action.type == LoopActionT.Type.IMAGE_DETECT
			var what := "Image detect" if is_image else "Pixel detect"
			var target := "image" if is_image else "colour"
			var hit := await _detect_once(action, gen)
			# The condition holds when the colour or image is missing — or,
			# with "If found", when it is there. ~Wait re-checks the same spot
			# until it no longer holds (till found / till gone), the ~Timeout
			# runs out, or the loop is stopped; ~Skip then skips the rest of
			# the layer while it still holds. A Safe walk-through does neither
			# — safe_continue carries it on regardless.
			var fires := (hit.x >= 0) == action.if_found
			var walk_through := action.safe_continue and not backend.is_real()
			var wait_mode := action.wait and not walk_through
			var waiting_for := ("the %s to go" % target) if action.if_found else ("the %s" % target)
			var wait_started := Time.get_ticks_msec()
			var wait_limit := action.roll_wait_timeout_ms()
			var timed_out := false
			while wait_mode and fires and is_running and gen == _generation:
				if action.wait_timeout and Time.get_ticks_msec() - wait_started >= wait_limit:
					timed_out = true
					break
				_last_event = "%s: waiting for %s…" % [what, waiting_for]
				emit_signal("status", _last_event)
				_set_tracker(tracker_pos, tracker_visible, "WAIT DETECT")
				await _sleep_ms(action.roll_wait_ms())
				if not is_running or gen != _generation:
					break
				hit = await _detect_once(action, gen)
				fires = (hit.x >= 0) == action.if_found
			if not is_running or gen != _generation:
				return LoopActionT.OnFail.CONTINUE
			var found := hit.x >= 0
			if found:
				# The tracker marks an image at its middle (hit is its corner);
				# that middle is also where Capture Mouse's Detect goes.
				_last_hit = hit + action.image_size() / 2 if is_image else hit
				_has_last_hit = true
				_set_tracker(_last_hit, true, "DETECT")
			if timed_out:
				_last_event = "%s: still %s (timed out)." % [what, "there" if found else "not found"]
			elif found:
				_last_event = "%s: found at (%d, %d)." % [what, hit.x, hit.y]
			else:
				_last_event = "%s: not found." % what
			if fires:
				# ~If: a Safe run walks on regardless.
				if walk_through:
					_last_event = _last_event.trim_suffix(".") + " (Safe: carrying on)."
				elif action.skip:
					emit_signal("status", _last_event)
					return LoopActionT.OnFail.SKIP_LAYER
				else:
					_last_event = _last_event.trim_suffix(".") + ", carrying on."
			emit_signal("status", _last_event)
		LoopActionT.Type.STOP:
			_set_tracker(tracker_pos, tracker_visible, "STOP")
			var count := int(_stop_counts.get(action, 0)) + 1
			_stop_counts[action] = count
			var threshold := maxi(1, action.stop_after)
			if count < threshold:
				emit_signal("status", "Stop action: pass %d of %d." % [count, threshold])
			elif action.stop_scope == LoopActionT.StopScope.LAYER:
				_last_event = "Stop action"
				return LoopActionT.OnFail.SKIP_LAYER
			else:
				var reason := "Stopped by a Stop action."
				if threshold > 1:
					reason = "Stopped by a Stop action (after %d passes)." % threshold
				stop(reason)
				return LoopActionT.OnFail.CONTINUE
		LoopActionT.Type.CAPTURE:
			match action.capture_mode:
				LoopActionT.CaptureMode.SAVE:
					if _save_cursor():
						emit_signal("status", "Capture: saved mouse position (%d, %d)" % [_saved_cursor.x, _saved_cursor.y])
					else:
						emit_signal("status", "Capture: could not read the mouse position")
				LoopActionT.CaptureMode.LOAD:
					if _has_saved_cursor:
						await _travel(_mouse_pos(), _saved_cursor, action.roll_duration_ms(), action.wiggle, "CAPTURE LOAD")
						emit_signal("status", "Capture: moved to saved position (%d, %d)" % [_saved_cursor.x, _saved_cursor.y])
					else:
						# Nothing to go back to: do nothing and switch the action off so
						# it stops being attempted every iteration.
						emit_signal("status", "Capture: nothing saved yet — action disabled.")
						ProjectData.disable_action(layer_index, action_index)
				LoopActionT.CaptureMode.DETECT:
					# The last detect's spot. Nothing found yet is not a fault
					# of the action (the detect may find next pass): carry on.
					if _has_last_hit:
						await _travel(_mouse_pos(), _last_hit, action.roll_duration_ms(), action.wiggle, "CAPTURE DETECT")
						emit_signal("status", "Capture: moved to the last detect's spot (%d, %d)" % [_last_hit.x, _last_hit.y])
					else:
						emit_signal("status", "Capture: no detect has found anything yet.")
	return LoopActionT.OnFail.CONTINUE


## Status line for an input action the backend refused because it would have
## landed on Loop Automator itself (~Self off).
func _report_skipped(action: LoopActionT) -> void:
	if backend.last_skipped:
		emit_signal("status", "%s skipped: it would land on Loop Automator (turn on ~Self to allow that)." % LoopActionT.type_name(action.type))


## A Click set to Hold, Down or Up at `p`: the button goes down and is
## remembered as held (so a stop lets go of it), a Hold sleeps its time and
## lets go, an Up lets go. With ~Move off it all happens where the cursor is
## (`p`), without a move. The button's name is what the status line says.
func _press_button(action: LoopActionT, p: Vector2i) -> void:
	var name := LoopActionT.button_name(action.button)
	if action.press_mode == LoopActionT.PressMode.UP:
		_set_tracker(p, true, "UP")
		if action.move_to:
			backend.mouse_button(action.button, false, p)
		else:
			backend.button_here(action.button, false)
		# Refused by ~Self (it would land on this app): still held, so the
		# stop lets go of it where it went down.
		if not backend.last_skipped:
			_held_buttons.erase(action.button)
		_report_skipped(action)
		return
	var hold := action.press_mode == LoopActionT.PressMode.HOLD
	_set_tracker(p, true, "HOLD" if hold else "DOWN")
	if action.move_to:
		backend.mouse_button(action.button, true, p)
	else:
		backend.button_here(action.button, true)
	if backend.last_skipped:
		_report_skipped(action)
		return
	_held_buttons[action.button] = p
	if not hold:
		emit_signal("status", "%s button down." % name)
		return
	var ms := action.roll_hold_ms()
	emit_signal("status", "%s button held %d ms." % [name, ms])
	var gen := _generation
	await _sleep_ms(ms)
	# A stop meanwhile has let go already. The release is where the cursor
	# is now (the user may have moved it), not a jump back to the point.
	if gen == _generation and _held_buttons.has(action.button):
		backend.release_button(action.button)
		_held_buttons.erase(action.button)


## A Key set to Hold, Down or Up: its text read as presses (see
## KeyStrokes: "^c" is Ctrl and c, "(wa)" is w and a), each pressed and
## remembered as held, or let go of. A Hold sleeps its time and lets go
## of what it pressed. A stroke a press cannot express (an unknown name, a
## group too long for one helper command) is typed once on the way down and
## ignored on the way up.
func _press_keys(action: LoopActionT) -> void:
	var presses: Array = []
	var typed := PackedStringArray()
	for stroke in KeyStrokesT.split(action.keys):
		var press := KeyStrokesT.parse(stroke)
		if press.is_empty() or (press["keys"] as PackedStringArray).size() > KEY_GROUP_MAX:
			typed.append(stroke)
		else:
			presses.append({"mods": press["mods"], "keys": press["keys"]})
	if action.press_mode == LoopActionT.PressMode.UP:
		_set_tracker(tracker_pos, tracker_visible, "KEY UP")
		presses.reverse()
		for press in presses:
			backend.press_keys(press["mods"], press["keys"], false)
			_forget_held(press)
		emit_signal("status", "Keys up: \"%s\"." % action.keys)
		return
	var hold := action.press_mode == LoopActionT.PressMode.HOLD
	_set_tracker(tracker_pos, tracker_visible, "KEY HOLD" if hold else "KEY DOWN")
	for press in presses:
		backend.press_keys(press["mods"], press["keys"], true)
		if backend.last_skipped:
			_report_skipped(action)
			return
		_held_keys.append(press)
	if not typed.is_empty():
		backend.send_keys("".join(typed))
		emit_signal("status", "Keys down: \"%s\" (\"%s\" cannot be held, typed instead)." % [action.keys, "".join(typed)])
	if not hold:
		if typed.is_empty():
			emit_signal("status", "Keys down: \"%s\"." % action.keys)
		return
	var ms := action.roll_hold_ms()
	emit_signal("status", "Keys held %d ms: \"%s\"." % [ms, action.keys])
	var gen := _generation
	await _sleep_ms(ms)
	# A stop meanwhile has let go already.
	if gen != _generation:
		return
	presses.reverse()
	for press in presses:
		if _held_index(press) >= 0:
			backend.press_keys(press["mods"], press["keys"], false)
			_forget_held(press)


## Where `press` (a {"mods", "keys"}) sits in the held list, or -1.
func _held_index(press: Dictionary) -> int:
	for i in range(_held_keys.size() - 1, -1, -1):
		if _held_keys[i]["mods"] == press["mods"] and _held_keys[i]["keys"] == press["keys"]:
			return i
	return -1


## Drops `press` (a {"mods", "keys"} that was let go of) from the held list.
func _forget_held(press: Dictionary) -> void:
	var i := _held_index(press)
	if i >= 0:
		_held_keys.remove_at(i)


## A captured action still running in the helper is cut short, so the
## mouse is the user's again at once. Before _release_held: that call waits
## for the helper, which would otherwise be the rest of the dwell. Returns
## whether there was one to cut short.
func _interrupt_helper() -> bool:
	if _captured_thread != null and _captured_thread.is_alive() and backend != null:
		backend.interrupt()
		return true
	return false


## Lets go of every button and key a Down left pressed (keys in the reverse
## order they went down), so a stop never leaves something stuck.
func _release_held() -> void:
	if backend == null:
		return
	for b in _held_buttons.keys():
		backend.release_button(b)
	_held_buttons.clear()
	while not _held_keys.is_empty():
		var press: Dictionary = _held_keys.pop_back()
		backend.press_keys(press["mods"], press["keys"], false)


## A mouse action with "Captures": the backend remembers the cursor, performs
## the action and puts the cursor back as one unit, keeping the user's own
## movement meanwhile (with "Ghost Cursor" a stand-in cursor follows the user
## while the real one is hidden). The saved position also lands in the
## Capture slot. Runs on a worker thread so a long dwell / drag does not
## freeze the UI.
func _execute_captured(action: LoopActionT) -> void:
	var from := action.roll_point()
	var to := action.roll_point2()
	var kind := "move"
	var ms := action.roll_duration_ms()
	# The travel the duration is spent on: a move gets there from where the
	# cursor is, a drag goes from its first point to its second.
	var path := MousePathT.make(_mouse_pos(), from, ms, action.wiggle)
	match action.type:
		LoopActionT.Type.CLICK:
			kind = "click"
		LoopActionT.Type.DRAG:
			kind = "drag"
			path = MousePathT.make(from, to, ms, action.wiggle)
	var label := kind.to_upper() + " ↩"
	_set_tracker(from, true, label)
	var b := backend
	var gen := _generation
	var thread := Thread.new()
	# The helper runs the whole action as one command, the real cursor
	# pinned to its point the whole time. A stop meanwhile cuts the command
	# short (see stop): the user has the mouse back at once, not when the
	# dwell is over.
	_captured_thread = thread
	_captured_button = -1 if kind == "move" else action.button
	thread.start(func() -> Array:
		return b.run_captured(kind, action.button, from, to, ms, action.ghost_cursor, path))
	# The tracker walks the path while the helper moves the real cursor.
	var started := Time.get_ticks_msec()
	while thread.is_alive():
		if ms > 0 and is_running and gen == _generation:
			_set_tracker(Vector2i(MousePathT.at(path, float(Time.get_ticks_msec() - started) / float(ms)).round()), true, label)
		await get_tree().process_frame
	var result: Array = thread.wait_to_finish()
	_captured_thread = null
	_captured_button = -1
	if result.size() != 2:
		if gen != _generation:
			# Cut short: the helper was ended mid-action, so a button it had
			# pressed (a click's, a drag's) is let go of here - off the main
			# thread, since the first command after a kill starts a fresh
			# helper (a second or so).
			if kind != "move":
				var release := Thread.new()
				release.start(func(): b.release_button(action.button))
				while release.is_alive():
					await get_tree().process_frame
				release.wait_to_finish()
		elif b.last_skipped:
			_report_skipped(action)
		else:
			emit_signal("status", "%s: could not capture the mouse position" % LoopActionT.type_name(action.type))
		return
	_saved_cursor = result[0]
	_has_saved_cursor = true
	_set_tracker(result[1], true, "RESTORE")


## ~Keys: the pause between two keystrokes, and the longer one a hand
## makes now and then (one keystroke in KEY_PAUSE_LONG_EVERY, on average).
const KEY_PAUSE_MIN_MS := 40
const KEY_PAUSE_MAX_MS := 160
const KEY_PAUSE_LONG_MIN_MS := 200
const KEY_PAUSE_LONG_MAX_MS := 420
const KEY_PAUSE_LONG_EVERY := 9
## ~Keys: how a press goes. Modifiers down, then the key after KEY_LEAD
## (Ctrl … c), held KEY_HOLD, and the modifiers up KEY_TRAIL after it.
const KEY_LEAD_MIN_MS := 30
const KEY_LEAD_MAX_MS := 70
const KEY_HOLD_MIN_MS := 35
const KEY_HOLD_MAX_MS := 95
const KEY_TRAIL_MIN_MS := 20
const KEY_TRAIL_MAX_MS := 60
## A group "(abc…)" longer than this is one helper call too long to stop;
## SendKeys sends it instead.
const KEY_GROUP_MAX := 32


## How long a key SendKeys cannot send (see KeyStrokes.EXTRA) is held when
## the plain typing taps it.
const EXTRA_TAP_MS := 30


## Types a Key action's text the plain way: SendKeys gets it as it is. A
## few keys SendKeys cannot send ({SUPER}, a lone {CTRL}, the $ Win prefix -
## see KeyStrokes.EXTRA), so a text with one is cut around those strokes: the
## stretches between them go to SendKeys, each such stroke (with its ^ + %
## modifiers, if any) is one press by the helper, in order.
func _type_plain(action: LoopActionT) -> void:
	var runs: Array = []   # Strings for SendKeys, presses for the helper
	var plain := ""
	for stroke in KeyStrokesT.split(action.keys):
		var press := KeyStrokesT.parse(stroke)
		if not KeyStrokesT.helper_only(press):
			plain += stroke
			continue
		if not plain.is_empty():
			runs.append(plain)
			plain = ""
		for r in press["repeat"]:
			runs.append(press)
	if runs.is_empty():
		# Nothing SendKeys cannot send: the text goes as written, untouched.
		backend.send_keys(action.keys)
		_report_skipped(action)
		return
	if not plain.is_empty():
		runs.append(plain)
	for run in runs:
		if run is String:
			backend.send_keys(run)
		else:
			backend.hold_keys(run["mods"], run["keys"], 0, EXTRA_TAP_MS, 0, 0)
		if backend.last_skipped:
			_report_skipped(action)
			return


## Types a Key action's text one keystroke at a time (see KeyStrokes.split:
## a combo stays one keystroke), each press with real timing — Ctrl goes
## down, c is pressed and held a moment, Ctrl comes up — and a random pause
## between presses, the way typing goes. A stroke the helper cannot press
## key by key goes through SendKeys as it is. A stop ends the typing
## between strokes.
func _type_paced(action: LoopActionT) -> void:
	var gen := _generation
	var b := backend
	# One entry per press: a repeated key ("{ENTER 3}") is three presses, so
	# a stop lands between them and each gets its own timing.
	var presses: Array = []
	for stroke in KeyStrokesT.split(action.keys):
		var press := KeyStrokesT.parse(stroke)
		if press.is_empty() or (press["keys"] as PackedStringArray).size() > KEY_GROUP_MAX:
			presses.append(stroke)   # SendKeys sends it as it is
		else:
			for r in press["repeat"]:
				presses.append(press)
	for i in presses.size():
		if not is_running or gen != _generation:
			return
		var press: Variant = presses[i]
		# The helper blocks for the whole press, so it runs off the main thread.
		var thread := Thread.new()
		if press is String:
			thread.start(func(): b.send_keys(press))
		else:
			var lead := randi_range(KEY_LEAD_MIN_MS, KEY_LEAD_MAX_MS)
			var hold := randi_range(KEY_HOLD_MIN_MS, KEY_HOLD_MAX_MS)
			var gap := randi_range(KEY_PAUSE_MIN_MS, KEY_PAUSE_MAX_MS)
			var trail := randi_range(KEY_TRAIL_MIN_MS, KEY_TRAIL_MAX_MS)
			thread.start(func(): b.hold_keys(press["mods"], press["keys"], lead, hold, gap, trail))
		while thread.is_alive():
			await get_tree().process_frame
		thread.wait_to_finish()
		if b.last_skipped:
			_report_skipped(action)
			return
		if i < presses.size() - 1:
			var pause := randi_range(KEY_PAUSE_MIN_MS, KEY_PAUSE_MAX_MS)
			if randi_range(1, KEY_PAUSE_LONG_EVERY) == 1:
				pause = randi_range(KEY_PAUSE_LONG_MIN_MS, KEY_PAUSE_LONG_MAX_MS)
			await _sleep_ms(pause)


## A move with a duration is sent to the helper in pieces of about this
## long, so a stop takes effect between them (a captured action is one
## helper command and runs to its end).
const TRAVEL_CHUNK_MS := 200


## Moves the cursor from `from` to `to` over `ms` (see MousePath; `wiggle`
## bends the route a little), showing the travel on the tracker as `label`.
## With `ms` 0 it is a jump. A stop ends the travel where the cursor is.
func _travel(from: Vector2i, to: Vector2i, ms: int, wiggle: bool, label: String) -> void:
	var path := MousePathT.make(from, to, ms, wiggle)
	if path.size() <= 2:
		# A jump — or, going nowhere with a duration (a drag held in place),
		# a stay of that long.
		_set_tracker(to, true, label)
		backend.move_to(to)
		if ms > 0:
			await _sleep_ms(ms)
		return
	var gen := _generation
	var started := Time.get_ticks_msec()
	if backend.is_real():
		# The helper steps the real cursor, a piece of the path at a time on
		# a worker thread; the tracker follows the clock meanwhile.
		var b := backend
		var pieces := maxi(1, ceili(float(ms) / float(TRAVEL_CHUNK_MS)))
		var last := 0
		for c in pieces:
			if not is_running or gen != _generation:
				return
			var end := path.size() - 1 if c == pieces - 1 else roundi(float(path.size() - 1) * float(c + 1) / float(pieces))
			var piece := path.slice(last, end + 1)
			var piece_ms := roundi(float(ms) * float(end - last) / float(path.size() - 1))
			last = end
			var thread := Thread.new()
			thread.start(func(): b.move_path(piece, piece_ms))
			while thread.is_alive():
				if is_running and gen == _generation:
					_set_tracker(Vector2i(MousePathT.at(path, float(Time.get_ticks_msec() - started) / float(ms)).round()), true, label)
				await get_tree().process_frame
			thread.wait_to_finish()
	else:
		while true:
			var t := float(Time.get_ticks_msec() - started) / float(ms)
			if t >= 1.0 or not is_running or gen != _generation:
				break
			var p := Vector2i(MousePathT.at(path, t).round())
			backend.move_to(p)
			_set_tracker(p, true, label)
			await get_tree().process_frame
	if is_running and gen == _generation:
		backend.move_to(to)
		_set_tracker(to, true, label)


## Remembers the current mouse position. Returns false (leaving any earlier
## saved position alone) if the backend cannot read it.
func _save_cursor() -> bool:
	var pos := backend.get_cursor_pos()
	if pos == Vector2i(-1, -1):
		return false
	_saved_cursor = pos
	_has_saved_cursor = true
	_set_tracker(pos, true, "CAPTURE SAVE")
	return true


## Most pixels a Pixel Detect scans per check. Bigger rects are sampled on a
## grid instead (every 2nd, 3rd… pixel), which still catches anything larger
## than the step but keeps a whole-screen check well under a second. (An
## Image Detect tries every offset: the compiled scan rules most out on one
## pixel, so a whole screen is still a few ms.)
const DETECT_MAX_SAMPLES := 250000


## Where the mouse is right now, for a follow-cursor detect: the OS cursor
## (read directly, no helper process). A Safe run reads the real screen too,
## so its rect follows the real mouse as well, not the preview's virtual
## cursor (which sits at the origin until a Move) — only where no screen can
## be read at all does the virtual cursor stand in.
func _mouse_pos() -> Vector2i:
	if backend.is_real() or get_screen_sampler() != null:
		return DisplayServer.mouse_get_position()
	return backend.get_cursor_pos()


## One detect read (Pixel or Image): rolls the rect, pins it so the overlay cuts it out
## (two frames — the first drawn with the hole, the second for the desktop
## compositor to show it; one frame leaked 1 read in 100), reads, unpins.
## Returns the hit, or (-1, -1) when not found or the run ended mid-read.
func _detect_once(action: LoopActionT, gen: int) -> Vector2i:
	var rect := action.roll_detect_rect(_mouse_pos())
	# Only what is on a screen can be read: the part of the rect off every
	# display (or a size no screen has - a file can say anything) is left
	# out, rather than asked of the screen reader, which would try to make
	# room for it. Nothing on screen at all is nothing to find.
	var screens := _screen_bounds()
	if screens.has_area():
		rect = rect.intersection(screens)
		if not rect.has_area():
			print("%s detect: the rect is off every screen -> not found" % ("Image" if action.type == LoopActionT.Type.IMAGE_DETECT else "Pixel"))
			return Vector2i(-1, -1)
	detect_rect = rect
	detect_rect_pinned = true
	_set_tracker(rect.get_center(), true, "DETECT")
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_running or gen != _generation:
		detect_rect_pinned = false
		return Vector2i(-1, -1)
	var hit := _find_image(action, rect) if action.type == LoopActionT.Type.IMAGE_DETECT else _find_color(action, rect)
	detect_rect_pinned = false
	return hit


## Looks for `action.color` (± a tolerance rolled from the action's range, per
## channel) anywhere in `rect` (the rect rolled for this run). Returns the
## screen position of the first match, or (-1, -1). The backend checks the
## rect's centre first — it is where "Sample & place" read the colour from —
## then a grid of every step-th pixel. A Safe run reads the real screen too
## (a read touches nothing), through the same reader colour picking uses;
## only where no screen reader exists at all is the colour taken as found,
## so the loop still flows.
func _find_color(action: LoopActionT, rect: Rect2i) -> Vector2i:
	var reader := backend if backend.is_real() else get_screen_sampler()
	if reader == null:
		return rect.get_center()
	# ~Self gates reading Loop Automator's own window, the same as it gates
	# clicks and keys: off (default) a detect ignores pixels on the app's
	# window; on, it may match them. The overlay is never read either way.
	reader.avoid_pid = 0 if feedback else OS.get_process_id()
	var step := maxi(1, int(ceil(sqrt(float(rect.size.x * rect.size.y) / float(DETECT_MAX_SAMPLES)))))
	var tolerance := action.roll_tolerance()
	var result := reader.find_color(rect, action.color, tolerance, step)
	if result.is_empty():
		print("Pixel detect in [%d, %d, %d×%d]: screen read failed (see warning above) -> not found" % [rect.position.x, rect.position.y, rect.size.x, rect.size.y])
		return Vector2i(-1, -1)
	var hit: Vector2i = result["hit"]
	if hit == Vector2i(-1, -1):
		# Logged (user://logs) so a flaky detect can be diagnosed after the fact.
		print("Pixel detect in [%d, %d, %d×%d]: centre read #%s, expected #%s +-%d, no match in rect (step %d) -> not found" % [
			rect.position.x, rect.position.y, rect.size.x, rect.size.y,
			(result["centre"] as Color).to_html(false), action.color.to_html(false), tolerance, step])
	return hit


## Looks for `action`'s template image (every pixel ± a tolerance rolled from
## the action's range, on brightness alone with `ignore_colour`, up to a
## rolled `mismatch` % of its pixels off) anywhere in `rect`, at every offset
## it fits. Returns
## the screen position of its top-left corner at the first match, or
## (-1, -1). Reads through the same reader and ~Self guard as _find_color;
## with no screen reader at all the image is taken as found (Safe on an OS
## without one), so the loop still flows.
func _find_image(action: LoopActionT, rect: Rect2i) -> Vector2i:
	var reader := backend if backend.is_real() else get_screen_sampler()
	if reader == null:
		return rect.position
	var size := action.image_size()
	if size.x == 0:
		print("Image detect in [%d, %d, %d×%d]: no image captured -> not found" % [rect.position.x, rect.position.y, rect.size.x, rect.size.y])
		return Vector2i(-1, -1)
	if size.x > rect.size.x or size.y > rect.size.y:
		print("Image detect in [%d, %d, %d×%d]: the %d×%d image does not fit the rect -> not found" % [
			rect.position.x, rect.position.y, rect.size.x, rect.size.y, size.x, size.y])
		return Vector2i(-1, -1)
	reader.avoid_pid = 0 if feedback else OS.get_process_id()
	var tolerance := action.roll_tolerance()
	var mismatch := action.roll_mismatch()
	var result := reader.find_image(rect, action.image_png, tolerance, action.ignore_colour, mismatch, LoopActionT.IMAGE_EDGE)
	if result.is_empty():
		print("Image detect in [%d, %d, %d×%d]: screen read failed (see warning above) -> not found" % [rect.position.x, rect.position.y, rect.size.x, rect.size.y])
		return Vector2i(-1, -1)
	var hit: Vector2i = result["hit"]
	if hit == Vector2i(-1, -1):
		print("Image detect in [%d, %d, %d×%d]: %d×%d image +-%d (%d%% may be off%s) not in rect -> not found" % [
			rect.position.x, rect.position.y, rect.size.x, rect.size.y, size.x, size.y, tolerance, mismatch,
			", ignore colour" if action.ignore_colour else ""])
	return hit


## The rect every connected display lies in (screen coordinates), or an
## empty rect where there is no display to ask (headless).
static func _screen_bounds() -> Rect2i:
	var count := DisplayServer.get_screen_count()
	if count <= 0:
		return Rect2i()
	var bounds := Rect2i(DisplayServer.screen_get_position(0), DisplayServer.screen_get_size(0))
	for screen in range(1, count):
		bounds = bounds.merge(Rect2i(DisplayServer.screen_get_position(screen), DisplayServer.screen_get_size(screen)))
	return bounds


func _sleep_ms(ms: int) -> void:
	await get_tree().create_timer(maxf(0.001, ms / 1000.0)).timeout


func _set_tracker(pos: Vector2i, visible: bool, label: String) -> void:
	tracker_pos = pos
	tracker_visible = visible
	tracker_label = label
	emit_signal("tracker_changed", tracker_pos, tracker_visible, tracker_label)
