extends RefCounted
class_name StopHotkey
## A system-wide F8 (~F8): the start and stop key of the loop from any
## window.
##
## Loop Automator's own F8 / Esc only work while its window has the focus,
## and a loop that clicks other programs takes the focus away with it. So
## while ~F8 is on, a small helper process holds F8 as a global hotkey
## (RegisterHotKey) and prints a line for every press; the engine polls
## that each frame and stops - or starts - the loop. F8 is reserved
## system-wide meanwhile (other programs do not see it) and released the
## moment the helper is stopped. Windows only; elsewhere `state` is
## UNAVAILABLE.

const PowerShellHostT := preload("res://scripts/powershell_host.gd")
const SCRIPT_FILE := "stop_hotkey.ps1"

enum State { OFF, STARTING, ARMED, UNAVAILABLE }

var state: int = State.OFF
## Why the hotkey is UNAVAILABLE (for the status line), "" otherwise.
var reason: String = ""

var _proc: Dictionary = {}
var _pending := PackedByteArray()

## Registers F8 (VK_F8) for this thread, then prints "stop" for every press
## until stdin closes or says 'quit'. The first line is "ready", or
## "error ..." when another program already owns F8.
const SCRIPT := """Add-Type @\"
using System;
using System.Runtime.InteropServices;
using System.Threading;
public class StopKey {
  [StructLayout(LayoutKind.Sequential)] public struct Pt { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct Msg { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public Pt pt; }
  [DllImport(\"user32.dll\")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
  [DllImport(\"user32.dll\")] static extern bool UnregisterHotKey(IntPtr h, int id);
  [DllImport(\"user32.dll\")] static extern bool PeekMessage(out Msg m, IntPtr h, uint lo, uint hi, uint remove);
  static volatile bool done = false;
  public static int Run(uint vk) {
    Msg m;
    PeekMessage(out m, IntPtr.Zero, 0, 0, 0);  // gives this thread a message queue
    if (!RegisterHotKey(IntPtr.Zero, 1, 0x4000, vk)) {  // MOD_NOREPEAT
      Console.Out.WriteLine(\"error F8 is already registered by another program\"); Console.Out.Flush();
      return 1;
    }
    // F8 with any of Shift, Ctrl, Alt, Win down too: a hotkey fires only on
    // its exact modifiers, and a loop holding one (a Key Down of "^", a
    // capital's Shift) would make plain F8 stop nothing. A combination
    // another program owns is left to it.
    for (uint mods = 1; mods < 16; mods++) RegisterHotKey(IntPtr.Zero, 1 + (int)mods, 0x4000 | mods, vk);
    Console.Out.WriteLine(\"ready\"); Console.Out.Flush();
    // Stdin closing (or 'quit') ends the loop: the parent is gone or done.
    Thread reader = new Thread(delegate() {
      try { string l; while ((l = Console.In.ReadLine()) != null && l != \"quit\") { } } catch { }
      done = true;
    });
    reader.IsBackground = true;
    reader.Start();
    try {
      while (!done) {
        while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1))
          if (m.message == 0x0312) { Console.Out.WriteLine(\"stop\"); Console.Out.Flush(); }  // WM_HOTKEY
        Thread.Sleep(10);
      }
    } finally { for (int id = 1; id <= 16; id++) UnregisterHotKey(IntPtr.Zero, id); }
    return 0;
  }
}
\"@
exit ([StopKey]::Run(0x77))
"""


## Starts the helper (asynchronously: `state` becomes ARMED once it reports
## in, see poll). A helper already running is stopped first.
func start() -> void:
	stop()
	reason = ""
	if OS.get_name() != "Windows":
		state = State.UNAVAILABLE
		reason = "not on Windows"
		return
	var path := PowerShellHostT.write_script(SCRIPT_FILE, SCRIPT)
	if path.is_empty():
		state = State.UNAVAILABLE
		reason = "could not write the helper script"
		return
	_proc = OS.execute_with_pipe(PowerShellHostT.executable(), PowerShellHostT.file_args(path), false)
	if _proc.is_empty():
		state = State.UNAVAILABLE
		reason = "could not start PowerShell"
		return
	_pending = PackedByteArray()
	state = State.STARTING


## Reads whatever the helper has printed so far. Returns true when the stop
## key was pressed since the last poll. Non-blocking; call it every frame.
func poll() -> bool:
	if _proc.is_empty():
		return false
	var io: FileAccess = _proc["stdio"]
	while true:
		var chunk := io.get_buffer(256)
		if chunk.size() == 0:
			break
		_pending.append_array(chunk)
	var pressed := false
	while true:
		var nl := _pending.find(10)
		if nl < 0:
			break
		var line := _pending.slice(0, nl).get_string_from_ascii().strip_edges()
		_pending = _pending.slice(nl + 1)
		if line == "ready":
			state = State.ARMED
		elif line == "stop":
			pressed = true
		elif line.begins_with("error"):
			state = State.UNAVAILABLE
			reason = line.substr(6).strip_edges()
	# Armed too: a helper that dies later (killed, crashed) holds F8 no more,
	# and the status line must not go on saying F8 stops the loop.
	if (state == State.STARTING or state == State.ARMED) and not OS.is_process_running(_proc["pid"]):
		state = State.UNAVAILABLE
		reason = "the helper exited (exit code %d)" % OS.get_process_exit_code(_proc["pid"])
	return pressed


## Releases F8 and ends the helper.
func stop() -> void:
	state = State.OFF
	if _proc.is_empty():
		return
	var proc := _proc
	_proc = {}
	_pending = PackedByteArray()
	_shutdown(proc)


## Ends a helper process. Static (and given the pipes explicitly) so it can
## also run from _notification(PREDELETE), when the instance is already gone.
static func _shutdown(proc: Dictionary) -> void:
	var pid: int = proc["pid"]
	var io: FileAccess = proc["stdio"]
	if OS.is_process_running(pid):
		io.store_line("quit")
	io.close()
	(proc["stderr"] as FileAccess).close()
	# Closing stdin ends the loop; a stuck helper is killed outright (the OS
	# releases a thread's hotkeys with the thread).
	for i in 10:
		if not OS.is_process_running(pid):
			return
		OS.delay_msec(5)
	OS.kill(pid)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and not _proc.is_empty():
		_shutdown(_proc)
