extends "res://scripts/input/input_backend.gd"
class_name WindowsBackend
## Best-effort real input on Windows via a small PowerShell helper script.
##
## Every command — input and screen reads — goes to one long-running helper
## process over a pipe (see `_server`), synchronously, so action ordering and
## wait timings stay deterministic. Spawning the helper per call (~200 ms)
## is only the fallback when no server can be started.

const PowerShellHostT := preload("res://scripts/powershell_host.gd")
const MousePathT := preload("res://scripts/model/mouse_path.gd")
const LoopActionT := preload("res://scripts/model/loop_action.gd")
const KeyStrokesT := preload("res://scripts/model/key_strokes.gd")
const HELPER_FILE := "input_helper.ps1"

## The pipe to the helper carries a line of at most 4096 bytes whole
## (store_line cuts a longer one there, with no line break): the helper
## would wait for the rest of it, and this side for an answer, until the
## timeout killed the helper. A command over this is refused instead (see
## _server_call); what can be long goes in pieces (a Key's text, a
## captured action's path, a template).
const PIPE_LINE_MAX := 4000
## Key text goes in pieces of at most this many UTF-8 bytes (base64 makes
## them a third bigger), cut between keystrokes.
const KEY_PIECE_BYTES := 2400
## ...and of at most this many keystrokes (see KeyStrokes.events).
const KEY_PIECE_EVENTS := 2000
## An encoded path (see MousePath.encode) longer than this is sent ahead in
## pieces of PATH_PIECE_CHARS ('pathpart'); the command then says "@".
const PATH_INLINE_MAX := 3000
const PATH_PIECE_CHARS := 3000

## Absolute path of the helper script, "" when it could not be written (no
## helper then; every call answers "failed"). The script is rewritten right
## before each launch (see _spawn_args), this only records where.
var _helper_real_path: String = ""
var _last_pos: Vector2i = Vector2i.ZERO

## The helper in its 'serve' mode, talked to over a pipe: a few ms per
## command instead of the ~200 ms it costs to spawn PowerShell. Started on
## first use; if it dies or stops answering it is killed and the next call
## starts a fresh one. A call that cannot get a server at all falls back to
## spawning the helper for that one command.
var _server: Dictionary = {}          # OS.execute_with_pipe result: stdio, stderr, pid
var _server_pending := PackedByteArray()  # bytes received after the last full line
var _server_failed_at: int = -1       # ticks when the server last failed to start
const SERVER_START_TIMEOUT_MS := 20000
const SERVER_READ_TIMEOUT_MS := 4000
## An image scan on a big rect with mismatches allowed (see find_image).
const IMAGE_SCAN_TIMEOUT_MS := 30000
const SERVER_RETRY_MS := 10000
## Reads may come from a worker thread (live colour preview) while playback
## uses the same backend on the main thread.
var _server_mutex := Mutex.new()
## Starts the server in the background (see warm_up) so its ~1.5 s start-up
## (two C# compiles) is not paid by the first action of a run.
var _warm_thread: Thread
## Set by shutdown(): no server is started any more, and a warm-up thread
## still at work ends the server itself when it is done (see _server_call).
var _closing := false
## Set by interrupt(): the empty answer the waiting call is about to get is
## meant, not a fault, so it is not logged as one - or, with no call
## waiting, the next command from a worker thread is the one meant and is
## dropped (see _server_call and _run_sync). `_cut_short_at` is when: a flag nobody
## consumed (the thread had just finished) is forgotten after CUT_SHORT_MS
## rather than swallowing a command of a later run.
var _cut_short := false
var _cut_short_at: int = 0
const CUT_SHORT_MS := 2000
## The server's pid (-1: none), kept beside `_server` for interrupt(), which
## runs on the main thread while a worker holds the lock and may be
## replacing `_server` itself: an int is read whole, a Dictionary is not.
var _server_pid: int = -1
## Whether the last _run_sync got an "error ..." answer (the helper ran the
## command and failed it, as opposed to ending without an answer).
var _last_error := false

const HELPER_SCRIPT := """param([Parameter(ValueFromRemainingArguments=$true)][string[]]$a)
# 'guard <pid> <command...>': clicks and keys that would land on a window of
# that process are skipped (\"skipped\" is printed instead). Loop Automator
# passes its own pid unless ~Self is on, so a loop cannot drive the app
# that is running it.
$script:guard = 0
$cmd = $a[0]
if ($cmd -eq 'guard') { $cmd = $a[2] }
# Only the input commands (and the server, which runs them too) need the
# P/Invoke shim; skipping the compile keeps one-shot 'pixel' / 'rect' /
# 'cursor' reads as quick as possible.
if ($cmd -ne 'pixel' -and $cmd -ne 'rect' -and $cmd -ne 'cursor') {
Add-Type @\"
using System;
using System.Runtime.InteropServices;
[StructLayout(LayoutKind.Sequential)] public struct Win32Pt { public int X; public int Y; }
[StructLayout(LayoutKind.Sequential)] public struct Win32Sz { public int W; public int H; }
[StructLayout(LayoutKind.Sequential)] public struct Win32CursorInfo { public int cbSize; public int flags; public IntPtr hCursor; public Win32Pt pt; }
[StructLayout(LayoutKind.Sequential, Pack=1)] public struct Win32Blend { public byte op; public byte flags; public byte alpha; public byte fmt; }
[StructLayout(LayoutKind.Sequential)] public struct Win32MouseInput { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra; }
[StructLayout(LayoutKind.Sequential)] public struct Win32Input { public uint type; public Win32MouseInput mi; }
public class Win32In {
  [DllImport(\"user32.dll\")] public static extern bool SetCursorPos(int x,int y);
  [DllImport(\"user32.dll\")] public static extern bool GetCursorPos(out Win32Pt p);
  [DllImport(\"user32.dll\")] public static extern IntPtr WindowFromPoint(Win32Pt p);
  [DllImport(\"user32.dll\")] public static extern IntPtr GetForegroundWindow();
  [DllImport(\"user32.dll\")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint pid);
  [DllImport(\"user32.dll\")] public static extern bool GetCursorInfo(ref Win32CursorInfo pci);
  [DllImport(\"user32.dll\")] public static extern IntPtr CopyIcon(IntPtr h);
  [DllImport(\"user32.dll\")] public static extern IntPtr CreateCursor(IntPtr inst,int xh,int yh,int w,int h,byte[] and,byte[] xor);
  [DllImport(\"user32.dll\")] public static extern bool SetSystemCursor(IntPtr h,uint id);
  [DllImport(\"user32.dll\")] public static extern bool SystemParametersInfo(uint a,uint b,IntPtr c,uint d);
  [DllImport(\"user32.dll\")] public static extern int GetSystemMetrics(int n);
  [DllImport(\"user32.dll\")] public static extern IntPtr LoadCursorW(IntPtr inst,IntPtr name);
  [DllImport(\"user32.dll\", CharSet=CharSet.Unicode)] public static extern IntPtr CreateWindowExW(int ex,string cls,string name,int style,int x,int y,int w,int h,IntPtr parent,IntPtr menu,IntPtr inst,IntPtr p);
  [DllImport(\"user32.dll\")] public static extern bool DestroyWindow(IntPtr h);
  [DllImport(\"winmm.dll\")] public static extern uint timeBeginPeriod(uint ms);
  [DllImport(\"winmm.dll\")] public static extern uint timeEndPeriod(uint ms);
  [DllImport(\"user32.dll\")] public static extern bool ShowWindow(IntPtr h,int n);
  [DllImport(\"user32.dll\")] public static extern void keybd_event(byte vk,byte scan,uint flags,IntPtr extra);
  [DllImport(\"user32.dll\")] public static extern uint MapVirtualKeyW(uint code,uint type);
  [DllImport(\"user32.dll\", CharSet=CharSet.Unicode)] public static extern short VkKeyScanW(char ch);
  [DllImport(\"user32.dll\")] public static extern int GetWindowLongW(IntPtr h,int i);
  [DllImport(\"user32.dll\")] public static extern int SetWindowLongW(IntPtr h,int i,int v);
  [DllImport(\"user32.dll\")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int cx,int cy,uint f);
  [DllImport(\"user32.dll\")] static extern IntPtr GetDC(IntPtr h);
  [DllImport(\"user32.dll\")] static extern int ReleaseDC(IntPtr h,IntPtr dc);
  [DllImport(\"user32.dll\")] static extern bool UpdateLayeredWindow(IntPtr h,IntPtr dst,ref Win32Pt pos,ref Win32Sz sz,IntPtr src,ref Win32Pt srcPos,int key,ref Win32Blend blend,int flags);
  [DllImport(\"gdi32.dll\")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
  [DllImport(\"gdi32.dll\")] static extern IntPtr SelectObject(IntPtr dc,IntPtr o);
  [DllImport(\"gdi32.dll\")] public static extern bool DeleteObject(IntPtr o);
  [DllImport(\"gdi32.dll\")] static extern bool DeleteDC(IntPtr dc);
  // Gives a WS_EX_LAYERED window per-pixel alpha content from a 32bpp
  // premultiplied bitmap (what Bitmap.GetHbitmap(Color.FromArgb(0)) yields).
  public static void SetAlphaBitmap(IntPtr hwnd,IntPtr hbmp,int x,int y,int w,int h) {
    IntPtr screen = GetDC(IntPtr.Zero);
    IntPtr mem = CreateCompatibleDC(screen);
    IntPtr old = SelectObject(mem,hbmp);
    Win32Pt pos = new Win32Pt(); pos.X = x; pos.Y = y;
    Win32Sz sz = new Win32Sz(); sz.W = w; sz.H = h;
    Win32Pt src = new Win32Pt();
    Win32Blend b = new Win32Blend(); b.op = 0; b.flags = 0; b.alpha = 255; b.fmt = 1;
    UpdateLayeredWindow(hwnd,screen,ref pos,ref sz,mem,ref src,0,ref b,2);
    SelectObject(mem,old); DeleteDC(mem); ReleaseDC(IntPtr.Zero,screen);
  }
  [DllImport(\"user32.dll\")] static extern uint SendInput(uint n,Win32Input[] inputs,int size);
  // One input event that moves the cursor to (x,y) AND presses / releases a
  // button there. SetCursorPos followed by mouse_event is two steps, and any
  // real mouse motion queued in between lands the click off its point.
  public static void MouseAt(int x,int y,uint buttonFlag) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    Win32Input[] inp = new Win32Input[1];
    inp[0].type = 0;
    // Absolute coordinates: 0..65535 across the virtual desktop, mapped back
    // to pixels with (abs * size) >> 16, so round up to land on the pixel.
    inp[0].mi.dx = (int)Math.Ceiling((x - vx) * 65536.0 / vw);
    inp[0].mi.dy = (int)Math.Ceiling((y - vy) * 65536.0 / vh);
    inp[0].mi.dwFlags = 0x0001 | 0x8000 | 0x4000 | buttonFlag;  // MOVE | ABSOLUTE | VIRTUALDESK
    SendInput(1,inp,Marshal.SizeOf(typeof(Win32Input)));
  }
  // A button press or release where the cursor is, with no move at all.
  public static void ButtonOnly(uint buttonFlag) {
    Win32Input[] inp = new Win32Input[1];
    inp[0].type = 0;
    inp[0].mi.dwFlags = buttonFlag;
    SendInput(1,inp,Marshal.SizeOf(typeof(Win32Input)));
  }
  // One wheel notch (delta +-120: up / right positive) where the cursor is.
  public static void Wheel(int delta,bool horizontal) {
    Win32Input[] inp = new Win32Input[1];
    inp[0].type = 0;
    inp[0].mi.mouseData = unchecked((uint)delta);
    inp[0].mi.dwFlags = horizontal ? 0x01000u : 0x0800u;  // HWHEEL | WHEEL
    SendInput(1,inp,Marshal.SizeOf(typeof(Win32Input)));
  }
}
\"@
}
# Button flags for MouseAt: down / up for left, right ('1'), middle ('2').
function Down-Flag([string]$btn) { switch ($btn) { '1' { 0x0008 } '2' { 0x0020 } default { 0x0002 } } }
function Up-Flag([string]$btn) { switch ($btn) { '1' { 0x0010 } '2' { 0x0040 } default { 0x0004 } } }
function Read-Cursor { $p = New-Object Win32Pt; [Win32In]::GetCursorPos([ref]$p) | Out-Null; return $p }
# One key event, with the scan code the key has on this layout: a program
# that reads keys by scan code (a game) ignores an event without one.
function Key-Event([int]$vk, [int]$flags) {
  # The Windows keys are extended keys, as the keyboard sends them.
  if ($vk -eq 0x5B -or $vk -eq 0x5C) { $flags = $flags -bor 1 }
  $scan = [Win32In]::MapVirtualKeyW([uint32]$vk, 0) -band 0xFF
  [Win32In]::keybd_event([byte]$vk, [byte]$scan, [uint32]$flags, [IntPtr]::Zero)
}
# The modifier letters of a key command (c / s / a / w: Ctrl, Shift, Alt,
# Win) as virtual keys, in the order they go down.
function Mod-Vks([string]$mods) {
  $d = @()
  if ($mods.Contains('c')) { $d += 0x11 }
  if ($mods.Contains('s')) { $d += 0x10 }
  if ($mods.Contains('a')) { $d += 0x12 }
  if ($mods.Contains('w')) { $d += 0x5B }
  return $d
}
# A key of the kdown / kup commands (\"c<code>\" a character found on the
# keyboard layout, \"v<vk>\" a virtual key) as @{ vk; shift; ext }: the key to
# press, whether Shift is needed for the character (unless Shift is a
# modifier already) and the extended-key flag the navigation keys carry.
# $null for a character the layout has no plain key for.
function Resolve-Key([string]$k, [string]$mods) {
  $vk = 0; $shift = $false
  if ($k.StartsWith('v')) {
    $vk = [int]$k.Substring(1)
    if ($vk -lt 1 -or $vk -gt 254) { throw ('not a key: ' + $k) }
  } else {
    $scan = [Win32In]::VkKeyScanW([char][int]$k.Substring(1))
    if ($scan -eq -1 -or ((($scan -shr 8) -band 6) -ne 0)) { return $null }
    $vk = $scan -band 0xFF; $shift = ((($scan -shr 8) -band 1) -eq 1) -and -not $mods.Contains('s')
  }
  $ext = 0; if (($vk -ge 0x21 -and $vk -le 0x28) -or $vk -eq 0x2D -or $vk -eq 0x2E) { $ext = 1 }
  return @{ vk = $vk; shift = $shift; ext = $ext }
}
# Captured actions: ($sx,$sy) is where the cursor started, ($lx,$ly) where we
# last knew it to be, and ($ux,$uy) the user's own movement so far. Jump moves
# the cursor to the action point and pins it there: every reading folds the
# movement since the last one into ($ux,$uy) and snaps the cursor back, so a
# hand that keeps moving cannot drag the click off its point (the movement
# all goes to the ghost / the restore instead). The user's position (start +
# movement) is kept on the virtual screen, where a real cursor would have
# stopped at the edge.
$script:sx = 0; $script:sy = 0; $script:lx = 0; $script:ly = 0; $script:ux = 0; $script:uy = 0
$script:vx = 0; $script:vy = 0; $script:vr = 0; $script:vb = 0
$script:pinned = $false; $script:px = 0; $script:py = 0
# A path too long for one line, sent ahead in pieces (the server's
# 'pathpart'); the next 'cap' whose path says '@' takes it.
$script:pathBuf = ''
function Read-Motion {
  $p = Read-Cursor
  $script:ux += $p.X - $script:lx; $script:uy += $p.Y - $script:ly
  $script:lx = $p.X; $script:ly = $p.Y
  if ($script:vr -gt $script:vx) {
    $script:ux = [math]::Max($script:vx, [math]::Min($script:vr, $script:sx + $script:ux)) - $script:sx
    $script:uy = [math]::Max($script:vy, [math]::Min($script:vb, $script:sy + $script:uy)) - $script:sy
  }
  if ($script:pinned -and ($p.X -ne $script:px -or $p.Y -ne $script:py)) {
    [Win32In]::SetCursorPos($script:px,$script:py) | Out-Null
    $script:lx = $script:px; $script:ly = $script:py
  }
}
function Jump([int]$nx, [int]$ny) {
  Read-Motion; Ghost-Move
  [Win32In]::SetCursorPos($nx,$ny) | Out-Null
  $script:lx = $nx; $script:ly = $ny
  $script:px = $nx; $script:py = $ny; $script:pinned = $true
}
# Ghost cursor: the real cursor is made invisible while it is off doing the
# action, and a click-through window showing the same cursor image follows the
# user's hand instead, so nothing appears to jump.
$script:ghost = [IntPtr]::Zero; $script:ghostBmp = [IntPtr]::Zero; $script:hidden = $false
$script:hx = 0; $script:hy = 0; $script:gw = 32; $script:gh = 32
$script:cursorIds = @(32512,32513,32514,32515,32516,32642,32643,32644,32645,32646,32648,32649,32650)
$script:cursorCopies = @{}
function Ghost-Move {
  if ($script:ghost -eq [IntPtr]::Zero) { return }
  # SWP_NOSIZE | SWP_NOACTIVATE, kept HWND_TOPMOST
  [Win32In]::SetWindowPos($script:ghost, [IntPtr](-1), ($script:sx + $script:ux - $script:hx), ($script:sy + $script:uy - $script:hy), 0, 0, 0x11) | Out-Null
}
function Ghost-Start {
  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  # A private copy of the cursor the user sees right now (the shared system
  # handle is about to be blanked).
  $ci = New-Object Win32CursorInfo
  $ci.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($ci)
  $bmp = $null
  if ([Win32In]::GetCursorInfo([ref]$ci) -and $ci.hCursor -ne [IntPtr]::Zero) {
    $copy = [Win32In]::CopyIcon($ci.hCursor)
    if ($copy -ne [IntPtr]::Zero) {
      try {
        $cur = New-Object System.Windows.Forms.Cursor($copy)
        $script:hx = $cur.HotSpot.X; $script:hy = $cur.HotSpot.Y
        $bmp = [System.Drawing.Icon]::FromHandle($copy).ToBitmap()
      } catch { $bmp = $null }
    }
  }
  if ($bmp -eq $null) {
    $cur = [System.Windows.Forms.Cursors]::Arrow
    $script:hx = $cur.HotSpot.X; $script:hy = $cur.HotSpot.Y
    $bmp = New-Object System.Drawing.Bitmap $cur.Size.Width, $cur.Size.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $cur.Draw($g, (New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height))
    $g.Dispose()
  }
  $script:gw = $bmp.Width; $script:gh = $bmp.Height
  $gx = $script:sx - $script:hx; $gy = $script:sy - $script:hy
  # A bare popup window (no WinForms Form: that only turns TopMost on when it
  # is shown, and a background process is not allowed to raise a window to
  # topmost after the fact - it must be created that way).
  # WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW |
  # WS_EX_NOACTIVATE: above everything, per-pixel alpha, never takes a click
  # or the focus, not in the taskbar. [int]::MinValue is WS_POPUP.
  $h = [Win32In]::CreateWindowExW((0x8 -bor 0x80000 -bor 0x20 -bor 0x80 -bor 0x08000000), 'Static', '', [int]::MinValue, $gx, $gy, $script:gw, $script:gh, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
  if ($h -eq [IntPtr]::Zero) { return }
  $script:ghostBmp = $bmp.GetHbitmap([System.Drawing.Color]::FromArgb(0))
  [Win32In]::SetAlphaBitmap($h, $script:ghostBmp, $gx, $gy, $script:gw, $script:gh)
  $script:ghost = $h
  # Catch up with the hand before the ghost appears (the snapshot above took a
  # few ms), then SW_SHOWNOACTIVATE.
  Read-Motion; Ghost-Move
  [Win32In]::ShowWindow($h, 4) | Out-Null
  [System.Windows.Forms.Application]::DoEvents()
  # Now blank every system cursor so the real one is invisible while it works,
  # keeping a copy of each so they can be put straight back afterwards.
  $cw = [Win32In]::GetSystemMetrics(13); $ch = [Win32In]::GetSystemMetrics(14)
  $bytes = [int][math]::Floor(($cw + 7) / 8) * $ch
  foreach ($id in $script:cursorIds) {
    $orig = [Win32In]::LoadCursorW([IntPtr]::Zero, [IntPtr]$id)
    if ($orig -ne [IntPtr]::Zero) { $c = [Win32In]::CopyIcon($orig); if ($c -ne [IntPtr]::Zero) { $script:cursorCopies[$id] = $c } }
    $and = New-Object byte[] $bytes
    for ($i = 0; $i -lt $bytes; $i++) { $and[$i] = 255 }
    $xor = New-Object byte[] $bytes
    $blank = [Win32In]::CreateCursor([IntPtr]::Zero, 0, 0, $cw, $ch, $and, $xor)
    if ($blank -ne [IntPtr]::Zero) { [Win32In]::SetSystemCursor($blank, $id) | Out-Null }
  }
  $script:hidden = $true
  Read-Motion; Ghost-Move
}
function Ghost-Stop {
  if ($script:hidden) {
    # Put the saved copies straight back (SetSystemCursor consumes them);
    # SPI_SETCURSORS (a slower full reload of the scheme) covers any we missed.
    $missed = $false
    foreach ($id in $script:cursorIds) {
      if ($script:cursorCopies.ContainsKey($id)) { if (-not [Win32In]::SetSystemCursor($script:cursorCopies[$id], $id)) { $missed = $true } }
      else { $missed = $true }
    }
    $script:cursorCopies = @{}
    if ($missed) { [Win32In]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 0) | Out-Null }
    $script:hidden = $false
  }
  if ($script:ghost -ne [IntPtr]::Zero) { [Win32In]::DestroyWindow($script:ghost) | Out-Null; $script:ghost = [IntPtr]::Zero }
  if ($script:ghostBmp -ne [IntPtr]::Zero) { [Win32In]::DeleteObject($script:ghostBmp) | Out-Null; $script:ghostBmp = [IntPtr]::Zero }
}
# Waits until the stopwatch reads $due ms, keeping the real cursor pinned and
# the ghost on the user's hand meanwhile (every ~1 ms, so each display frame
# gets the freshest position).
function Wait-Until($sw, [int]$due) {
  do {
    Read-Motion
    if ($script:ghost -ne [IntPtr]::Zero) {
      Ghost-Move
      [System.Windows.Forms.Application]::DoEvents()
    }
    [System.Threading.Thread]::Sleep(1)
  } while ($sw.ElapsedMilliseconds -lt $due)
}
function Wait-Ms([int]$ms) { Wait-Until ([System.Diagnostics.Stopwatch]::StartNew()) $ms }
# Walks the pinned cursor along a path (\"x,y;x,y;...\", the points evenly
# spaced in time) over $ms: each point is due at its share of the time, and
# the last one is exactly where the travel ends.
function Glide([string]$path, [int]$ms) {
  $pts = $path.Split(';')
  $n = $pts.Count
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  for ($i = 0; $i -lt $n; $i++) {
    $xy = $pts[$i].Split(',')
    Jump ([int]$xy[0]) ([int]$xy[1])
    if ($n -gt 1) { Wait-Until $sw ([int]([long]$ms * ($i + 1) / $n)) }
  }
}
# True when $h belongs to the guarded process (see 'guard' above).
function Guarded([IntPtr]$h) {
  if ($script:guard -eq 0 -or $h -eq [IntPtr]::Zero) { return $false }
  $owner = [uint32]0
  [Win32In]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
  return ($owner -eq [uint32]$script:guard)
}
# True when a click at (x, y) would land on the guarded process. The overlay
# is hit-test transparent, so WindowFromPoint looks straight through it.
function Guarded-Point([int]$x,[int]$y) {
  $p = New-Object Win32Pt; $p.X = $x; $p.Y = $y
  return (Guarded ([Win32In]::WindowFromPoint($p)))
}
# Runs one command (with its optional 'guard <pid>' prefix). Whatever it
# prints is the answer: one line at most, nothing for plain success.
function Run-Cmd([string[]]$a) {
$script:guard = 0
if ($a[0] -eq 'guard') { $script:guard = [int]$a[1]; $a = @($a | Select-Object -Skip 2) }
$cmd = $a[0]
switch ($cmd) {
  'move' {
    # A jump. Through SendInput, not SetCursorPos: a program that reads the
    # mouse as raw input (a game turning its camera) sees SendInput's
    # motion and never sees SetCursorPos at all. (Verified in Roblox: a
    # right-drag walked with SetCursorPos does nothing; SendInput, absolute
    # or relative, turns the camera. Absolute lands on the exact pixel.)
    [Win32In]::MouseAt([int]$a[1],[int]$a[2],0)
  }
  'path' {
    # path <x,y;x,y;...> <ms>: move the cursor through the points, evenly
    # spaced over the time (a Move, Click or Drag with a duration). Each
    # step is SendInput motion, as for 'move'.
    $pts = ([string]$a[1]).Split(';'); $n = $pts.Count; $ms = [int]$a[2]
    $timerRes = ([Win32In]::timeBeginPeriod(1) -eq 0)
    try {
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      for ($i = 0; $i -lt $n; $i++) {
        $xy = $pts[$i].Split(',')
        [Win32In]::MouseAt([int]$xy[0],[int]$xy[1],0)
        $due = [int]([long]$ms * ($i + 1) / $n)
        while ($sw.ElapsedMilliseconds -lt $due) { [System.Threading.Thread]::Sleep(1) }
      }
    } finally { if ($timerRes) { [Win32In]::timeEndPeriod(1) | Out-Null } }
  }
  'down' {
    if (Guarded-Point ([int]$a[1]) ([int]$a[2])) { Write-Output 'skipped'; break }
    [Win32In]::MouseAt([int]$a[1],[int]$a[2],(Down-Flag $a[3]))
  }
  'up' {
    if (Guarded-Point ([int]$a[1]) ([int]$a[2])) { Write-Output 'skipped'; break }
    [Win32In]::MouseAt([int]$a[1],[int]$a[2],(Up-Flag $a[3]))
  }
  'release' {
    # release <button>: lets go of a mouse button where the cursor is,
    # without moving it - what a stop does with a button a Down or Hold
    # left pressed, so the cursor never jumps back to where it went down.
    # Never refused (see Guarded): the press was allowed where it happened.
    [Win32In]::ButtonOnly((Up-Flag $a[1]))
  }
  'tap' {
    # tap / bdown / bup <button>: a click, a press or a release where the
    # cursor is right now, with no move at all (a Click with ~Move off).
    # Guarded like a click at that point.
    $c = Read-Cursor
    if (Guarded-Point $c.X $c.Y) { Write-Output 'skipped'; break }
    [Win32In]::ButtonOnly((Down-Flag $a[1])); [Win32In]::ButtonOnly((Up-Flag $a[1]))
  }
  'bdown' {
    $c = Read-Cursor
    if (Guarded-Point $c.X $c.Y) { Write-Output 'skipped'; break }
    [Win32In]::ButtonOnly((Down-Flag $a[1]))
  }
  'bup' {
    $c = Read-Cursor
    if (Guarded-Point $c.X $c.Y) { Write-Output 'skipped'; break }
    [Win32In]::ButtonOnly((Up-Flag $a[1]))
  }
  'wheel' {
    # wheel <up|down|left|right> <n> <ms> <uneven 0|1>: the wheel turns n
    # notches that way where the cursor is, one event per notch, spread
    # over ms (a moment apart at least), the way a wheel is read; uneven
    # makes the gaps vary like a hand's. The program under the cursor gets
    # it (guarded like a click there).
    $c = Read-Cursor
    if (Guarded-Point $c.X $c.Y) { Write-Output 'skipped'; break }
    $n = [Math]::Min([Math]::Max([int]$a[2], 1), 200)
    $ms = 0; if ($a.Count -gt 3) { $ms = [int]$a[3] }
    $uneven = ($a.Count -gt 4 -and $a[4] -eq '1')
    $gap = [Math]::Max(12, [int]($ms / $n))
    $rnd = New-Object System.Random
    $delta = 120; $horizontal = $false
    switch ($a[1]) { 'down' { $delta = -120 } 'left' { $delta = -120; $horizontal = $true } 'right' { $horizontal = $true } }
    for ($i = 0; $i -lt $n; $i++) {
      if ($i -gt 0) {
        $g = $gap; if ($uneven) { $g = [int]($gap * (0.5 + $rnd.NextDouble())) }
        [System.Threading.Thread]::Sleep($g)
      }
      [Win32In]::Wheel($delta, $horizontal)
    }
  }
  'cap' {
    # cap <move|click|drag> <ghost 0|1> <button> <x> <y> <x2> <y2> <ms> [path]
    # A whole Captures action in one process: remember the cursor, do the
    # action, put the cursor back where it was plus whatever the user moved it
    # meanwhile - so it is only away for a few milliseconds and the user's own
    # movement is never lost. With ghost=1 the real cursor is hidden for the
    # duration and a ghost cursor stands in for it, so nothing appears to jump.
    # The path (\"x,y;x,y;...\") is the travel over $ms: to (x, y) for a
    # move or a click, from (x, y) to (x2, y2) for a drag; without one the
    # cursor jumps. A path of '@' is the one sent ahead in pieces (see
    # 'pathpart'). Prints \"savedX,savedY,restoredX,restoredY\".
    $kind = $a[1]; $useGhost = ($a[2] -eq '1'); $btn = $a[3]
    $x = [int]$a[4]; $y = [int]$a[5]; $x2 = [int]$a[6]; $y2 = [int]$a[7]; $ms = [int]$a[8]
    $path = ''; if ($a.Count -gt 9) { $path = [string]$a[9] }
    if ($path -eq '@') { $path = $script:pathBuf }
    $script:pathBuf = ''
    if ($kind -ne 'move' -and ((Guarded-Point $x $y) -or ($kind -eq 'drag' -and (Guarded-Point $x2 $y2)))) {
      Write-Output 'skipped'; break
    }
    $s = Read-Cursor
    # Fresh tracking state: the server runs many of these in one process.
    $script:sx = $s.X; $script:sy = $s.Y; $script:lx = $s.X; $script:ly = $s.Y
    $script:ux = 0; $script:uy = 0; $script:pinned = $false
    # SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN
    $script:vx = [Win32In]::GetSystemMetrics(76); $script:vy = [Win32In]::GetSystemMetrics(77)
    $script:vr = $script:vx + [Win32In]::GetSystemMetrics(78) - 1; $script:vb = $script:vy + [Win32In]::GetSystemMetrics(79) - 1
    # 1 ms timer resolution: Thread.Sleep(1) is otherwise ~16 ms, which would
    # leave the pin / ghost updating at a stuttery ~60 Hz.
    $timerRes = ([Win32In]::timeBeginPeriod(1) -eq 0)
    # Set while the button is down, so a failure part-way lets go of it.
    $held = $false
    try {
      if ($useGhost) { Ghost-Start }
      switch ($kind) {
        'move' {
          if ($path -ne '') { Glide $path $ms } else { Jump $x $y; Wait-Ms $ms }
        }
        'click' {
          if ($path -ne '') { Glide $path $ms } else { Jump $x $y }
          Wait-Ms 15
          $held = $true; [Win32In]::MouseAt($x,$y,(Down-Flag $btn)); Wait-Ms 15; [Win32In]::MouseAt($x,$y,(Up-Flag $btn)); $held = $false
        }
        'drag' {
          Jump $x $y
          Wait-Ms 15
          $held = $true; [Win32In]::MouseAt($x,$y,(Down-Flag $btn))
          if ($path -ne '') { Glide $path $ms } else { Wait-Ms $ms; Jump $x2 $y2 }
          Wait-Ms 15
          [Win32In]::MouseAt($x2,$y2,(Up-Flag $btn)); $held = $false
        }
      }
      Read-Motion
      $script:pinned = $false
      $tx = $s.X + $script:ux; $ty = $s.Y + $script:uy
      [Win32In]::SetCursorPos($tx,$ty) | Out-Null
      $script:lx = $tx; $script:ly = $ty
    } finally {
      if ($held) { [Win32In]::ButtonOnly((Up-Flag $btn)) }
      Ghost-Stop
      if ($timerRes) { [Win32In]::timeEndPeriod(1) | Out-Null }
    }
    Write-Output (\"{0},{1},{2},{3}\" -f $s.X,$s.Y,$tx,$ty)
  }
  'cursors-restore' {
    # Reload the user's cursor scheme (undoes ghost blanking after a crash).
    [Win32In]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 0) | Out-Null
  }
  'key' {
    # Keys go to the foreground window. The text arrives base64-encoded (see
    # WindowsBackend.send_keys): one argument with no spaces or line breaks,
    # so nothing in it can ever be read as a command of its own.
    if (Guarded ([Win32In]::GetForegroundWindow())) { Write-Output 'skipped'; break }
    Add-Type -AssemblyName System.Windows.Forms
    $text = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$a[1]))
    # Text SendKeys cannot read (a stray brace, an unknown {keyword}) is
    # refused whole, nothing typed. Its message quotes what it did not
    # like ('Keyword \"PASSWORD\" is not valid.') and the answer ends up in
    # Loop Automator's log, so the quoted part is left out of it.
    try { [System.Windows.Forms.SendKeys]::SendWait($text) }
    catch {
      $why = $_.Exception.Message
      if ($null -ne $_.Exception.InnerException) { $why = $_.Exception.InnerException.Message }
      throw ('the text is not valid SendKeys syntax: ' + ($why -replace '\"[^\"]*\"', '\"...\"'))
    }
  }
  'hold' {
    # hold <mods|-> <keys> <lead> <hold> <gap> <trail>: one keystroke with
    # real timing (~Keys). The modifiers (letters c / s / a / w) go down, $lead
    # ms later each key (\"c<code>\" a character found on the keyboard
    # layout, \"v<vk>\" a virtual key) is held $hold ms, $gap ms apart, and
    # $trail ms after the last the modifiers come up. A character the
    # layout has no key for is sent by SendKeys instead.
    if (Guarded ([Win32In]::GetForegroundWindow())) { Write-Output 'skipped'; break }
    $mods = [string]$a[1]; $keys = ([string]$a[2]).Split(',')
    $lead = [int]$a[3]; $hold = [int]$a[4]; $gap = [int]$a[5]; $trail = [int]$a[6]
    $down = @()
    if ($mods.Contains('c')) { $down += 0x11 }
    if ($mods.Contains('s')) { $down += 0x10 }
    if ($mods.Contains('a')) { $down += 0x12 }
    if ($mods.Contains('w')) { $down += 0x5B }
    try {
      foreach ($m in $down) { Key-Event $m 0 }
      if ($down.Count -gt 0) { [System.Threading.Thread]::Sleep($lead) }
      for ($i = 0; $i -lt $keys.Count; $i++) {
        $k = $keys[$i]; $vk = 0; $shift = $false
        if ($k.StartsWith('v')) { $vk = [int]$k.Substring(1) }
        else {
          $ch = [char][int]$k.Substring(1)
          $scan = [Win32In]::VkKeyScanW($ch)
          # No key for it, or one that needs Ctrl / Alt (AltGr) on this
          # layout: SendKeys knows how to type it.
          if ($scan -eq -1 -or ((($scan -shr 8) -band 6) -ne 0)) {
            Add-Type -AssemblyName System.Windows.Forms
            $t = [string]$ch; if ('+^%~(){}[]'.Contains($t)) { $t = '{' + $t + '}' }
            [System.Windows.Forms.SendKeys]::SendWait($t)
            if ($i -lt $keys.Count - 1) { [System.Threading.Thread]::Sleep($gap) }
            continue
          }
          $vk = $scan -band 0xFF; $shift = ((($scan -shr 8) -band 1) -eq 1) -and -not $mods.Contains('s')
        }
        # KEYEVENTF_EXTENDEDKEY for the navigation keys, as the keyboard sends them.
        $ext = 0; if (($vk -ge 0x21 -and $vk -le 0x28) -or $vk -eq 0x2D -or $vk -eq 0x2E) { $ext = 1 }
        if ($shift) { Key-Event 0x10 0 }
        Key-Event $vk $ext
        [System.Threading.Thread]::Sleep($hold)
        Key-Event $vk ($ext -bor 2)
        if ($shift) { Key-Event 0x10 2 }
        if ($i -lt $keys.Count - 1) { [System.Threading.Thread]::Sleep($gap) }
      }
      if ($down.Count -gt 0) { [System.Threading.Thread]::Sleep($trail) }
    } finally {
      [array]::Reverse($down)
      foreach ($m in $down) { Key-Event $m 2 }
    }
  }
  'kdown' {
    # kdown <mods|-> <keys>: the modifiers go down, then each key (the forms
    # of 'hold'), and they stay down - a Key action's Down, or the start of
    # its Hold; 'kup' is the reverse. A character the layout has no key for
    # cannot be held: SendKeys types it once instead.
    if (Guarded ([Win32In]::GetForegroundWindow())) { Write-Output 'skipped'; break }
    $mods = [string]$a[1]; $keys = ([string]$a[2]).Split(',')
    # Every key is resolved before anything goes down, so a bad one is an
    # error and not a modifier left pressed; and what did go down before a
    # failure comes back up.
    $plan = @(); foreach ($k in $keys) { $plan += ,@($k, (Resolve-Key $k $mods)) }
    $pressed = @()
    try {
      foreach ($m in (Mod-Vks $mods)) { Key-Event $m 0; $pressed += $m }
      foreach ($pk in $plan) {
        $r = $pk[1]
        if ($null -eq $r) {
          Add-Type -AssemblyName System.Windows.Forms
          $t = [string][char][int]([string]$pk[0]).Substring(1); if ('+^%~(){}[]'.Contains($t)) { $t = '{' + $t + '}' }
          [System.Windows.Forms.SendKeys]::SendWait($t)
          continue
        }
        if ($r.shift) { Key-Event 0x10 0; $pressed += 0x10 }
        Key-Event $r.vk $r.ext; $pressed += $r.vk
      }
      $pressed = @()
    } finally {
      [array]::Reverse($pressed)
      foreach ($v in $pressed) { Key-Event $v 2 }
    }
  }
  'kup' {
    # kup <mods|-> <keys>: lets go of what kdown pressed, keys first (last
    # down first), then the modifiers. Never refused (see Guarded): a key
    # left down would be far worse than a release landing on this app.
    $mods = [string]$a[1]; $keys = ([string]$a[2]).Split(',')
    [array]::Reverse($keys)
    foreach ($k in $keys) {
      $r = Resolve-Key $k $mods
      if ($null -eq $r) { continue }
      Key-Event $r.vk ($r.ext -bor 2)
      if ($r.shift) { Key-Event 0x10 2 }
    }
    $down = @(Mod-Vks $mods)
    [array]::Reverse($down)
    foreach ($m in $down) { Key-Event $m 2 }
  }
  'cursor' {
    # Where the real cursor is right now, as "x,y" (Capture actions).
    Add-Type -AssemblyName System.Windows.Forms
    $p = [System.Windows.Forms.Cursor]::Position
    Write-Output (\"{0},{1}\" -f $p.X,$p.Y)
  }
  'pixel' {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap 1,1
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen([int]$a[1],[int]$a[2],0,0,(New-Object System.Drawing.Size 1,1))
    $c = $bmp.GetPixel(0,0)
    Write-Output (\"{0},{1},{2}\" -f $c.R,$c.G,$c.B)
    $g.Dispose(); $bmp.Dispose()
  }
  'rect' {
    # Whole screen rect as a base64 PNG on one line (Pixel Detect scans it).
    Add-Type -AssemblyName System.Drawing
    $w = [Math]::Max(1, [int]$a[3]); $h = [Math]::Max(1, [int]$a[4])
    $bmp = New-Object System.Drawing.Bitmap $w,$h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen([int]$a[1],[int]$a[2],0,0,(New-Object System.Drawing.Size $w,$h))
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output ([Convert]::ToBase64String($ms.ToArray()))
    $ms.Dispose(); $g.Dispose(); $bmp.Dispose()
  }
}
}
if ($cmd -ne 'serve') { Run-Cmd $a; exit 0 }
# Long-running helper: one line in, one line out, until stdin closes or
# 'quit'. Spawning PowerShell costs ~200 ms per call; answering from a process
# that is already up costs a few ms, which is what lets a follow-cursor Pixel
# Detect keep up with the mouse and an action run in one frame. Besides every
# command above (input commands get their 'guard <pid>' prefix as usual; the
# 'key' text is one base64 argument; \"ok\" is answered when the command
# prints nothing), the server has read commands of its own:
#   find x y w h r g b tol step guard  -> \"x,y\" of the first pixel within
#     tol of (r,g,b), sampling every step-th pixel (centre first), or
#     \"none,r,g,b\" with the centre pixel's colour. A match on a window of
#     `guard` (Loop Automator itself, ~Self off) is skipped; 0 matches
#     anything. The scan runs here, in compiled C#, so no image crosses the pipe.
#   tplpart id b64               -> \"ok\": a piece of a template on its way
#     (a line over ~4 KB does not make it through the pipe, so a PNG comes
#     in pieces of a couple of thousand characters).
#   tpl id b64                   -> \"ok\": the last piece; the pieces so far
#     plus this one are the base64 PNG kept as template `id` for image
#     commands (a handful are kept; older ones are dropped).
#   image x y w h id tol guard grey miss edge -> \"x,y\" of the top-left of
#     the first spot in the rect where the template's pixels are within tol
#     of the screen (grey 1: on brightness alone, ignoring colour; up to
#     miss % of them may be off; its outermost edge pixels are not compared
#     when it is big enough to have an inside; every offset is tried, the template's centre pixel
#     first, so a miss costs about one comparison per offset), \"none\", or
#     \"notpl\" when `id` is not loaded (send a tpl and try again). `guard` as for find.
#   pathpart chars               -> \"ok\": a piece of a captured action's
#     path on its way (a long travel is more points than one line holds);
#     the next 'cap' whose path argument is '@' uses the pieces so far.
#   pixel x y                    -> \"r,g,b\"
#   cursor                       -> \"x,y\"
# A failing command answers \"error ...\". The first line printed is \"ready\".
[Console]::InputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -ReferencedAssemblies System.Drawing @\"
using System; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
using System.Collections.Generic; using System.IO;
public class Scan {
  static byte[] buf = new byte[0];
  // Templates for 'image', as 32bpp BGRA rows (stride w * 4), by id.
  class Tpl { public int w; public int h; public byte[] px; }
  static Dictionary<string, Tpl> tpls = new Dictionary<string, Tpl>();
  const int MaxTpls = 16;
  // Pieces of templates still being uploaded (see Part / Load).
  static Dictionary<string, System.Text.StringBuilder> parts = new Dictionary<string, System.Text.StringBuilder>();
  [StructLayout(LayoutKind.Sequential)] struct PT { public int x; public int y; }
  [DllImport(\"user32.dll\")] static extern IntPtr WindowFromPoint(PT p);
  [DllImport(\"user32.dll\")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  static bool Near(byte[] p, int i, int r, int g, int b, int tol) {
    return Math.Abs(p[i+2] - r) <= tol && Math.Abs(p[i+1] - g) <= tol && Math.Abs(p[i] - b) <= tol;
  }
  // True when the window at (x, y) belongs to the guarded process (~Self
  // off). The overlay is click-through, so WindowFromPoint looks past it to
  // whatever is underneath — a match on Loop Automator's own builder window
  // is skipped, a match on the target app is not.
  static bool Guarded(int x, int y, int guard) {
    if (guard == 0) return false;
    PT p; p.x = x; p.y = y;
    IntPtr h = WindowFromPoint(p);
    if (h == IntPtr.Zero) return false;
    uint pid; GetWindowThreadProcessId(h, out pid);
    return pid == (uint)guard;
  }
  // Grabs the screen rect into `buf` (32bpp BGRA) and returns its stride.
  static int Grab(int x, int y, int w, int h) {
    using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb))
    using (Graphics gr = Graphics.FromImage(bmp)) {
      gr.CopyFromScreen(x, y, 0, 0, new Size(w, h));
      BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      int n = d.Stride * h;
      if (buf.Length < n) buf = new byte[n];
      Marshal.Copy(d.Scan0, buf, 0, n);
      bmp.UnlockBits(d);
      return d.Stride;
    }
  }
  public static string Find(int x, int y, int w, int h, int r, int g, int b, int tol, int step, int guard) {
    int stride = Grab(x, y, w, h);
    int cx = w / 2, cy = h / 2, c = cy * stride + cx * 4;
    if (Near(buf, c, r, g, b, tol) && !Guarded(x + cx, y + cy, guard)) return (x + cx) + \",\" + (y + cy);
    for (int yy = 0; yy < h; yy += step) {
      int row = yy * stride;
      for (int xx = 0; xx < w; xx += step)
        if (Near(buf, row + xx * 4, r, g, b, tol) && !Guarded(x + xx, y + yy, guard)) return (x + xx) + \",\" + (y + yy);
    }
    return \"none,\" + buf[c+2] + \",\" + buf[c+1] + \",\" + buf[c];
  }
  public static string Pixel(int x, int y) {
    Grab(x, y, 1, 1);
    return buf[2] + \",\" + buf[1] + \",\" + buf[0];
  }
  public static string Part(string id, string b64) {
    System.Text.StringBuilder sb;
    if (!parts.TryGetValue(id, out sb)) { sb = new System.Text.StringBuilder(); parts[id] = sb; }
    sb.Append(b64);
    return \"ok\";
  }
  public static string Load(string id, string b64) {
    System.Text.StringBuilder sb;
    if (parts.TryGetValue(id, out sb)) { parts.Remove(id); b64 = sb.Append(b64).ToString(); }
    Tpl t = new Tpl();
    using (MemoryStream ms = new MemoryStream(Convert.FromBase64String(b64)))
    using (Bitmap src = new Bitmap(ms))
    using (Bitmap bmp = src.Clone(new Rectangle(0, 0, src.Width, src.Height), PixelFormat.Format32bppArgb)) {
      t.w = bmp.Width; t.h = bmp.Height; t.px = new byte[t.w * t.h * 4];
      BitmapData d = bmp.LockBits(new Rectangle(0, 0, t.w, t.h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
      for (int yy = 0; yy < t.h; yy++)
        Marshal.Copy(new IntPtr(d.Scan0.ToInt64() + yy * d.Stride), t.px, yy * t.w * 4, t.w * 4);
      bmp.UnlockBits(d);
    }
    if (tpls.Count >= MaxTpls) tpls.Clear();
    tpls[id] = t;
    return \"ok\";
  }
  // Pixel i of p within tol of pixel j of q (both BGRA): on every channel,
  // or with grey on brightness alone (30 / 59 / 11 % weights), so a tint
  // that changes the colour but not how light it is still matches.
  static bool Same(byte[] p, int i, byte[] q, int j, int tol, bool grey) {
    if (grey) {
      int lp = (p[i+2] * 299 + p[i+1] * 587 + p[i] * 114) / 1000;
      int lq = (q[j+2] * 299 + q[j+1] * 587 + q[j] * 114) / 1000;
      return Math.Abs(lp - lq) <= tol;
    }
    return Math.Abs(p[i] - q[j]) <= tol && Math.Abs(p[i+1] - q[j+1]) <= tol && Math.Abs(p[i+2] - q[j+2]) <= tol;
  }
  // The template at (ox, oy) matches with at most `allowed` pixels off, its
  // outermost `e` pixels left out.
  static bool At(int stride, int ox, int oy, Tpl t, int tol, bool grey, int allowed, int e) {
    int off = 0;
    for (int ty = e; ty < t.h - e; ty++) {
      int row = (oy + ty) * stride + ox * 4, trow = ty * t.w * 4;
      for (int tx = e; tx < t.w - e; tx++)
        if (!Same(buf, row + tx * 4, t.px, trow + tx * 4, tol, grey) && ++off > allowed) return false;
    }
    return true;
  }
  public static string Image(int x, int y, int w, int h, string id, int tol, int guard, bool grey, int miss, int edge) {
    Tpl t;
    if (!tpls.TryGetValue(id, out t)) return \"notpl\";
    if (t.w > w || t.h > h) return \"none\";
    int stride = Grab(x, y, w, h);
    // miss % of the template's pixels may be off; with none allowed the
    // centre pixel alone rules most offsets out.
    // The outermost edge pixels are skipped when there is an inside.
    int e = (edge > 0 && t.w > 2 * edge && t.h > 2 * edge) ? edge : 0;
    int allowed = Math.Max(0, Math.Min(100, miss)) * (t.w - 2 * e) * (t.h - 2 * e) / 100;
    int tcx = t.w / 2, tcy = t.h / 2, tc = (tcy * t.w + tcx) * 4;
    for (int oy = 0; oy + t.h <= h; oy++) {
      int row = (oy + tcy) * stride;
      for (int ox = 0; ox + t.w <= w; ox++) {
        if (allowed == 0 && !Same(buf, row + (ox + tcx) * 4, t.px, tc, tol, grey)) continue;
        if (At(stride, ox, oy, t, tol, grey, allowed, e) && !Guarded(x + ox + tcx, y + oy + tcy, guard)) return (x + ox) + \",\" + (y + oy);
      }
    }
    return \"none\";
  }
}
\"@
$out = [Console]::Out
$out.WriteLine('ready'); $out.Flush()
while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line -or $line -eq 'quit') { break }
  $p = $line.Split(' ')
  try {
    switch ($p[0]) {
      'find' { $out.WriteLine([Scan]::Find([int]$p[1],[int]$p[2],[int]$p[3],[int]$p[4],[int]$p[5],[int]$p[6],[int]$p[7],[int]$p[8],[int]$p[9],[int]$p[10])) }
      'pixel' { $out.WriteLine([Scan]::Pixel([int]$p[1],[int]$p[2])) }
      'tplpart' { $out.WriteLine([Scan]::Part($p[1], $p[2])) }
      'tpl' { $out.WriteLine([Scan]::Load($p[1], $p[2])) }
      'pathpart' { $script:pathBuf += [string]$p[1]; $out.WriteLine('ok') }
      'image' { $out.WriteLine([Scan]::Image([int]$p[1],[int]$p[2],[int]$p[3],[int]$p[4],$p[5],[int]$p[6],[int]$p[7],($p[8] -eq '1'),[int]$p[9],[int]$p[10])) }
      'cursor' { $c = [System.Windows.Forms.Cursor]::Position; $out.WriteLine(('{0},{1}' -f $c.X,$c.Y)) }
      default {
        $res = @(Run-Cmd $p)
        if ($res.Count -eq 0) { $out.WriteLine('ok') } else { $out.WriteLine([string]$res[-1]) }
      }
    }
  } catch { $out.WriteLine('error ' + $_.Exception.Message.Replace(\"`n\",' ').Replace(\"`r\",' ')) }
  $out.Flush()
}
"""


func _init() -> void:
	# Written once here so an unwritable location is known up front; every
	# launch rewrites it again (see _spawn_args).
	_helper_real_path = PowerShellHostT.write_script(HELPER_FILE, HELPER_SCRIPT)


func backend_name() -> String:
	return "Windows (PowerShell, experimental)"


func is_real() -> bool:
	return true


## Ends the server and, with `wait`, joins the warm-up thread. Main thread
## only. The owner calls this before dropping the backend. Starting the
## server takes a second or two, so a thread still at it is not waited for
## unless asked (a Run and a quick Stop would stall the UI): it sees
## `_closing` and ends the server itself. At quit `wait` is given, since
## a thread running this code once the scripts are gone is a crash;
## PREDELETE below is the last resort.
func shutdown(wait: bool = false) -> void:
	_closing = true
	scan_generation += 1
	if _warm_thread != null and _warm_thread.is_alive() and not wait:
		# The lock is free only while the thread is not inside _server_call:
		# then the server (if it got up) is ended here, since the thread
		# has already passed its own check.
		if _server_mutex.try_lock():
			_stop_server()
			_server_mutex.unlock()
		return
	if _warm_thread != null:
		_warm_thread.wait_to_finish()
		_warm_thread = null
	_server_mutex.lock()
	_stop_server()
	_server_mutex.unlock()


func settled() -> bool:
	return _warm_thread == null and _server.is_empty()


## Ends the server process outright, whatever it is doing: the thread
## waiting on its answer sees it gone and returns "", and the next call
## starts a fresh server. Nothing here touches `_server` itself (the
## waiting thread holds the lock and cleans up once it notices).
## A ghost cursor the killed helper had blanked is put back by the caller
## that gets the empty answer (see run_captured).
func interrupt() -> void:
	scan_generation += 1
	var pid := _server_pid
	if pid < 0:
		return
	if OS.is_process_running(pid):
		_cut_short_at = Time.get_ticks_msec()
		_cut_short = true
		OS.kill(pid)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		# No instance method calls here: the script instance is already gone.
		if _warm_thread != null:
			_warm_thread.wait_to_finish()
		if not _server.is_empty():
			_shutdown_server(_server)


## Starts the helper server on a worker thread so it is ready before the
## first action. Safe to call any time; a call that needs the server while
## it is still starting simply waits for it.
func warm_up() -> void:
	if _warm_thread != null or not _server.is_empty() or _helper_real_path.is_empty():
		return
	_warm_thread = Thread.new()
	_warm_thread.start(func(): _server_call("cursor"))


# ------------------------------------------------------------ read server
## Sends one command line to the helper server. Returns {"served": bool,
## "line": String}: served is false when no server could take the command
## (callers may use the one-shot path instead); with served true, line is the
## answer — "" if the server did not answer in time (it is then restarted on
## the next call), "error ..." if the command itself failed. An input command
## that was served must not be run again either way. Thread-safe.
func _server_call(cmd: String, timeout_ms: int = SERVER_READ_TIMEOUT_MS) -> Dictionary:
	_server_mutex.lock()
	# A finished warm-up thread is joined by the next caller (never by itself).
	if _warm_thread != null and not _warm_thread.is_alive() and OS.get_thread_caller_id() == OS.get_main_thread_id():
		_warm_thread.wait_to_finish()
		_warm_thread = null
	var result := {"served": false, "line": ""}
	var bytes := cmd.to_utf8_buffer().size()
	# An interrupt nobody was waiting through (the thread had just finished):
	# forgotten, rather than swallowing a command of a later run.
	if _cut_short and Time.get_ticks_msec() - _cut_short_at > CUT_SHORT_MS:
		_cut_short = false
	if bytes > PIPE_LINE_MAX:
		# Sent, it would be cut short (see PIPE_LINE_MAX): the helper would
		# wait for the rest of the line and this side for the answer, and the
		# timeout would kill a healthy helper. Refused here, whole.
		result["served"] = true
		result["line"] = "error the command is %d bytes; one line to the helper holds %d" % [bytes, PIPE_LINE_MAX]
	elif _cut_short and OS.get_thread_caller_id() != OS.get_main_thread_id():
		# The interrupt landed between two commands of the action being cut
		# short (a path piece and the action itself, say): the next command
		# from its thread is the one meant, and it is not run on a fresh
		# server. (A main-thread command meanwhile - the stop letting go of
		# a button - goes through and starts one.)
		result["served"] = true
		_cut_short = false
		if not _server.is_empty() and not OS.is_process_running(_server_pid):
			_stop_server()
	elif _server_ready():
		result["served"] = true
		var io: FileAccess = _server["stdio"]
		io.store_line(cmd)
		var line := _server_read_line(timeout_ms)
		# An empty answer is the interrupt this thread was waiting through
		# (not a fault), or the helper stuck.
		if line.is_empty():
			if not _cut_short:
				push_warning("WindowsBackend: helper server did not answer %s; restarting it on the next call." % JSON.stringify(_loggable(cmd)))
			_stop_server()
		result["line"] = line
		# An interrupt that came after the answer had arrived is spent too.
		_cut_short = false
	if _closing:
		_stop_server()   # shut down meanwhile: this thread ends the server
	_server_mutex.unlock()
	return result


## `cmd` as it may appear in a log line: the text of a 'key' command (which
## can be anything a loop types, a password included) is replaced by its
## length. Godot's log file is what ends up attached to bug reports.
static func _loggable(cmd: String) -> String:
	var parts := cmd.split(" ")
	for i in parts.size() - 1:
		if parts[i] == "key":
			parts[i + 1] = "<%d chars>" % parts[i + 1].length()
			break
		# A press by key: the key list (after the modifiers) says what was typed.
		if (parts[i] == "hold" or parts[i] == "kdown" or parts[i] == "kup") and i + 2 < parts.size():
			parts[i + 2] = "<%d keys>" % (parts[i + 2].count(",") + 1)
			break
	# A travel path is hundreds of points; its length says enough.
	for i in parts.size():
		if parts[i].contains(";"):
			parts[i] = "<%d points>" % (parts[i].count(";") + 1)
	# A template upload is a PNG in base64, in pieces.
	if parts.size() == 3 and (parts[0] == "tpl" or parts[0] == "tplpart"):
		parts[2] = "<%d chars>" % parts[2].length()
	return " ".join(parts)


## The answer line of a served read command, or "" (no server, timeout or
## error) — reads are safe to repeat on the one-shot path.
func _server_read(cmd: String) -> String:
	var line: String = _server_call(cmd)["line"]
	return "" if line.begins_with("error ") else line


## True with a live server (starting one if needed). Holds off for a while
## after a failed start so a broken helper does not cost a start-up per read.
func _server_ready() -> bool:
	if _closing:
		return false
	if not _server.is_empty():
		if OS.is_process_running(_server["pid"]):
			return true
		_stop_server()
	if _helper_real_path.is_empty():
		return false
	if _server_failed_at >= 0 and Time.get_ticks_msec() - _server_failed_at < SERVER_RETRY_MS:
		return false
	var args := _spawn_args(PackedStringArray(["serve"]))
	var started := OS.execute_with_pipe(PowerShellHostT.executable(), args, false) if not args.is_empty() else {}
	if started.is_empty():
		push_warning("WindowsBackend: could not start the read server; using one-shot reads.")
		_server_failed_at = Time.get_ticks_msec()
		return false
	_server = started
	_server_pid = int(started["pid"])
	_server_pending = PackedByteArray()
	var hello := _server_read_line(SERVER_START_TIMEOUT_MS)
	if hello != "ready":
		# An interrupt() while it was coming up is not the helper's fault (see
		# _run_sync): no hold-off, or the next ten seconds go one-shot.
		if not _cut_short:
			push_warning("WindowsBackend: read server did not come up (got %s); using one-shot reads." % JSON.stringify(hello))
			_server_failed_at = Time.get_ticks_msec()
		_stop_server()
		return false
	_server_failed_at = -1
	return true


## Next line from the server's stdout, or "" after `timeout_ms` (or once the
## process is gone). The pipe is non-blocking, so this polls.
func _server_read_line(timeout_ms: int) -> String:
	var io: FileAccess = _server["stdio"]
	var deadline := Time.get_ticks_msec() + timeout_ms
	var next_alive_check := 0
	while true:
		var nl := _server_pending.find(10)
		if nl >= 0:
			var line := _server_pending.slice(0, nl).get_string_from_ascii().strip_edges()
			_server_pending = _server_pending.slice(nl + 1)
			return line
		var chunk := io.get_buffer(4096)
		if chunk.size() > 0:
			_server_pending.append_array(chunk)
			continue
		var now := Time.get_ticks_msec()
		if now >= deadline:
			return ""
		if now >= next_alive_check:
			if not OS.is_process_running(_server["pid"]):
				return ""
			next_alive_check = now + 100
		OS.delay_msec(1)
	return ""


func _stop_server() -> void:
	if _server.is_empty():
		return
	var server := _server
	_server = {}
	_server_pid = -1
	_server_pending = PackedByteArray()
	_shutdown_server(server)


## Ends a server process. Static (and given the pipes explicitly) so it can
## also run from _notification(PREDELETE), when the instance is already gone.
static func _shutdown_server(server: Dictionary) -> void:
	var pid: int = server["pid"]
	var io: FileAccess = server["stdio"]
	if OS.is_process_running(pid):
		io.store_line("quit")
	io.close()
	(server["stderr"] as FileAccess).close()
	# Closing stdin ends the serve loop; a stuck helper is killed outright.
	for i in 20:
		if not OS.is_process_running(pid):
			return
		OS.delay_msec(5)
	OS.kill(pid)


## The powershell.exe arguments for one launch of the helper with `extra`
## appended, or an empty array if the script could not be (re)written. The
## script is rewritten from HELPER_SCRIPT immediately before every launch, so
## what runs is always this build's helper and never an edited copy.
func _spawn_args(extra: PackedStringArray) -> PackedStringArray:
	var path := PowerShellHostT.write_script(HELPER_FILE, HELPER_SCRIPT)
	if path.is_empty():
		push_warning("WindowsBackend: could not write the helper script to %s." % PowerShellHostT.script_dir())
		return PackedStringArray()
	var args := PowerShellHostT.file_args(path)
	args.append_array(extra)
	return args


## Runs the helper once for `extra` (the one-shot path, ~200 ms per call):
## {"code": exit code, -1 if it could not start; "line": first output line
## or ""}.
func _run_once(extra: PackedStringArray) -> Dictionary:
	var args := _spawn_args(extra)
	if args.is_empty():
		return {"code": -1, "line": ""}
	var output: Array = []
	var code := OS.execute(PowerShellHostT.executable(), args, output, true)
	var line := String(output[0]).strip_edges() if not output.is_empty() else ""
	return {"code": code, "line": line}


## Runs one input command and returns its output line ("" if it failed or
## printed nothing). Goes to the helper server when there is one (a few ms),
## otherwise spawns the helper for this call. Input commands carry the guard
## pid (see the helper's 'guard'); a command the guard refused sets
## `last_skipped`. `timeout_ms` bounds how long the server may take — a
## captured action legitimately runs for its whole dwell.
func _run_sync(extra: PackedStringArray, timeout_ms: int = SERVER_READ_TIMEOUT_MS) -> String:
	if _helper_real_path.is_empty():
		return ""
	var cmd := PackedStringArray()
	if avoid_pid > 0:
		cmd.append_array(PackedStringArray(["guard", str(avoid_pid)]))
	cmd.append_array(extra)
	last_skipped = false
	_last_error = false
	var served := _server_call(" ".join(cmd), timeout_ms)
	var line: String = served["line"]
	if served["served"]:
		if line.begins_with("error "):
			_last_error = true
			var why := line.substr(6)
			# PowerShell quotes the value it could not use ('Cannot convert
			# value "128512" to type "System.Char"'): for a key command that
			# is a piece of what the loop types, and the log is what gets
			# attached to bug reports (see _loggable).
			if extra[0] in ["key", "hold", "kdown", "kup"]:
				why = RegEx.create_from_string("\"[^\"]*\"").sub(why, "\"...\"", true)
			push_warning("WindowsBackend: %s failed in the helper: %s" % [extra[0], why])
			if extra[0] in ["key", "hold", "kdown"]:
				keys_refused = true
			return ""
		if line.is_empty() and extra[0] in ["key", "hold", "kdown"]:
			# Ended without an answer (timed out and killed): SendKeys may have
			# had a modifier of a "+(…)" or "^{…}" down, and the helper that
			# would have let go of it is gone. Let go of all four.
			_run_sync(PackedStringArray(["kup", "csaw", "v17"]))
			keys_refused = true
			return ""
		if line == "ok":
			line = ""
	elif _cut_short and OS.get_thread_caller_id() != OS.get_main_thread_id():
		# The interrupt landed while the server was coming up for this very
		# command (a captured action right after Run, or after the last stop
		# ended the server): the command is the one meant, and it is not run
		# on a one-shot process, where nothing could cut it short.
		_cut_short = false
		return ""
	elif extra[0] in ["key", "hold", "kdown"]:
		# No server, and what a loop types (a password, say) is not put on
		# a process's command line, where process auditing and any program
		# of the user's can read it: the press is not made.
		if not keys_refused:
			push_warning("WindowsBackend: %s not sent: the helper server is not running." % extra[0])
		keys_refused = true
		return ""
	else:
		# No server: one process for this call.
		var once := _run_once(cmd)
		if int(once["code"]) != 0:
			return ""
		line = once["line"]
	last_skipped = (line == "skipped")
	return line


## Parses the first point of an "x,y[,...]" line from the helper, or (-1, -1).
static func _parse_point(line: String, offset: int = 0) -> Vector2i:
	var parts := line.split(",")
	if parts.size() >= offset + 2 and parts[offset].is_valid_int() and parts[offset + 1].is_valid_int():
		return Vector2i(int(parts[offset]), int(parts[offset + 1]))
	return Vector2i(-1, -1)


func move_to(pos: Vector2i) -> void:
	_last_pos = pos
	_run_sync(PackedStringArray(["move", str(pos.x), str(pos.y)]))


func mouse_button(button: int, pressed: bool, pos: Vector2i) -> void:
	_last_pos = pos
	var verb := "down" if pressed else "up"
	_run_sync(PackedStringArray([verb, str(pos.x), str(pos.y), str(button)]))


func release_button(button: int) -> void:
	_run_sync(PackedStringArray(["release", str(button)]))


func button_here(button: int, pressed: bool) -> void:
	_run_sync(PackedStringArray(["bdown" if pressed else "bup", str(button)]))


func click_here(button: int) -> void:
	_run_sync(PackedStringArray(["tap", str(button)]))


func scroll(dir: int, notches: int, ms: int = 0, uneven: bool = false) -> void:
	var n := clampi(notches, 1, LoopActionT.NOTCHES_MAX)
	_run_sync(PackedStringArray(["wheel", LoopActionT.scroll_dir_name(dir), str(n), str(maxi(0, ms)), "1" if uneven else "0"]),
		maxi(ms, n * 12) * 2 + SERVER_READ_TIMEOUT_MS)


## Moves the real cursor through `path` over `ms` (the helper's 'path').
func move_path(path: PackedVector2Array, ms: int) -> void:
	if path.is_empty():
		return
	_last_pos = Vector2i(path[path.size() - 1].round())
	_run_sync(PackedStringArray(["path", MousePathT.encode(path), str(ms)]), ms + SERVER_READ_TIMEOUT_MS)


func run_captured(kind: String, button: int, from: Vector2i, to: Vector2i, ms: int, ghost: bool, path: PackedVector2Array) -> Array:
	last_cut_off = false
	var cmd := PackedStringArray([
		"cap", kind, "1" if ghost else "0", str(button),
		str(from.x), str(from.y), str(to.x), str(to.y), str(ms)])
	if path.size() > 2:
		var arg := _path_arg(MousePathT.encode(path))
		if arg.is_empty():
			# The server went away while the path was on its way (a stop's
			# interrupt): the action is not run on a fresh one.
			return []
		cmd.append(arg)
	var line := _run_sync(cmd, ms + 10000)
	last_cut_off = line.is_empty() and not last_skipped and not _last_error
	if last_skipped:
		return []
	var saved := _parse_point(line, 0)
	var restored := _parse_point(line, 2)
	if saved == Vector2i(-1, -1) or restored == Vector2i(-1, -1):
		# An empty answer is what an interrupt() leaves; anything else is a fault.
		if not line.is_empty():
			push_warning("WindowsBackend: captured %s failed (output %s)." % [kind, JSON.stringify(line)])
		if ghost:
			# The helper may have died with the system cursors blanked.
			_run_sync(PackedStringArray(["cursors-restore"]))
		return []
	_last_pos = restored
	return [saved, restored]


## `encoded` (see MousePath.encode) as the path argument of a captured
## action's command: as it is when it fits the line, else sent ahead in
## pieces the server keeps ('pathpart') and "@" in its place. With no server
## the whole path goes on the one-shot command line, which has the room. ""
## when the server stopped taking pieces (it was ended meanwhile).
func _path_arg(encoded: String) -> String:
	if encoded.length() <= PATH_INLINE_MAX:
		return encoded
	var at := 0
	while at < encoded.length():
		var call := _server_call("pathpart " + encoded.substr(at, PATH_PIECE_CHARS))
		if not call["served"]:
			return encoded
		if call["line"] != "ok":
			return ""
		at += PATH_PIECE_CHARS
	return "@"


func send_keys(text: String) -> void:
	# The helper takes one line per command, so the text travels as a single
	# base64 argument: no character in it (a line break above all) can be read
	# as a command, and it crosses the one-shot command line unchanged too. A
	# long text is more than one line holds: it goes in pieces, one command
	# each, cut between keystrokes (a "{ENTER}" or a "^(ab)" is never split).
	# Each command also makes at most KEY_PIECE_EVENTS keystrokes: SendKeys
	# queues all of a command's keystrokes at once, and a stop cannot take
	# back what is queued. A single keystroke (a group) that makes more is
	# refused, text and all, as is the rest of the text after a piece the
	# helper refused: typing what is left of a text is typing another text.
	var clean := KeyStrokesT.clamp_repeats(text.replace("\r", "").replace("\n", ""))
	if clean.is_empty():
		return
	var send := KeyStrokesT.pieces(clean, KEY_PIECE_BYTES, KEY_PIECE_EVENTS)
	for piece in send:
		if KeyStrokesT.events(piece) > KEY_PIECE_EVENTS:
			push_warning("WindowsBackend: key text not sent: one keystroke of it makes more than %d." % KEY_PIECE_EVENTS)
			keys_refused = true
			return
	for piece in send:
		_run_sync(PackedStringArray(["key", Marshalls.utf8_to_base64(piece)]), 30000)
		if last_skipped:
			return
		if _last_error:
			keys_refused = true
			return


func hold_keys(mods: String, keys: PackedStringArray, lead: int, hold: int, gap: int, trail: int) -> void:
	if keys.is_empty():
		return
	var total := lead + trail + keys.size() * (hold + gap)
	_run_sync(PackedStringArray(["hold", mods if not mods.is_empty() else "-", ",".join(keys),
		str(lead), str(hold), str(gap), str(trail)]), total + SERVER_READ_TIMEOUT_MS)


func press_keys(mods: String, keys: PackedStringArray, pressed: bool) -> void:
	if keys.is_empty():
		return
	_run_sync(PackedStringArray(["kdown" if pressed else "kup", mods if not mods.is_empty() else "-", ",".join(keys)]))


func get_cursor_pos() -> Vector2i:
	if _helper_real_path.is_empty():
		return Vector2i(-1, -1)
	var served := _parse_point(_server_read("cursor"))
	if served != Vector2i(-1, -1):
		return served
	var first_error := ""
	for attempt in 2:
		var once := _run_once(PackedStringArray(["cursor"]))
		var line: String = once["line"]
		var pos := _parse_point(line)
		if int(once["code"]) == 0 and pos != Vector2i(-1, -1):
			return pos
		if attempt == 0:
			first_error = "exit %d, output %s" % [int(once["code"]), JSON.stringify(line)]
			OS.delay_msec(50)
	push_warning("WindowsBackend: cursor position read failed twice (first: %s)." % first_error)
	return Vector2i(-1, -1)


## Parses "r,g,b" from the helper, or a transparent colour.
static func _parse_rgb(line: String) -> Color:
	var parts := line.split(",")
	if parts.size() >= 3 and parts[0].is_valid_int() and parts[1].is_valid_int() and parts[2].is_valid_int():
		return Color8(int(parts[0]), int(parts[1]), int(parts[2]), 255)
	return Color(0, 0, 0, 0)


func get_pixel(pos: Vector2i) -> Color:
	if _helper_real_path.is_empty():
		return Color(0, 0, 0, 0)
	var served := _parse_rgb(_server_read("pixel %d %d" % [pos.x, pos.y]))
	if served.a > 0.0:
		return served
	# A read occasionally comes back empty (PowerShell start-up hiccup, or the
	# desktop momentarily unavailable to CopyFromScreen); one retry covers it,
	# and a failure that survives the retry is logged so it can be diagnosed.
	var first_error := ""
	for attempt in 2:
		var once := _run_once(PackedStringArray(["pixel", str(pos.x), str(pos.y)]))
		var line: String = once["line"]
		var parts := line.split(",")
		if int(once["code"]) == 0 and parts.size() >= 3:
			return Color8(int(parts[0]), int(parts[1]), int(parts[2]), 255)
		if attempt == 0:
			first_error = "exit %d, output %s" % [int(once["code"]), JSON.stringify(line)]
			OS.delay_msec(50)
	push_warning("WindowsBackend: pixel read at (%d, %d) failed twice (first: %s)." % [pos.x, pos.y, first_error])
	return Color(0, 0, 0, 0)


## Whether a scan that got no server should be dropped rather than done here
## (a screen read and a scan in script, which nothing can cut short): the
## backend is shut down, or an interrupt() - a stop - landed while this
## call was starting the server. The interrupt is spent.
func _read_abandoned() -> bool:
	if _closing:
		return true
	if _cut_short and Time.get_ticks_msec() - _cut_short_at <= CUT_SHORT_MS:
		_cut_short = false
		return true
	return false


## The read server scans in-process and answers "x,y" or "none,r,g,b"; without
## one the rect is fetched as an image and scanned here (InputBackend).
func find_color(rect: Rect2i, color: Color, tolerance: int, step: int) -> Dictionary:
	if _helper_real_path.is_empty():
		return {}
	# The last argument is the guard pid: with ~Self off a match on a Loop
	# Automator window is skipped (see the helper's Scan.Guarded), so a detect
	# never triggers on the app running it; 0 (~Self on) reads everything.
	var line := _server_read("find %d %d %d %d %d %d %d %d %d %d" % [
		rect.position.x, rect.position.y, maxi(1, rect.size.x), maxi(1, rect.size.y),
		color.r8, color.g8, color.b8, tolerance, maxi(1, step), avoid_pid])
	if line.begins_with("none,"):
		var centre := _parse_rgb(line.substr(5))
		if centre.a > 0.0:
			return {"hit": Vector2i(-1, -1), "centre": centre}
	else:
		var hit := _parse_point(line)
		if hit != Vector2i(-1, -1):
			return {"hit": hit, "centre": color}
	if _read_abandoned():
		return {}
	return super.find_color(rect, color, tolerance, step)


## The read server scans in-process (see the helper's Scan.Image) and answers
## "x,y" or "none". The template is sent once per server and kept there
## under an id made from its bytes, so a re-check sends only the command;
## "notpl" (a fresh server, or an old template dropped) means send it again.
## A scan that allows mismatches on a big rect can take a second or more
## (see Scan.Image), so it gets a longer wait than other reads. Only with no
## server at all is the rect fetched as an image and scanned here — never
## after a served scan that failed or timed out (script would take minutes).
func find_image(rect: Rect2i, png: PackedByteArray, tolerance: int, grey: bool = false, mismatch: int = 0, edge: int = 0) -> Dictionary:
	if _helper_real_path.is_empty() or png.is_empty():
		return {}
	var id := "%d_%08x" % [png.size(), hash(png)]
	var cmd := "image %d %d %d %d %s %d %d %d %d %d" % [
		rect.position.x, rect.position.y, maxi(1, rect.size.x), maxi(1, rect.size.y),
		id, tolerance, avoid_pid, 1 if grey else 0, mismatch, edge]
	var call := _server_call(cmd, IMAGE_SCAN_TIMEOUT_MS)
	if not call["served"]:
		if _read_abandoned():
			return {}
		return super.find_image(rect, png, tolerance, grey, mismatch, edge)
	var line: String = call["line"]
	if line == "notpl" and _upload_template(id, png):
		line = String(_server_call(cmd, IMAGE_SCAN_TIMEOUT_MS)["line"])
	if line == "none":
		return {"hit": Vector2i(-1, -1)}
	var hit := _parse_point(line)
	if hit != Vector2i(-1, -1):
		return {"hit": hit}
	return {}


## Sends `png` to the server as template `id`. A line over about 4 KB does
## not make it through the pipe whole, so the base64 goes in pieces
## (tplpart …) with the last one on the tpl command that decodes it. True
## when the server took it.
const TEMPLATE_PIECE_CHARS := 2048
func _upload_template(id: String, png: PackedByteArray) -> bool:
	var b64 := Marshalls.raw_to_base64(png)
	var at := 0
	while b64.length() - at > TEMPLATE_PIECE_CHARS:
		if _server_read("tplpart %s %s" % [id, b64.substr(at, TEMPLATE_PIECE_CHARS)]) != "ok":
			return false
		at += TEMPLATE_PIECE_CHARS
	return _server_read("tpl %s %s" % [id, b64.substr(at)]) == "ok"


func read_rect(rect: Rect2i) -> Image:
	if _helper_real_path.is_empty():
		return null
	var first_error := ""
	for attempt in 2:
		var once := _run_once(PackedStringArray(["rect", str(rect.position.x), str(rect.position.y), str(rect.size.x), str(rect.size.y)]))
		var line: String = once["line"]
		if int(once["code"]) == 0 and not line.is_empty():
			var img := Image.new()
			if img.load_png_from_buffer(Marshalls.base64_to_raw(line)) == OK and not img.is_empty():
				return img
		if attempt == 0:
			first_error = "exit %d, %d chars of output" % [int(once["code"]), line.length()]
			OS.delay_msec(50)
	push_warning("WindowsBackend: screen read of [%d, %d, %d×%d] failed twice (first: %s)." % [rect.position.x, rect.position.y, rect.size.x, rect.size.y, first_error])
	return null
