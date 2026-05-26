# macOS Fiddle API Inventory

This document inventories the places where Echoes calls macOS native APIs through Ruby Fiddle. It is intended as a maintenance map for porting, test isolation, and future backend cleanup.

Inventory date: 2026-05-26.

## Scope

Included:

- Direct `Fiddle.dlopen` / `Fiddle::Function.new` bindings for macOS libraries.
- Objective-C runtime dispatch through `Echoes::ObjC`.
- AppKit, Foundation, CoreGraphics, and CoreText classes/functions reached through those bindings.

Not included:

- Windows Fiddle bindings in `lib/echoes/win32.rb`, `lib/echoes/conpty.rb`, `lib/echoes/gui_win32.rb`, and `lib/echoes/kitty_graphics_win32.rb`.
- Plain Ruby Unix APIs such as `PTY`, `fork`, `ioctl`, or filesystem calls.

## Entry Points

| File | Role |
| --- | --- |
| `lib/echoes/objc.rb` | Central macOS binding layer. Loads Objective-C runtime, AppKit, Foundation, CoreGraphics, and CoreText. Defines `objc_msgSend` signatures, Objective-C helpers, constants, and C function bindings. |
| `lib/echoes/gui.rb` | Main AppKit terminal GUI. Most Objective-C calls happen here through `ObjC::MSG_*` helpers. |
| `lib/echoes/kitty_graphics_appkit.rb` | AppKit/CoreGraphics image decoder for kitty graphics and iTerm2 image paths on macOS. |
| `lib/echoes/preferences.rb` | macOS preferences backend using `NSUserDefaults`. |

## Native Libraries

| Library | Loaded in | Purpose |
| --- | --- | --- |
| `/usr/lib/libobjc.A.dylib` | `lib/echoes/objc.rb` | Objective-C runtime: class lookup, selector registration, class creation, protocol registration, and `objc_msgSend`. |
| `/System/Library/Frameworks/AppKit.framework/AppKit` | `lib/echoes/objc.rb` | AppKit classes, constants, and `NSRectFill`. |
| `/System/Library/Frameworks/Foundation.framework/Foundation` | `lib/echoes/objc.rb` | Foundation classes reached through Objective-C runtime. The handle is loaded for framework availability, while calls use `objc_msgSend`. |
| `/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics` | `lib/echoes/objc.rb`, `lib/echoes/kitty_graphics_appkit.rb` | Bitmap contexts, image creation, image drawing, graphics state transforms, and image/provider release. |
| `/System/Library/Frameworks/CoreText.framework/CoreText` | `lib/echoes/objc.rb` | Font fallback through `CTFontCreateForString`. |

## Objective-C Runtime Binding

Defined in `lib/echoes/objc.rb`.

| Binding | Native symbol | Used for |
| --- | --- | --- |
| `GetClass` | `objc_getClass` | Resolve Objective-C classes such as `NSApplication`, `NSWindow`, `NSView`, `NSFont`, `NSPasteboard`, and `NSUserDefaults`. |
| `RegisterName` | `sel_registerName` | Resolve selectors used by `objc_msgSend`. |
| `AllocateClassPair` | `objc_allocateClassPair` | Create the custom `EchoesTerminalView` subclass of `NSView`. |
| `AddMethod` | `class_addMethod` | Add Ruby Fiddle closure-backed Objective-C methods to `EchoesTerminalView`. |
| `RegisterClassPair` | `objc_registerClassPair` | Register `EchoesTerminalView` with the Objective-C runtime. |
| `GetMethodImpl` | `class_getMethodImplementation` | Fetch `NSView#setFrameSize:` so the override can call the superclass implementation. |
| `AddProtocol` | `class_addProtocol` | Declare `NSTextInputClient` support for IME. |
| `GetProtocol` | `objc_getProtocol` | Resolve `NSTextInputClient`. |
| `objc_msgSend` wrappers | `objc_msgSend` | All Objective-C message sends. Echoes defines wrapper variants for pointer, integer, double, rect, point, and mixed signatures. |

The `ObjC` helper also exposes:

- `cls`, `sel`, `retain`, `release`
- `nsstring`, `to_ruby_string`, `nsdict`, `nsnumber_int`
- AppKit constants such as `NSFontAttributeName`, `NSForegroundColorAttributeName`, `NSPasteboardTypeString`, and `NSPasteboardTypeFileURL`
- modifier flag constants mirrored by OS-independent configuration code

## AppKit GUI Usage

Implemented primarily in `lib/echoes/gui.rb`.

### Application, Window, View, and Run Loop

| API family | Native classes/selectors | Purpose |
| --- | --- | --- |
| Application lifecycle | `NSApplication.sharedApplication`, `setActivationPolicy:`, `run`, `terminate:`, `activateIgnoringOtherApps:` | Create and run the GUI application. |
| Window creation | `NSWindow alloc`, `initWithContentRect:styleMask:backing:defer:`, `setTitle:`, `setCollectionBehavior:`, `setAcceptsMouseMovedEvents:`, `setLevel:`, `center`, `orderOut:` | Create main and external windows, including borderless/fullscreen OSC-opened windows. |
| Window/view wiring | `setContentView:`, `makeKeyAndOrderFront:`, `makeFirstResponder:`, `setFrameAutosaveName:` | Attach terminal views to windows and restore/save frame state. |
| View creation | Custom `EchoesTerminalView < NSView` | Receives drawing, keyboard, mouse, drag/drop, focus, resize, menu action, and IME callbacks. |
| Timer | `NSTimer scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:`, `invalidate` | 60 Hz polling/repaint loop via `timerFired:`. |
| Notifications | `NSNotificationCenter.defaultCenter`, `addObserver:selector:name:object:` | Track `NSWindowDidBecomeKeyNotification` and `NSWindowDidResignKeyNotification`. |
| Autorelease | `NSAutoreleasePool alloc/init/drain` | Wrap drawing to keep temporary Cocoa objects bounded. |

### Custom Objective-C View Methods

`GUI#create_view_class` installs Fiddle closures as Objective-C methods on `EchoesTerminalView`.

| Method group | Selectors |
| --- | --- |
| Drawing and layout | `drawRect:`, `isFlipped`, `resetCursorRects`, `setFrameSize:` |
| Keyboard and menu dispatch | `keyDown:`, `performKeyEquivalent:`, menu actions such as `newWindow:`, `newTab:`, `closeTab:`, `showAbout:`, profile selectors, copy/search/pane actions |
| Mouse and scroll | `scrollWheel:`, `mouseDown:`, `mouseDragged:`, `mouseMoved:`, `mouseUp:`, `rightMouseDown:`, `rightMouseDragged:`, `rightMouseUp:`, `otherMouseDown:`, `otherMouseDragged:`, `otherMouseUp:` |
| Focus | `windowDidBecomeKey:`, `windowDidResignKey:` |
| IME / text input | `insertText:replacementRange:`, `insertText:`, `doCommandBySelector:`, `setMarkedText:selectedRange:replacementRange:`, `unmarkText`, `hasMarkedText`, `markedRange`, `selectedRange`, `validAttributesForMarkedText`, `attributedSubstringForProposedRange:actualRange:`, `firstRectForCharacterRange:actualRange:`, `characterIndexForPoint:` |
| Drag and drop | `draggingEntered:`, `performDragOperation:` |
| Completion popup | `completionPicked:` |

### Menus and Commands

| Native classes/selectors | Purpose |
| --- | --- |
| `NSMenu alloc/initWithTitle:` | Build the application menu bar, window menu, view menu, profile submenu, and completion popup. |
| `NSMenuItem alloc/initWithTitle:action:keyEquivalent:` | Create menu commands and bind them to selectors on `EchoesTerminalView`. |
| `setKeyEquivalentModifierMask:`, `setSubmenu:`, `separatorItem`, `addItem:` | Configure shortcuts, submenu hierarchy, and separators. |
| `NSApplication#setMainMenu:` | Install the app menu bar. |
| `NSApplication#setWindowsMenu:` | Let AppKit populate the Window menu with open windows. |
| `popUpMenuPositioningItem:atLocation:inView:` | Show tab completion candidates at the terminal cursor. |

### Drawing, Text, Fonts, and Colors

| API family | Native classes/functions | Purpose |
| --- | --- | --- |
| Fill drawing | `NSColor#setFill`, `NSRectFill` | Draw backgrounds, selections, cursors, pane borders, tab bar, search highlights, and pane fills. |
| Text drawing | `NSString#drawAtPoint:withAttributes:`, `NSAttributedString` | Draw terminal cells, tab labels, status/search text, IME marked text, and about panel credits. |
| Text attributes | `NSFontAttributeName`, `NSForegroundColorAttributeName`, `NSUnderlineStyleAttributeName`, `NSStrikethroughStyleAttributeName`, `NSLigatureAttributeName` | Pass font, color, underline, strike, and ligature settings into AppKit text drawing. |
| Fonts | `NSFont fontWithName:size:`, `monospacedSystemFontOfSize:weight:`, `familyName`, `maximumAdvancement`, `ascender`, `descender`, `leading`, `defaultLineHeightForFont` | Create configured fonts and compute terminal cell metrics. |
| Font traits | `NSFontManager.sharedFontManager`, `convertFont:toHaveTrait:` | Generate bold and italic font variants. |
| Font fallback | `CTFontCreateForString` | Find a fallback font for glyphs missing from the configured terminal font. |
| Text measurement | `NSString#sizeWithAttributes:` | Measure glyphs and strings for terminal layout and multicell text. |
| Colors | `NSColor colorWithRed:green:blue:alpha:`, `colorWithAlphaComponent:` | Create and cache color objects. |
| Gradients | `NSGradient initWithStartingColor:endingColor:`, `drawInRect:angle:` | Draw configured pane gradient backgrounds. |
| Graphics context | `NSGraphicsContext.currentContext`, `CGContext` | Access the current CoreGraphics context for scaled text and images. |

### CoreGraphics Rendering

Bindings are defined in `lib/echoes/objc.rb` and used from `lib/echoes/gui.rb`.

| Binding | Native symbol | Purpose |
| --- | --- | --- |
| `CGColorSpaceCreateDeviceRGB` / `CGColorSpaceRelease` | CoreGraphics | Create/release RGB color spaces for bitmap contexts. |
| `CGBitmapContextCreate` | CoreGraphics | Wrap RGBA buffers before creating or drawing `CGImage` values. |
| `CGBitmapContextCreateImage` | CoreGraphics | Convert an RGBA bitmap context into a cached `CGImage`. |
| `CGContextDrawImage` | CoreGraphics | Draw kitty graphics and sixel images into the view. |
| `CGContextSaveGState` / `CGContextRestoreGState` | CoreGraphics | Scope transforms during image and scaled text drawing. |
| `CGContextTranslateCTM` / `CGContextScaleCTM` | CoreGraphics | Flip image coordinates and horizontally scale multicell text. |
| `CGImageRelease` / `CGContextRelease` | CoreGraphics | Release CoreGraphics objects created by Echoes. |

### Clipboard, Pasteboard, Drag and Drop

| Native classes/selectors | Purpose |
| --- | --- |
| `NSPasteboard.generalPasteboard`, `clearContents`, `setString:forType:`, `stringForType:` | Copy/paste text and implement OSC 52 clipboard handling. |
| `NSPasteboardTypeString` | String pasteboard type. |
| `NSPasteboardTypeFileURL` | File URL drag type registered on terminal views. |
| `registerForDraggedTypes:` | Enable file drag/drop on `EchoesTerminalView`. |
| `draggingPasteboard`, `readObjectsForClasses:options:` | Read dropped file URLs. |
| `NSURL#path`, `NSURL.fileURLWithPath:`, `NSURL.URLWithString:` | Convert between Cocoa URLs and Ruby strings. |

### Input, Events, Cursor, and IME

| Native classes/selectors | Purpose |
| --- | --- |
| `NSEvent#characters`, `charactersIgnoringModifiers`, `keyCode`, `modifierFlags`, `deltaY`, `clickCount` | Keyboard, search, copy mode, mouse, and scroll handling. |
| `interpretKeyEvents:` | Route text input through Cocoa's text input system so IME can call `NSTextInputClient` methods. |
| `NSCursor.IBeamCursor`, `addCursorRect:cursor:`, `NSCursor.hide`, `NSCursor.unhide` | Terminal pointer shape and pointer visibility. |
| `NSInvocation invocationWithMethodSignature:`, `setSelector:`, `invokeWithTarget:`, `getReturnValue:` | Work around Fiddle limitations for struct returns such as `NSView#frame`, `NSEvent#locationInWindow`, and `NSScreen#frame` / `visibleFrame`. |
| `NSTextInputClient` protocol | Enables composition text, marked ranges, selected ranges, candidate positioning, and IME insert/unmark callbacks. |

### Screens, External Windows, and Capture

| Native classes/selectors | Purpose |
| --- | --- |
| `NSScreen.screens`, `NSScreen.mainScreen`, `objectAtIndex:`, `count` | Report display info and choose a target screen for OSC external window requests. |
| `NSWindow#screen` | Find the screen associated with a pane/window. |
| `frame`, `visibleFrame`, `backingScaleFactor` | Compute display geometry and pixel dimensions. Struct returns are read through `NSInvocation`. |
| `NSView#dataWithPDFInsideRect:` | Capture a pane/view rectangle as PDF bytes. |
| `NSView#bitmapImageRepForCachingDisplayInRect:`, `cacheDisplayInRect:toBitmapImageRep:` | Render a view rectangle into an `NSBitmapImageRep`. |
| `NSBitmapImageRep#representationUsingType:properties:` | Encode capture output as PNG. |

### Dialogs, Workspace, and Notifications

| Native/API path | Purpose |
| --- | --- |
| `NSOpenPanel.openPanel`, `setCanChooseFiles:`, `setCanChooseDirectories:`, `setAllowsMultipleSelection:`, `setDirectoryURL:`, `runModal`, `URL` | Prompt for a file to edit. |
| `NSApplication#orderFrontStandardAboutPanelWithOptions:` | Show the AppKit About panel with custom credits. |
| `NSWorkspace.sharedWorkspace`, `openURL:` | Open hyperlinks in the default browser/application. |
| `terminal-notifier` subprocess fallback in `GUI#post_notification` | User notifications currently avoid `NSUserNotification` because bundled/ruby-launch contexts are unreliable. This is not a direct Fiddle API call, but it is part of the macOS notification path. |

## AppKit/CoreGraphics Image Decoder

Implemented in `lib/echoes/kitty_graphics_appkit.rb`.

| API family | Native symbols/classes | Purpose |
| --- | --- | --- |
| PNG input | `NSData dataWithBytes:length:` | Wrap raw PNG bytes as Cocoa data. |
| PNG decode | `NSBitmapImageRep imageRepWithData:`, `pixelsWide`, `pixelsHigh`, `CGImage` | Decode PNG data and expose a `CGImage`. |
| CoreGraphics bitmap output | `CGColorSpaceCreateDeviceRGB`, `CGBitmapContextCreate`, `CGContextDrawImage`, `CGContextRelease`, `CGColorSpaceRelease` | Draw decoded PNG data into a controlled RGBA8 buffer. |
| Raw RGB/RGBA conversion | `CGDataProviderCreateWithData`, `CGImageCreate`, `CGContextDrawImage`, `CGImageRelease`, `CGDataProviderRelease` | Wrap raw pixel bytes in a `CGImage`, then convert to Echoes' RGBA8 image shape. |

This file intentionally isolates the AppKit/CoreGraphics decoder so non-GUI or non-macOS paths can avoid loading it.

## Preferences

Implemented in `lib/echoes/preferences.rb`.

| Native class/selectors | Purpose |
| --- | --- |
| `NSUserDefaults alloc/initWithSuiteName:` | Use the `jp.dio.echoes` suite stored under `~/Library/Preferences`. |
| `objectForKey:` | Distinguish missing values from stored `0.0`. |
| `doubleValue` | Convert stored numeric preference objects to Ruby floats. |
| `setDouble:forKey:` | Persist floating-point preferences, currently window geometry. |
| `removeObjectForKey:` | Delete persisted preference values. |

`Preferences` only loads `objc.rb` when `Platform.macos?` is true. Other platforms use the JSON backend.

## Load Boundaries

- `lib/echoes.rb` conditionally loads GUI/native files by platform; this keeps `require "echoes"` from loading AppKit/CoreGraphics on Windows.
- `lib/echoes/preferences.rb` conditionally requires `objc.rb` only for macOS.
- `lib/echoes/kitty_graphics_appkit.rb` requires `objc.rb` and loads CoreGraphics directly, so callers must keep it macOS-only.
- `lib/echoes/gui.rb` is an AppKit backend and assumes `Echoes::ObjC` is available.

## Maintenance Notes

- Any new AppKit/Foundation/CoreGraphics/CoreText call should be routed through `ObjC` or a small backend-local binding, then added to this inventory.
- Prefer keeping direct `Fiddle.dlopen` calls centralized in `objc.rb` unless a file is intentionally isolated to avoid loading a framework in headless tests.
- Struct-return Objective-C methods are fragile through Fiddle. Existing code uses `NSInvocation` for `NSPoint`/`NSRect` returns; follow that pattern when adding similar calls.
- `objc_msgSend` signatures must exactly match the native ABI. Add a named `MSG_*` wrapper in `ObjC` instead of reusing a near match.
- Retain/release ownership should be explicit for CoreGraphics objects created by Echoes. AppKit autoreleased objects are generally handled through Cocoa autorelease pools around drawing.
