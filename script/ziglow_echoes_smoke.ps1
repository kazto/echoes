[CmdletBinding()]
param(
  [string]$RepoRoot,
  [string]$OutDir,
  [string]$ZiglowExe = '..\ziglow\zig-out\bin\ziglow.exe',
  [string]$ZiglowInput = '..\ziglow\tmp\echoes-verify\test.md',
  [int]$RenderWaitSeconds = 5,
  [int]$WindowX = 40,
  [int]$WindowY = 40,
  [int]$WindowWidth = 1000,
  [int]$WindowHeight = 600
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class NativeZiglowEchoesSmoke {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
  public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
}
'@

$PW_RENDERFULLCONTENT = 0x00000002

$scriptRootPath = if ($PSScriptRoot) {
  $PSScriptRoot
} else {
  Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $RepoRoot) {
  $RepoRoot = Join-Path $scriptRootPath '..'
}
$repo = (Resolve-Path $RepoRoot).Path

if (-not $OutDir) {
  $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
  $OutDir = Join-Path $repo "tmp\ziglow-echoes-smoke\$timestamp"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Resolve-SmokePath([string]$Path) {
  if ([System.IO.Path]::IsPathRooted($Path)) {
    return (Resolve-Path -LiteralPath $Path).Path
  }

  return (Resolve-Path -LiteralPath (Join-Path $repo $Path)).Path
}

function Quote-CmdArgument([string]$Path) {
  '"' + ($Path -replace '"', '\"') + '"'
}

$ziglowExePath = Resolve-SmokePath $ZiglowExe
$ziglowInputPath = Resolve-SmokePath $ZiglowInput
if (-not (Test-Path -LiteralPath $ziglowExePath)) {
  throw "ziglow executable was not found: $ziglowExePath"
}
if (-not (Test-Path -LiteralPath $ziglowInputPath)) {
  throw "ziglow input file was not found: $ziglowInputPath"
}

$command = "$(Quote-CmdArgument $ziglowExePath) $(Quote-CmdArgument $ziglowInputPath)"
$beforeCmd = @(Get-Process -Name cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$env:SHELL = if ($env:COMSPEC) { $env:COMSPEC } else { 'C:\Windows\System32\cmd.exe' }
$p = Start-Process -FilePath 'ruby' -ArgumentList @('-Ilib', 'exe\echoes') -WorkingDirectory $repo -PassThru

function Escape-SendKeysText([string]$Text) {
  $Text -replace '([\+\^%~\(\)\{\}\[\]])', '{$1}'
}

function Capture([string]$Name) {
  $rect = New-Object NativeZiglowEchoesSmoke+RECT
  [NativeZiglowEchoesSmoke]::GetWindowRect($p.MainWindowHandle, [ref]$rect) | Out-Null
  $w = [Math]::Max(1, $rect.Right - $rect.Left)
  $h = [Math]::Max(1, $rect.Bottom - $rect.Top)
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  try {
    if (-not [NativeZiglowEchoesSmoke]::PrintWindow($p.MainWindowHandle, $hdc, $PW_RENDERFULLCONTENT)) {
      throw "PrintWindow failed for screenshot: $Name"
    }
  }
  finally {
    $g.ReleaseHdc($hdc)
  }
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

  [NativeZiglowEchoesSmoke]::ShowWindow($p.MainWindowHandle, 5) | Out-Null
  [NativeZiglowEchoesSmoke]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
  [NativeZiglowEchoesSmoke]::SetWindowPos($p.MainWindowHandle, [IntPtr]::Zero, $WindowX, $WindowY, $WindowWidth, $WindowHeight, 0x0040) | Out-Null
  Start-Sleep -Seconds 3

  $initial = Capture '01-initial.png'
  [System.Windows.Forms.SendKeys]::SendWait((Escape-SendKeysText $command))
  Start-Sleep -Seconds 1
  $commandEntered = Capture '02-command-entered.png'
  [System.Windows.Forms.SendKeys]::SendWait('{ENTER}')
  Start-Sleep -Seconds $RenderWaitSeconds
  $ziglowOutput = Capture '03-ziglow-output.png'

  [System.Windows.Forms.SendKeys]::SendWait('%{F4}')
  Start-Sleep -Seconds 3
  if (-not $p.HasExited) {
    [NativeZiglowEchoesSmoke]::PostMessage($p.MainWindowHandle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
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
    command = $command
    screenshots = @($initial, $commandEntered, $ziglowOutput)
    new_cmd_processes = @()
  } | ConvertTo-Json -Compress
}
finally {
  if ($p -and -not $p.HasExited) { $p.Kill() }
}
