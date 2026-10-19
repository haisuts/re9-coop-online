# Bring one window to the front by its handle (dev tool: with two games running, um win drive sends
# input to whichever re9 window is in front).   powershell -File tools/fg.ps1 <hwnd>
param([long]$hwnd)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class Fg {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
"@
$h = [IntPtr]$hwnd
$fgThread = [Fg]::GetWindowThreadProcessId([Fg]::GetForegroundWindow(), [IntPtr]::Zero)
$me = [Fg]::GetCurrentThreadId()
[Fg]::AttachThreadInput($me, $fgThread, $true) | Out-Null
[Fg]::ShowWindow($h, 5) | Out-Null
$ok = [Fg]::SetForegroundWindow($h)
[Fg]::AttachThreadInput($me, $fgThread, $false) | Out-Null
if ([Fg]::GetForegroundWindow() -eq $h) { "front" } else { "not front ($ok)" }
