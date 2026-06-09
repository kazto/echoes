# Cross-Platform GUI Refactor — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current "two classes, one name" pattern with a single `Echoes::GUI` orchestrator that delegates to a platform-selected `GUI::Backend::Win32` or `GUI::Backend::Mac`, wired through a testable `Platform.gui_backend` factory.

**Architecture:** Three sequential tasks. Task 0 creates pure infrastructure (abstract class + factory) with no functional changes. Task 1 renames the Win32 implementation to `GUI::Backend::Win32`, creates the thin `GUI` orchestrator, updates test allocations, and wires `load_gui_backend` — fully verifiable on Windows. Task 2 renames the macOS implementation to `GUI::Backend::Mac` in `gui.rb` — mechanical class rename only, no logic changes, verified by diff review.

**Tech Stack:** Ruby 3.2+, test-unit (~> 3.0), existing AppKit (macOS) and Win32/Fiddle (Windows) native bindings. Run tests with `bundle exec rake test`. Single test file: `bundle exec ruby -Ilib -Itest <file>`.

---

## File Map

### New files
- `lib/echoes/gui/backend.rb` — `GUI::Backend` abstract base class
- `lib/echoes/gui_orchestrator.rb` — thin `Echoes::GUI` orchestrator (delegates run to backend)

### Modified files
- `lib/echoes/platform.rb` — add `gui_backend(os)` factory
- `lib/echoes/echoes.rb` — update `load_gui_backend` to require backend.rb + gui_orchestrator.rb
- `lib/echoes/gui_win32.rb` — require `gui/backend` before other win32 files
- `lib/echoes/gui_win32/core.rb` — rename class from `GUI` to `GUI::Backend::Win32 < GUI::Backend`
- `lib/echoes/gui_win32/menu.rb` — reopen `GUI::Backend::Win32`
- `lib/echoes/gui_win32/window_and_input.rb` — reopen `GUI::Backend::Win32`
- `lib/echoes/gui_win32/rendering_primitives.rb` — reopen `GUI::Backend::Win32`
- `lib/echoes/gui_win32/rendering_panes.rb` — reopen `GUI::Backend::Win32`
- `lib/echoes/gui_win32/rendering_capture_and_tab.rb` — reopen `GUI::Backend::Win32`
- `lib/echoes/gui_win32/search.rb` — reopen `GUI::Backend::Win32`
- `lib/echoes/gui.rb` — rename class from `GUI` to `GUI::Backend::Mac < GUI::Backend`
- `test/echoes/platform_test.rb` — add `gui_backend` factory tests
- `test/echoes/gui_test.rb` — update `Echoes::GUI.allocate` → `Echoes::GUI::Backend::Win32.allocate` in Win32 block

---

## Task 0: GUI::Backend abstract class + Platform.gui_backend factory

**Why:** Creates the testable infrastructure that Tasks 1 and 2 depend on. No functional change — the factory is wired up but not yet called by production code.

**Files:**
- Create: `lib/echoes/gui/backend.rb`
- Modify: `lib/echoes/platform.rb`
- Modify: `test/echoes/platform_test.rb`

- [ ] **Step 1: Write the failing factory test**

Add to `test/echoes/platform_test.rb` (at the bottom, before the final `end`):

```ruby
  test "gui_backend raises Error for unsupported platform" do
    assert_raise(Echoes::Error) do
      Echoes::Platform.gui_backend("linux-gnu")
    end
  end

  if Echoes::Platform.windows?
    test "gui_backend returns Win32 backend class on Windows" do
      klass = Echoes::Platform.gui_backend
      assert_equal "Echoes::GUI::Backend::Win32", klass.name
    end
  end
```

- [ ] **Step 2: Run — must fail with NoMethodError**

```bash
bundle exec ruby -Ilib -Itest test/echoes/platform_test.rb
```

Expected: `NoMethodError: undefined method 'gui_backend' for Echoes::Platform`

- [ ] **Step 3: Create lib/echoes/gui/backend.rb**

```ruby
# frozen_string_literal: true

module Echoes
  class GUI
    # Abstract base class for platform GUI backends.
    # Each backend owns a native window, run loop, and rendering.
    # The GUI orchestrator (gui_orchestrator.rb) holds one backend instance
    # and delegates #run to it.
    #
    # Subclasses must implement #initialize and #run.
    # All other methods are platform-specific and live only on the subclass.
    class Backend
      def initialize(command:, rows:, cols:, font_size: nil)
        raise NotImplementedError, "#{self.class}#initialize not implemented"
      end

      def run
        raise NotImplementedError, "#{self.class}#run not implemented"
      end
    end
  end
end
```

- [ ] **Step 4: Add gui_backend to Platform**

In `lib/echoes/platform.rb`, add after the `unix?` method:

```ruby
    def gui_backend(os = host_os)
      if windows?(os)
        GUI::Backend::Win32
      elsif macos?(os)
        GUI::Backend::Mac
      else
        raise Echoes::Error, "Echoes GUI is not supported on this platform"
      end
    end
```

The method references `GUI::Backend::Win32` / `GUI::Backend::Mac`, which are defined only after `load_gui_backend` runs. Calling `gui_backend` before that raises `NameError` — the same contract as `ShellBackend.for_platform` calling `MacPtyBackend` before PTY is loaded.

- [ ] **Step 5: Run — tests for gui_backend pass; full suite stays green**

```bash
bundle exec ruby -Ilib -Itest test/echoes/platform_test.rb
```

Expected: the new `gui_backend` tests pass (Win32 test is skipped on non-Windows), `Error for unsupported platform` passes.

```bash
bundle exec rake test
```

Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/echoes/gui/backend.rb lib/echoes/platform.rb test/echoes/platform_test.rb
git commit -m "feat: add GUI::Backend abstract class and Platform.gui_backend factory

Adds the backend seam infrastructure. Platform.gui_backend(os) follows
the same injectable-os pattern as ShellBackend.for_platform. The
Win32/Mac backend classes are not yet defined — that happens in
subsequent tasks."
```

---

## Task 1: Rename Win32 GUI class + thin orchestrator + wire load_gui_backend

**Why:** Renames `Echoes::GUI` (Win32) to `Echoes::GUI::Backend::Win32`, creates the thin `Echoes::GUI` orchestrator that the CLI calls, updates `load_gui_backend`, and updates the 112 Win32-specific test allocations. Fully verifiable on Windows.

**Files:**
- Modify: `lib/echoes/gui_win32.rb`
- Modify: `lib/echoes/gui_win32/core.rb` (class rename)
- Modify: `lib/echoes/gui_win32/menu.rb`
- Modify: `lib/echoes/gui_win32/window_and_input.rb`
- Modify: `lib/echoes/gui_win32/rendering_primitives.rb`
- Modify: `lib/echoes/gui_win32/rendering_panes.rb`
- Modify: `lib/echoes/gui_win32/rendering_capture_and_tab.rb`
- Modify: `lib/echoes/gui_win32/search.rb`
- Create: `lib/echoes/gui_orchestrator.rb`
- Modify: `lib/echoes/echoes.rb`
- Modify: `test/echoes/gui_test.rb`

### Step 1: Require gui/backend in gui_win32.rb

In `lib/echoes/gui_win32.rb`, add as the **first require** (before any others):

```ruby
# frozen_string_literal: true

require_relative 'gui/backend'   # Must load before gui_win32/core.rb defines Backend::Win32
require_relative 'win32'
require_relative 'window_registry'
# ... rest unchanged
```

- [ ] **Step 1a: Read gui_win32.rb and add the require**

```bash
head -5 lib/echoes/gui_win32.rb
```

Prepend `require_relative 'gui/backend'` as the first line after `# frozen_string_literal: true`.

### Step 2: Rename core.rb class definition

- [ ] **Step 2a: Read core.rb top to find the class opening**

```bash
grep -n "^module Echoes\|^  class GUI\|^    class " lib/echoes/gui_win32/core.rb | head -10
```

- [ ] **Step 2b: Replace the class opening in core.rb**

Find the class definition block:

```ruby
module Echoes
  class GUI
```

Replace with:

```ruby
module Echoes
  class GUI
    class Backend
      class Win32 < Backend
```

And find the matching `end` of the old `class GUI` block at the bottom of the file. Add two extra `end` lines to close `Backend` and `Win32` before the final `end` of `module Echoes`:

The bottom of the file currently looks like:

```ruby
  end  # class GUI
end    # module Echoes
```

Change to:

```ruby
      end  # class Win32
    end    # class Backend
  end      # class GUI
end        # module Echoes
```

**Important:** The indentation of all existing methods inside the class increases by 2 levels (8 spaces instead of 4). Read the file first to understand the current indentation, then adjust accordingly. The most reliable approach is to re-indent the entire file body by 2 extra levels.

- [ ] **Step 2c: Verify core.rb parses correctly**

```bash
ruby -Ilib -e "require 'echoes/gui/backend'; require 'echoes/gui_win32/core'" 2>&1 | head -5
```

Expected: no output (no error). If error, fix indentation.

### Step 3: Rename the other 6 win32 files

For each of these files, change the class-opening line from `class GUI` to `class GUI::Backend::Win32`:

- `lib/echoes/gui_win32/menu.rb`
- `lib/echoes/gui_win32/window_and_input.rb`
- `lib/echoes/gui_win32/rendering_primitives.rb`
- `lib/echoes/gui_win32/rendering_panes.rb`
- `lib/echoes/gui_win32/rendering_capture_and_tab.rb`
- `lib/echoes/gui_win32/search.rb`

In each file, find:

```ruby
module Echoes
  class GUI
```

Replace with:

```ruby
module Echoes
  class GUI::Backend::Win32
```

The `end` count does not change — one `end` for the class, one for the module, same as before.

- [ ] **Step 3a: Apply the change to all 6 files**

Use the Edit tool on each file. Verify with:

```bash
grep -l "class GUI$" lib/echoes/gui_win32/*.rb
```

Expected: empty output (no files remain with `class GUI` on its own).

### Step 4: Create the thin GUI orchestrator

- [ ] **Step 4a: Create lib/echoes/gui_orchestrator.rb**

```ruby
# frozen_string_literal: true

module Echoes
  # Thin platform-agnostic orchestrator. Owns no native state itself;
  # delegates run() to the platform backend selected by Platform.gui_backend.
  class GUI
    extend GUI::Osc7

    def initialize(command: Echoes.config.shell, rows: Echoes.config.rows, cols: Echoes.config.cols, font_size: nil)
      @backend = Platform.gui_backend.new(
        command: command, rows: rows, cols: cols, font_size: font_size
      )
    end

    def run
      @backend.run
    end

    # capture_format_for exists on both platform backends and is called from
    # tests and from the prompt_for_screenshot flow via self.class.
    def self.capture_format_for(path)
      Platform.gui_backend.capture_format_for(path)
    end
  end
end
```

### Step 5: Update load_gui_backend in echoes.rb

- [ ] **Step 5a: Read the current load_gui_backend**

```bash
grep -n "def load_gui_backend" -A 12 lib/echoes.rb
```

- [ ] **Step 5b: Replace load_gui_backend**

Find:

```ruby
  def load_gui_backend
    if Platform.windows?
      require_relative "echoes/win32"
      require_relative "echoes/gui_win32"
    elsif Platform.macos?
      require_relative "echoes/objc"
      require_relative "echoes/gui"
    else
      raise Error, "Echoes GUI is not supported on this platform"
    end
  end
```

Replace with:

```ruby
  def load_gui_backend
    require_relative "echoes/gui/backend"
    if Platform.windows?
      require_relative "echoes/win32"
      require_relative "echoes/gui_win32"
    elsif Platform.macos?
      require_relative "echoes/objc"
      require_relative "echoes/gui"
    else
      raise Error, "Echoes GUI is not supported on this platform"
    end
    require_relative "echoes/gui_orchestrator"
  end
```

### Step 6: Update test allocations

Tests in `test/echoes/gui_test.rb` inside the `if Echoes::Platform.windows?` block use `Echoes::GUI.allocate` to create backend instances for testing private methods. After renaming, they need `Echoes::GUI::Backend::Win32.allocate`.

- [ ] **Step 6a: Count and bulk-replace in gui_test.rb**

```bash
grep -c "Echoes::GUI\.allocate" test/echoes/gui_test.rb
```

Run the replacement (use PowerShell on Windows):

```powershell
(Get-Content test/echoes/gui_test.rb -Raw) -replace 'Echoes::GUI\.allocate', 'Echoes::GUI::Backend::Win32.allocate' | Set-Content test/echoes/gui_test.rb
```

Verify:

```bash
grep -c "Echoes::GUI\.allocate" test/echoes/gui_test.rb
```

Expected: 0.

```bash
grep -c "Backend::Win32\.allocate" test/echoes/gui_test.rb
```

Expected: same number as before.

- [ ] **Step 6b: Check gui_win32_parity_unit_test.rb**

```bash
grep -n "Echoes::GUI\.allocate\|Echoes::GUI\.new" test/echoes/gui_win32_parity_unit_test.rb
```

Replace any `Echoes::GUI.allocate` with `Echoes::GUI::Backend::Win32.allocate` in that file too.

- [ ] **Step 6c: Check for Echoes::GUI.new in Win32 test contexts**

```bash
grep -n "Echoes::GUI\.new" test/echoes/gui_test.rb | head -5
```

`Echoes::GUI.new` called via the thin orchestrator is correct — no change needed there.

### Step 7: Run the full test suite

- [ ] **Step 7a: Run all tests**

```bash
bundle exec rake test
```

Expected: 0 failures. If failures, read the error and fix.

Common failure modes:
- `NameError: uninitialized constant Echoes::GUI::Backend::Win32` — the class rename in one of the 7 files did not take effect; re-check that file.
- `NoMethodError` on `GUI` thin orchestrator — a method exists only on the backend; the test should be calling `Backend::Win32.allocate`, not `GUI.allocate`.

### Step 8: Commit

- [ ] **Step 8: Commit**

```bash
git add lib/echoes/gui_win32.rb \
        lib/echoes/gui_win32/core.rb \
        lib/echoes/gui_win32/menu.rb \
        lib/echoes/gui_win32/window_and_input.rb \
        lib/echoes/gui_win32/rendering_primitives.rb \
        lib/echoes/gui_win32/rendering_panes.rb \
        lib/echoes/gui_win32/rendering_capture_and_tab.rb \
        lib/echoes/gui_win32/search.rb \
        lib/echoes/gui_orchestrator.rb \
        lib/echoes/echoes.rb \
        test/echoes/gui_test.rb \
        test/echoes/gui_win32_parity_unit_test.rb
git commit -m "refactor: rename Win32 GUI class to Backend::Win32, add thin orchestrator

Echoes::GUI is now a thin platform-agnostic orchestrator. The Win32
implementation moves to GUI::Backend::Win32 < GUI::Backend. All 7
gui_win32 files are updated; load_gui_backend now requires gui/backend
and gui_orchestrator. Test allocations updated to Backend::Win32."
```

---

## Task 2: Rename macOS GUI class to Backend::Mac

**Why:** Completes the "two classes, one name" resolution on the macOS side. `lib/echoes/gui.rb` is 3546 lines of AppKit code — we rename the outer class only; all internal logic is unchanged. macOS cannot be runtime-verified; review is by diff inspection only.

**Safety rule:** This task must contain ZERO logic changes. Every edit is a class name substitution or an `end` count adjustment. If any edit touches method bodies, stop and raise a concern.

**Files:**
- Modify: `lib/echoes/gui.rb`

- [ ] **Step 1: Verify no existing GUI::Backend::Mac**

```bash
grep -rn "Backend::Mac\|Backend::Mac" lib/
```

Expected: 0 results (it doesn't exist yet).

- [ ] **Step 2: Read the top of gui.rb to understand the class structure**

```bash
head -20 lib/echoes/gui.rb
```

The file currently opens:

```ruby
# frozen_string_literal: true

# ... requires ...

module Echoes
  class GUI
    require_relative "gui/osc7"
    # ... constants and methods ...
  end
end
```

- [ ] **Step 3: Change the class opening**

Find in `lib/echoes/gui.rb`:

```ruby
module Echoes
  class GUI
```

Replace with:

```ruby
module Echoes
  class GUI
    class Backend
      class Mac < Backend
```

- [ ] **Step 4: Add closing ends at the bottom**

Read the bottom of the file:

```bash
tail -5 lib/echoes/gui.rb
```

Currently:

```ruby
  end  # class GUI
end    # module Echoes
```

Replace with:

```ruby
      end  # class Mac
    end    # class Backend
  end      # class GUI
end        # module Echoes
```

**Important:** Re-indent all content inside `class Mac` by 2 additional levels (add 4 spaces to every line inside the former `class GUI` body). Use a single bulk re-indent operation on the file body between the new class opening and `end # class Mac`.

- [ ] **Step 5: Remove extend GUI::Osc7 from Backend::Mac (already on thin orchestrator)**

In `lib/echoes/gui.rb`, find:

```ruby
        require_relative "gui/osc7"
        extend Echoes::GUI::Osc7
```

The `extend Echoes::GUI::Osc7` on `Backend::Mac` is harmless but redundant — the thin orchestrator `GUI` already extends it. Leave it in place (removing is an unnecessary change that adds risk). The `require_relative "gui/osc7"` is still needed to ensure `GUI::Osc7` is defined when `gui.rb` is loaded.

- [ ] **Step 6: Check for any references to Echoes::GUI as a class within gui.rb**

```bash
grep -n "Echoes::GUI\b\|< GUI\b\|= GUI\b" lib/echoes/gui.rb | grep -v "Osc7\|SearchController\|Layout\|Backend"
```

Expected: 0 results. Any remaining `Echoes::GUI` that refers to the class itself (not the controllers) is a reference that might need updating to `Echoes::GUI::Backend::Mac`.

- [ ] **Step 7: Verify parse correctness via syntax check**

```bash
ruby -c lib/echoes/gui.rb
```

Expected: `Syntax OK`

- [ ] **Step 8: Run the test suite (macOS behaviour unchanged via diff review)**

```bash
bundle exec rake test
```

Expected: 0 failures.

On Windows, macOS-specific tests are skipped or omitted. The test count should be the same as after Task 1. If count changes, investigate.

- [ ] **Step 9: Diff review**

```bash
git diff lib/echoes/gui.rb | head -80
```

Inspect the diff manually. Every changed line must be one of:
- The class opening line (`class GUI` → `class Backend; class Mac < Backend`)
- An indentation change (4 more spaces per line)
- The closing `end` additions

If any method body is changed, that is a mistake — revert and redo.

- [ ] **Step 10: Commit**

```bash
git add lib/echoes/gui.rb
git commit -m "refactor: rename macOS GUI class to Backend::Mac

Mechanical class rename only — no logic changes. gui.rb now defines
GUI::Backend::Mac < GUI::Backend. The thin GUI orchestrator
(gui_orchestrator.rb) remains the public Echoes::GUI class on all
platforms. Verified by syntax check and diff review (macOS not
runtime-accessible)."
```

---

## Self-Review

**Spec coverage:**
- "single GUI orchestrator" → `gui_orchestrator.rb` ✅
- "Platform.gui_backend factory" → `platform.rb#gui_backend` ✅
- "GUI::Backend abstract class" → `gui/backend.rb` ✅
- "GUI::Backend::Mac < Backend" → Task 2 ✅
- "GUI::Backend::Win32 < Backend" → Task 1 ✅
- "load_gui_backend selects backend" → updated in Task 1 ✅
- "macOS = mechanical move only" → Task 2 is rename only ✅
- "Windows-only verification" → Tasks 0 and 1 fully testable; Task 2 syntax-checked + diff reviewed ✅

**Placeholder scan:** None found.

**Type consistency:**
- `GUI::Backend::Win32` used consistently in all 7 win32 files, test updates, orchestrator, and factory.
- `GUI::Backend::Mac` used consistently in Task 2 and factory.
- `Platform.gui_backend` (no arguments) → returns class for current OS; `Platform.gui_backend(os)` → injectable for tests.

**macOS safety:** Task 2 is class rename + re-indent only. Step 6 and 9 explicitly verify no logic changes slipped in. No new code added to `gui.rb`.
