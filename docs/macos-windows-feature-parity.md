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
| GUI app lifecycle | `NSApplication.sharedApplication`, `run`, `terminate:` | Win32 message loop with `PeekMessageW`, `TranslateMessage`, `DispatchMessageW`, `WM_QUIT` | Done | `lib/echoes/gui_win32/core.rb`, `lib/echoes/gui_win32/rendering_primitives.rb` | Complete Win32 message loop with WM_CLOSE/WM_QUIT handling, proper shutdown sequence via `request_window_close`. WM_DESTROY cleanup includes tab closure, font/brush deletion, window registry unregistration, and resource cleanup. Native timer with SetTimer/KillTimer for I/O polling. Platform-specific differences exist, but all lifecycle management is functional. |
| Window creation | `NSWindow initWithContentRect:styleMask:backing:defer:` | `RegisterClassExW`, `CreateWindowExW`, `ShowWindow`, `UpdateWindow` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Single main Win32 window exists. AppKit-style multiple windows are not implemented. |
| Window title | `NSWindow#setTitle:` | `SetWindowTextW` | Done | `lib/echoes/gui_win32.rb` | Used for tab/window title and notification fallback. |
| Window autosave | `setFrameAutosaveName:`, `NSUserDefaults` | JSON preferences backend plus `GetWindowRect` | Done | `lib/echoes/preferences.rb`, `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Normal Windows launches restore the last saved window frame from JSON preferences and save the frame on exit. Explicit `ECHOES_WINDOW_*` launches still use their requested geometry without overwriting the saved default. |
| Content view / first responder | `setContentView:`, `makeFirstResponder:` | `HWND` receives `WndProc` messages, `SetFocus` | Done | `lib/echoes/gui_win32.rb` | Different model, but keyboard input is routed to the terminal window. |
| Custom view subclass | Runtime-created `EchoesTerminalView < NSView` | `WndProc` callback closure | Done | `lib/echoes/gui_win32.rb` | Windows uses a window procedure instead of dynamic class methods. |
| Repaint callback | `drawRect:` | `WM_PAINT`, double-buffered GDI paint | Done | `lib/echoes/gui_win32.rb` | Win32 has double buffering with compatible DC/bitmap. |
| Resize callback | `setFrameSize:` hook | `WM_SIZE`, `GetClientRect` | Done | `lib/echoes/gui_win32.rb` | Resize updates terminal rows/cols and ConPTY size. |
| Timer / polling repaint | `NSTimer scheduledTimerWithTimeInterval:` | `SetTimer`, `WM_TIMER`, fallback loop tick | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Windows uses a native `WM_TIMER` tick to poll ConPTY output and refresh dynamic Window menu state, with the existing loop tick retained as a fallback if timer setup fails. |
| Window focus notifications | `NSNotificationCenter` for key/resign notifications | `WM_SETFOCUS` / `WM_KILLFOCUS` equivalent | Done | `lib/echoes/gui_win32.rb` | Win32 focus changes update focused state and send focus reporting sequences when `?1004` is enabled. |
| Menu bar | `NSMenu`, `NSMenuItem`, `setMainMenu:` | Win32 menus and accelerator table | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32/menu.rb` | Comprehensive app menu (Echoes/File/Edit/View/Window/Shell/Help) with full accelerator table support for keyboard shortcuts. Covers tab management, search, profile selection, pointer hiding, 'Select All', font scaling, copy/paste, window management (minimize, maximize, fullscreen), and shell operations (split, close pane). Platform-specific differences exist (macOS Services menu vs. Windows approach), but all core terminal UI functionality is present. |
| Window menu | `NSApplication#setWindowsMenu:` | Win32 menu plus shared process window registry | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32/menu.rb`, `lib/echoes/window_registry.rb` | Cross-process window registry backed by shared memory with mutex synchronization. Lists up to 32 Echoes windows across all processes with focus, minimize, maximize, restore, bring-all-to-front, and tab navigation commands. Process-registry model differs from AppKit's in-process menu but provides full window management functionality. |
| Tab bar | `NSTabView` / custom drawing | Custom GDI drawing and click handling | Done | `lib/echoes/gui_win32.rb` | Windows implements a native-looking interactive tab bar using GDI, supporting active tab highlighting and mouse click selection. |
| Completion popup | `NSMenu#popUpMenuPositioningItem:atLocation:inView:` | `TrackPopupMenu` anchored at the terminal cursor | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32/menu.rb` | Native `TrackPopupMenu`-based completion popup implementation at cursor position. Full candidate menu display with selection and application. Requires embedded mode to trigger; embedded rubish mode remains unsupported on Windows, so this path is not exercised in normal usage, but the popup substrate is complete and ready for embedded mode when available. |
| Keyboard input | `NSEvent#characters`, `keyCode`, `modifierFlags`, `interpretKeyEvents:` | `WM_CHAR`, `WM_KEYDOWN`, virtual-key mapping | Done | `lib/echoes/gui_win32.rb` | Special keys and Ctrl-letter mappings are implemented. |
| Copy mode/search key routing | AppKit keyboard callbacks | Win32 `WM_CHAR` / `WM_KEYDOWN` routed to shared pane logic | Done | `lib/echoes/gui_win32.rb` | Search mode, live query updates, next/previous navigation, copy-mode h/j/k/l plus arrow and paging keys, selection helpers, and full 'Select All' support exist. |
| IME composition | `NSTextInputClient` | IMM32: `WM_IME_*`, `ImmGetContext`, `ImmGetCompositionStringW`, `ImmSetCandidateWindow`, `ImmGetCompositionStringW` (attributes), `ImmGetCompositionStringW` (reading) | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32/window_and_input.rb` | Inline composition, result commit, cursor-based candidate positioning, colored underline feedback, target clause highlighting, reading string (furigana) support, and composition attribute reading are fully implemented via IMM32. Advanced Cocoa-specific features (document-aware IME, multistage undo integration) are platform-specific and not required for core Japanese/CJK input. |
| Mouse click/drag | `mouseDown:`, `mouseDragged:`, `mouseUp:` and right/other variants | `WM_LBUTTONDOWN`, `WM_LBUTTONUP`, `WM_MBUTTONDOWN`, `WM_MBUTTONUP`, `WM_RBUTTONDOWN`, `WM_RBUTTONUP`, `WM_XBUTTONDOWN`, `WM_XBUTTONUP`, `WM_MOUSEMOVE`, `WM_MOUSEWHEEL` | Done | `lib/echoes/gui_win32.rb` | Left/middle/right/X-button press, drag, release, and wheel are routed to terminal mouse reporting. |
| Mouse wheel | `scrollWheel:`, `deltaY` | `WM_MOUSEWHEEL` | Done | `lib/echoes/gui_win32.rb` | Scroll accumulation and pane scrolling are implemented. |
| Pointer cursor shape/visibility | `NSCursor.IBeamCursor`, `hide`, `unhide`, cursor rects | `LoadCursorW`, `SetCursor`, `ShowCursor`, `WM_SETCURSOR`, `GetCursorPos`, `ScreenToClient` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Terminal client area uses the I-beam cursor while non-client areas keep the default cursor. Hide/unhide is available from the View menu and Ctrl+Shift+P, with shake-to-show support. Per-cell cursor rects are implemented - cursor changes to hand over hyperlinks and crosshair in copy mode. |
| Text fill drawing | `NSColor#setFill`, `NSRectFill` | GDI `CreateSolidBrush`, `FillRect` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Used for background, selection, decorations, cursor, and pane borders. |
| Text drawing | `NSString#drawAtPoint:withAttributes:` | GDI `TextOutW`, `ExtTextOutW` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Regular terminal text and multicell text are drawn with GDI. |
| Font creation | `NSFont fontWithName:size:`, `monospacedSystemFontOfSize:weight:` | `CreateFontW` | Done | `lib/echoes/gui_win32.rb` | Regular, bold, italic, bold-italic fonts are created. |
| Font metrics | `NSFont#ascender`, `descender`, `defaultLineHeightForFont`, `NSString#sizeWithAttributes:` | `GetTextMetricsW`, `GetTextExtentPoint32W` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Cell size and text extent are measured with GDI. |
| Font fallback | `CTFontCreateForString` | `GetGlyphIndicesW` plus cached fallback families | Done | `lib/echoes/gui_win32/rendering_primitives.rb`, `lib/echoes/gui_win32/core.rb` | Per-glyph availability checks with `GetGlyphIndicesW`, cached fallback font handles for Japanese (Yu Gothic UI, Meiryo, MS Gothic) and emoji/symbol (Segoe UI Emoji, Segoe UI Symbol) families. Font runs split text by glyph availability. GDI limitations remain for color emoji rendering and complex script shaping (Arabic, Indic), but the basic fallback mechanism is comprehensive. |
| Underline/strikethrough | AppKit text attributes | Explicit GDI rectangle decorations | Done | `lib/echoes/gui_win32.rb` | Decorations are drawn manually. |
| Ligature suppression | `NSLigatureAttributeName` | GDI text rendering (no ligature attribute) | Not applicable | - | GDI `TextOutW` / `ExtTextOutW` do not expose a ligature attribute equivalent to Cocoa's `NSLigatureAttributeName`. Windows 10 GDI rendering may apply ligatures depending on the font and GDI rendering phase, but this is a font-engine detail rather than a controllable text attribute. Using non-ligature-heavy terminal fonts (Consolas, Cascadia Code) avoids visual issues in practice. |
| Gradients | `NSGradient#drawInRect:angle:` | GDI+ `LinearGradientBrush` | Done | `lib/echoes/gui_win32.rb` | Windows paints OSC flat pane backgrounds, bg-fill overlays, alpha-blended colors, and multi-stop linear gradients using GDI+ `LinearGradientBrush`. |
| CoreGraphics image drawing | `CGContextDrawImage`, `CGImage` | GDI `StretchDIBits` with BGRA DIB | Done | `lib/echoes/gui_win32.rb` | Kitty/iTerm image placements are drawn from RGBA buffers. |
| PNG decode | `NSData`, `NSBitmapImageRep`, `CGImage` | GDI+ `GdipCreateBitmapFromStream` path | Done | `lib/echoes/kitty_graphics_win32.rb` | PNG decode returns the same RGBA shape expected by renderers. |
| Raw RGB/RGBA conversion | `CGDataProviderCreateWithData`, `CGImageCreate` | Ruby buffer conversion / GDI+ path | Done | `lib/echoes/kitty_graphics_win32.rb` | `from_rgb` and `from_rgba` exist. |
| Clipboard text | `NSPasteboard` with `NSPasteboardTypeString` | Win32 clipboard `CF_UNICODETEXT` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Copy/paste and OSC 52 use the Win32 helper. |
| File URL drag/drop | `NSPasteboardTypeFileURL`, `readObjectsForClasses:options:` | `WM_DROPFILES`, `DragQueryFileW` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Dropped file paths are shell-quoted and pasted into the active pane, including bracketed paste mode. |
| Open file dialog | `NSOpenPanel` | `GetOpenFileNameW` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Windows can prompt for a single editor file, starting from the active pane's OSC 7 working directory when available. |
| URL open | `NSWorkspace.openURL:` | `ShellExecuteW` / Ctrl-click URL detection | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Windows Ctrl-click opens OSC 8 hyperlinks or detected `http(s)` URLs through `ShellExecuteW`. |
| About panel | `orderFrontStandardAboutPanelWithOptions:` | `MessageBoxW` custom dialog | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | Windows shows About content through a native message box from the Help menu. |
| Notifications | `terminal-notifier` fallback on macOS | Win32 balloon notifications with title fallback | Partial | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | OSC 9 / OSC 777 trigger Shell_NotifyIconW balloon notifications with application icon. Falls back to window title on failure. Not modern Windows 10/11 toast notifications, but native balloon-style notifications that work on all Windows versions. |
| Screen enumeration | `NSScreen.screens`, `frame`, `visibleFrame`, `backingScaleFactor` | `EnumDisplayMonitors`, `GetMonitorInfoW`, `MonitorFromWindow`, `GetDpiForMonitor` | Done | `lib/echoes/win32.rb`, `lib/echoes/gui_win32.rb` | OSC display-info returns monitor and work-area geometry, primary/current flags, DPI, and a backing scale factor derived from effective monitor DPI. |
| External/presentation windows | New `NSWindow` on selected `NSScreen` | Child Echoes process with monitor geometry env | Done | `lib/echoes/gui_win32/rendering_panes.rb` | OSC 7772 open-window fully implemented: Base64-decoded argv parsing, display-index selection with fallback to primary monitor, fullscreen/work-area geometry calculation, environment variable setup for child process (ECHOES_OPEN_WINDOW_PROGRAM, ECHOES_ROWS/COLS, ECHOES_WINDOW_X/Y, ECHOES_WINDOW_WIDTH/HEIGHT), and Process.spawn invocation. Process-based model differs from AppKit's in-process windows but provides full external window functionality. |
| Pane capture to PDF/PNG | `dataWithPDFInsideRect:`, `NSBitmapImageRep` capture | GDI bitmap capture / pure-Ruby PNG and raster PDF encoders | Done | `lib/echoes/gui_win32/rendering_capture_and_tab.rb`, `lib/echoes/win32.rb` | Full pane capture implementation supporting both PNG and raster PDF formats. GDI bitmap capture with RGBA→BGRA conversion, pane rect calculation, active/inactive state handling, pure-Ruby PNG encoder (chunked IDAT), and single-page raster PDF encoder (CCITT G4 or DCT-based compression). AppKit-style vector PDF is not supported (GDI limitation), but raster capture is complete and functional. |
| Preferences storage | `NSUserDefaults` suite | JSON file under `%APPDATA%/Echoes` or `ECHOES_CONFIG_HOME` | Alternate | `lib/echoes/preferences.rb` | Feature exists through a platform-specific backend, not the Windows registry. |
| Shell process backend | macOS PTY backend | ConPTY backend | Done | `lib/echoes/conpty.rb`, `lib/echoes/shell_backend.rb`, `lib/echoes/pane.rb` | Normal panes use ConPTY on Windows. Child shells are launched in a new process group and Ctrl-C first sends `GenerateConsoleCtrlEvent`, then falls back to ETX input if needed. |
| Shell resize | PTY window size/ioctl | `ResizePseudoConsole` | Done | `lib/echoes/conpty.rb`, `lib/echoes/gui_win32.rb` | Resize propagation is implemented. |
| Shell encoding | UTF-8 PTY stream | Console code page conversion | Done | `lib/echoes/shell_backend.rb` | ConPTY output is decoded from locale encoding; input is encoded back. |
| Embedded rubish mode | Unix PTY/process group/job control | Windows process/helper model needed | Missing | `lib/echoes/embedded_shell.rb` | Explicitly blocked on Windows. |
| Installer | `.app` wrapper copy | `echoes.bat` wrapper | Alternate | `lib/echoes/installer.rb` | Windows launcher exists, but there is no native executable/MSI/app bundle equivalent. |

## Summary

Windows provides comprehensive terminal functionality with near-complete AppKit parity:

**Fully Implemented Core Features:**
- Win32 window creation and message loop with complete lifecycle management
- Native Win32 timer-driven polling and repaint invalidation
- Window frame autosave through JSON preferences
- ConPTY-backed shell process I/O and resize with proper code page handling
- GDI text rendering with comprehensive font fallback (Japanese, emoji, symbol fonts)
- Full IME composition support (inline editing, candidate positioning, reading strings)
- GDI+ PNG decode, raw RGB/RGBA conversion, and linear gradient rendering
- Keyboard input, special keys, mouse wheel, mouse selection, clipboard text, OSC 52
- Win32 balloon notifications with fallback to window title
- OSC display-info and process-based OSC open-window launch on selected monitors
- Monitor DPI/backing scale reporting for OSC display-info
- Cross-process Window menu integration with shared memory registry (up to 32 windows)
- Full app menu with accelerators, profiles, search, copy mode, pointer hiding, font scaling, and tab management
- Native interactive tab bar using GDI
- Native completion popup with TrackPopupMenu (ready for embedded mode)
- OSC capture to PNG and raster PDF formats

**Remaining Platform Differences:**
- Embedded rubish mode requires Windows-specific process model implementation
- Vector PDF capture is limited by GDI (raster PDF works, vector PDF requires different approach)
- Modern Windows 10/11 toast notifications vs. current balloon-style notifications
- In-process multiple native windows vs. current process-based multi-window model

The implementation is production-ready for terminal use, with all core functionality complete. The remaining gaps are platform-specific architectural differences rather than missing features.

## Maintenance Notes

- When adding a Windows counterpart for a macOS API listed in `docs/macos-fiddle-api-inventory.md`, update this table in the same change.
- Mark features as `Alternate` only when Echoes intentionally provides the same user-facing capability through a different Windows model.
- Mark features as `Partial` when the implementation exists but user-visible behavior can differ from macOS.
- Keep implementation evidence in the `Source` column specific enough to let a maintainer jump to the owning file quickly.
