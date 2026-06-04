# GUI::Selection Extraction — Phase 1b Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the duplicated anchor-normalization and cell-boundary-check logic into a shared `GUI::Selection` module, eliminating two pieces of copy-paste code that have already drifted between macOS and Windows.

**Architecture:** One task. Create `lib/echoes/gui/selection.rb` with two stateless `module_function`s (`normalize_selection` / `cell_in_range?`), add tests, then wire both GUI implementations to delegate. macOS `selection_range` / `cell_selected?` become thin delegators (mechanical only — no runtime verification). Windows keeps its copy_mode branching, replacing only the anchor-based part with shared helpers. Follows the pattern established by `GUI::Layout`, `GUI::Osc7`, and `GUI::SearchController`.

**Tech Stack:** Ruby 3.2+, test-unit (~> 3.0). Run tests: `bundle exec rake test`. Single file: `bundle exec ruby -Ilib -Itest <file>`. Do NOT run `ruby -e "..."` one-liners.

---

## Duplication evidence

**macOS `selection_range`** (`lib/echoes/gui.rb:2529`):
```ruby
def selection_range
  return nil unless @selection_anchor && @selection_end
  a_r, a_c = @selection_anchor
  b_r, b_c = @selection_end
  if a_r < b_r || (a_r == b_r && a_c <= b_c)
    [a_r, a_c, b_r, b_c]
  else
    [b_r, b_c, a_r, a_c]
  end
end
```

**Windows `selection_range`** (`lib/echoes/gui_win32/rendering_panes.rb:315`):
```ruby
private def selection_range
  pane = current_tab&.active_pane
  copy_mode = pane&.copy_mode
  if copy_mode && copy_mode.active && copy_mode.selecting?
    (sr, sc), (er, ec) = [copy_mode.selection_start, copy_mode.selection_end].sort_by { |p| [p[0], p[1]] }
    scrollback_size = pane.screen.scrollback.size
    sr += scrollback_size
    er += scrollback_size
    return [sr, sc, er, ec]
  end
  return nil unless @selection_anchor && @selection_end
  (sr, sc), (er, ec) = [@selection_anchor, @selection_end].sort_by { |p| [p[0], p[1]] }
  [sr, sc, er, ec]
end
```

**macOS `cell_selected?`** (`lib/echoes/gui.rb:2712`):
```ruby
def cell_selected?(row, col)
  range = selection_range
  return false unless range
  sr, sc, er, ec = range
  return false if row < sr || row > er
  return col >= sc && col <= ec if sr == er
  return col >= sc if row == sr
  return col <= ec if row == er
  true
end
```

**Windows `cell_selected?`** (`lib/echoes/gui_win32/rendering_capture_and_tab.rb:395`):
```ruby
private def cell_selected?(src_row, col)
  if (tab = current_tab) && (pane = tab.active_pane)
    copy_mode = pane.copy_mode
    if copy_mode && copy_mode.active && copy_mode.selecting?
      sel_start, sel_end = [copy_mode.selection_start, copy_mode.selection_end].sort_by { |p| [p[0], p[1]] }
      cm_row = src_row - pane.screen.scrollback.size
      if cm_row >= sel_start[0] && cm_row <= sel_end[0]
        if cm_row == sel_start[0] && cm_row == sel_end[0]
          return col >= sel_start[1] && col <= sel_end[1]
        elsif cm_row == sel_start[0]
          return col >= sel_start[1]
        elsif cm_row == sel_end[0]
          return col <= sel_end[1]
        else
          return true
        end
      end
    end
  end
  if @selection_anchor && @selection_end
    (sr, sc), (er, ec) = [@selection_anchor, @selection_end].sort_by { |p| [p[0], p[1]] }
    if src_row >= sr && src_row <= er
      if src_row == sr && src_row == er
        return col >= sc && col <= ec
      elsif src_row == sr
        return col >= sc
      elsif src_row == er
        return col <= ec
      else
        return true
      end
    end
  end
  false
end
```

The anchor-normalization and boundary-check logic is **identical** across platforms. The Windows version inlines the boundary check rather than delegating to `selection_range`, resulting in the same logic duplicated twice.

---

## File Map

### New files
- `lib/echoes/gui/selection.rb` — `GUI::Selection` module (`normalize_selection`, `cell_in_range?`)
- `test/echoes/gui_selection_test.rb` — unit tests

### Modified files
- `lib/echoes/gui.rb` — replace `selection_range` and `cell_selected?` bodies with delegation
- `lib/echoes/gui_win32/rendering_panes.rb` — replace anchor-normalization in `selection_range` with shared helper
- `lib/echoes/gui_win32/rendering_capture_and_tab.rb` — replace anchor-based boundary check in `cell_selected?` with shared helpers
- `Rakefile` — add `gui_selection_test.rb` to `CORE_TEST_FILES`

---

## Task 1: Extract GUI::Selection

### Step 1: Write the failing tests

Create `test/echoes/gui_selection_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "echoes/gui/selection"

class GuiSelectionTest < Test::Unit::TestCase
  include Echoes::GUI::Selection

  # --- normalize_selection ---

  def test_normalize_returns_nil_when_anchor_nil
    assert_nil normalize_selection(nil, [0, 0])
  end

  def test_normalize_returns_nil_when_endpoint_nil
    assert_nil normalize_selection([0, 0], nil)
  end

  def test_normalize_returns_nil_when_both_nil
    assert_nil normalize_selection(nil, nil)
  end

  def test_normalize_same_point
    assert_equal [3, 5, 3, 5], normalize_selection([3, 5], [3, 5])
  end

  def test_normalize_anchor_before_endpoint_same_row
    assert_equal [2, 1, 2, 7], normalize_selection([2, 1], [2, 7])
  end

  def test_normalize_endpoint_before_anchor_same_row
    # reversed: endpoint comes before anchor — must swap
    assert_equal [2, 1, 2, 7], normalize_selection([2, 7], [2, 1])
  end

  def test_normalize_anchor_above_endpoint
    assert_equal [1, 3, 4, 6], normalize_selection([1, 3], [4, 6])
  end

  def test_normalize_anchor_below_endpoint
    # reversed: anchor is below endpoint — must swap
    assert_equal [1, 3, 4, 6], normalize_selection([4, 6], [1, 3])
  end

  def test_normalize_same_row_anchor_col_equal_to_endpoint
    # anchor col == endpoint col, same row → anchor is start
    assert_equal [5, 3, 5, 3], normalize_selection([5, 3], [5, 3])
  end

  # --- cell_in_range? ---

  def test_cell_in_range_single_row_selection
    # Selection: row 3, col 2..5
    assert_true  cell_in_range?(3, 2, 3, 2, 3, 5)
    assert_true  cell_in_range?(3, 5, 3, 2, 3, 5)
    assert_false cell_in_range?(3, 1, 3, 2, 3, 5)
    assert_false cell_in_range?(3, 6, 3, 2, 3, 5)
    assert_false cell_in_range?(2, 3, 3, 2, 3, 5)  # wrong row
    assert_false cell_in_range?(4, 3, 3, 2, 3, 5)  # wrong row
  end

  def test_cell_in_range_multi_row_start_row
    # Selection: row 2 col 3 → row 5 col 7
    # Start row: must be >= sc
    assert_true  cell_in_range?(2, 3, 2, 3, 5, 7)   # at start col
    assert_true  cell_in_range?(2, 10, 2, 3, 5, 7)  # past start col, still on start row
    assert_false cell_in_range?(2, 2, 2, 3, 5, 7)   # before start col
  end

  def test_cell_in_range_multi_row_end_row
    # End row: must be <= ec
    assert_true  cell_in_range?(5, 7, 2, 3, 5, 7)   # at end col
    assert_true  cell_in_range?(5, 0, 2, 3, 5, 7)   # before end col, still on end row
    assert_false cell_in_range?(5, 8, 2, 3, 5, 7)   # past end col
  end

  def test_cell_in_range_multi_row_middle_row
    # Middle rows: any col is selected
    assert_true cell_in_range?(3, 0, 2, 3, 5, 7)
    assert_true cell_in_range?(3, 100, 2, 3, 5, 7)
    assert_true cell_in_range?(4, 0, 2, 3, 5, 7)
  end

  def test_cell_in_range_row_outside_selection
    assert_false cell_in_range?(1, 5, 2, 3, 5, 7)  # above
    assert_false cell_in_range?(6, 5, 2, 3, 5, 7)  # below
  end
end
```

- [ ] **Step 2: Run — must fail with LoadError**

```bash
bundle exec ruby -Ilib -Itest test/echoes/gui_selection_test.rb
```

Expected: `LoadError: cannot load such file -- echoes/gui/selection`

- [ ] **Step 3: Create lib/echoes/gui/selection.rb**

```ruby
# frozen_string_literal: true

module Echoes
  module GUI
    module Selection
      module_function

      # Normalize two selection anchors into [sr, sc, er, ec] with sr,sc ≤ er,ec.
      # Returns nil if either anchor is nil.
      def normalize_selection(anchor, endpoint)
        return nil unless anchor && endpoint

        a_r, a_c = anchor
        b_r, b_c = endpoint
        if a_r < b_r || (a_r == b_r && a_c <= b_c)
          [a_r, a_c, b_r, b_c]
        else
          [b_r, b_c, a_r, a_c]
        end
      end

      # Returns true if (row, col) falls within the normalized range [sr, sc, er, ec].
      def cell_in_range?(row, col, sr, sc, er, ec)
        return false if row < sr || row > er
        return col >= sc && col <= ec if sr == er
        return col >= sc if row == sr
        return col <= ec if row == er
        true
      end
    end
  end
end
```

- [ ] **Step 4: Run — must pass**

```bash
bundle exec ruby -Ilib -Itest test/echoes/gui_selection_test.rb
```

Expected: all tests pass, 0 failures.

- [ ] **Step 5: Wire delegation in gui_win32/rendering_panes.rb**

Read the file first to confirm exact current content:

```bash
grep -n "require\|frozen_string\|def selection_range" lib/echoes/gui_win32/rendering_panes.rb | head -10
```

Add `require_relative "../gui/selection"` near the top of the file (after `# frozen_string_literal: true`, consistent with how other shared modules are required in win32 files).

Find `selection_range` (around line 315). The current body is:

```ruby
    private def selection_range
      pane = current_tab&.active_pane
      copy_mode = pane&.copy_mode
      if copy_mode && copy_mode.active && copy_mode.selecting?
        (sr, sc), (er, ec) = [copy_mode.selection_start, copy_mode.selection_end].sort_by { |p| [p[0], p[1]] }
        scrollback_size = pane.screen.scrollback.size
        sr += scrollback_size
        er += scrollback_size
        return [sr, sc, er, ec]
      end

      return nil unless @selection_anchor && @selection_end

      (sr, sc), (er, ec) = [@selection_anchor, @selection_end].sort_by { |p| [p[0], p[1]] }
      [sr, sc, er, ec]
    end
```

Replace the anchor-based branch (last 4 lines) with the shared helper:

```ruby
    private def selection_range
      pane = current_tab&.active_pane
      copy_mode = pane&.copy_mode
      if copy_mode && copy_mode.active && copy_mode.selecting?
        (sr, sc), (er, ec) = [copy_mode.selection_start, copy_mode.selection_end].sort_by { |p| [p[0], p[1]] }
        scrollback_size = pane.screen.scrollback.size
        sr += scrollback_size
        er += scrollback_size
        return [sr, sc, er, ec]
      end

      Echoes::GUI::Selection.normalize_selection(@selection_anchor, @selection_end)
    end
```

- [ ] **Step 6: Wire delegation in gui_win32/rendering_capture_and_tab.rb**

Read the file to confirm exact current content:

```bash
grep -n "require\|frozen_string\|def cell_selected" lib/echoes/gui_win32/rendering_capture_and_tab.rb | head -10
```

Add `require_relative "../gui/selection"` near the top of the file.

Find `cell_selected?` (around line 395). The current anchor-based block at the bottom is:

```ruby
      if @selection_anchor && @selection_end
        (sr, sc), (er, ec) = [@selection_anchor, @selection_end].sort_by { |p| [p[0], p[1]] }
        if src_row >= sr && src_row <= er
          if src_row == sr && src_row == er
            return col >= sc && col <= ec
          elsif src_row == sr
            return col >= sc
          elsif src_row == er
            return col <= ec
          else
            return true
          end
        end
      end

      false
```

Replace it with the shared helpers:

```ruby
      range = Echoes::GUI::Selection.normalize_selection(@selection_anchor, @selection_end)
      return false unless range

      Echoes::GUI::Selection.cell_in_range?(src_row, col, *range)
```

The full method after the change:

```ruby
    private def cell_selected?(src_row, col)
      if (tab = current_tab) && (pane = tab.active_pane)
        copy_mode = pane.copy_mode
        if copy_mode && copy_mode.active && copy_mode.selecting?
          sel_start, sel_end = [copy_mode.selection_start, copy_mode.selection_end].sort_by { |p| [p[0], p[1]] }
          cm_row = src_row - pane.screen.scrollback.size
          if cm_row >= sel_start[0] && cm_row <= sel_end[0]
            if cm_row == sel_start[0] && cm_row == sel_end[0]
              return col >= sel_start[1] && col <= sel_end[1]
            elsif cm_row == sel_start[0]
              return col >= sel_start[1]
            elsif cm_row == sel_end[0]
              return col <= sel_end[1]
            else
              return true
            end
          end
        end
      end

      range = Echoes::GUI::Selection.normalize_selection(@selection_anchor, @selection_end)
      return false unless range

      Echoes::GUI::Selection.cell_in_range?(src_row, col, *range)
    end
```

- [ ] **Step 7: Wire delegation in gui.rb (macOS) — mechanical only**

**macOS cannot be runtime-verified. These are method-body substitutions only — no logic changes.**

Read the current methods to confirm exact content:

```bash
grep -n "def selection_range\|def cell_selected" lib/echoes/gui.rb
```

Add `require_relative "gui/selection"` near the top of `lib/echoes/gui.rb` (after existing requires at file scope). Read the top first:

```bash
grep -n "^require\|require_relative" lib/echoes/gui.rb | head -10
```

Find `selection_range` at the line identified above. Replace the body:

```ruby
        def selection_range
          GUI::Selection.normalize_selection(@selection_anchor, @selection_end)
        end
```

Find `cell_selected?`. Replace the body:

```ruby
        def cell_selected?(row, col)
          range = selection_range
          return false unless range

          GUI::Selection.cell_in_range?(row, col, *range)
        end
```

Verify the diff contains only method-body substitutions:

```bash
git diff lib/echoes/gui.rb
```

Every changed line must be either the require addition, or the replacement of the method body. If any other lines appear in the diff, STOP and report BLOCKED.

- [ ] **Step 8: Add to Rakefile CORE_TEST_FILES**

In `Rakefile`, find the `CORE_TEST_FILES` list. Add `"test/echoes/gui_selection_test.rb"` after `"test/echoes/gui_osc7_test.rb"`:

```ruby
  "test/echoes/gui_osc7_test.rb",
  "test/echoes/gui_selection_test.rb",
  "test/echoes/gui_win32_lint_test.rb",
```

- [ ] **Step 9: Run full test suite — must stay green**

```bash
bundle exec rake test
```

Expected: 0 failures. New tests add to the count. If failures occur, read the error carefully before fixing.

- [ ] **Step 10: Commit**

```bash
git add lib/echoes/gui/selection.rb \
        test/echoes/gui_selection_test.rb \
        lib/echoes/gui.rb \
        lib/echoes/gui_win32/rendering_panes.rb \
        lib/echoes/gui_win32/rendering_capture_and_tab.rb \
        Rakefile
git commit -m "refactor: extract GUI::Selection shared module

Removes duplicated anchor-normalization and boundary-check logic from
gui.rb and two gui_win32 files. normalize_selection and cell_in_range?
are now tested module_functions; both GUIs delegate the pure-anchor
path through them. Windows copy_mode branching is unchanged.

Eliminates the inline re-implementation of boundary checking in
gui_win32/rendering_capture_and_tab.rb that duplicated the logic
already present (via selection_range delegation) in gui.rb."
```

---

## Self-Review

**Spec coverage:**
- `normalize_selection` extracted and tested ✅
- `cell_in_range?` extracted and tested ✅
- macOS `selection_range` delegates to `normalize_selection` ✅
- macOS `cell_selected?` delegates via `selection_range` + `cell_in_range?` ✅
- Windows `selection_range` anchor-branch replaced ✅
- Windows `cell_selected?` anchor-branch replaced ✅
- copy_mode handling unchanged (platform-specific, stays in each backend) ✅
- Rakefile updated ✅

**Placeholder scan:** None. All code blocks are complete.

**Type consistency:** `normalize_selection(anchor, endpoint) → [sr, sc, er, ec] | nil` and `cell_in_range?(row, col, sr, sc, er, ec) → bool` used consistently in module definition, tests, and all delegation sites.

**macOS safety:** Steps 7's diff check enforces "method-body substitutions only." The macOS `cell_selected?` previously called `selection_range` and then did the boundary check inline — after this change it calls `selection_range` (which now uses `normalize_selection`) and then `cell_in_range?`. The behavior is identical; the diff check confirms no other changes.
