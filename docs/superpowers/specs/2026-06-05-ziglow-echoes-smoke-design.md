# Ziglow Echoes Smoke Design

**Date:** 2026-06-05
**Status:** Approved
**Scope:** Windows-only manual verification harness for running ziglow inside Echoes.

## Goal

Create a repeatable way to launch Echoes on Windows, start `ziglow` from the terminal using `cmd.exe`, and save screenshots that can be inspected while developing Kitty Text Sizing Protocol support in ziglow.

## Chosen Approach

Add a dedicated PowerShell script instead of extending the general Windows GUI smoke test. The new script keeps ziglow verification separate from the existing Echoes GUI health check, while reusing the same Win32 automation pattern: launch Echoes, wait for its window, bring it to the foreground, send keystrokes, capture screenshots, and close the window cleanly.

Echoes will start with `cmd.exe` as its shell. The script accepts these default sibling-repository paths:

```text
..\ziglow\zig-out\bin\ziglow.exe ..\ziglow\tmp\echoes-verify\test.md
```

Before typing the command into Echoes, the script resolves both paths to absolute paths and quotes them. This avoids depending on the startup directory of the `cmd.exe` process inside Echoes.

## Components

- `script/ziglow_echoes_smoke.ps1`: Windows-only harness that launches Echoes, sends the ziglow command, captures screenshots, and closes Echoes.
- `Rakefile`: Adds `test:ziglow_echoes_smoke`, mirroring `test:windows_gui_smoke`.

## Outputs

The script writes images under `tmp\ziglow-echoes-smoke\<timestamp>\`. It saves at least:

- `01-initial.png`: Echoes after startup.
- `02-command-entered.png`: The ziglow command after being typed.
- `03-ziglow-output.png`: The terminal after ziglow has had time to render output.

The primary success artifact is the saved image set. Automatic visual correctness checks are intentionally minimal for the first version.

## Failure Handling

The script fails when Echoes exits early, the window handle is never created, a screenshot is missing or empty, Echoes cannot be closed, or a new `cmd.exe` process remains after shutdown.

## Out of Scope

- Implementing Kitty Text Sizing Protocol in ziglow.
- Adding OCR, image diffing, or pixel-level protocol assertions.
- Changing the existing `script/windows_gui_smoke.ps1` behavior.
