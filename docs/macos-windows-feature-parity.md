# macOS / Windows Feature Parity

This document maps the macOS native API inventory to the closest Windows capability and the current Echoes implementation status.

Inventory date: 2026-05-26.

## Status Legend

| Status | Meaning |
| --- | --- |
| Done | Windows has an implementation in the current source that provides the Echoes feature. |
| Partial | Windows has a working subset, but it is not equivalent to the macOS/AppKit behavior. |
| Alternate | Windows intentionally uses a different persistence, packaging, or UX model. |
| Missing | Windows has no current implementation for this feature. |
| Not applicable | The macOS API is an implementation detail with no direct Windows feature requirement. |

## Source Map

| Area | Windows source |
| --- | --- |
| Win32 Fiddle bindings | `lib/echoes/win32.rb` |
| Windows GUI backend | `lib/echoes/gui_win32.rb` |
| Windows window registry | `lib/echoes/window_registry.rb` |
| Windows ConPTY shell backend | `lib/echoes/conpty.rb`, `lib/echoes/shell_backend.rb` |
| Windows PNG/RGB/RGBA decoder | `lib/echoes/kitty_graphics_win32.rb` |
| Preferences | `lib/echoes/preferences.rb` |
| Installer | `lib/echoes/installer.rb` |
| Platform selection / load boundary | `lib/echoes.rb`, `lib/echoes/platform.rb`, `exe/echoes` |

## Parity Table

| macOS feature | macOS API / mechanism | Windows counterpart | Current status | Source | Gap / note |
| --- | --- | --- | --- | --- | --- |
| Lazy native load boundary | Conditional AppKit loading through `Echoes.load_gui_backend` | Conditional Win32 GUI loading | Done | `lib/echoes.rb`, `lib/echoes/platform.rb` | Windows avoids loading AppKit/CoreGraphics. |
| Native binding layer | Objective-C runtime via `libobjc` and `objc_msgSend` | Direct Win32 DLL bindings through Fiddle | Done | `lib/echoes/win32.rb` | Windows does not need an Objective-C-style dispatch layer. |
| GUI app lifecycle | `NSApplication.sharedApplication`, `run`, `terminate:` | Win32 message loop with `PeekMessageW`, `TranslateMessage`, `DispatchMessageW`, `WM_QUIT` | Partial | `lib/echoes/gui_win32.rb` | Basic loop and native menu command dispatch exist. App-level services are still not equivalent to AppKit. |
| Window creation | `NSWindow initWithContentRect:styleMask:backing:defer:` | `RegisterClassExW`, `CreateWindowExW`, `ShowWindow`, `UpdateWindow` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Single main Win32 window exists. AppKit-style multiple windows are not implemented. |
| Window title | `NSWindow#setTitle:` | `SetWindowTextW` | Done | `lib/echoes/gui_win32.rb` | Used for tab/window title and notification fallback. |
| Window autosave | `setFrameAutosaveName:`, `NSUserDefaults` | JSON preferences backend plus `GetWindowRect` | Done | `lib/echoes/preferences.rb`, `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Normal Windows launches restore the last saved window frame from JSON preferences and save the frame on exit. Explicit `ECHOES_WINDOW_*` launches still use their requested geometry without overwriting the saved default. |
| Content view / first responder | `setContentView:`, `makeFirstResponder:` | `HWND` receives `WndProc` messages, `SetFocus` | Done | `lib/echoes/gui_win32.rb` | Different model, but keyboard input is routed to the terminal window. |
| Custom view subclass | Runtime-created `EchoesTerminalView < NSView` | `WndProc` callback closure | Done | `lib/echoes/gui_win32.rb` | Windows uses a window procedure instead of dynamic class methods. |
| Repaint callback | `drawRect:` | `WM_PAINT`, double-buffered GDI paint | Done | `lib/echoes/gui_win32.rb` | Win32 has double buffering with compatible DC/bitmap. |
| Resize callback | `setFrameSize:` hook | `WM_SIZE`, `GetClientRect` | Done | `lib/echoes/gui_win32.rb` | Resize updates terminal rows/cols and ConPTY size. |
| Timer / polling repaint | `NSTimer scheduledTimerWithTimeInterval:` | Manual polling in message loop with short sleep/repaint | Partial | `lib/echoes/gui_win32.rb` | Functional polling exists; it is not a native Win32 timer abstraction. |
| Window focus notifications | `NSNotificationCenter` for key/resign notifications | `WM_SETFOCUS` / `WM_KILLFOCUS` equivalent | Done | `lib/echoes/gui_win32.rb` | Win32 focus changes update focused state and send focus reporting sequences when `?1004` is enabled. |
| Menu bar | `NSMenu`, `NSMenuItem`, `setMainMenu:` | Win32 menus and accelerator table | Partial | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Windows has File/Edit/View/Window/Shell/Help menus and accelerators for common tab, pane, search, profile, pointer, About, and Exit commands. App-level macOS services are not equivalent. |
| Window menu | `NSApplication#setWindowsMenu:` | Win32 menu plus shared process window registry | Partial | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb`, `lib/echoes/window_registry.rb` | Windows lists open Echoes windows across processes and can focus, minimize, maximize, or restore the current window. It is process-registry based rather than AppKit's in-process windows menu. |
| Completion popup | `NSMenu#popUpMenuPositioningItem:atLocation:inView:` | `TrackPopupMenu` anchored at the terminal cursor | Partial | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Windows has a native popup substrate for embedded-pane completion requests. Embedded rubish mode is still unsupported on Windows, so the normal Windows GUI cannot exercise this path yet. |
| Keyboard input | `NSEvent#characters`, `keyCode`, `modifierFlags`, `interpretKeyEvents:` | `WM_CHAR`, `WM_KEYDOWN`, virtual-key mapping | Done | `lib/echoes/gui_win32.rb` | Special keys and Ctrl-letter mappings are implemented. |
| Copy mode/search key routing | AppKit keyboard callbacks | Win32 `WM_CHAR` / `WM_KEYDOWN` routed to shared pane logic | Partial | `lib/echoes/gui_win32.rb` | Search mode, live query updates, next/previous navigation, and selection helpers exist, but the Windows UI surface is smaller than AppKit. |
| IME composition | `NSTextInputClient` | IMM32: `WM_IME_*`, `ImmGetContext`, `ImmGetCompositionStringW`, `ImmSetCandidateWindow` | Partial | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Inline composition, result commit, and cursor-based candidate positioning exist. Full Cocoa text-input parity is not implemented. |
| Mouse click/drag | `mouseDown:`, `mouseDragged:`, `mouseUp:` and right/other variants | `WM_LBUTTONDOWN`, `WM_LBUTTONUP`, `WM_MBUTTONDOWN`, `WM_MBUTTONUP`, `WM_RBUTTONDOWN`, `WM_RBUTTONUP`, `WM_XBUTTONDOWN`, `WM_XBUTTONUP`, `WM_MOUSEMOVE`, `WM_MOUSEWHEEL` | Done | `lib/echoes/gui_win32.rb` | Left/middle/right/X-button press, drag, release, and wheel are routed to terminal mouse reporting. |
| Mouse wheel | `scrollWheel:`, `deltaY` | `WM_MOUSEWHEEL` | Done | `lib/echoes/gui_win32.rb` | Scroll accumulation and pane scrolling are implemented. |
| Pointer cursor shape/visibility | `NSCursor.IBeamCursor`, `hide`, `unhide`, cursor rects | `LoadCursorW`, `SetCursor`, `ShowCursor`, `WM_SETCURSOR` | Partial | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Terminal client area uses the I-beam cursor while non-client areas keep the default cursor. Hide/unhide is available from the View menu and Ctrl+Shift+P, with shake-to-show support. Per-cell cursor rects are not implemented. |
| Text fill drawing | `NSColor#setFill`, `NSRectFill` | GDI `CreateSolidBrush`, `FillRect` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Used for background, selection, decorations, cursor, and pane borders. |
| Text drawing | `NSString#drawAtPoint:withAttributes:` | GDI `TextOutW`, `ExtTextOutW` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Regular terminal text and multicell text are drawn with GDI. |
| Font creation | `NSFont fontWithName:size:`, `monospacedSystemFontOfSize:weight:` | `CreateFontW` | Done | `lib/echoes/gui_win32.rb` | Regular, bold, italic, bold-italic fonts are created. |
| Font metrics | `NSFont#ascender`, `descender`, `defaultLineHeightForFont`, `NSString#sizeWithAttributes:` | `GetTextMetricsW`, `GetTextExtentPoint32W` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Cell size and text extent are measured with GDI. |
| Font fallback | `CTFontCreateForString` | `GetGlyphIndicesW` plus fallback families | Partial | `lib/echoes/gui_win32.rb` | Fallback runs exist for common Japanese/emoji/symbol fonts. Complex shaping/color emoji are still GDI-limited. |
| Underline/strikethrough | AppKit text attributes | Explicit GDI rectangle decorations | Done | `lib/echoes/gui_win32.rb` | Decorations are drawn manually. |
| Ligature suppression | `NSLigatureAttributeName` | GDI text rendering | Missing | - | GDI path does not expose equivalent ligature control. |
| Gradients | `NSGradient#drawInRect:angle:` | Manual GDI scanline fill | Partial | `lib/echoes/gui_win32.rb` | Windows paints OSC flat pane backgrounds, bg-fill overlays, and two-endpoint linear gradients. Alpha blending and multi-stop gradients are not equivalent to AppKit. |
| CoreGraphics image drawing | `CGContextDrawImage`, `CGImage` | GDI `StretchDIBits` with BGRA DIB | Done | `lib/echoes/gui_win32.rb` | Kitty/iTerm image placements are drawn from RGBA buffers. |
| PNG decode | `NSData`, `NSBitmapImageRep`, `CGImage` | GDI+ `GdipCreateBitmapFromStream` path | Done | `lib/echoes/kitty_graphics_win32.rb` | PNG decode returns the same RGBA shape expected by renderers. |
| Raw RGB/RGBA conversion | `CGDataProviderCreateWithData`, `CGImageCreate` | Ruby buffer conversion / GDI+ path | Done | `lib/echoes/kitty_graphics_win32.rb` | `from_rgb` and `from_rgba` exist. |
| Clipboard text | `NSPasteboard` with `NSPasteboardTypeString` | Win32 clipboard `CF_UNICODETEXT` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Copy/paste and OSC 52 use the Win32 helper. |
| File URL drag/drop | `NSPasteboardTypeFileURL`, `readObjectsForClasses:options:` | `WM_DROPFILES`, `DragQueryFileW` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Dropped file paths are shell-quoted and pasted into the active pane, including bracketed paste mode. |
| Open file dialog | `NSOpenPanel` | `GetOpenFileNameW` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Windows can prompt for a single editor file, starting from the active pane's OSC 7 working directory when available. |
| URL open | `NSWorkspace.openURL:` | `ShellExecuteW` / Ctrl-click URL detection | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Windows Ctrl-click opens OSC 8 hyperlinks or detected `http(s)` URLs through `ShellExecuteW`. |
| About panel | `orderFrontStandardAboutPanelWithOptions:` | `MessageBoxW` custom dialog | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Windows shows About content through a native message box from the Help menu. |
| Notifications | `terminal-notifier` fallback on macOS | Window title fallback | Alternate | `lib/echoes/gui_win32.rb` | OSC 9 / OSC 777 requests set the Win32 window title; no native toast implementation. |
| Screen enumeration | `NSScreen.screens`, `frame`, `visibleFrame`, `backingScaleFactor` | `EnumDisplayMonitors`, `GetMonitorInfoW`, `MonitorFromWindow` | Partial | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | OSC display-info returns monitor and work-area geometry plus primary/current flags. Backing scale factor is not represented. |
| External/presentation windows | New `NSWindow` on selected `NSScreen` | Child Echoes process with monitor geometry env | Partial | `lib/echoes/gui_win32.rb` | OSC open-window launches a separate Windows Echoes process on the requested monitor with decoded argv and initial geometry. It is process-based rather than an in-process multi-window model. |
| Pane capture to PDF/PNG | `dataWithPDFInsideRect:`, `NSBitmapImageRep` capture | GDI bitmap capture / pure-Ruby PNG and raster PDF encoders | Partial | `lib/echoes/gui_win32.rb`, `lib/echoes/win32.rb` | OSC capture writes PNG files or one-page raster PDFs on Windows. AppKit-style vector PDF capture is not implemented. |
| Preferences storage | `NSUserDefaults` suite | JSON file under `%APPDATA%/Echoes` or `ECHOES_CONFIG_HOME` | Alternate | `lib/echoes/preferences.rb` | Feature exists through a platform-specific backend, not the Windows registry. |
| Shell process backend | macOS PTY backend | ConPTY backend | Done | `lib/echoes/conpty.rb`, `lib/echoes/shell_backend.rb`, `lib/echoes/pane.rb` | Normal panes use ConPTY on Windows. Ctrl-C delivery remains a known gap. |
| Shell resize | PTY window size/ioctl | `ResizePseudoConsole` | Done | `lib/echoes/conpty.rb`, `lib/echoes/gui_win32.rb` | Resize propagation is implemented. |
| Shell encoding | UTF-8 PTY stream | Console code page conversion | Done | `lib/echoes/shell_backend.rb` | ConPTY output is decoded from locale encoding; input is encoded back. |
| Embedded rubish mode | Unix PTY/process group/job control | Windows process/helper model needed | Missing | `lib/echoes/embedded_shell.rb` | Explicitly blocked on Windows. |
| Installer | `.app` wrapper copy | `echoes.bat` wrapper | Alternate | `lib/echoes/installer.rb` | Windows launcher exists, but there is no native executable/MSI/app bundle equivalent. |

## Summary

Windows currently covers the core terminal path:

- Win32 window creation and message loop.
- Window frame autosave through JSON preferences.
- ConPTY-backed shell process I/O and resize.
- GDI text rendering, font selection, basic font fallback, decorations, selections, and image blitting.
- GDI+ PNG decode and raw RGB/RGBA conversion.
- Keyboard input, special keys, mouse wheel, basic mouse selection, clipboard text, OSC 52, and minimal OSC notification fallback.
- OSC display-info and process-based OSC open-window launch on a selected monitor.
- Basic Window menu integration backed by a shared Win32 window registry.
- Native completion popup substrate for embedded-pane completion requests.
- OSC capture to PNG and raster PDF.
- JSON preferences and `.bat` installer.

The largest remaining AppKit parity gaps are:

- App-level macOS menu services.
- In-process multiple native windows and full AppKit-style Window menu behavior.
- Vector pane capture.
- Full Cocoa-style IME/text-input parity.
- Full gradient alpha/multi-stop parity, ligature control, per-cell cursor rect parity, and richer font shaping.
- Native toast notifications.
- Embedded rubish mode, which also blocks user-visible completion popup parity on Windows.
- Robust Ctrl-C delivery through ConPTY.

## Maintenance Notes

- When adding a Windows counterpart for a macOS API listed in `docs/macos-fiddle-api-inventory.md`, update this table in the same change.
- Mark features as `Alternate` only when Echoes intentionally provides the same user-facing capability through a different Windows model.
- Mark features as `Partial` when the implementation exists but user-visible behavior can differ from macOS.
- Keep implementation evidence in the `Source` column specific enough to let a maintainer jump to the owning file quickly.
