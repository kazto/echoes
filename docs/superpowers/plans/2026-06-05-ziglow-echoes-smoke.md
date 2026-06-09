# Ziglow Echoes Smoke Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Windows-only smoke harness that launches Echoes, starts ziglow from `cmd.exe`, and saves screenshots for manual Text Sizing Protocol verification.

**Architecture:** Create a dedicated PowerShell script modeled after `script/windows_gui_smoke.ps1`, then expose it through a Rake task. Keep ziglow-specific behavior outside the existing general GUI smoke script.

**Tech Stack:** Ruby Rake, PowerShell, Win32 user32 calls through `Add-Type`, Windows Forms `SendKeys`, System.Drawing screenshots.

---

## File Structure

- Create `script/ziglow_echoes_smoke.ps1`: Dedicated ziglow-on-Echoes harness.
- Modify `Rakefile`: Add `test:ziglow_echoes_smoke`.
- Test through `bundle exec rake test:ziglow_echoes_smoke` on Windows.

### Task 1: Add the Ziglow PowerShell Harness

**Files:**
- Create: `script/ziglow_echoes_smoke.ps1`

- [ ] **Step 1: Create the script from the existing smoke pattern**

Create `script/ziglow_echoes_smoke.ps1` with parameters for `RepoRoot`, `OutDir`, `ZiglowExe`, `ZiglowInput`, and `RenderWaitSeconds`. Default `ZiglowExe` to `..\ziglow\zig-out\bin\ziglow.exe` and `ZiglowInput` to `..\ziglow\tmp\echoes-verify\test.md`. Resolve both defaults to absolute paths before sending the command to Echoes because the `cmd.exe` process inside Echoes may start outside the Echoes repository directory.

- [ ] **Step 2: Launch Echoes with cmd.exe**

Set `$env:SHELL` to `$env:COMSPEC` or `C:\Windows\System32\cmd.exe`, then start `ruby -Ilib exe\echoes` in the repository root.

- [ ] **Step 3: Capture startup and ziglow output screenshots**

Wait for `MainWindowHandle`, bring the window forward, capture `01-initial.png`, send the escaped command, capture `02-command-entered.png`, wait for ziglow rendering, then capture `03-ziglow-output.png`.

- [ ] **Step 4: Close Echoes and report JSON**

Send Alt+F4, fall back to `WM_CLOSE`, fail if Echoes remains alive, fail if new `cmd.exe` processes remain, and output compact JSON containing `exited`, `screenshots`, and `command`.

### Task 2: Add the Rake Task

**Files:**
- Modify: `Rakefile`

- [ ] **Step 1: Add `test:ziglow_echoes_smoke`**

Inside the existing `namespace :test`, add a Windows-only task that locates `script/ziglow_echoes_smoke.ps1`, invokes PowerShell with `-NoLogo -NoProfile -ExecutionPolicy Bypass -File`, prints the command, and raises `"Ziglow Echoes smoke failed"` if it fails.

### Task 3: Verify the Harness

**Files:**
- Verify: `script/ziglow_echoes_smoke.ps1`
- Verify: `Rakefile`

- [ ] **Step 1: Run syntax-level checks**

Run `bundle exec ruby -c Rakefile`.
Expected: `Syntax OK`.

- [ ] **Step 2: Run the ziglow smoke task**

Run `bundle exec rake test:ziglow_echoes_smoke`.
Expected: JSON output with three screenshot paths under `tmp\ziglow-echoes-smoke\<timestamp>\`.

- [ ] **Step 3: Inspect artifacts**

Confirm `01-initial.png`, `02-command-entered.png`, and `03-ziglow-output.png` exist and are non-empty.
