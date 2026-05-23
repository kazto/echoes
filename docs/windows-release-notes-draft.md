# Windows Initial Support Release Notes Draft

This draft summarizes the current Windows support scope for the first Windows-capable release.

## Supported

- `require "echoes"` works on Windows without loading AppKit or CoreGraphics.
- Windows core tests can be run with `ruby -S rake test:core`.
- Normal shell panes use ConPTY on Windows.
- The Windows shell default resolves in this order: `COMSPEC`, `pwsh`, `powershell.exe`.
- ConPTY panes support read / write, resize, cwd, explicit environment variables, and cleanup on close.
- Preferences use JSON persistence on Windows.
- Configuration is loaded from `%APPDATA%/Echoes/echoes.conf`, with legacy `~/.config/echoes/echoes.conf` fallback.
- `echoes install` creates a Windows `echoes.bat` launcher.
- The Windows GUI has a minimal Win32 implementation: window, GDI text drawing, shell polling, keyboard input, resize, clipboard, notifications, URL open, image blit, and basic text styles.
- Kitty graphics and iTerm2 inline images decode PNG through GDI+ and render through GDI blitting.

## Unsupported Or Incomplete

- Embedded rubish mode is not supported on Windows.
- Windows GUI file dialog, drag and drop, multi-display window placement, and full IME behavior remain incomplete.
- macOS full test verification must still be run on macOS before release.
- Remote Windows CI success is not yet confirmed.

## Minimum Windows Requirements

- Ruby 4.0 x64 for the current tested environment.
- Windows 10 1809 or later, or Windows 11, because the shell backend depends on ConPTY.

## Verification Snapshot

- Local Windows core tests pass with `ruby -S rake test:core` (verified 2026-05-23: 603 tests, 1289 assertions, 0 failures).
- Local Windows default test pass with `ruby -S rake test`.
- Windows GUI launch verified 2026-05-23 (`ruby -Ilib exe/echoes`).
- Windows-specific installer, preferences, shell backend, GUI helper, image decode, and text rendering tests are included in the core test set.
