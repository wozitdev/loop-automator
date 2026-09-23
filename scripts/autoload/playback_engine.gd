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

# Where the user's own mouse is, kept apart from where the loop puts the
# cursor: where it was when the run started, plus whatever the user has
# moved it since (see _note_user_motion; a captured action folds in what
# was moved while it ran). Capture Mouse's Mouse goes there. `_loop_cursor`
# is where the loop last left the cursor (valid once `_loop_moved`), so the
# user's movement since is what differs from it.
var _user_cursor: Vector2i = Vector2i.ZERO
var _loop_cursor: Vector2i = Vector2i.ZERO
var _loop_moved: bool = false

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
var _held_keys: Dictionary = {}   # _held_key(press) -> press, in the order they went down

# The worker thread of a captured action under way (see _execute_captured):
# the helper runs the whole action as one command with the real cursor
# pinned, so a stop ends that command (see _interrupt_helper) rather than
# leaving the user without a mouse until the dwell is over.
var _captured_thread: Thread = null
# The button that action may have down in the helper (-1 for a move): let
# go of at quit if the action was cut short, since the coroutine that does
# it after a stop never resumes once the tree is going.
var _captured_button: int = -1
# ...and the backend it went down on.
var _captured_backend: InputBackendT = null
# The worker thread of an Image Detect scan under way, and the backend it
# asked: a scan that allows mismatches on a big rect can take the helper
# many seconds, so it runs off the main thread (F8 and the UI keep working)
# and a stop ends it the way it ends a captured action.
var _detect_thread: Thread = null
var _detect_reader: InputBackendT = null
# Every scan thread not yet joined, the stopped runs' included: joined at
# quit (only the latest is `_detect_thread`).
var _scan_threads: Array[Thread] = []
# Every other worker thread not yet joined (see _start_worker).
var _work_threads: Array[Thread] = []

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
	_interrupt_helper()
	_release_held()
	# A captured click or drag under way (or cut short by a stop just now)
	# may have its button down in the helper; the action's own coroutine
	# would let go of it, but no frame comes now, so it is done here (the
	# call waits for the killed helper to be noticed, then runs on a fresh
	# one). A release of a button that is up changes nothing.
	# On the backend the action ran on: a Live stop has switched to Safe since.
	if _captured_button >= 0 and _captured_backend != null:
		_captured_backend.release_button(_captured_button)
	_stop_hotkey.stop()
	# The backends end their helpers while the scripts are still loaded: a
	# warm-up thread still running backend code at teardown is a crash.
	if backend != null:
		backend.shutdown(true)
	if _screen_sampler != null:
		_screen_sampler.shutdown(true)
	_sweep_retired(true)
	# Worker threads whose coroutines no frame will resume (a captured
	# action cut short above, a piece of typing or travel under way): the
	# backends are shut, so what is left of their work returns at once, and
	# each is joined here so none is destroyed mid-flight.
	for t in _work_threads:
		t.wait_to_finish()
	_work_threads.clear()
	_captured_thread = null
	# Image Detect scans still under way (one per run a stop cut short):
	# joined so none is destroyed mid-flight.
	for t in _scan_threads:
		t.wait_to_finish()
	_scan_threads.clear()
	_detect_thread = null


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
			# Lost in the middle of a Live run (its helper killed or crashed):
			# the run was started counting on F8 from any window - the builder
			# may be minimised out of sight - so it ends here rather than
			# going on driving the mouse and keyboard with no stop key.
			if is_running and before == StopHotkeyT.State.ARMED and backend.is_real():
				stop("Stopped: the global F8 stopped working (%s)." % _stop_hotkey.reason)
				return
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
		_stop_hotkey.set_modifiers(is_running)
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
	# Work of the last run still ending (a helper command a stop cut short,
	# a scan, a release after a cut-off captured click): its coroutine acts
	# when it is done - lets go of a button, unpins a detect rect - and must
	# not do that in the middle of a new run.
	# (Not yet joined, rather than alive: a thread that has just finished
	# still has its coroutine to come back to.)
	if not _work_threads.is_empty() or not _scan_threads.is_empty():
		emit_signal("status", "Still ending the last run - press Run again in a moment.")
		return
	is_running = true
	_generation += 1
	_cursor_unplaced = false
	# F8 with a modifier down stops it too, while it runs (see StopHotkey).
	_stop_hotkey.set_modifiers(true)
	_user_cursor = _mouse_pos()
	_loop_moved = false
	_has_last_hit = false
	_sweep_retired()
	_stop_counts.clear()
	_held_buttons.clear()
	_held_keys.clear()
	backend.keys_refused = false
	# (No worker of the last run is left - see above - so an interrupt it
	# did not spend is nobody's.)
	backend.clear_interrupt()
	var sampler := get_screen_sampler()
	if sampler != null and sampler != backend:
		sampler.clear_interrupt()
	# A global F8 another program owned last time is tried again for this run.
	if _stop_hotkey.state == StopHotkeyT.State.UNAVAILABLE:
		_stop_hotkey.stop()
	_refresh_hotkey()
	# Get the helper up now (on its own thread) rather than at the first
	# action: a Live run's clicks call it from this thread, and one the last
	# stop ended would otherwise be started here, with F8 unread meanwhile.
	# A Safe run still reads the screen for its Pixel Detects.
	var reader := backend if backend.is_real() else get_screen_sampler()
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
	_stop_hotkey.set_modifiers(false)
	last_stop_reason = reason
	_generation += 1
	_interrupt_helper()
	# Interrupted once: a later stop must not interrupt the backend again on
	# behalf of these threads (it would end whatever that run has under way).
	_detect_thread = null
	_detect_reader = null
	_captured_thread = null
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
	# The helper coming up (see start): its first command from this thread
	# (a click) would wait for it here, with F8 unread meanwhile.
	while backend.warming() and is_running and gen == _generation:
		await get_tree().process_frame
	while is_running and gen == _generation:
		# The loop delay leads every pass (the first one too). With the "~" in
		# front of it, it leads every action instead: the first action's is the
		# pass's, so no pass waits twice.
		var ran := 0
		if not project.delay_after_each_action:
			await _wait_loop_delay(project, gen, "Loop delay")
			if not is_running or gen != _generation:
				break
		for li in project.layers.size():
			if not is_running or gen != _generation:
				break
			# A layer deleted during a Safe run (see the action guard below).
			if li >= project.layers.size():
				break
			var layer: LoopLayerT = project.layers[li]
			# Enabled, or the solo layer while one is set (see ProjectData).
			if not ProjectData.layer_runs(li):
				continue
			var skip_layer := false
			for ai in layer.actions.size():
				# A pass of instant actions (clicks, jumps, key downs: helper
				# calls on this thread that await nothing) would otherwise run
				# whole without a frame - and F8 is read once a frame. A frame
				# goes by whenever YIELD_EVERY_MS have passed without one.
				if _frame_due():
					await get_tree().process_frame
				# A helper that died mid-run (a scan that timed out, a crash) is
				# started again on its own thread before the next action, not
				# by that action's first command on this one, with F8 unread.
				if backend.helper_down():
					backend.call("warm_up")
				# (Waited out whoever started it: a command that found the
				# helper down in the last action has already set one going.)
				while backend.warming() and is_running and gen == _generation:
					await get_tree().process_frame
				# No helper to be had: a Live run is not carried on through a
				# process per command on this thread (a second or more each,
				# F8 unread meanwhile).
				if backend.helper_unavailable() and is_running and gen == _generation:
					stop("Stopped: the input helper (PowerShell) could not be started - see the log.")
					return
				if not is_running or gen != _generation:
					break
				# A Safe run leaves the builder open: an action deleted
				# meanwhile makes the layer shorter than when this pass began.
				if ai >= layer.actions.size():
					break
				var action: LoopActionT = layer.actions[ai]
				if not action.enabled:
					continue
				current_layer_index = li
				current_action_index = ai
				_last_event = ""
				emit_signal("action_executing", li, ai)
				ran += 1
				if project.delay_after_each_action:
					await _wait_loop_delay(project, gen, "Action delay")
					if not is_running or gen != _generation:
						break
				_note_user_motion()
				var result := await _execute_action(action)
				# Stopped meanwhile (a long Hold outlived the run): nothing of
				# this run's is noted into the next one's cursor tracking.
				if not is_running or gen != _generation:
					break
				_note_loop_cursor(action)
				# Keys the backend would not send (see WindowsBackend._run_sync):
				# a run that went on clicking without its typing would be a
				# different loop from the one that was read.
				if is_running and gen == _generation and backend.keys_refused:
					stop("Stopped: a Key action could not be typed as written (see the log): the rest of the loop is not run without it.")
					return
				if result == LoopActionT.OnFail.STOP_LOOP:
					stop("%s Loop stopped." % _last_event)
					return
				if result == LoopActionT.OnFail.SKIP_LAYER:
					_last_event = _last_event.trim_suffix(".") + ", skipped the rest of %s." % _quote(layer.name)
					emit_signal("status", _last_event)
					skip_layer = true
				if skip_layer:
					break
			if skip_layer:
				continue
		if not is_running or gen != _generation:
			break
		if ran == 0:
			# Nothing to run (no actions, or none switched on): one pass says
			# so, rather than a loop that runs forever doing nothing.
			stop("Stopped: the loop has no actions to run.")
			return
		# One frame per pass whatever the delay: a pass with nothing to wait
		# for (no actions, or instant ones with a 0 ms delay) would otherwise
		# spin without ever letting a frame - or a stop - through.
		await get_tree().process_frame
	# Loop ended naturally (only happens if stopped).


## How long a run may go without letting a frame through (see _run_loop).
const YIELD_EVERY_MS := 12
var _seen_frame: int = -1
var _frame_at: int = 0


## Whether YIELD_EVERY_MS have passed since the run first saw the frame it
## is in: time for it to let one through.
func _frame_due() -> bool:
	var frame := Engine.get_process_frames()
	var now := Time.get_ticks_msec()
	if frame != _seen_frame:
		_seen_frame = frame
		_frame_at = now
		return false
	return now - _frame_at >= YIELD_EVERY_MS


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
func _execute_action(action: LoopActionT) -> int:
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
			# (Windows would stop the cursor at the nearest screen's edge, and a
			# click or scroll where it is would land there, unseen.)
			if _off_screens(action, [p]):
				# ...nor where it was before: a click or scroll "where the
				# cursor is" after this Move is meant for its point, not for
				# the last action's target. Skipped too, until a point lands.
				_cursor_unplaced = true
				return LoopActionT.OnFail.CONTINUE
			await _travel(_mouse_pos(), p, action.roll_duration_ms(), action.wiggle, "MOVE")
		LoopActionT.Type.CLICK:
			# ~Move: get to the point first (over the duration, like a Move);
			# off, the press is wherever the cursor is.
			var p := _mouse_pos()
			if not action.move_to and _cursor_unplaced and action.press_mode != LoopActionT.PressMode.UP:
				emit_signal("status", "Click skipped: the Move before it was to no screen.")
				return LoopActionT.OnFail.CONTINUE
			if action.move_to:
				p = action.roll_point()
				if _off_screens(action, [p]):
					# An Up is let go of all the same, where the cursor is: the
					# button a Down pressed would otherwise stay down, every
					# later move a drag.
					if action.press_mode == LoopActionT.PressMode.UP and _held_buttons.has(action.button):
						_let_go(action.button)
					# (Nor did the cursor go where this Click meant it to.)
					_cursor_unplaced = true
					return LoopActionT.OnFail.CONTINUE
				_cursor_unplaced = false
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
				# Its up (or the release after it) not carried out: the button
				# may be down - kept as held, and let go of as a Hold's is
				# (tried again, the run stopped if that fails too).
				if backend.last_failed:   # (a refused up whose release failed too included)
					_held_buttons[action.button] = p
					_let_go(action.button)
			else:
				await _press_button(action, p)
		LoopActionT.Type.DRAG:
			var p := action.roll_point()
			var p2 := action.roll_point2()
			if _off_screens(action, [p, p2]):
				return LoopActionT.OnFail.CONTINUE
			_set_tracker(p, true, "DRAG START")
			backend.mouse_button(action.button, true, p)
			if backend.last_skipped:
				_report_skipped(action)
			else:
				# Held while it travels, so a stop mid-drag lets go of it (on
				# the real backend, before a Live run's stop swaps in Safe).
				_held_buttons[action.button] = p
				var gen := _generation
				await _travel(p, p2, action.roll_duration_ms(), action.wiggle, "DRAG")
				if gen == _generation and _held_buttons.has(action.button):
					_set_tracker(p2, true, "DRAG END")
					backend.mouse_button(action.button, false, p2)
					# Refused by ~Self, or not carried out: let go of where the
					# cursor is all the same (never refused), rather than held
					# down for the rest of an endless run.
					if backend.last_skipped or backend.last_failed:
						_report_skipped(action)
						_let_go(action.button)
					else:
						_held_buttons.erase(action.button)
		LoopActionT.Type.SCROLL:
			# The wheel turns where the cursor is (a Move before it puts it
			# somewhere).
			if _cursor_unplaced:
				emit_signal("status", "Scroll skipped: the Move before it was to no screen.")
				return LoopActionT.OnFail.CONTINUE
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
				await _off_thread(func(): b.scroll(action.scroll_dir, k, k * gap, action.wiggle))
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
				await _type_plain(action)
		LoopActionT.Type.WAIT:
			var wait := action.roll_wait_ms()
			emit_signal("status", "Delay: %d ms" % wait)
			_set_tracker(tracker_pos, tracker_visible, "DELAY")
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
				LoopActionT.CaptureMode.MOUSE:
					# Where the user's own mouse is (see _user_cursor).
					var travel_gen := _generation
					await _travel(_mouse_pos(), _user_cursor, action.roll_duration_ms(), action.wiggle, "CAPTURE MOUSE")
					# A stop during the travel has said why, and it did not get there.
					if is_running and travel_gen == _generation:
						emit_signal("status", "Capture: moved to your mouse position (%d, %d)" % [_user_cursor.x, _user_cursor.y])
				LoopActionT.CaptureMode.DETECT:
					# The last detect's spot. Nothing found yet is not a fault
					# of the action (the detect may find next pass): carry on.
					if _has_last_hit:
						var travel_gen := _generation
						await _travel(_mouse_pos(), _last_hit, action.roll_duration_ms(), action.wiggle, "CAPTURE DETECT")
						if is_running and travel_gen == _generation:
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
		# Refused by ~Self (it would land on this app): let go of where the
		# cursor is all the same (never refused) - a button left down for
		# the rest of the run would drag every later action with it.
		_report_skipped(action)
		if (backend.last_skipped or backend.last_failed) and _held_buttons.has(action.button):
			_let_go(action.button)
		else:
			_held_buttons.erase(action.button)
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
		_let_go(action.button)


## A Key set to Hold, Down or Up: its text read as presses (see
## KeyStrokes: "^c" is Ctrl and c, "(wa)" is w and a), each pressed and
## remembered as held, or let go of. A Hold sleeps its time and lets go
## of what it pressed. A stroke a press cannot express (an unknown name, a
## group too long for one helper command) is typed once on the way down and
## ignored on the way up.
func _press_keys(action: LoopActionT) -> void:
	# The run this press belongs to, taken before anything is awaited: a
	# stop (or a new run) during the typed pieces below must not find this
	# coroutine letting go of the next run's keys.
	var gen := _generation
	var presses: Array = []
	var typed := PackedStringArray()
	for stroke in KeyStrokesT.split(action.keys):
		var press := KeyStrokesT.parse(stroke)
		if press.is_empty() or (press["keys"] as PackedStringArray).size() > KEY_GROUP_MAX:
			typed.append(stroke)
		else:
			presses.append({"mods": press["mods"], "keys": press["keys"]})
	# Each press is a helper call on this thread, and each down one to let go
	# of on a stop: a Key Down of thousands of characters would hold the UI
	# (and F8) for as long as they take, twice.
	if presses.size() > KEY_GROUP_MAX:
		stop("Stopped: a Key %s holds %d presses; one holds %d at most." % [
			"Up" if action.press_mode == LoopActionT.PressMode.UP else "Down / Hold", presses.size(), KEY_GROUP_MAX])
		return
	if action.press_mode == LoopActionT.PressMode.UP:
		_set_tracker(tracker_pos, tracker_visible, "KEY UP")
		presses.reverse()
		for press in presses:
			if not _key_up(press):
				return
		emit_signal("status", "Keys up: %s." % _keys_status(action.keys))
		return
	var hold := action.press_mode == LoopActionT.PressMode.HOLD
	_set_tracker(tracker_pos, tracker_visible, "KEY HOLD" if hold else "KEY DOWN")
	# Every press left down is one helper call when the run stops (and at
	# quit): a loop of Key Downs of ever other keys is kept to a list the
	# stop gets through at once.
	var fresh := 0
	for press in presses:
		if not _is_held(press):
			fresh += 1
	if _held_keys.size() + fresh > HELD_KEYS_MAX:
		stop("Stopped: Key Downs would leave more than %d presses held at once." % HELD_KEYS_MAX)
		return
	# A press or a piece refused by ~Self (this app came to the front) ends
	# the pressing and typing, but not the run: a Hold then lets go of what
	# it pressed at once, rather than leaving it down for the rest of it.
	var skipped := false
	for press in presses:
		backend.press_keys(press["mods"], press["keys"], true)
		# Refused or failed (a key the helper could not press): the run ends
		# here (see _run_loop), and its stop lets go of what went down -
		# nothing more is pressed, and no Hold waits out its time first.
		if backend.keys_refused:
			return
		if backend.last_skipped:
			_report_skipped(action)
			skipped = true
			break
		# Once in the list however often it goes down (a Key Down in a
		# loop): the stop's one release lets go of it, and a list that grew
		# every pass would be as many releases, one after another.
		if not _is_held(press):
			_held_keys[_held_key(press)] = press
	if not typed.is_empty() and not skipped and not backend.keys_refused:
		for stroke in typed:
			if skipped:
				break
			# A group too long to hold is typed by the helper, KEY_GROUP_MAX
			# keys to a command; anything else by SendKeys, in pieces.
			var big := KeyStrokesT.parse(stroke)
			var sends: Array[Callable] = []
			if not big.is_empty():
				var keys: PackedStringArray = big["keys"]
				for at in range(0, keys.size(), KEY_GROUP_MAX):
					sends.append(backend.hold_keys.bind(big["mods"], keys.slice(at, at + KEY_GROUP_MAX), 0, EXTRA_TAP_MS, 0, 0))
			else:
				for piece in KeyStrokesT.pieces(stroke, PLAIN_PIECE_BYTES, PLAIN_PIECE_EVENTS):
					sends.append(backend.send_keys.bind(piece))
			for send in sends:
				if not is_running or gen != _generation:
					return
				await _off_thread(send)
				if backend.keys_refused or gen != _generation:
					return
				if backend.last_skipped:
					_report_skipped(action)
					skipped = true
					break
		if not skipped:
			emit_signal("status", "Keys down: %s (%s cannot be held, typed instead)." % [_keys_status(action.keys), _keys_status("".join(typed))])
	if not hold:
		if typed.is_empty() and not skipped:
			emit_signal("status", "Keys down: %s." % _keys_status(action.keys))
		return
	if not skipped:
		var ms := action.roll_hold_ms()
		emit_signal("status", "Keys held %d ms: %s." % [ms, _keys_status(action.keys)])
		await _sleep_ms(ms)
		# A stop meanwhile has let go already.
		if gen != _generation:
			return
	presses.reverse()
	for press in presses:
		if _is_held(press) and not _key_up(press):
			return


## A Key's text as the status line shows it: cut to a line's worth and
## marked as the list shows it (LoopAction.ltr_marked), so it reads in the
## order it types.
static func _keys_status(text: String) -> String:
	# Its start and its end (see LoopAction.describe): what runs last in a
	# long text is as much a part of it as what runs first.
	var shown := text if text.length() <= 60 else text.left(30) + " … " + text.right(27)
	return _quote(LoopActionT.ltr_marked(shown))


## Text from a loop file (a layer's name, a Key's text) as a status line
## quotes it: in JSON's quotes (a quote in it is \") and isolated left to
## right, so it cannot read as the status line's own words ("Stopped: F8
## pressed." inside a layer name) or turn the line around it.
static func _quote(s: String) -> String:
	return char(0x2066) + JSON.stringify(s) + char(0x2069)


## Lets go of `press` and drops it from the held list. A release that does
## not go through ends the run here - its stop tries twice more (the helper
## it failed on is gone by then: a fresh one, or one-shot letting go of
## every key) - rather than going on with a Ctrl or a Shift down under
## every later action. False when it stopped the run.
func _key_up(press: Dictionary) -> bool:
	backend.press_keys(press["mods"], press["keys"], false)
	if not backend.last_failed:
		_forget_held(press)
		return true
	stop("Stopped: a key could not be let go of (see the log).")
	return false


## The key of `press` (a {"mods", "keys"}) in the held list.
static func _held_key(press: Dictionary) -> String:
	return "%s|%s" % [press["mods"], ",".join(press["keys"])]


## Whether `press` is in the held list.
func _is_held(press: Dictionary) -> bool:
	return _held_keys.has(_held_key(press))


## Drops `press` (a {"mods", "keys"} that was let go of) from the held list.
func _forget_held(press: Dictionary) -> void:
	_held_keys.erase(_held_key(press))


## A captured action still running in the helper is cut short, so the
## mouse is the user's again at once. Before _release_held: that call waits
## for the helper, which would otherwise be the rest of the dwell. Returns
## whether there was one to cut short.
func _interrupt_helper() -> bool:
	if _detect_thread != null and _detect_thread.is_alive() and _detect_reader != null:
		_detect_reader.interrupt()
	if _captured_thread != null and _captured_thread.is_alive() and backend != null:
		backend.interrupt()
		return true
	# Typing on a worker (a group of keys, SendKeys' piece): cut short too,
	# or the stop's releases would wait for it - a second or so, or the
	# command's whole timeout if the helper hangs. (The backend lets a path
	# or wheel piece, a moment's work, run out.)
	for t in _work_threads:
		if t.is_alive() and backend != null:
			backend.interrupt()
			break
	return false


## Lets go of `button` where the cursor is; it stays in the held list (for
## the stop to try again) unless that went through.
func _let_go(button: int) -> void:
	# Failing, the run ends here (its stop tries twice more, see
	# _release_held) rather than going on dragging with the button down.
	backend.release_button(button)
	if not backend.last_failed:
		_held_buttons.erase(button)
		return
	stop("Stopped: a mouse button could not be let go of (see the log).")


## Lets go of every button and key a Down left pressed (keys in the reverse
## order they went down), so a stop never leaves something stuck.
func _release_held() -> void:
	if backend == null:
		return
	# Each release that goes unanswered (its helper died on it) is tried
	# once more: the second goes to a fresh helper, or one-shot.
	for b in _held_buttons.keys():
		backend.release_button(b)
		if backend.last_failed:
			backend.release_button(b)
	_held_buttons.clear()
	var order := _held_keys.values()
	_held_keys.clear()
	order.reverse()
	for press in order:
		backend.press_keys(press["mods"], press["keys"], false)
		if backend.last_failed:
			backend.press_keys(press["mods"], press["keys"], false)
			# Failing twice, the rest would too (the second went one-shot,
			# letting go of every key): not a process per key on this thread.
			if backend.last_failed:
				push_warning("Playback: keys could not be let go of at the stop.")
				break


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
	if kind == "click" and _off_screens(action, [from]) or kind == "drag" and _off_screens(action, [from, to]):
		return
	var label := kind.to_upper() + " ↩"
	_set_tracker(from, true, label)
	var b := backend
	var gen := _generation
	# The helper runs the whole action as one command, the real cursor
	# pinned to its point the whole time. A stop meanwhile cuts the command
	# short (see stop): the user has the mouse back at once, not when the
	# dwell is over.
	_captured_button = -1 if kind == "move" else action.button
	_captured_backend = b
	var thread := _start_worker(func() -> Array:
		return b.run_captured(kind, action.button, from, to, ms, action.ghost_cursor, path))
	_captured_thread = thread
	# The tracker walks the path while the helper moves the real cursor.
	var started := Time.get_ticks_msec()
	while thread.is_alive():
		if ms > 0 and is_running and gen == _generation:
			_set_tracker(Vector2i(MousePathT.at(path, float(Time.get_ticks_msec() - started) / float(ms)).round()), true, label)
		await get_tree().process_frame
	var result: Array = _join_worker(thread)
	# Still this action's (a stop has only let go of the thread: no new run
	# starts while this one's workers are alive, see start).
	if _captured_thread == thread or _captured_thread == null:
		_captured_thread = null
		if not (b.last_cut_off and kind != "move"):
			_captured_button = -1
	if result.size() != 2:
		var skipped := gen == _generation and b.last_skipped
		if b.last_cut_off and kind != "move":
			# Cut short by a stop, or timed out and ended: the helper may
			# have died with a click's or a drag's button down (an error
			# answer has let go of it already), so it is let go of here -
			# off the main thread, since the first command after a kill
			# starts a fresh helper (a second or so).
			await _off_thread(func(): b.release_button(action.button))
			# Kept for the quit to try again if that did not go through.
			if not b.last_failed:
				_captured_button = -1
		if gen != _generation:
			pass
		elif skipped:
			_report_skipped(action)
		else:
			emit_signal("status", "%s: could not capture the mouse position" % LoopActionT.type_name(action.type))
		return
	# The cursor is back where it was plus what the user moved meanwhile:
	# that movement is the user's (see _user_cursor).
	_user_cursor += (result[1] as Vector2i) - (result[0] as Vector2i)
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
## ~Keys: a group's keys go to the helper this many to a command (about a
## second at the slowest), so a stop lands within one.
const KEY_PACED_GROUP := 4


## How long a key SendKeys cannot send (see KeyStrokes.EXTRA) is held when
## the plain typing taps it.
const EXTRA_TAP_MS := 30
## The plain typing goes to the helper in pieces of at most this many
## bytes of SendKeys text (cut between keystrokes), each on a worker
## thread: a stop lands between pieces, so F8 ends a long text within a
## moment rather than when SendKeys is done with all of it. SendKeys types
## at some hundreds of characters a second at best, so the pieces are small
## (a piece costs a helper round trip of a millisecond or so).
const PLAIN_PIECE_BYTES := 24
## ...and of at most this many keystrokes: "{ENTER 1000}" is a dozen bytes
## and a thousand presses SendKeys queues at once.
const PLAIN_PIECE_EVENTS := 24
## The most presses Key Downs may leave held at once (see _press_keys).
const HELD_KEYS_MAX := 64


## Runs `work` (a backend call that blocks for as long as the input takes)
## on a worker thread, letting frames - and a stop, F8 above all - through
## meanwhile.
func _off_thread(work: Callable) -> Variant:
	var thread := _start_worker(work)
	while thread.is_alive():
		await get_tree().process_frame
	return _join_worker(thread)


## Starts `work` on a worker thread kept in `_work_threads` until
## _join_worker: a coroutine that never resumes (the app quitting under
## it) leaves its thread to _exit_tree, which joins it rather than letting
## it be destroyed mid-flight.
func _start_worker(work: Callable) -> Thread:
	var thread := Thread.new()
	_work_threads.append(thread)
	# Which thread it was, for its command's outcome to be the caller's
	# after the join (see InputBackend.adopt_flags).
	thread.start(func() -> Array: return [work.call(), OS.get_thread_caller_id()])
	return thread


func _join_worker(thread: Thread) -> Variant:
	var done: Variant = thread.wait_to_finish()
	_work_threads.erase(thread)
	if not (done is Array and (done as Array).size() == 2):
		return null
	InputBackendT.adopt_flags(done[1])
	return done[0]


## Types a Key action's text the plain way: SendKeys gets it as it is. A
## few keys SendKeys cannot send ({SUPER}, a lone {CTRL}, the $ Win prefix -
## see KeyStrokes.EXTRA), so a text with one is cut around those strokes: the
## stretches between them go to SendKeys, each such stroke (with its ^ + %
## modifiers, if any) is one press by the helper, in order. Each stretch
## goes in pieces (see PLAIN_PIECE_BYTES); a stop ends the typing between
## them.
## Each piece and press is sent as it comes (a "{WIN 1000}" is a thousand
## presses, and a text can hold hundreds of those: nothing is built ahead).
func _type_plain(action: LoopActionT) -> void:
	var gen := _generation
	var b := backend
	var plain := ""
	for stroke in KeyStrokesT.split(action.keys):
		var press := KeyStrokesT.parse(stroke)
		# A group of more than KEY_GROUP_MAX keys goes to the helper too, in
		# slices (below): SendKeys would queue all of it at once.
		var big_group := not press.is_empty() and (press["keys"] as PackedStringArray).size() > KEY_GROUP_MAX
		if not KeyStrokesT.helper_only(press) and not big_group:
			if press.is_empty() or int(press["repeat"]) <= PLAIN_PIECE_EVENTS:
				plain += stroke
				continue
			# "{ENTER 1000}" is a few bytes and a thousand presses: it goes as
			# "{ENTER 24}"s, so a stop lands between them.
			if not plain.is_empty():
				if not await _send_plain(action, b, gen, plain):
					return
				plain = ""
			var head := stroke.substr(0, stroke.rfind(" "))
			var left := int(press["repeat"])
			while left > 0:
				var k := mini(left, PLAIN_PIECE_EVENTS)
				if not await _send_plain(action, b, gen, "%s %d}" % [head, k]):
					return
				left -= k
			continue
		if not plain.is_empty():
			if not await _send_plain(action, b, gen, plain):
				return
			plain = ""
		# One helper command per KEY_GROUP_MAX keys at most: a stop lands
		# between commands, and "$(" with hundreds of keys ")" as one would
		# hold the Windows key for as long as they take.
		var keys: PackedStringArray = press["keys"]
		for r in press["repeat"]:
			for at in range(0, keys.size(), KEY_GROUP_MAX):
				if not is_running or gen != _generation:
					return
				await _off_thread(b.hold_keys.bind(press["mods"], keys.slice(at, at + KEY_GROUP_MAX), 0, EXTRA_TAP_MS, 0, 0))
				if not _typed_on(action, b):
					return
	if not plain.is_empty():
		await _send_plain(action, b, gen, plain)


## `plain` to SendKeys in pieces (see PLAIN_PIECE_BYTES), for _type_plain.
## False once the typing is to end: a stop, or a piece not typed.
func _send_plain(action: LoopActionT, b: InputBackendT, gen: int, plain: String) -> bool:
	for piece in KeyStrokesT.pieces(plain, PLAIN_PIECE_BYTES, PLAIN_PIECE_EVENTS):
		if not is_running or gen != _generation:
			return false
		await _off_thread(b.send_keys.bind(piece))
		if not _typed_on(action, b):
			return false
	return true


## Whether typing may go on after a key command: not when it was skipped
## (~Self) or refused - what is left of a text is another text.
func _typed_on(action: LoopActionT, b: InputBackendT) -> bool:
	if b.last_skipped:
		_report_skipped(action)
		return false
	return not b.keys_refused


## Types a Key action's text one keystroke at a time (see KeyStrokes.split:
## a combo stays one keystroke), each press with real timing — Ctrl goes
## down, c is pressed and held a moment, Ctrl comes up — and a random pause
## between presses, the way typing goes. A stroke the helper cannot press
## key by key goes through SendKeys as it is. A stop ends the typing
## between strokes.
func _type_paced(action: LoopActionT) -> void:
	var gen := _generation
	var b := backend
	# One press at a time: a repeated key ("{ENTER 3}") is three presses, so
	# a stop lands between them and each gets its own timing. Taken as they
	# come, not listed ahead (a text can make hundreds of thousands).
	var first := true
	for stroke in KeyStrokesT.split(action.keys):
		var parsed := KeyStrokesT.parse(stroke)
		# A group of any length goes KEY_PACED_GROUP keys to a command (see
		# below), its modifiers - the Win key's $ too - with each: only what
		# is not a press at all goes to SendKeys.
		var whole := parsed.is_empty()
		for r in (1 if whole else int(parsed["repeat"])):
			if not is_running or gen != _generation:
				return
			if not first:
				var pause := randi_range(KEY_PAUSE_MIN_MS, KEY_PAUSE_MAX_MS)
				if randi_range(1, KEY_PAUSE_LONG_EVERY) == 1:
					pause = randi_range(KEY_PAUSE_LONG_MIN_MS, KEY_PAUSE_LONG_MAX_MS)
				await _sleep_ms(pause)
				if not is_running or gen != _generation:
					return
			first = false
			# The helper blocks for the whole press, so it runs off the main thread.
			if whole:
				await _off_thread(b.send_keys.bind(stroke))   # SendKeys sends it as it is
			else:
				# A group goes KEY_PACED_GROUP keys to a command: each key is held
				# and paced here, so a whole group in one would keep pressing
				# (its modifiers down) for seconds after a stop.
				var keys: PackedStringArray = parsed["keys"]
				for at in range(0, keys.size(), KEY_PACED_GROUP):
					if at > 0 and (not is_running or gen != _generation):
						return
					var lead := randi_range(KEY_LEAD_MIN_MS, KEY_LEAD_MAX_MS)
					var hold := randi_range(KEY_HOLD_MIN_MS, KEY_HOLD_MAX_MS)
					var gap := randi_range(KEY_PAUSE_MIN_MS, KEY_PAUSE_MAX_MS)
					var trail := randi_range(KEY_TRAIL_MIN_MS, KEY_TRAIL_MAX_MS)
					await _off_thread(b.hold_keys.bind(parsed["mods"], keys.slice(at, at + KEY_PACED_GROUP), lead, hold, gap, trail))
					if not _typed_on(action, b):
						return
				continue
			if not _typed_on(action, b):
				return


## A move with a duration is sent to the helper in pieces of about this
## long, so a stop takes effect between them (a captured action is one
## helper command and runs to its end).
const TRAVEL_CHUNK_MS := 200


## Moves the cursor from `from` to `to` over `ms` (see MousePath; `wiggle`
## bends the route a little), showing the travel on the tracker as `label`.
## With `ms` 0 it is a jump. A stop ends the travel where the cursor is.
func _travel(from: Vector2i, to: Vector2i, ms: int, wiggle: bool, label: String) -> void:
	# Every travel is to a point on a screen (a Move, a Click's, a Drag's, a
	# Capture's): the cursor is somewhere again (see _cursor_unplaced).
	_cursor_unplaced = false
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
			var thread := _start_worker(func(): b.move_path(piece, piece_ms))
			while thread.is_alive():
				if is_running and gen == _generation:
					_set_tracker(Vector2i(MousePathT.at(path, float(Time.get_ticks_msec() - started) / float(ms)).round()), true, label)
				await get_tree().process_frame
			_join_worker(thread)
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


## Before an action: whatever the cursor has moved since the loop last left
## it is the user's own movement, and goes to `_user_cursor`. Until the loop
## has moved the cursor at all (and in a Safe run, where it never does), the
## user's mouse is simply where the cursor is.
func _note_user_motion() -> void:
	var now := _mouse_pos()
	if _loop_moved:
		_user_cursor += now - _loop_cursor
		_loop_cursor = now
	else:
		_user_cursor = now


## After an action that may have moved the real cursor: where it left it.
func _note_loop_cursor(action: LoopActionT) -> void:
	if not backend.is_real():
		return
	if LoopActionT.supports_captures(action.type) or action.type == LoopActionT.Type.CAPTURE:
		_loop_cursor = _mouse_pos()
		_loop_moved = true


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
		if gen == _generation:
			detect_rect_pinned = false
		return Vector2i(-1, -1)
	var hit := Vector2i(-1, -1)
	if action.type == LoopActionT.Type.IMAGE_DETECT:
		hit = await _find_image(action, rect)
		if not is_running or gen != _generation:
			hit = Vector2i(-1, -1)
	else:
		hit = await _find_color(action, rect)
		if not is_running or gen != _generation:
			hit = Vector2i(-1, -1)
	# Only this run's pin (a stop has unpinned it already).
	if gen == _generation:
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
	var colour := action.color
	# On a worker thread, as an Image Detect's scan: the read may have to
	# start the helper first (a second or more), and F8 is read on this one.
	var result: Dictionary = await _scan_off_thread(reader, func() -> Dictionary:
		return reader.find_color(rect, colour, tolerance, step))
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
	var png := action.image_png
	var grey := action.ignore_colour
	var result: Dictionary = await _scan_off_thread(reader, func() -> Dictionary:
		return reader.find_image(rect, png, tolerance, grey, mismatch, LoopActionT.IMAGE_EDGE))
	if result.is_empty():
		print("Image detect in [%d, %d, %d×%d]: screen read failed (see warning above) -> not found" % [rect.position.x, rect.position.y, rect.size.x, rect.size.y])
		return Vector2i(-1, -1)
	var hit: Vector2i = result["hit"]
	if hit == Vector2i(-1, -1):
		print("Image detect in [%d, %d, %d×%d]: %d×%d image +-%d (%d%% may be off%s) not in rect -> not found" % [
			rect.position.x, rect.position.y, rect.size.x, rect.size.y, size.x, size.y, tolerance, mismatch,
			", ignore colour" if action.ignore_colour else ""])
	return hit


## Runs a detect's screen read `scan` (a call on `reader`) on a worker
## thread, letting frames - and a stop - through meanwhile; a stop ends the
## read (see _interrupt_helper). Returns what `scan` returned.
func _scan_off_thread(reader: InputBackendT, scan: Callable) -> Dictionary:
	var thread := Thread.new()
	_detect_thread = thread
	_scan_threads.append(thread)
	_detect_reader = reader
	thread.start(scan)
	while thread.is_alive():
		await get_tree().process_frame
	var result: Dictionary = thread.wait_to_finish()
	_scan_threads.erase(thread)
	if _detect_thread == thread:
		_detect_thread = null
		_detect_reader = null
	return result


## Set when a Move was skipped for having no screen to go to (see MOVE):
## what presses "where the cursor is" waits for a point that lands.
var _cursor_unplaced := false


## True (and said on the status line) when one of `points` of a press or a
## drag is on no screen: Windows would press it at the nearest screen's edge
## (a window's Close button, the taskbar's corner), where nothing shows it.
func _off_screens(action: LoopActionT, points: Array) -> bool:
	var count := DisplayServer.get_screen_count()
	if count <= 0:
		return false
	for p in points:
		var on := false
		for screen in count:
			if Rect2i(DisplayServer.screen_get_position(screen), DisplayServer.screen_get_size(screen)).has_point(p):
				on = true
				break
		if not on:
			emit_signal("status", "%s skipped: its point (%d, %d) is on no screen." % [LoopActionT.type_name(action.type), p.x, p.y])
			return true
	return false


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
