# Cross-Platform GUI Refactor — Design

**Date:** 2026-06-03
**Status:** Approved (design direction)
**Scope:** Design direction only — target class structure + phased migration plan. No implementation in this document.

## Problem

Echoes began as a macOS-only terminal. The `feature/windows` branch added Windows
support. Both grew ad-hoc, so platform-agnostic logic is duplicated and has already
**drifted** between the two implementations.

The core structural problem: **both `gui.rb` (macOS) and `gui_win32/core.rb` (Windows)
define the same `Echoes::GUI` class.** They are two complete, parallel implementations
selected at load time by `Echoes.load_gui_backend`. There is no shared code between
them — only a shared class name.

### Evidence of drift (measured, not assumed)

Comparing the search methods that exist in *both* implementations:

- `build_search_matcher` — **byte-identical** except `def` vs `private def`. Pure copy-paste.
- `scan_row_for_matches` — **macOS has a guard against zero-width regex (`\b`, `^`, `$`,
  lookahead) infinite loops; Windows does not.** Windows carries a latent hang bug.
  The two also handle `nil` cells differently.
- `search_next` / `search_prev` — Windows returns a boolean, macOS returns `nil`. API drift.
- `current_search_match_at?` — same logic, divergent variable names.

This is the justification for the refactor: the duplication is real, it has drifted, and
one platform already lacks a bug fix the other has. Unifying into a shared controller
propagates the fix for free.

### What is already well-factored (the model to follow)

`shell_backend.rb` already abstracts the PTY/shell layer cleanly with a `for_platform`
factory plus inheritance:

```
ShellBackend.for_platform →
  UnixPtyBackend ──→ MacPtyBackend (inherits)
  WindowsPopenBackend
  WindowsConPTYBackend
```

`platform.rb` already provides `windows?` / `macos?` / `unix?` detection. This refactor
extends the same patterns to the GUI layer.

## Hard Constraint: Windows-only verification

The developer can only runtime-verify on **Windows**. The macOS path (`gui.rb`,
`kitty_graphics_appkit.rb`, `objc.rb`) **cannot be executed or visually checked.**

This constraint drives every decision below. The governing rule for macOS:

> **For macOS code: move, never rewrite.** New logic goes only into shared,
> Windows-testable controllers. macOS-specific native code is relocated mechanically
> behind a thin seam, never re-authored.

## Chosen Approach: Hybrid, phased (Approach C)

Rejected alternatives:
- **A. Conservative seam only** — leaves the rendering-loop duplication in place.
- **B. Full Template Method (inheritance-heavy)** — would move the *untestable* macOS
  draw loop into a shared base class. The recent master pixel-snapping commits show this
  loop has subtle, silently-regressable behavior. Too risky under Windows-only verification.

**C** extracts the safe, high-value duplication first (logic), pushes platform code
behind a delegation seam via mechanical moves, and **defers the risky macOS draw-loop
unification into an independent, freezable phase.**

Axis of the design:
- **Delegation** for the platform seam (`GUI` → `Backend`) and for extracted controllers
  (`GUI` → `SearchController`/`Layout`/`Selection`/…).
- **Inheritance** only *within* a platform backend family (`Backend::Mac/Win32/Linux <
  Backend`; future Mac/Linux Unix sharing) and for the Phase 3 `Renderer::Base` draw template.

## Target Class Structure

```
Echoes
├─ GUI                         Single, platform-agnostic orchestrator.
│                              Owns tabs/panes, wires events→actions,
│                              composes one Backend + the controllers.
│                              (Resolves the "two classes, one name" problem.)
│
├─ Platform                    Existing. windows?/macos?/unix? + new gui_backend factory.
│
├─ controllers  (delegated; pure logic; unit-testable on Windows + CI)
│   ├─ GUI::Layout             tab_bar_height / grid_offset / resize→rows,cols / pane_rect
│   ├─ GUI::SearchController    perform / matcher / scan / next,prev / scroll_to_match / *_match_at?
│   ├─ GUI::Selection           selection_range / word-drag extend / grid_position / cell_selected?
│   ├─ GUI::KeyBindings         semantic key+menu → action-symbol mapping table
│   ├─ CopyMode                 existing copy_mode.rb, merged with both GUIs' copy-mode keys
│   └─ Osc7 (or Pane#cwd)       pane_local_cwd / cwd_from_osc7_uri
│
└─ backends  (delegated; native; factory-selected)
    ├─ GUI::Backend                   Abstract interface (documented roles + defaults).
    ├─ GUI::Backend::Mac   < Backend  Wraps current gui.rb / kitty_graphics_appkit / objc.
    ├─ GUI::Backend::Win32 < Backend  Wraps current gui_win32/* / kitty_graphics_win32 / win32.
    └─ GUI::Backend::Linux < Backend  Future. Shares Unix bits with Mac via base/module.
```

- `GUI` is **single** and is **not** subclassed per platform. Platform variation lives in
  the `Backend` hierarchy.
- `load_gui_backend` changes from selecting a `GUI` class to selecting a `Backend` impl.

## Platform Backend Seam

Modeled on `shell_backend.rb`'s `for_platform`. `GUI` performs every native operation
through this interface (delegation). The backend is **not monolithic** — it supplies
cohesive role collaborators:

```
GUI::Backend (abstract)
├─ #renderer    → Renderer     drawing primitives
├─ #window      → WindowSystem window create / run-loop / timer / DPI / title / resize notify
├─ #input       → InputSource  native event → normalized key descriptor (see below)
├─ #clipboard   → Clipboard    copy / paste
├─ #menu        → MenuBar      menu build / accelerators
├─ #notifier    → Notifier     native notifications (OSC 9 etc.)
├─ #graphics    → Graphics     kitty / sixel / image decode + blit (wrapped, not unified)
└─ #dialogs     → Dialogs      file picker / about / open-window
```

Example minimal `Renderer` interface:

```
Renderer:
  begin_frame(dirty_min_y, dirty_max_y)
  fill_cell_bg(col, row, rgba)            # pixel-snapping unified in base in Phase 3
  draw_text_run(col, row, text, font, fg, attrs)
  draw_cursor(rect, style)
  blit_image(placement, rect)
  draw_divider(rect) / draw_active_border(rect) / draw_tab_bar(...)
  present
  cell_width / cell_height / measure_glyph   # font metrics
```

**Pragmatic rule:** roles are an *interface contract*, not a mandate to split classes
immediately. Initially `Backend::Mac` / `Backend::Win32` implement the role methods
directly (the macOS impl already co-locates everything on one NSView). Extract to
separate role classes only when a backend grows unwieldy (YAGNI).

`for_platform` is implemented as `Platform.gui_backend(os)`, with `os` injectable so the
factory branch is unit-testable (same technique as `shell_backend.rb`).

## Input Handling: action-dispatch unification only

Decision: **unify only the action dispatch, not full event normalization.** macOS
`key_down` / `mouse_*` are untestable, so we do not rewrite the native input path.

Flow:

```
native layer (per backend) → extract normalized key descriptor (keysym + modifiers)
                           → KeyBindings.action_for(key, mods, context)  [shared]
                           → GUI executes the returned action symbol
                              (action_new_tab / action_copy / action_search_next …)
```

- Each backend keeps its own native event reading (NSEvent / Win32 MSG).
- The **key→action decision table** (`KeyBindings`) and the **action implementations**
  (on `GUI`) are shared and Windows-testable.
- Mouse coordinate math, IME, and scroll raw handling **stay in each backend for now**
  (macOS input path preserved). No full `SemanticEvent` normalization.

This is the low/medium-risk middle ground: unify "which action a key triggers" and "what
the action does" without touching the macOS native event body.

## Extracted Controllers (Phase 1 targets)

All operate on the existing `Screen` / `Pane` / `Tab` model, call no native API, and are
therefore unit-testable on Windows + CI — which also makes their extraction safe for
macOS (identical logic, relocated).

| Controller | Merged from (both GUIs) | Win from unifying |
|---|---|---|
| `GUI::SearchController` | perform_search / build_search_matcher / scan_row_for_matches / search_next / search_prev / scroll_to_match / *_match_at? | **Propagates the macOS zero-width-regex guard to Windows**; unifies return-value API |
| `GUI::Layout` | tab_bar_height / grid_y_offset / tab_bar_y / handle_resize rows,cols math / pane_rect | One reflow calculation; prevents the class of bug master's tab-bar-reflow fix addressed |
| `GUI::Selection` | selection_range / extend_word_drag_selection / grid_position / cell_selected? | Unified selection + text extraction |
| `GUI::KeyBindings` | key_down / perform_key_equivalent branches + win32 windows_key_sequence / menu dispatch | Single key+menu → action-symbol map (core of action-dispatch unification) |
| `Osc7` (or `Pane#cwd`) | pane_local_cwd / cwd_from_osc7_uri (the `self.` methods) | Collapses fully-identical duplication |
| `CopyMode` | existing copy_mode.rb + both GUIs' copy-mode key handling | Unified copy-mode operations |

Shape:
- Stateless calculations → `module_function`. Stateful ones (search results, selection
  anchor) → a single instance held by `GUI` and delegated to.
- Controllers take their inputs as arguments and return results; they do **not** reach
  into `GUI` internals (testability).

Extraction method per controller: **write a characterization test first** (run on
Windows) to pin current behavior, then mechanically move the logic and keep green. Where
the two platforms had drifted, **converge on the macOS version (the more correct one) by
default**, recording each such change as an intentional fix.

## Phased Migration Plan

Each phase is independently mergeable and stays green.

### Phase 0 — Integrate master (groundwork)
master has 5 commits not yet in `feature/windows` (cell-bg pixel snapping, tab-bar
reflow, v0.3.0, README, porting docs). `gui.rb` is the conflict source. Merge master into
`feature/windows` **before** refactoring, so "converge on macOS version" uses the latest
baseline.

### Phase 1 — Extract pure controllers (safe; the main event)
Per controller: (1) characterization test first, (2) mechanically move logic to a shared
class, both GUIs delegate, (3) converge drift onto macOS version, pin with tests.
macOS risk ≈ none (identical-logic relocation). Most duplication dies here.

### Phase 2 — Introduce the backend seam (delegation)
Merge `GUI` into a single orchestrator; add `Platform.gui_backend` factory +
`Backend::Mac` / `Backend::Win32`. **Existing native code is moved mechanically only**
(no logic change). Change `load_gui_backend` to select a backend. macOS = "code moves,
behavior unchanged." Medium risk (seam wiring).

### Phase 3 — Unify draw template (optional; freezable)
Only the parts where both draw loops already agree become a `Renderer::Base` Template
Method. Because this touches the macOS draw loop, it is a **separate phase that can be
frozen until a macOS test machine is available.**

### Phase 4 — Linux backend (future)
Add `Backend::Linux < Backend` against the same interface; reuse Phase 1 controllers for
free. Share Unix bits with Mac (PTY already handled in `shell_backend.rb`).

## Verification Strategy (Windows-only)

| Target | Method |
|---|---|
| Pure controllers (Phase 1) | test-unit unit tests (run both OSes in CI) |
| Windows GUI | existing win32 GUI smoke rake task + manual on real hardware |
| macOS GUI | **No runtime check possible** → (1) characterization tests pin behavior, (2) changes limited to mechanical moves, (3) `git diff` review confirms "logic unchanged", (4) no behavior change at phase boundaries |
| Factory branching | inject `os` and unit-test (shell_backend technique) |

**macOS safety core:** for macOS, "don't write new code, only relocate existing code"
across every phase. New logic always lands in the shared, testable controllers.

## Risks & Mitigations

| Risk | Mitigation |
|---|---|
| Silent macOS render/input regression (untestable) | macOS = mechanical moves only; new logic shared-side; characterization tests + diff review; Phase 3 freezable |
| Backend seam two-way wiring gets complex | Roles stay contracts; implement directly on the backend first; split into role classes only when bloated (YAGNI) |
| "Converge on macOS" changes Windows behavior in Phase 1 | Record each drift individually; confirm via Windows smoke; mark as intentional fix |
| Thin characterization coverage over 3,600-line gui.rb | Test per extracted method; don't chase full coverage — pin only the parts being extracted |
| Large PRs hard to review | Phase = independent PR; further split commits per controller |

## Out of Scope (YAGNI)

- Internal unification of the graphics layer (kitty/sixel) — only *wrapped* behind the
  backend `#graphics` role, not merged.
- Redesign of the `objc.rb` / `win32.rb` native bindings themselves.
- Implementing the Linux backend (interface is opened for it; impl is future work).
- Full draw-loop unification (Phase 3; freezable).

## Design Goals — Met

- Resolve the "two `GUI` classes, one name" into a single orchestrator. ✅
- Two axes: inheritance (backend family / Renderer base) + delegation (GUI→controllers /
  GUI→backend). ✅
- Linux on-ramp (a 4th backend against the same interface). ✅
- macOS safety under Windows-only verification (mechanical moves + new logic concentrated
  on the testable side). ✅
