extends RefCounted
class_name Recorder
## Record: what the user does with the mouse and keyboard, as a stream of
## events, until F8. A small helper process listens to the mouse and
## keyboard system-wide through Raw Input (RegisterRawInputDevices with
## RIDEV_INPUTSINK, the way games and macro tools do - not a keyboard hook,
## which is what a keylogger installs and what antivirus heuristics look
## for) and prints one line per event; poll() reads them each frame.
## Recording.to_actions turns the stream into a layer's actions. Windows
## only.
##
## The helper leaves out what a loop must not contain: injected input (a
## program moving the cursor, our own helpers), anything on Loop Automator's
## own windows (the ~Self rule: the guard pid), and F8 itself - a press of
## F8 ends the recording instead ("stop" is printed). F8 is held as a
## hotkey (RegisterHotKey, as the run's ~F8 is) so the program under it
## does not get it. While ~F8 already holds it, that helper's press ends
## the recording through the engine instead (see `f8_taken`).

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
## The most events a recording keeps (about an hour of constant motion):
## past it the recording ends as if F8 had been pressed, and this is set.
const MAX_EVENTS := 400000
var limit_reached: bool = false
## True when F8 could not be taken: another program holds it as a hotkey
## (the run's own ~F8 helper, or something else - then F8 does not end the
## recording; the builder's Stop button and Esc do).
var f8_taken: bool = false

var _proc: Dictionary = {}
var _pending := PackedByteArray()
## What the helper wrote to stderr (PowerShell's own errors, an Add-Type that
## does not compile): kept for `reason` when the helper dies before "ready",
## and drained so a full pipe can never stall it.
var _stderr_text := PackedByteArray()
const STDERR_KEEP := 4096

## record <guard pid> [any]: listens to the mouse and keyboard, prints
## "ready", then a line per event until stdin closes / says 'quit' or F8 is
## pressed ("stop"). A second argument "any" keeps injected events too
## (probes).
const SCRIPT := """param([int]$guard = 0, [string]$mode = '')
Add-Type -ReferencedAssemblies System.Windows.Forms @\"
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
public class Rec : NativeWindow {
  [StructLayout(LayoutKind.Sequential)] public struct Pt { public int X; public int Y; }
  [StructLayout(LayoutKind.Sequential)] public struct Msg { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public Pt pt; }
  [StructLayout(LayoutKind.Sequential)] public struct RawDev { public ushort page; public ushort usage; public uint flags; public IntPtr target; }
  [DllImport(\"user32.dll\", SetLastError = true)] static extern bool RegisterRawInputDevices(RawDev[] devs, uint n, uint size);
  [DllImport(\"user32.dll\")] static extern uint GetRawInputData(IntPtr h, uint cmd, IntPtr data, ref uint size, uint header);
  [DllImport(\"user32.dll\")] static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
  [DllImport(\"user32.dll\")] static extern bool UnregisterHotKey(IntPtr h, int id);
  [DllImport(\"user32.dll\")] static extern bool PeekMessage(out Msg m, IntPtr h, uint lo, uint hi, uint remove);
  [DllImport(\"user32.dll\")] static extern IntPtr DispatchMessage(ref Msg m);
  [DllImport(\"user32.dll\")] static extern bool GetCursorPos(out Pt p);
  [DllImport(\"user32.dll\")] static extern IntPtr WindowFromPoint(Pt p);
  [DllImport(\"user32.dll\")] static extern IntPtr GetForegroundWindow();
  [DllImport(\"user32.dll\")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport(\"winmm.dll\")] static extern uint timeBeginPeriod(uint ms);
  [DllImport(\"winmm.dll\")] static extern uint timeEndPeriod(uint ms);
  static volatile bool done = false;
  static uint guard;
  static bool any;
  static bool hotkey;  // F8 is ours (see Run)
  static System.Diagnostics.Stopwatch sw;
  static long lastMove = -1000;
  // One RAWINPUT at a time: its header (type, size, device, wParam), then
  // the mouse or keyboard block. Big enough for either.
  static IntPtr buf;
  const int BUF = 256;
  static readonly int hdr = 8 + 2 * IntPtr.Size;
  static bool Guarded(IntPtr h) {
    if (guard == 0 || h == IntPtr.Zero) return false;
    uint pid; GetWindowThreadProcessId(h, out pid);
    return pid == guard;
  }
  // Lines go out through a queue and a thread of their own, so the message
  // loop never waits on a full pipe (the parent not reading for a second)
  // and input keeps coming in. The window check for a mouse event is made
  // there too: WindowFromPoint asks the window under the point
  // (WM_NCHITTEST), and a program that is not answering would hold it.
  struct Ev { public string line; public bool atPoint; public Pt pt; }
  static System.Collections.Generic.Queue<Ev> lines = new System.Collections.Generic.Queue<Ev>();
  // The most lines kept waiting for the writer (a window under the cursor
  // that does not answer holds it): past that, input is dropped rather
  // than the queue growing for as long as the recording runs.
  const int MaxQueued = 50000;
  static void Out(string s) { Ev e; e.line = s; e.atPoint = false; e.pt = new Pt(); Push(e); }
  static void OutAt(string s, Pt p) { Ev e; e.line = s; e.atPoint = true; e.pt = p; Push(e); }
  static void Push(Ev e) { lock (lines) { if (lines.Count < MaxQueued || !e.atPoint) lines.Enqueue(e); Monitor.Pulse(lines); } }
  static void Writer() {
    while (true) {
      Ev e;
      lock (lines) { while (lines.Count == 0) Monitor.Wait(lines); e = lines.Dequeue(); }
      if (e.atPoint && Guarded(WindowFromPoint(e.pt))) continue;
      try { Console.Out.WriteLine(e.line); Console.Out.Flush(); } catch { done = true; return; }
    }
  }
  // Gives the writer a moment to send what is queued (the \"stop\" line
  // above all) before the process ends.
  static void Drain() {
    for (int i = 0; i < 200; i++) { lock (lines) { if (lines.Count == 0) return; } Thread.Sleep(10); }
  }
  static void Stop() { if (!done) { Out(\"stop\"); done = true; } }
  // WM_INPUT: one raw mouse or keyboard report. Input a program made
  // (SendInput, keybd_event - our own helpers) comes with no device.
  protected override void WndProc(ref Message m) {
    if (m.Msg == 0xFF) OnInput(m.LParam);
    base.WndProc(ref m);
  }
  static void OnInput(IntPtr h) {
    uint size = BUF;
    uint got = GetRawInputData(h, 0x10000003, buf, ref size, (uint)hdr);  // RID_INPUT
    if (got == uint.MaxValue || got < hdr) return;
    int type = Marshal.ReadInt32(buf, 0);
    bool injected = Marshal.ReadIntPtr(buf, 8) == IntPtr.Zero;
    long t = sw.ElapsedMilliseconds;
    if (type == 0) {  // RIM_TYPEMOUSE
      if (got < hdr + 24 || (!any && injected)) return;
      int flags = Marshal.ReadInt16(buf, hdr) & 0xFFFF;
      int btn = Marshal.ReadInt16(buf, hdr + 4) & 0xFFFF;
      short data = Marshal.ReadInt16(buf, hdr + 6);
      int dx = Marshal.ReadInt32(buf, hdr + 12), dy = Marshal.ReadInt32(buf, hdr + 16);
      Pt p; GetCursorPos(out p);
      string at = \" \" + p.X + \" \" + p.Y;
      // Motion: at most one line every 8 ms.
      if ((dx != 0 || dy != 0 || (flags & 1) != 0) && t - lastMove >= 8) { lastMove = t; OutAt(\"m \" + t + at, p); }
      if ((btn & 0x001) != 0) OutAt(\"d \" + t + \" 0\" + at, p);
      if ((btn & 0x002) != 0) OutAt(\"u \" + t + \" 0\" + at, p);
      if ((btn & 0x004) != 0) OutAt(\"d \" + t + \" 1\" + at, p);
      if ((btn & 0x008) != 0) OutAt(\"u \" + t + \" 1\" + at, p);
      if ((btn & 0x010) != 0) OutAt(\"d \" + t + \" 2\" + at, p);
      if ((btn & 0x020) != 0) OutAt(\"u \" + t + \" 2\" + at, p);
      if ((btn & 0x400) != 0) OutAt(\"w \" + t + \" \" + data + \" 0\" + at, p);
      if ((btn & 0x800) != 0) OutAt(\"w \" + t + \" \" + data + \" 1\" + at, p);
    } else if (type == 1) {  // RIM_TYPEKEYBOARD
      if (got < hdr + 16) return;
      int kflags = Marshal.ReadInt16(buf, hdr + 2) & 0xFFFF;
      int vk = Marshal.ReadInt16(buf, hdr + 6) & 0xFFFF;
      bool up = (kflags & 1) != 0;
      int ext = (kflags & 2) != 0 ? 1 : 0;
      if (vk == 0xFF) return;  // the fake shift some keys are padded with
      // F8 ends the recording (WM_HOTKEY, below) and is never in it.
      if (vk != 0x77 && (any || !injected) && !Guarded(GetForegroundWindow())) {
        Out(\"k \" + t + \" \" + vk + \" \" + (up ? 0 : 1) + \" \" + ext);
      }
    }
  }
  [DllImport(\"user32.dll\")] static extern bool SetProcessDPIAware();
  public static int Run(uint guardPid, bool anyInput) {
    // Screen pixels as Godot counts them (it is DPI aware; powershell.exe
    // is not): scaled units would put every recorded point off.
    SetProcessDPIAware();
    guard = guardPid; any = anyInput;
    buf = Marshal.AllocHGlobal(BUF);
    Thread writer = new Thread(Writer); writer.IsBackground = true; writer.Start();
    Msg m;
    PeekMessage(out m, IntPtr.Zero, 0, 0, 0);  // gives this thread a message queue
    // A message-only window takes the reports (RIDEV_INPUTSINK: from every
    // window, in front or not).
    Rec w = new Rec();
    CreateParams cp = new CreateParams();
    cp.Parent = (IntPtr)(-3);  // HWND_MESSAGE
    w.CreateHandle(cp);
    RawDev[] devs = new RawDev[2];
    devs[0].page = 1; devs[0].usage = 2; devs[0].flags = 0x100; devs[0].target = w.Handle;  // mouse
    devs[1].page = 1; devs[1].usage = 6; devs[1].flags = 0x100; devs[1].target = w.Handle;  // keyboard
    if (!RegisterRawInputDevices(devs, 2, (uint)Marshal.SizeOf(typeof(RawDev)))) {
      Out(\"error could not listen to the mouse and keyboard (\" + Marshal.GetLastWin32Error() + \")\");
      Drain();
      w.DestroyHandle();
      return 1;
    }
    // F8 as a hotkey, as the run's ~F8 holds it: its press comes as
    // WM_HOTKEY and the program in front never sees it. When another
    // program (the run's own helper, with ~F8 on) has it, the press goes
    // there instead - a hotkey's key is not reported as input either.
    hotkey = RegisterHotKey(IntPtr.Zero, 1, 0x4000, 0x77);  // MOD_NOREPEAT, VK_F8
    if (!hotkey) Out(\"nohotkey\");
    // ...with any modifiers down too, as the run's does (see StopHotkey).
    else for (uint mods = 1; mods < 16; mods++) RegisterHotKey(IntPtr.Zero, 1 + (int)mods, 0x4000 | mods, 0x77);
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
      while (!done) {
        while (PeekMessage(out m, IntPtr.Zero, 0, 0, 1)) {
          if (m.message == 0x0312) Stop();  // WM_HOTKEY
          else DispatchMessage(ref m);
        }
        Thread.Sleep(1);
      }
    } finally {
      if (hotkey) for (int id = 1; id <= 16; id++) UnregisterHotKey(IntPtr.Zero, id);
      w.DestroyHandle();
      if (timer) timeEndPeriod(1);
    }
    Drain();
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
	limit_reached = false
	f8_taken = false
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
## when F8 was pressed (the helper has stopped listening; call stop()).
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
		elif line == "nohotkey":
			f8_taken = true
		elif line.begins_with("error"):
			state = State.UNAVAILABLE
			reason = line.substr(6).strip_edges()
		elif events.size() >= MAX_EVENTS:
			# Left running for hours: what there is becomes the layer's
			# actions, as if F8 had been pressed now.
			limit_reached = true
			stopped = true
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
	# The helper reports Windows' coordinates; the app works in Godot's (see
	# WindowsBackend._origin).
	var o := DisplayServer.screen_get_position(DisplayServer.get_primary_screen())
	match p[0]:
		"m":
			if p.size() >= 4:
				return {"kind": "m", "t": t, "x": int(p[2]) + o.x, "y": int(p[3]) + o.y}
		"d", "u":
			if p.size() >= 5:
				return {"kind": p[0], "t": t, "button": int(p[2]), "x": int(p[3]) + o.x, "y": int(p[4]) + o.y}
		"w":
			if p.size() >= 6:
				return {"kind": "w", "t": t, "delta": int(p[2]), "horizontal": p[3] == "1", "x": int(p[4]) + o.x, "y": int(p[5]) + o.y}
		"k":
			if p.size() >= 5:
				return {"kind": "k", "t": t, "vk": int(p[2]), "down": p[3] == "1", "extended": p[4] == "1"}
	return {}


## Ends the helper (its listening goes with it) and returns the events read so
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
	# releases a thread's hotkey and window with the thread).
	for i in 10:
		if not OS.is_process_running(pid):
			return
		OS.delay_msec(5)
	OS.kill(pid)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and not _proc.is_empty():
		_shutdown(_proc)
