[CmdletBinding()]
param(
  [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
  [string]$OutDir
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class NativeWin {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@

$repo = (Resolve-Path $RepoRoot).Path
if (-not $OutDir) {
  $OutDir = Join-Path $repo 'tmp\gui-smoke'
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$beforeCmd = @(Get-Process -Name cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$p = Start-Process -FilePath 'ruby' -ArgumentList @('-Ilib', 'exe\echoes') -WorkingDirectory $repo -PassThru

function Capture([string]$Name) {
  $rect = New-Object NativeWin+RECT
  [NativeWin]::GetWindowRect($p.MainWindowHandle, [ref]$rect) | Out-Null
  $w = [Math]::Max(1, $rect.Right - $rect.Left)
  $h = [Math]::Max(1, $rect.Bottom - $rect.Top)
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
  $path = Join-Path $OutDir $Name
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose()
  $bmp.Dispose()
  if (-not (Test-Path -LiteralPath $path)) {
    throw "screenshot was not written: $path"
  }
  if ((Get-Item -LiteralPath $path).Length -le 0) {
    throw "screenshot was empty: $path"
  }
  $path
}

try {
  $deadline = (Get-Date).AddSeconds(15)
  do {
    Start-Sleep -Milliseconds 250
    $p.Refresh()
  } while ($p.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline -and -not $p.HasExited)

  if ($p.HasExited) { throw "Echoes exited early with code $($p.ExitCode)" }
  if ($p.MainWindowHandle -eq 0) { throw 'Echoes window handle was not created' }

  [NativeWin]::ShowWindow($p.MainWindowHandle, 5) | Out-Null
  [NativeWin]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
  Start-Sleep -Seconds 3

  $initial = Capture '01-initial.png'
  [System.Windows.Forms.SendKeys]::SendWait('d')
  Start-Sleep -Seconds 1
  $typedD = Capture '02-typed-d.png'

  [System.Windows.Forms.SendKeys]::SendWait('ir')
  Start-Sleep -Milliseconds 500
  [System.Windows.Forms.SendKeys]::SendWait('{BACKSPACE}{BACKSPACE}{BACKSPACE}')
  Start-Sleep -Seconds 1
  $backspaced = Capture '03-backspaced-dir.png'

  [System.Windows.Forms.SendKeys]::SendWait('dir')
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Seconds 2
  $dirOut = Capture '04-dir-output.png'

  [NativeWin]::SetWindowPos($p.MainWindowHandle, [IntPtr]::Zero, 80, 80, 1000, 720, 0x0040) | Out-Null
  Start-Sleep -Seconds 2
  $resized = Capture '05-resized.png'

  [System.Windows.Forms.SendKeys]::SendWait('%{F4}')
  Start-Sleep -Seconds 3
  if (-not $p.HasExited) {
    [NativeWin]::PostMessage($p.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Start-Sleep -Seconds 2
  }
  if (-not $p.HasExited) {
    throw 'Echoes did not exit cleanly'
  }

  $afterCmd = @(Get-Process -Name cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  $newCmd = @($afterCmd | Where-Object { $beforeCmd -notcontains $_ })
  if ($newCmd.Count -gt 0) {
    throw "leftover cmd.exe processes: $($newCmd -join ',')"
  }

  [pscustomobject]@{
    exited = $true
    screenshots = @($initial, $typedD, $backspaced, $dirOut, $resized)
    new_cmd_processes = @()
  } | ConvertTo-Json -Compress
}
finally {
  if ($p -and -not $p.HasExited) { $p.Kill() }
}
