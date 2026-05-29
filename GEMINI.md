# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Echoes is a Ruby gem (currently a freshly scaffolded template at v0.1.0). Author: Akira Matsuda. Requires Ruby >= 3.2.0. Licensed under MIT.

## Commands

- **Install dependencies:** `bin/setup`
- **Run all tests:** `bundle exec rake test` (or just `bundle exec rake`, test is the default task)
- **Run a single test file:** `bundle exec ruby -Ilib:test test/echoes_test.rb`
- **Run a single test method:** `bundle exec ruby -Ilib:test test/echoes_test.rb -n test_method_name`
- **Interactive console:** `bin/console`
- **Install gem locally:** `bundle exec rake install`

## Architecture

Standard Ruby gem layout:

- `lib/echoes.rb` — Main module entry point (defines `Echoes` module)
- `lib/echoes/version.rb` — Version constant
- `sig/echoes.rbs` — RBS type signatures
- `test/` — Tests using **test-unit** framework (not minitest, not rspec)

## Testing

Uses the **test-unit** gem (~> 3.0). Test classes inherit from `Test::Unit::TestCase`. Test helper is at `test/test_helper.rb`.

## Windows GUI Manual Verification

Codex can verify the Windows GUI from PowerShell by launching Echoes, sending keystrokes to the Win32 window, taking screenshots, and checking for leftover shell processes. Use this for Windows GUI regressions that cannot be covered by unit tests.

Run from the repository root. Use `ruby -Ilib exe\echoes`; `ruby exe\echoes` does not add `lib/` to the load path.

```powershell
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

$repo = (Get-Location).Path
$outDir = Join-Path $repo 'tmp\gui-smoke'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$beforeCmd = @(Get-Process -Name cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
$p = Start-Process -FilePath 'ruby' -ArgumentList @('-Ilib', 'exe\echoes') -WorkingDirectory $repo -PassThru

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

  function Capture($name) {
    $rect = New-Object NativeWin+RECT
    [NativeWin]::GetWindowRect($p.MainWindowHandle, [ref]$rect) | Out-Null
    $w = [Math]::Max(1, $rect.Right - $rect.Left)
    $h = [Math]::Max(1, $rect.Bottom - $rect.Top)
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bmp.Size)
    $path = Join-Path $outDir $name
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $bmp.Dispose()
    $path
  }

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
  if (-not $p.HasExited) { $p.Kill() }

  $afterCmd = @(Get-Process -Name cmd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
  $newCmd = @($afterCmd | Where-Object { $beforeCmd -notcontains $_ })
  [pscustomobject]@{
    exited = $p.HasExited
    screenshots = @($initial, $typedD, $backspaced, $dirOut, $resized)
    new_cmd_processes = ($newCmd -join ',')
  } | ConvertTo-Json -Compress
}
finally {
  if ($p -and -not $p.HasExited) { $p.Kill() }
}
```

Expected screenshots:

- `01-initial.png`: `cmd.exe` banner and prompt are visible.
- `02-typed-d.png`: prompt remains visible after typing `d`.
- `03-backspaced-dir.png`: after typing `dir` and pressing Backspace three times, the cursor returns to the prompt end.
- `04-dir-output.png`: Enter produces `dir` output.
- `05-resized.png`: output remains coherent after resizing.
- `new_cmd_processes` should be empty after the GUI exits.

## CI

GitHub Actions runs `bundle exec rake` on push to master and on pull requests (Ruby 4.1.0, ubuntu-latest).
