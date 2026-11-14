# screenshot-ask: persistent capture server.
#
# One long-lived PowerShell process, so the WPF/Drawing assemblies are paid for once instead
# of on every click (cold start was ~2.4 s; a reused process is ~0.3 s).
#
# Protocol: one JSON object per line on stdin, one JSON object per line on stdout.
#   in : {"id":1,"op":"region"}
#   out: {"id":1,"ok":true,"x":..,"y":..,"width":..,"height":..,"png":"<base64>"}
#        {"id":1,"ok":false,"cancelled":true}
#        {"id":1,"ok":false,"copied":true}          (user pressed 复制: clipboard only)
#        {"id":1,"ok":false,"code":"busy","message":".."}
#        {"id":1,"ok":false,"error":".."}
#
# ops:
#   ping    liveness + warmup report
#   region  overlay picker (hide DSH -> still -> drag/refine -> confirm)
#   full    whole virtual screen, no UI
#   crop    still + crop a rect given in DIP (headless, for tests)
#
# ASCII only: PowerShell 5.1 reads BOM-less files as ANSI.

param(
  [string]$LogFile = ''
)

$ErrorActionPreference = 'Stop'
$MinSize = 8          # DIP: smaller than this is a stray click, not a selection
$HandleSize = 10      # DIP: side of the resize grips
$HideSettleMs = 40    # how long DSH stays hidden before the still is grabbed

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public class DshNative {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);

  static int wantPid = -1;

  static bool VisitPid(IntPtr h, IntPtr p) {
    int pid;
    GetWindowThreadProcessId(h, out pid);
    if (pid != wantPid) return true;
    var cls = new StringBuilder(256);
    GetClassName(h, cls, cls.Capacity);
    if (!cls.ToString().StartsWith("Chrome_WidgetWin", StringComparison.Ordinal)) return true;
    RECT r;
    if (!GetWindowRect(h, out r)) return true;
    long area = (long)(r.Right - r.Left) * (long)(r.Bottom - r.Top);
    if (area > bestArea) { bestArea = area; best = h; }
    return true;
  }

  public static System.Collections.Generic.List<IntPtr> Hits = new System.Collections.Generic.List<IntPtr>();

  static bool VisitAll(IntPtr h, IntPtr p) {
    int pid;
    GetWindowThreadProcessId(h, out pid);
    if (pid != wantPid) return true;
    var cls = new StringBuilder(256);
    GetClassName(h, cls, cls.Capacity);
    if (!cls.ToString().StartsWith("Chrome_WidgetWin", StringComparison.Ordinal)) return true;
    RECT r;
    if (!GetWindowRect(h, out r)) return true;
    if ((r.Right - r.Left) <= 0 || (r.Bottom - r.Top) <= 0) return true;
    Hits.Add(h);
    return true;
  }

  public static int[] RectOf(IntPtr h) {
    RECT r;
    if (!GetWindowRect(h, out r)) return new int[] { 0, 0, 0, 0 };
    return new int[] { r.Left, r.Top, r.Right, r.Bottom };
  }

  public static System.Collections.Generic.HashSet<int> Want = new System.Collections.Generic.HashSet<int>();

  static bool VisitAny(IntPtr h, IntPtr p) {
    int pid;
    GetWindowThreadProcessId(h, out pid);
    if (!Want.Contains(pid)) return true;
    RECT r;
    if (!GetWindowRect(h, out r)) return true;
    if ((r.Right - r.Left) < 100 || (r.Bottom - r.Top) < 100) return true;
    Hits.Add(h);
    return true;
  }

  public static string ClassNameOf(IntPtr h) {
    var cls = new StringBuilder(256);
    GetClassName(h, cls, cls.Capacity);
    return cls.ToString();
  }

  public static IntPtr[] ForPids(int[] pids) {
    Want.Clear();
    foreach (int pid in pids) Want.Add(pid);
    Hits.Clear();
    EnumWindows(new EnumProc(VisitAny), IntPtr.Zero);
    return Hits.ToArray();
  }

  public static IntPtr[] AllByPid(int pid) {
    Hits.Clear();
    wantPid = pid;
    EnumWindows(new EnumProc(VisitAll), IntPtr.Zero);
    return Hits.ToArray();
  }

  public static IntPtr FindByPid(int pid) {
    best = IntPtr.Zero;
    bestArea = -1;
    wantPid = pid;
    EnumWindows(new EnumProc(VisitPid), IntPtr.Zero);
    return best;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int Left, Top, Right, Bottom; }

  static IntPtr best = IntPtr.Zero;
  static long bestArea = -1;
  static string wantClass = "";
  static string wantSuffix = "";

  // Largest matching window wins: the app has tiny helper windows of the same class, and
  // "first match in z-order" used to pick a 158x26 shadow instead of the real 1280x781 window.
  static bool Visit(IntPtr h, IntPtr p) {
    var cls = new StringBuilder(256);
    GetClassName(h, cls, cls.Capacity);
    if (!string.Equals(cls.ToString(), wantClass, StringComparison.Ordinal)) return true;
    var title = new StringBuilder(1024);
    GetWindowText(h, title, title.Capacity);
    var text = title.ToString();
    if (wantSuffix.Length > 0 && !text.EndsWith(wantSuffix, StringComparison.Ordinal)) return true;
    RECT r;
    if (!GetWindowRect(h, out r)) return true;
    long w = r.Right - r.Left;
    long hh = r.Bottom - r.Top;
    long area = w * hh;
    if (area > bestArea) { bestArea = area; best = h; }
    return true;
  }

  public static IntPtr Find(string className, string titleSuffix) {
    best = IntPtr.Zero;
    bestArea = -1;
    wantClass = className;
    wantSuffix = titleSuffix ?? "";
    EnumWindows(new EnumProc(Visit), IntPtr.Zero);
    return best;
  }

  public static int OwnerPid(IntPtr h) {
    int pid;
    GetWindowThreadProcessId(h, out pid);
    return pid;
  }

  public static long Area(IntPtr h) {
    if (h == IntPtr.Zero) return -1;
    RECT r;
    if (!GetWindowRect(h, out r)) return -1;
    return (long)(r.Right - r.Left) * (long)(r.Bottom - r.Top);
  }

  public static void Hide(IntPtr h) { if (h != IntPtr.Zero) ShowWindow(h, 0); }
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  public static bool Iconic(IntPtr h) { return h != IntPtr.Zero && IsIconic(h); }
  public static void Minimize(IntPtr h) { if (h != IntPtr.Zero) ShowWindow(h, 6); }
  public static void Show(IntPtr h) { if (h != IntPtr.Zero) { ShowWindow(h, 5); SetForegroundWindow(h); } }
  public static void ShowNoActivate(IntPtr h) { if (h != IntPtr.Zero) { ShowWindow(h, 4); } }
  [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("dwmapi.dll")] public static extern int DwmFlush();
  public static void FlushCompositor() { try { DwmFlush(); } catch { } }
  public static void HideOwnConsole() {
    IntPtr c = GetConsoleWindow();
    if (c != IntPtr.Zero) { ShowWindow(c, 0); }
  }
  // Work even when this process does not own the keyboard focus (the overlay often cannot take
  // it: Windows refuses SetForegroundWindow from a background process).
  public static bool KeyDown(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }
  public static bool EscapeDown() { return KeyDown(0x1B); }
  public static bool EnterDown() { return KeyDown(0x0D); }
  public static bool DpiAware() { return SetProcessDpiAwarenessContext(new IntPtr(-4)); }
}
'@

try { $null = [DshNative]::DpiAware() } catch { }
try { [DshNative]::HideOwnConsole() } catch { }

# HideOwnConsole only knows the console window this process owns. Under ConPTY / Windows
# Terminal the console host is a different process (conhost.exe, WindowsTerminal.exe), and the
# window may also be created a moment after we start - so sweep the whole process family for
# console-class windows and hide them by handle.
function Hide-ConsoleWindows {
  try {
    $pids = Get-AppPids
    if ($pids.Length -eq 0) { return 0 }
    $hidden = 0
    foreach ($w in [DshNative]::ForPids([int[]]$pids)) {
      $cls = [DshNative]::ClassNameOf($w)
      if ($cls -match 'Console|CASCADIA|ConPTY|PseudoConsole|Terminal') {
        [DshNative]::Hide($w)
        $hidden++
      }
    }
    return $hidden
  } catch { return 0 }
}

function Write-Log([string]$text) {
  if ($LogFile -and $LogFile.Length -gt 0) {
    try { Add-Content -LiteralPath $LogFile -Value ((Get-Date).ToUniversalTime().ToString('s') + 'Z server: ' + $text) } catch { }
  }
}

function Send-Line($payload) {
  $json = $payload | ConvertTo-Json -Compress -Depth 4
  [Console]::Out.WriteLine($json)
  [Console]::Out.Flush()
}

# ---------------------------------------------------------------- still capture

# The DSH app process is the parent of this one. Its biggest Chrome_WidgetWin window is the
# real app window; title matching alone used to grab a 158x26 shadow, and class-only matching
# would happily hide Edge (same class, 2582x1622).
# The window is not owned by whoever spawned us: the plugin host sits under the Electron main
# process, and the visible window belongs to the main process (or a sibling app process).
# So collect the whole app process family instead of guessing one pid.
function Get-AppPids {
  if ($null -ne $script:appPids -and $script:appPids.Length -gt 0) { return $script:appPids }
  $script:appPids = @()

  $all = @()
  try { $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop) } catch { return $script:appPids }
  if ($all.Length -eq 0) { return $script:appPids }

  $parentOf = @{}
  $nameOf = @{}
  foreach ($proc in $all) {
    $parentOf[[int]$proc.ProcessId] = [int]$proc.ParentProcessId
    $nameOf[[int]$proc.ProcessId] = [string]$proc.Name
  }

  $pattern = 'DeepSeek|dsh|electron'
  # 1) walk up from this process to the top-most app process
  $top = $PID
  if ($null -ne $script:appPidStart -and $script:appPidStart -gt 0) { $top = $script:appPidStart }
  $guard = 0
  while ($guard -lt 16) {
    $guard++
    $parent = 0
    if ($parentOf.ContainsKey($top)) { $parent = $parentOf[$top] }
    if ($parent -le 0) { break }
    $parentName = ''
    if ($nameOf.ContainsKey($parent)) { $parentName = $nameOf[$parent] }
    if ($parentName -notmatch $pattern) { break }
    $top = $parent
  }

  # 2) every app process whose ancestry reaches that top process (siblings included)
  $pids = New-Object System.Collections.Generic.List[int]
  foreach ($proc in $all) {
    $id = [int]$proc.ProcessId
    if ([string]$proc.Name -notmatch $pattern) { continue }
    $walk = $id
    $hops = 0
    $inFamily = $false
    while ($hops -lt 24) {
      $hops++
      if ($walk -eq $top) { $inFamily = $true; break }
      if (-not $parentOf.ContainsKey($walk)) { break }
      $walk = $parentOf[$walk]
      if ($walk -le 0) { break }
    }
    if ($inFamily) { $pids.Add($id) }
  }
  if (-not $pids.Contains($top)) { $pids.Add($top) }
  $script:appPids = $pids.ToArray()
  return $script:appPids
}

function Get-AppPid {
  $pids = Get-AppPids
  if ($pids.Length -gt 0) { return $pids[0] }
  return 0
}

# Hide every app window for the duration of the still: the app owns several, and leaving one
# visible puts a rectangle of DSH into the picture.
function Get-DshWindows {
  $pids = Get-AppPids
  if ($pids.Length -gt 0) {
    $list = [DshNative]::ForPids([int[]]$pids)
    if ($list.Length -gt 0) { return $list }
    $script:appPids = @()   # the family changed under us; recompute next time
  }
  $single = Get-DshWindow
  if ($single -ne [IntPtr]::Zero) { return @($single) }
  return @()
}

function Get-DshWindow {
  $appPid = Get-AppPid
  if ($appPid -gt 0) {
    $w = [DshNative]::FindByPid($appPid)
    if ($w -ne [IntPtr]::Zero) { return $w }
  }
  # fallback: biggest window whose title ends with the app suffix
  $suffix = ([char]0x2014) + ' DeepSeek Harness'
  $best = [IntPtr]::Zero
  $bestArea = -1
  foreach ($cls in @('Chrome_WidgetWin_1', 'Chrome_WidgetWin_0')) {
    $candidate = [DshNative]::Find($cls, $suffix)
    $area = [DshNative]::Area($candidate)
    if ($area -gt $bestArea) { $bestArea = $area; $best = $candidate }
  }
  return $best
}

# Grabs the whole virtual screen in physical pixels. DSH is hidden for the length of the
# grab only (~40 ms + capture), because a still of DSH itself is useless as a backdrop.
# ShowWindow returns before the compositor has finished: at 40 ms the still can still contain a
# half-faded DSH. Sample the area the app window occupied until two consecutive samples agree.
function Wait-Until-Clear($windows) {
  # Two things went wrong before: the rect list was flattened into one int[4] (so the loop skipped
  # everything and this never waited), and the sample was copied 1:1 into a quarter-size bitmap.
  # Now take the union of the given windows inside this function and sample a small patch in its
  # middle until three consecutive samples are identical.
  if ($null -eq $windows -or $windows.Length -eq 0) { return 0 }
  $left = [int]::MaxValue
  $top = [int]::MaxValue
  $right = [int]::MinValue
  $bottom = [int]::MinValue
  foreach ($w in $windows) {
    try { $r = [DshNative]::RectOf($w) } catch { continue }
    if ($null -eq $r -or $r.Length -lt 4) { continue }
    if (($r[2] - $r[0]) -le 0 -or ($r[3] - $r[1]) -le 0) { continue }
    if ($r[0] -lt $left) { $left = $r[0] }
    if ($r[1] -lt $top) { $top = $r[1] }
    if ($r[2] -gt $right) { $right = $r[2] }
    if ($r[3] -gt $bottom) { $bottom = $r[3] }
  }
  if ($right -le $left -or $bottom -le $top) { return 0 }

  $pw = [Math]::Min(320, $right - $left)
  $ph = [Math]::Min(240, $bottom - $top)
  $px = $left + [int](($right - $left - $pw) / 2)
  $py = $top + [int](($bottom - $top - $ph) / 2)

  $sha = [System.Security.Cryptography.SHA1]::Create()
  $previous = ''
  $stable = 0
  $startedAt = [DateTime]::UtcNow
  $deadline = $startedAt.AddMilliseconds(800)
  while ([DateTime]::UtcNow -lt $deadline) {
    $bmp = New-Object System.Drawing.Bitmap $pw, $ph
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($px, $py, 0, 0, (New-Object System.Drawing.Size $pw, $ph))
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Bmp)
    $hash = [Convert]::ToBase64String($sha.ComputeHash($ms.ToArray()))
    $ms.Dispose()
    $bmp.Dispose()
    if ($hash -eq $previous) {
      $stable++
      if ($stable -ge 2) {
        return [int](([DateTime]::UtcNow - $startedAt).TotalMilliseconds)
      }
    } else {
      $stable = 0
    }
    $previous = $hash
    Start-Sleep -Milliseconds 16
  }
  return 800
}

function New-Still {
  param([switch]$SkipHide, [int]$ExtraMs = 0, [switch]$KeepHidden)
  $script:dshWindows = Get-DshWindows
  $script:dshWindow = $script:dshWindow = if ($script:dshWindows.Length -gt 0) { $script:dshWindows[0] } else { [IntPtr]::Zero }
  $hid = $false
  $skipped = 0
  $script:hidTargets = @()
  if ($SkipHide) {
    $script:dshWindows = @()
  } elseif ($script:dshWindows.Length -gt 0) {
    # Only windows that are actually on screen: a minimized window reports -32000 and has no
    # business being touched (hiding it would also lose its minimized state on restore).
    foreach ($w in $script:dshWindows) {
      try { $r = [DshNative]::RectOf($w) } catch { continue }
      if ($null -eq $r -or $r.Length -lt 4) { continue }
      if (($r[2] - $r[0]) -lt 40 -or ($r[3] - $r[1]) -lt 40) { continue }
      if ($r[0] -le -30000 -or $r[1] -le -30000) { continue }
      # Only windows that are actually visible. Chromium keeps a hidden helper window
      # (Chrome_WidgetWin_0, empty title) in the same process; showing it back with SW_SHOW
      # turns it into a black rectangle that never goes away.
      if (-not [DshNative]::IsWindowVisible($w)) {
        $skipped++
        continue
      }
      $script:hidTargets += @{ hwnd = $w; iconic = [DshNative]::Iconic($w) }
      [DshNative]::Hide($w)
    }
    if ($script:hidTargets.Length -gt 0) {
      $hid = $true
      # Ask the compositor to commit the hide before we start sampling, so the fade is not
      # counted as "still settling".
      try { [DshNative]::FlushCompositor() } catch { }
      Start-Sleep -Milliseconds $HideSettleMs
      $handles = @($script:hidTargets | ForEach-Object { $_.hwnd })
      $waited = Wait-Until-Clear $handles
      Write-Log ("hide settle: " + $waited + "ms (" + $handles.Length + " window(s), " + $skipped + " invisible skipped)")
      if ($ExtraMs -gt 0) { Start-Sleep -Milliseconds $ExtraMs }
    }
  }

  try {
    $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $physicalWidth = [int]$bounds.Width
    $physicalHeight = [int]$bounds.Height
    if ($physicalWidth -le 0 -or $physicalHeight -le 0) { throw "empty virtual screen ($physicalWidth x $physicalHeight)" }

    $bitmap = New-Object System.Drawing.Bitmap $physicalWidth, $physicalHeight
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen([int]$bounds.Left, [int]$bounds.Top, 0, 0, $bitmap.Size)
    $graphics.Dispose()

    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $null = $stream.Seek(0, [System.IO.SeekOrigin]::Begin)
    # OnLoad: decode now, so the stream can be closed and the frame survives on its own.
    $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create(
      $stream,
      [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
      [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $frame.Freeze()
    $stream.Dispose()
  } finally {
    if ($hid -and -not $KeepHidden) {
      Write-Log 'still: restoring app windows'
      foreach ($t in $script:hidTargets) {
        if ($t.iconic) { [DshNative]::Minimize($t.hwnd) } else { [DshNative]::Show($t.hwnd) }
      }
      $script:hidTargets = @()
    } elseif ($hid) {
      Write-Log ('still: keeping ' + $script:hidTargets.Length + ' window(s) hidden for the picker')
    }
  }

  $script:still = $frame
  $script:physWidth = $frame.PixelWidth
  $script:physHeight = $frame.PixelHeight
  $script:dipLeft = [double][System.Windows.SystemParameters]::VirtualScreenLeft
  $script:dipTop = [double][System.Windows.SystemParameters]::VirtualScreenTop
  $script:dipWidth = [double][System.Windows.SystemParameters]::VirtualScreenWidth
  $script:dipHeight = [double][System.Windows.SystemParameters]::VirtualScreenHeight
  $script:scaleX = $script:physWidth / $script:dipWidth
  $script:scaleY = $script:physHeight / $script:dipHeight
}

# Crops a DIP rect out of the current still and returns the payload fields.
function Get-CropPayload($rect) {
  $px = [int][Math]::Round($rect.X * $script:scaleX)
  $py = [int][Math]::Round($rect.Y * $script:scaleY)
  $pw = [int][Math]::Round($rect.Width * $script:scaleX)
  $ph = [int][Math]::Round($rect.Height * $script:scaleY)
  if ($px -lt 0) { $px = 0 }
  if ($py -lt 0) { $py = 0 }
  if (($px + $pw) -gt $script:physWidth) { $pw = $script:physWidth - $px }
  if (($py + $ph) -gt $script:physHeight) { $ph = $script:physHeight - $py }
  if ($pw -le 0 -or $ph -le 0) { throw "selection is empty after scaling (${pw}x${ph})" }

  $sourceRect = New-Object System.Windows.Int32Rect $px, $py, $pw, $ph
  $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap
  $crop.BeginInit()
  $crop.Source = $script:still
  $crop.SourceRect = $sourceRect
  $crop.EndInit()
  $crop.Freeze()

  $outStream = New-Object System.IO.MemoryStream
  $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
  $null = $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($crop))
  $encoder.Save($outStream)
  $bytes = $outStream.ToArray()
  $outStream.Dispose()

  $script:lastCrop = $crop
  return [ordered]@{
    ok     = $true
    x      = $px
    y      = $py
    width  = $pw
    height = $ph
    png    = [Convert]::ToBase64String($bytes)
  }
}

# ---------------------------------------------------------------- overlay

function New-Brush($a, $r, $g, $b) {
  return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($a, $r, $g, $b))
}

function Get-HandlePoints($rect) {
  $mx = $rect.X + $rect.Width / 2
  $my = $rect.Y + $rect.Height / 2
  $x2 = $rect.X + $rect.Width
  $y2 = $rect.Y + $rect.Height
  return @{
    nw = New-Object System.Windows.Point $rect.X, $rect.Y
    n  = New-Object System.Windows.Point $mx, $rect.Y
    ne = New-Object System.Windows.Point $x2, $rect.Y
    e  = New-Object System.Windows.Point $x2, $my
    se = New-Object System.Windows.Point $x2, $y2
    s  = New-Object System.Windows.Point $mx, $y2
    sw = New-Object System.Windows.Point $rect.X, $y2
    w  = New-Object System.Windows.Point $rect.X, $my
  }
}

function Render-Mask {
  $group = New-Object System.Windows.Media.GeometryGroup
  $group.FillRule = [System.Windows.Media.FillRule]::EvenOdd
  $full = New-Object System.Windows.Media.RectangleGeometry
  $full.Rect = New-Object System.Windows.Rect 0, 0, $script:dipWidth, $script:dipHeight
  $null = $group.Children.Add($full)
  if ($null -ne $script:ui.rect -and $script:ui.rect.Width -gt 0 -and $script:ui.rect.Height -gt 0) {
    $hole = New-Object System.Windows.Media.RectangleGeometry
    $hole.Rect = $script:ui.rect
    $null = $group.Children.Add($hole)
  }
  $script:maskPath.Data = $group
}

function Render-Selection {
  $rect = $script:ui.rect
  if ($null -eq $rect -or $rect.Width -le 0 -or $rect.Height -le 0) {
    $script:selectionBox.Visibility = [System.Windows.Visibility]::Collapsed
    $script:badge.Visibility = [System.Windows.Visibility]::Collapsed
    $script:toolbar.Visibility = [System.Windows.Visibility]::Collapsed
    foreach ($k in $script:handles.Keys) { $script:handles[$k].Visibility = [System.Windows.Visibility]::Collapsed }
    Render-Mask
    return
  }

  $script:selectionBox.Visibility = [System.Windows.Visibility]::Visible
  [System.Windows.Controls.Canvas]::SetLeft($script:selectionBox, $rect.X)
  [System.Windows.Controls.Canvas]::SetTop($script:selectionBox, $rect.Y)
  $script:selectionBox.Width = $rect.Width
  $script:selectionBox.Height = $rect.Height

  $editing = ($script:ui.mode -eq 'idle')
  foreach ($k in $script:handles.Keys) {
    $shape = $script:handles[$k]
    if (-not $editing) { $shape.Visibility = [System.Windows.Visibility]::Collapsed; continue }
    $shape.Visibility = [System.Windows.Visibility]::Visible
    $p = $script:handlePoints[$k]
    [System.Windows.Controls.Canvas]::SetLeft($shape, $p.X - $HandleSize / 2)
    [System.Windows.Controls.Canvas]::SetTop($shape, $p.Y - $HandleSize / 2)
  }

  # size badge: physical pixels, same number the resulting file will have
  $physW = [int][Math]::Round($rect.Width * $script:scaleX)
  $physH = [int][Math]::Round($rect.Height * $script:scaleY)
  $script:badgeText.Text = "$physW x $physH"
  $script:badge.Visibility = [System.Windows.Visibility]::Visible
  $badgeY = $rect.Y - 30
  if ($badgeY -lt 4) { $badgeY = $rect.Y + 8 }
  [System.Windows.Controls.Canvas]::SetLeft($script:badge, $rect.X)
  [System.Windows.Controls.Canvas]::SetTop($script:badge, $badgeY)

  # toolbar: under the selection, flipping above when there is no room
  $script:toolbar.Visibility = [System.Windows.Visibility]::Visible
  $script:toolbar.Measure((New-Object System.Windows.Size ([double]::PositiveInfinity), ([double]::PositiveInfinity)))
  $tbW = $script:toolbar.DesiredSize.Width
  $tbH = $script:toolbar.DesiredSize.Height
  $tbX = $rect.X + $rect.Width - $tbW
  if ($tbX -lt 4) { $tbX = 4 }
  $tbY = $rect.Y + $rect.Height + 10
  if (($tbY + $tbH) -gt ($script:dipHeight - 4)) { $tbY = $rect.Y - $tbH - 10 }
  if ($tbY -lt 4) { $tbY = 4 }
  [System.Windows.Controls.Canvas]::SetLeft($script:toolbar, $tbX)
  [System.Windows.Controls.Canvas]::SetTop($script:toolbar, $tbY)

  Render-Mask
}

function Hit-Handle($point) {
  if ($null -eq $script:ui.rect -or $script:ui.mode -ne 'idle') { return '' }
  $tol = $HandleSize
  foreach ($k in $script:handlePoints.Keys) {
    $p = $script:handlePoints[$k]
    if ([Math]::Abs($point.X - $p.X) -le $tol -and [Math]::Abs($point.Y - $p.Y) -le $tol) { return $k }
  }
  return ''
}

# System.Windows.Rect rejects negative width/height, and dragging right-to-left (or pulling a
# handle past its opposite edge) produces exactly that. Always normalise before constructing.
function New-RectFromEdges($x1, $y1, $x2, $y2) {
  $x = [Math]::Min($x1, $x2)
  $y = [Math]::Min($y1, $y2)
  $w = [Math]::Abs($x2 - $x1)
  $h = [Math]::Abs($y2 - $y1)
  return New-Object System.Windows.Rect $x, $y, $w, $h
}

function Clamp-Rect($rect) {
  $x = $rect.X
  $y = $rect.Y
  $w = $rect.Width
  $h = $rect.Height
  if ($w -lt 0) { $x += $w; $w = -$w }
  if ($h -lt 0) { $y += $h; $h = -$h }
  if ($x -lt 0) { $w += $x; $x = 0 }
  if ($y -lt 0) { $h += $y; $y = 0 }
  if (($x + $w) -gt $script:dipWidth) { $w = $script:dipWidth - $x }
  if (($y + $h) -gt $script:dipHeight) { $h = $script:dipHeight - $y }
  if ($w -lt 0) { $w = 0 }
  if ($h -lt 0) { $h = 0 }
  return New-Object System.Windows.Rect $x, $y, $w, $h
}

function Set-CursorFor($point) {
  $cursor = [System.Windows.Input.Cursors]::Cross
  $handle = Hit-Handle $point
  if ($handle -ne '') {
    switch ($handle) {
      'nw' { $cursor = [System.Windows.Input.Cursors]::SizeNWSE }
      'se' { $cursor = [System.Windows.Input.Cursors]::SizeNWSE }
      'ne' { $cursor = [System.Windows.Input.Cursors]::SizeNESW }
      'sw' { $cursor = [System.Windows.Input.Cursors]::SizeNESW }
      'n'  { $cursor = [System.Windows.Input.Cursors]::SizeNS }
      's'  { $cursor = [System.Windows.Input.Cursors]::SizeNS }
      'e'  { $cursor = [System.Windows.Input.Cursors]::SizeWE }
      'w'  { $cursor = [System.Windows.Input.Cursors]::SizeWE }
    }
  } elseif ($null -ne $script:ui.rect -and $script:ui.mode -eq 'idle' -and $script:ui.rect.Contains($point)) {
    $cursor = [System.Windows.Input.Cursors]::SizeAll
  }
  if ($null -ne $script:window -and $script:window.Cursor -ne $cursor) { $script:window.Cursor = $cursor }
}

# Builds and runs the picker. Returns a result hashtable (ok/cancelled/copied).
# $SelfTest ('copy' | 'cancel' | 'confirm') runs the picker off-screen and clicks that button
# for you, so the button -> result plumbing can be verified without a human.
function Show-RegionOverlay {
  param([string]$SelfTest = '')

  $script:selfTest = $SelfTest
  $script:ui = @{
    mode   = 'idle'
    rect   = $null
    handle = ''
    origin = $null
    grabX  = 0.0
    grabY  = 0.0
  }
  $script:confirmed = $false
  $script:cancelled = $false
  $script:closing = $false
  $script:copied = $false

  $window = New-Object System.Windows.Window
  $window.WindowStyle = [System.Windows.WindowStyle]::None
  $window.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual
  $window.ShowInTaskbar = $false
  $window.Topmost = $true
  $window.Left = $script:dipLeft
  $window.Top = $script:dipTop
  $window.Width = $script:dipWidth
  $window.Height = $script:dipHeight
  $window.Cursor = [System.Windows.Input.Cursors]::Cross
  $window.Background = [System.Windows.Media.Brushes]::Black
  $window.Focusable = $true

  $root = New-Object System.Windows.Controls.Canvas
  $root.Width = $script:dipWidth
  $root.Height = $script:dipHeight
  $root.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb(255, 0, 0, 0))

  $image = New-Object System.Windows.Controls.Image
  $image.Source = $script:still
  $image.Width = $script:dipWidth
  $image.Height = $script:dipHeight
  $image.Stretch = [System.Windows.Media.Stretch]::Fill
  $null = $root.Children.Add($image)

  $script:maskPath = New-Object System.Windows.Shapes.Path
  $script:maskPath.Fill = New-Brush 130 0 0 0
  $script:maskPath.IsHitTestVisible = $false
  $null = $root.Children.Add($script:maskPath)

  $script:selectionBox = New-Object System.Windows.Controls.Border
  $script:selectionBox.BorderBrush = New-Brush 255 255 255 255
  $script:selectionBox.BorderThickness = New-Object System.Windows.Thickness 1.5
  $script:selectionBox.Background = [System.Windows.Media.Brushes]::Transparent
  $script:selectionBox.IsHitTestVisible = $false
  $script:selectionBox.Visibility = [System.Windows.Visibility]::Collapsed
  $null = $root.Children.Add($script:selectionBox)

  # resize grips
  $script:handles = @{}
  foreach ($k in @('nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w')) {
    $shape = New-Object System.Windows.Shapes.Rectangle
    $shape.Width = $HandleSize
    $shape.Height = $HandleSize
    $shape.Fill = New-Brush 255 255 255 255
    $shape.Stroke = New-Brush 255 40 40 40
    $shape.StrokeThickness = 1
    $shape.IsHitTestVisible = $false
    $shape.Visibility = [System.Windows.Visibility]::Collapsed
    $null = $root.Children.Add($shape)
    $script:handles[$k] = $shape
  }
  $script:handlePoints = @{}

  # size badge
  $script:badge = New-Object System.Windows.Controls.Border
  $script:badge.Background = New-Brush 235 32 32 36
  $script:badge.CornerRadius = New-Object System.Windows.CornerRadius 4
  $script:badge.Padding = New-Object System.Windows.Thickness 8, 3, 8, 3
  $script:badge.IsHitTestVisible = $false
  $script:badge.Visibility = [System.Windows.Visibility]::Collapsed
  $script:badgeText = New-Object System.Windows.Controls.TextBlock
  $script:badgeText.Foreground = New-Brush 255 255 255 255
  $script:badgeText.FontSize = 12
  $script:badgeText.FontFamily = New-Object System.Windows.Media.FontFamily 'Consolas'
  $script:badgeText.Text = ''
  $script:badge.Child = $script:badgeText
  $null = $root.Children.Add($script:badge)

  # toolbar: 复制 / 取消 / 确认
  $script:cells = @()
  $script:toolbar = New-Object System.Windows.Controls.Border
  $script:toolbar.Background = New-Brush 246 28 28 32
  $script:toolbar.CornerRadius = New-Object System.Windows.CornerRadius 8
  $script:toolbar.Padding = New-Object System.Windows.Thickness 4, 3, 4, 3
  $script:toolbar.Visibility = [System.Windows.Visibility]::Collapsed
  $bar = New-Object System.Windows.Controls.StackPanel
  $bar.Orientation = [System.Windows.Controls.Orientation]::Horizontal
  $script:toolbar.Child = $bar
  $null = $root.Children.Add($script:toolbar)

  $items = @(
    @{ text = ([char]0x590D) + ([char]0x5236); kind = 'copy' },
    @{ text = ([char]0x53D6) + ([char]0x6D88); kind = 'cancel' },
    @{ text = ([char]0x786E) + ([char]0x8BA4); kind = 'confirm' }
  )
  foreach ($item in $items) {
    $cell = New-Object System.Windows.Controls.Border
    $cell.Padding = New-Object System.Windows.Thickness 12, 5, 12, 5
    $cell.CornerRadius = New-Object System.Windows.CornerRadius 6
    $cell.Background = [System.Windows.Media.Brushes]::Transparent
    $cell.Cursor = [System.Windows.Input.Cursors]::Hand
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $item.text
    $label.FontSize = 13
    $label.Foreground = New-Brush 255 240 240 245
    $cell.Child = $label
    # The handler must not close over $kind: all three cells would then see the value the
    # variable holds when the click happens (the last one, i.e. "confirm").
    $cell.Tag = $item.kind
    $script:cells += $cell
    $cell.Add_MouseLeftButtonDown({
      param($sender, $eventArgs)
      $eventArgs.Handled = $true
      $pressed = ''
      if ($null -ne $sender) { $pressed = [string]$sender.Tag }
      switch ($pressed) {
        'copy'    { $script:copied = $true }
        'cancel'  { $script:cancelled = $true }
        'confirm' { $script:confirmed = $true }
      }
      if ($null -ne $script:window) { $script:window.Close() }
    })
    $cell.Add_MouseEnter({ param($sender, $eventArgs) if ($null -ne $sender) { $sender.Background = New-Brush 255 58 58 62 } })
    $cell.Add_MouseLeave({ param($sender, $eventArgs) if ($null -ne $sender) { $sender.Background = [System.Windows.Media.Brushes]::Transparent } })
    $null = $bar.Children.Add($cell)
  }

  $window.Content = $root
  $script:window = $window
  $script:root = $root

  Render-Mask
  Render-Selection

  $root.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    $point = $eventArgs.GetPosition($script:root)
    $handle = Hit-Handle $point
    if ($handle -ne '') {
      $script:ui.mode = 'resize'
      $script:ui.handle = $handle
      $null = $script:root.CaptureMouse()
      Render-Selection
      return
    }
    if ($null -ne $script:ui.rect -and $script:ui.rect.Width -ge $MinSize -and $script:ui.rect.Height -ge $MinSize -and $script:ui.rect.Contains($point)) {
      $script:ui.mode = 'move'
      $script:ui.grabX = $point.X - $script:ui.rect.X
      $script:ui.grabY = $point.Y - $script:ui.rect.Y
      $null = $script:root.CaptureMouse()
      Render-Selection
      return
    }
    $script:ui.mode = 'create'
    $script:ui.origin = $point
    $script:ui.rect = New-Object System.Windows.Rect $point.X, $point.Y, 0, 0
    $null = $script:root.CaptureMouse()
    Render-Selection
  })

  $root.Add_MouseMove({
    param($sender, $eventArgs)
    $point = $eventArgs.GetPosition($script:root)
    switch ($script:ui.mode) {
      'create' {
        $script:ui.rect = Clamp-Rect (New-RectFromEdges $script:ui.origin.X $script:ui.origin.Y $point.X $point.Y)
      }
      'move' {
        if ($null -ne $script:ui.rect) {
          $w = $script:ui.rect.Width
          $h = $script:ui.rect.Height
          $x = $point.X - $script:ui.grabX
          $y = $point.Y - $script:ui.grabY
          if ($x -lt 0) { $x = 0 }
          if ($y -lt 0) { $y = 0 }
          if (($x + $w) -gt $script:dipWidth) { $x = $script:dipWidth - $w }
          if (($y + $h) -gt $script:dipHeight) { $y = $script:dipHeight - $h }
          $script:ui.rect = New-Object System.Windows.Rect $x, $y, $w, $h
        }
      }
      'resize' {
        if ($null -ne $script:ui.rect) {
          $r = $script:ui.rect
          $l = $r.X
          $t = $r.Y
          $rt = $r.X + $r.Width
          $bt = $r.Y + $r.Height
          $k = $script:ui.handle
          if ($k -match 'w') { $l = $point.X }
          if ($k -match 'e') { $rt = $point.X }
          if ($k -match '^n') { $t = $point.Y }
          if ($k -match '^s') { $bt = $point.Y }
          if ($k -eq 'n' -or $k -eq 's') { $l = $r.X; $rt = $r.X + $r.Width }
          if ($k -eq 'e' -or $k -eq 'w') { $t = $r.Y; $bt = $r.Y + $r.Height }
          $script:ui.rect = Clamp-Rect (New-RectFromEdges $l $t $rt $bt)
        }
      }
      default { Set-CursorFor $point }
    }
    if ($script:ui.mode -ne 'idle') {
      $script:handlePoints = Get-HandlePoints $script:ui.rect
    }
    Render-Selection
  })

  $root.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    if ($script:ui.mode -eq 'idle') { return }
    $null = $script:root.ReleaseMouseCapture()
    if ($script:ui.mode -eq 'create') {
      if ($null -eq $script:ui.rect -or $script:ui.rect.Width -lt $MinSize -or $script:ui.rect.Height -lt $MinSize) {
        $script:ui.rect = $null
      }
    }
    $script:ui.mode = 'idle'
    $script:ui.handle = ''
    if ($null -ne $script:ui.rect) { $script:handlePoints = Get-HandlePoints $script:ui.rect }
    Render-Selection
  })

  $root.Add_MouseRightButtonUp({
    param($sender, $eventArgs)
    $script:cancelled = $true
    $script:window.Close()
  })

  # Keys come in two ways depending on who holds focus; both go through one handler.
  $script:keyHandler = {
    param($eventArgs)
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
      Write-Log 'esc: key event'
      if ($null -ne $script:ui.rect -and $script:ui.rect.Width -gt 0) {
        $script:ui.rect = $null
        $script:ui.mode = 'idle'
        Render-Selection
      } else {
        $script:cancelled = $true
        $script:window.Close()
      }
      $eventArgs.Handled = $true
      return
    }
    if ($eventArgs.Key -eq [System.Windows.Input.Key]::Enter) {
      if ($null -ne $script:ui.rect -and $script:ui.rect.Width -ge $MinSize -and $script:ui.rect.Height -ge $MinSize) {
        $script:confirmed = $true
        $script:window.Close()
        $eventArgs.Handled = $true
      }
    }
  }

  $window.Add_PreviewKeyDown({ param($sender, $eventArgs) & $script:keyHandler $eventArgs })
  $window.Add_KeyDown({ param($sender, $eventArgs) & $script:keyHandler $eventArgs })

  # Safety net: never leave the screen covered forever if the picker loses input.
  $script:idleTimer = New-Object System.Windows.Threading.DispatcherTimer
  $script:idleTimer.Interval = [TimeSpan]::FromSeconds(180)
  $script:idleTimer.Add_Tick({
    param($sender, $eventArgs)
    $script:idleTimer.Stop()
    $script:cancelled = $true
    if ($null -ne $script:window) { $script:window.Close() }
  })
  $script:idleTimer.Start()

  # DSH is back on screen as soon as the overlay is up: the overlay is Topmost, so the
  # restored window sits underneath it, keeps running, and never shows inside the still.
  $window.Add_Loaded({
    param($sender, $eventArgs)
    # The app stays hidden until the picker closes: restoring it here made it flash on screen
    # between "hidden" and "first painted frame of the overlay". The overlay shows a still that
    # already does not contain it, so keeping it hidden is also what the user expects to see.
    try {
      $helper = New-Object System.Windows.Interop.WindowInteropHelper $script:window
      [void][DshNative]::SetForegroundWindow($helper.Handle)
    } catch { }
    $null = $script:window.Activate()
    $script:window.Focus() | Out-Null
    [System.Windows.Input.Keyboard]::Focus($script:window) | Out-Null
  })

  # Belt and braces: the overlay cannot always take the keyboard focus (Windows refuses
  # SetForegroundWindow from a background process), so sample the physical keys instead.
  $script:escLatch = $true
  $script:enterLatch = $true
  $script:escWatch = New-Object System.Windows.Threading.DispatcherTimer
  $script:escWatch.Interval = [TimeSpan]::FromMilliseconds(30)
  $script:escWatch.Add_Tick({
    param($sender, $eventArgs)
    if ($script:closing) { return }
    $escDown = $false
    $enterDown = $false
    try { $escDown = [DshNative]::EscapeDown(); $enterDown = [DshNative]::EnterDown() } catch { }
    if (-not $escDown) { $script:escLatch = $false }
    if (-not $enterDown) { $script:enterLatch = $false }

    if ($escDown -and -not $script:escLatch) {
      $script:escLatch = $true
      Write-Log 'esc: async watcher'
      if ($null -ne $script:ui.rect -and $script:ui.rect.Width -gt 0) {
        $script:ui.rect = $null
        $script:ui.mode = 'idle'
        Render-Selection
      } else {
        $script:cancelled = $true
        if ($null -ne $script:window) { $script:window.Close() }
      }
      return
    }

    if ($enterDown -and -not $script:enterLatch) {
      $script:enterLatch = $true
      if ($null -ne $script:ui.rect -and $script:ui.rect.Width -ge $MinSize -and $script:ui.rect.Height -ge $MinSize) {
        Write-Log 'enter: async watcher'
        $script:confirmed = $true
        if ($null -ne $script:window) { $script:window.Close() }
      }
    }
  })
  $script:escWatch.Start()

  if ($script:selfTest -ne '') {
    $window.Left = -32000
    $window.Top = -32000
    $script:ui.rect = New-Object System.Windows.Rect 100, 100, 200, 150
    $script:handlePoints = Get-HandlePoints $script:ui.rect
    Render-Selection
    $script:selfTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:selfTimer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:selfTimer.Add_Tick({
      param($sender, $eventArgs)
      if ($null -ne $sender) { $sender.Stop() }
      $want = $script:selfTest
      foreach ($c in $script:cells) {
        if ([string]$c.Tag -eq $want) {
          $press = New-Object System.Windows.Input.MouseButtonEventArgs ([System.Windows.Input.Mouse]::PrimaryDevice), ([System.Environment]::TickCount), ([System.Windows.Input.MouseButton]::Left)
          $press.RoutedEvent = [System.Windows.UIElement]::MouseLeftButtonDownEvent
          $c.RaiseEvent($press)
          break
        }
      }
    })
    $script:selfTimer.Start()
  }

  $script:escWatch.Start()
  Write-Log ('overlay: showing (rect=' + $(if ($null -eq $script:ui.rect) { 'none' } else { '' + $script:ui.rect }) + ')')
  try {
    $null = $window.ShowDialog()
  } catch {
    Write-Log ('overlay failed: ' + $_.Exception.Message)
    $script:cancelled = $true
  } finally {
    if ($null -ne $script:escWatch) { $script:escWatch.Stop() }
    Write-Log ('overlay: closed (confirmed=' + $script:confirmed + ', cancelled=' + $script:cancelled + ', copied=' + $script:copied + ')')
    try { if ($null -ne $script:window) { $script:window.Close() } } catch { }
    $script:window = $null
    if ($null -ne $script:idleTimer) { $script:idleTimer.Stop() }
    if ($null -ne $script:hidTargets -and $script:hidTargets.Length -gt 0) {
      foreach ($t in $script:hidTargets) {
        if ($t.iconic) { [DshNative]::Minimize($t.hwnd) } else { [DshNative]::Show($t.hwnd) }
      }
      $script:hidTargets = @()
    }
  }

  if ($script:copied) {
    $rect = $script:ui.rect
    try {
      $payload = Get-CropPayload $rect
      $bitmap = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.IO.MemoryStream (,([Convert]::FromBase64String($payload.png)))))
      [System.Windows.Clipboard]::SetImage($bitmap)
      # Flush so the picture survives this process exiting (OLE clipboard otherwise dies with us).
      [System.Windows.Clipboard]::Flush()
    } catch {
      Write-Log ('clipboard failed: ' + $_.Exception.Message)
    }
    return @{ ok = $false; copied = $true }
  }

  if ($script:confirmed -and $null -ne $script:ui.rect) {
    return (Get-CropPayload $script:ui.rect)
  }

  return @{ ok = $false; cancelled = $true }
}

function Send-Payload($id, $started, $payload) {
  $out = [ordered]@{ id = $id; ms = [int](([DateTime]::UtcNow - $started).TotalMilliseconds) }
  foreach ($key in $payload.Keys) { $out[$key] = $payload[$key] }
  Send-Line $out
}

# ---------------------------------------------------------------- request loop

$script:appPid = $null
$script:appPids = @()
$script:appPidStart = 0
$script:dshWindows = @()
$script:hidTargets = @()
$script:dshWindow = [IntPtr]::Zero
$script:ready = $true
$startupWindows = Get-DshWindows
$startupHwnds = ($startupWindows | ForEach-Object { $_.ToInt64() }) -join ','
$null = Hide-ConsoleWindows
Write-Log ('server started (pid ' + $PID + ', app pid ' + (Get-AppPid) + ', windows [' + $startupHwnds + '])')

while ($true) {
  $line = [Console]::In.ReadLine()
  if ($null -eq $line) { break }
  $line = $line.Trim()
  if ($line.Length -eq 0) { continue }

  $request = $null
  try { $request = $line | ConvertFrom-Json } catch { $request = $null }
  if ($null -eq $request) {
    Send-Line ([ordered]@{ ok = $false; error = 'bad json request' })
    continue
  }

  $id = $request.id
  $op = [string]$request.op
  # diagnostic: pretend the app family starts here (used by the offline A/B checks)
  if ($null -ne $request.startpid) {
    $script:appPids = @()
    $script:appPidStart = [int]$request.startpid
  }
  $started = [DateTime]::UtcNow

  try {
    switch ($op) {
      'ping' {
        Send-Line ([ordered]@{ id = $id; ok = $true; pid = $PID; op = 'ping' })
      }
      'full' {
        $null = Hide-ConsoleWindows
        New-Still
        $rect = New-Object System.Windows.Rect 0, 0, $script:dipWidth, $script:dipHeight
        Send-Payload $id $started (Get-CropPayload $rect)
      }
      'crop' {
        $null = Hide-ConsoleWindows
        if ($request.nohide -eq $true) { New-Still -SkipHide } else { New-Still -ExtraMs ([int]$request.settle) }
        $parts = ([string]$request.rect).Split(',')
        if ($parts.Length -ne 4) { throw "crop needs rect='x,y,w,h'" }
        $rect = New-Object System.Windows.Rect ([double]$parts[0]), ([double]$parts[1]), ([double]$parts[2]), ([double]$parts[3])
        Send-Payload $id $started (Get-CropPayload $rect)
      }
      'windows' {
        if ($null -ne $request.startpid) {
          $script:appPids = @()
          $script:appPidStart = [int]$request.startpid
        }
        $pids = Get-AppPids
        $rows = @()
        foreach ($h in (Get-DshWindows)) {
          $r = [DshNative]::RectOf($h)
          $rows += [ordered]@{
            hwnd  = [int64]$h
            cls   = [DshNative]::ClassNameOf($h)
            x     = $r[0]
            y     = $r[1]
            width = $r[2] - $r[0]
            height = $r[3] - $r[1]
          }
        }
        Send-Line ([ordered]@{ id = $id; ok = $true; pids = $pids; windows = $rows })
      }
      'region' {
        $null = Hide-ConsoleWindows
        New-Still -KeepHidden
        Send-Payload $id $started (Show-RegionOverlay -SelfTest ([string]$request.selftest))
      }
      default {
        Send-Line ([ordered]@{ id = $id; ok = $false; error = ("unknown op '" + $op + "'") })
      }
    }
  } catch {
    $message = $_.Exception.Message -replace '[\r\n]+', ' '
    Write-Log ('op ' + $op + ' failed: ' + $message)
    Send-Line ([ordered]@{ id = $id; ok = $false; error = $message })
  }
}

Write-Log 'server stopped'
