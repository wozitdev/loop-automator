extends RefCounted
class_name Recorder
## Record: what the user does with the mouse and keyboard, as a stream of
## events, until F8. A small helper process holds system-wide mouse and
## keyboard hooks (WH_MOUSE_LL / WH_KEYBOARD_LL) and prints one line per
## event; poll() reads them each frame. Recording.to_actions turns the
## stream into a layer's actions. Windows only.
##
## The helper leaves out what a loop must not contain: injected input (a
## program moving the cursor, our own helpers), anything on Loop Automator's
## own windows (the ~Self rule: the guard pid), and F8 itself - a press of
## F8 ends the recording instead ("stop" is printed).

const PowerShellHostT := preload("res://scripts/powershell_host.gd")
const SCRIPT_FILE := "record_helper.ps1"

enum State { OFF, STARTING, ON, UNAVAILABLE }

var state: int = State.OFF
## Why the recorder is UNAVAILABLE (for the status line), "" otherwise.
var reason: String = ""
## The events read so far, in order: {"kind": "m" | "d" | "u" | "w" | "k",
## "t": ms since the start, and per kind: x, y (m / d / u / w); "button"
## (d / u: 0 left, 1 right, 2 middle); "delta" (w: +-120 per notch, up /
## right positive) and "horizontal"; "vk", "down", "extended" (k).
var events: Array = []

var _proc: Dictionary = {}
var _pending := PackedByteArray()
## What the helper wrote to stderr (PowerShell's own errors, an Add-Type that
## does not compile): kept for `reason` when the helper dies before "ready",
## and drained so a full pipe can never stall it.
var _stderr_text := PackedByteArray()
const STDERR_KEEP := 4096

## record <guard pid> [any]: hooks the mouse and keyboard, prints "ready",
## then a line per event until stdin closes / says 'quit' or F8 is pressed
## ("stop"). A second argument "any" keeps injected events too (probes).
const SCRIPT := """param([int]$guard = 0, [string]$mode = '')
Add-Type @\"
using System;
using System.Runtime.InteropServices;
using System.Threading;
public class Rec {
  [StructLayout(LayoutKind.Sequential)] public struct Pt { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct Msg { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public Pt pt; }
  [StructLayout(LayoutKind.Sequential)] public struct MsLL { public Pt pt; public int mouseData; public int flags; public int time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] public struct KbLL { public int vk; public int scan; public int flags; public int time; public IntPtr extra; }
  public delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
  [DllImport(\"user32.dll\")] static extern IntPtr SetWindowsHookExW(int id, HookProc proc, IntPtr mod, uint tid);
  [DllImport(\"user32.dll\")] static extern bool UnhookWindowsHookEx(IntPtr h);
  [DllImport(\"user32.dll\")] static extern IntPtr CallNextHookEx(IntPtr h, int code, IntPtr w, IntPtr l);
  [DllImport(\"user32.dll\")] static extern bool PeekMessage(out Msg m, IntPtr h, uint lo, uint hi, uint remove);
  [DllImport(\"user32.dll\")] static extern IntPtr WindowFromPoint(Pt p);
  [DllImport(\"user32.dll\")] static extern IntPtr GetForegroundWindow();
  [DllImport(\"user32.dll\")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport(\"kernel32.dll\")] static extern IntPtr GetModuleHandleW(string n);
  [DllImport(\"winmm.dll\")] static extern uint timeBeginPeriod(uint ms);
  [DllImport(\"winmm.dll\")] static extern uint timeEndPeriod(uint ms);
  // The delegates are kept in fields: a collected one would end the hook.
  static HookProc mouseProc, keyProc;
  static IntPtr hMouse, hKey;
  static volatile bool done = false;
  static uint guard;
  static bool any;
  static System.Diagnostics.Stopwatch sw;
  static long lastMove = -1000;
  static bool Guarded(IntPtr h) {
    if (guard == 0 || h == IntPtr.Zero) return false;
    uint pid; GetWindowThreadProcessId(h, out pid);
    return pid == guard;
  }
  static void Out(string s) { Console.Out.WriteLine(s); Console.Out.Flush(); }
  static IntPtr OnMouse(int code, IntPtr w, IntPtr l) {
    if (code >= 0) {
      MsLL m = (MsLL)Marshal.PtrToStructure(l, typeof(MsLL));
      bool injected = (m.flags & 1) != 0;
      if ((any || !injected) && !Guarded(WindowFromPoint(m.pt))) {
        long t = sw.ElapsedMilliseconds;
        int msg = (int)w;
        switch (msg) {
          case 0x200:  // WM_MOUSEMOVE: at most one every 8 ms
            if (t - lastMove >= 8) { lastMove = t; Out(\"m \" + t + \" \" + m.pt.X + \" \" + m.pt.Y); }
            break;
          case 0x201: Out(\"d \" + t + \" 0 \" + m.pt.X + \" \" + m.pt.Y); break;
          case 0x202: Out(\"u \" + t + \" 0 \" + m.pt.X + \" \" + m.pt.Y); break;
          case 0x204: Out(\"d \" + t + \" 1 \" + m.pt.X + \" \" + m.pt.Y); break;
          case 0x205: Out(\"u \" + t + \" 1 \" + m.pt.X + \" \" + m.pt.Y); break;
          case 0x207: Out(\"d \" + t + \" 2 \" + m.pt.X + \" \" + m.pt.Y); break;
          case 0x208: Out(\"u \" + t + \" 2 \" + m.pt.X + \" \" + m.pt.Y); break;
          case 0x20A: Out(\"w \" + t + \" \" + (short)((m.mouseData >> 16) & 0xFFFF) + \" 0 \" + m.pt.X + \" \" + m.pt.Y); break;
          case 0x20E: Out(\"w \" + t + \" \" + (short)((m.mouseData >> 16) & 0xFFFF) + \" 1 \" + m.pt.X + \" \" + m.pt.Y); break;
        }
      }
    }
    return CallNextHookEx(hMouse, code, w, l);
  }
  static IntPtr OnKey(int code, IntPtr w, IntPtr l) {
    if (code >= 0) {
      KbLL k = (KbLL)Marshal.PtrToStructure(l, typeof(KbLL));
      bool injected = (k.flags & 0x10) != 0;
      bool up = (k.flags & 0x80) != 0;
      int ext = (k.flags & 1);
      if (k.vk == 0x77 && !injected) {  // F8 ends the recording, and is not in it
        if (!up) { Out(\"stop\"); done = true; }
      } else if ((any || !injected) && !Guarded(GetForegroundWindow())) {
        Out(\"k \" + sw.ElapsedMilliseconds + \" \" + k.vk + \" \" + (up ? 0 : 1) + \" \" + ext);
      }
    }
    return CallNextHookEx(hKey, code, w, l);
  }
  public static int Run(uint guardPid, bool anyInput) {
    guard = guardPid; any = anyInput;
    Msg m;
    PeekMessage(out m, IntPtr.Zero, 0, 0, 0);  // gives this thread a message queue
    mouseProc = new HookProc(OnMouse); keyProc = new HookProc(OnKey);
    IntPtr mod = GetModuleHandleW(null);
    hMouse = SetWindowsHookExW(14, mouseProc, mod, 0);
    hKey = SetWindowsHookExW(13, keyProc, mod, 0);
    if (hMouse == IntPtr.Zero || hKey == IntPtr.Zero) {
      Out(\"error could not hook the mouse and keyboard (\" + Marshal.GetLastWin32Error() + \")\");
      if (hMouse != IntPtr.Zero) UnhookWindowsHookEx(hMouse);
      if (hKey != IntPtr.Zero) UnhookWindowsHookEx(hKey);
      return 1;
    }
    sw = System.Diagnostics.Stopwatch.StartNew();
    Out(\"ready\");
    // Stdin closing (or 'quit') ends the loop: the parent is gone or done.
    Thread reader = new Thread(delegate() {
      try { string s; while ((s = Console.In.ReadLine()) != null && s != \"quit\") { } } catch { }
      done = true;
    });
    reader.IsBackground = true;
    reader.Start();
    bool timer = timeBeginPeriod(1) == 0;
    try {
      // The hooks are called from inside PeekMessage, so keep pumping.
      while (!done) {
        while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1)) { }
        Thread.Sleep(1);
      }
    } finally {
      UnhookWindowsHookEx(hMouse); UnhookWindowsHookEx(hKey);
      if (timer) timeEndPeriod(1);
    }
    return 0;
  }
}
\"@
exit ([Rec]::Run([uint32]$guard, ($mode -eq 'any')))
"""


## Starts recording (asynchronously: `state` becomes ON once the helper
## reports in, see poll). `guard_pid` is the process whose windows are left
## out (Loop Automator's own). `any_input` keeps injected events too - for
## probes only.
func start(guard_pid: int, any_input: bool = false) -> void:
	stop()
	reason = ""
	events = []
	if OS.get_name() != "Windows":
		state = State.UNAVAILABLE
		reason = "not on Windows"
		return
	var path := PowerShellHostT.write_script(SCRIPT_FILE, SCRIPT)
	if path.is_empty():
		state = State.UNAVAILABLE
		reason = "could not write the helper script"
		return
	var args := PowerShellHostT.file_args(path)
	args.append(str(guard_pid))
	if any_input:
		args.append("any")
	_proc = OS.execute_with_pipe(PowerShellHostT.executable(), args, false)
	if _proc.is_empty():
		state = State.UNAVAILABLE
		reason = "could not start PowerShell"
		return
	_pending = PackedByteArray()
	_stderr_text = PackedByteArray()
	state = State.STARTING


## Reads whatever the helper has printed so far into `events`. Returns true
## when F8 was pressed (the helper has stopped hooking; call stop()).
## Non-blocking; call it every frame.
func poll() -> bool:
	if _proc.is_empty():
		return false
	var io: FileAccess = _proc["stdio"]
	while true:
		var chunk := io.get_buffer(4096)
		if chunk.size() == 0:
			break
		_pending.append_array(chunk)
	var err: FileAccess = _proc["stderr"]
	while true:
		var chunk := err.get_buffer(4096)
		if chunk.size() == 0:
			break
		if _stderr_text.size() < STDERR_KEEP:
			_stderr_text.append_array(chunk)
	var stopped := false
	while true:
		var nl := _pending.find(10)
		if nl < 0:
			break
		var line := _pending.slice(0, nl).get_string_from_ascii().strip_edges()
		_pending = _pending.slice(nl + 1)
		if line == "ready":
			state = State.ON
		elif line == "stop":
			stopped = true
		elif line.begins_with("error"):
			state = State.UNAVAILABLE
			reason = line.substr(6).strip_edges()
		else:
			var e := parse_line(line)
			if not e.is_empty():
				events.append(e)
	if state == State.STARTING and not OS.is_process_running(_proc["pid"]):
		state = State.UNAVAILABLE
		reason = "the helper exited (exit code %d)" % OS.get_process_exit_code(_proc["pid"])
		var said := _stderr_line()
		if not said.is_empty():
			reason += ": " + said
	return stopped


## The first line the helper wrote to stderr, at most 160 characters, or "".
## PowerShell writes its errors there (several lines; the first names it).
func _stderr_line() -> String:
	for line in _stderr_text.get_string_from_utf8().split("\n"):
		var s := line.strip_edges()
		if not s.is_empty():
			return s.left(160)
	return ""


## One helper line as an event (see `events`), or {} for anything else.
static func parse_line(line: String) -> Dictionary:
	var p := line.split(" ", false)
	if p.size() < 2 or not p[1].is_valid_int():
		return {}
	var t := int(p[1])
	match p[0]:
		"m":
			if p.size() >= 4:
				return {"kind": "m", "t": t, "x": int(p[2]), "y": int(p[3])}
		"d", "u":
			if p.size() >= 5:
				return {"kind": p[0], "t": t, "button": int(p[2]), "x": int(p[3]), "y": int(p[4])}
		"w":
			if p.size() >= 6:
				return {"kind": "w", "t": t, "delta": int(p[2]), "horizontal": p[3] == "1", "x": int(p[4]), "y": int(p[5])}
		"k":
			if p.size() >= 5:
				return {"kind": "k", "t": t, "vk": int(p[2]), "down": p[3] == "1", "extended": p[4] == "1"}
	return {}


## Ends the helper (the hooks go with it) and returns the events read so
## far - whatever the helper printed and had not been polled yet included.
func stop() -> Array:
	if _proc.is_empty():
		state = State.OFF
		return events
	poll()
	var proc := _proc
	_proc = {}
	_pending = PackedByteArray()
	state = State.OFF
	_shutdown(proc)
	return events


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
	# removes a thread's hooks with the thread).
	for i in 10:
		if not OS.is_process_running(pid):
			return
		OS.delay_msec(5)
	OS.kill(pid)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and not _proc.is_empty():
		_shutdown(_proc)
