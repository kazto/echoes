# Cross-Platform GUI Refactor — Phase 0 & Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract platform-agnostic GUI logic into shared, testable controllers (`GUI::Osc7`, `GUI::SearchController`, `GUI::Layout`), eliminating duplication between `gui.rb` (macOS) and `gui_win32/` (Windows) and fixing known drift bugs — all while keeping macOS code as mechanical moves only (no runtime verification available).

**Architecture:** Phase 0 merges 5 pending master commits into `feature/windows` to establish a fresh baseline. Phase 1 extracts three pure controllers using TDD: write characterization tests first, mechanically relocate logic from both GUIs into `lib/echoes/gui/*.rb`, then wire delegation back. macOS code is relocated only — no logic rewrites. All new logic (nil guards, zero-width regex fix, Windows path stripping) lands in the shared side only.

**Tech Stack:** Ruby 3.2+, test-unit (~> 3.0), existing `Echoes::Screen` / `Pane` / `Tab` / `CopyMode` model classes. Run tests with `bundle exec rake test` or `bundle exec ruby -Ilib:test <test_file>`.

---

## File Map

### New files (Phase 1)
- `lib/echoes/gui/osc7.rb` — `GUI::Osc7` module (stateless, module_function)
- `lib/echoes/gui/search_controller.rb` — `GUI::SearchController` class (stateful)
- `lib/echoes/gui/layout.rb` — `GUI::Layout` module (stateless, module_function)
- `test/echoes/gui_osc7_test.rb`
- `test/echoes/gui_search_controller_test.rb`
- `test/echoes/gui_layout_test.rb`

### Modified files (Phase 1)
- `lib/echoes/gui.rb` (macOS) — remove extracted methods, add requires, wire delegation
- `lib/echoes/gui_win32.rb` — add `require_relative` for new shared files
- `lib/echoes/gui_win32/core.rb` — remove `pane_local_cwd`, `cwd_from_osc7_uri`, `tab_bar_height`, `tab_bar_y`; init `@search`; delegate
- `lib/echoes/gui_win32/search.rb` — replace all methods with `@search` delegation
- `lib/echoes/gui_win32/rendering_capture_and_tab.rb` — replace `@search_mode` with `@search.active`

---

## Task 0: Merge master into feature/windows

**Files:**
- Modify: `lib/echoes/gui.rb` (conflict resolution)
- Modify: `lib/echoes/version.rb`, `README.md`, `docs/` (auto-resolved)

- [ ] **Step 1: Confirm you are on feature/windows**

```bash
git branch --show-current
# expected: feature/windows
```

- [ ] **Step 2: Merge master**

```bash
git merge master
```

Expected: merge conflict in `lib/echoes/gui.rb`. Other files (`lib/echoes/version.rb`, `README.md`, `docs/windows-porting-status.md`, `docs/windows-porting-tasks.md`) may auto-resolve or have conflicts too.

- [ ] **Step 3: Resolve gui.rb conflict**

Open `lib/echoes/gui.rb`. For each conflict marker (`<<<<<<<` / `=======` / `>>>>>>>`):

- Accept **both** sides — master added pixel-snapping logic in `draw_pane_content` and a new `reflow_to_current_view_size` method + calls in `create_tab`/`close_tab`. Keep all of it alongside existing feature/windows changes.
- If the same region was edited on both sides, manually merge: keep feature/windows content and also insert the master additions.

For `docs/` conflicts: if both sides modified `windows-porting-status.md`, keep the **master** version as the authoritative one (it's more recent) and discard duplicate content from feature/windows.

- [ ] **Step 4: Mark resolved and commit**

```bash
git add lib/echoes/gui.rb lib/echoes/version.rb README.md
git add docs/ 2>/dev/null; true
git commit -m "Merge branch 'master' into feature/windows"
```

- [ ] **Step 5: Run test suite — must stay green**

```bash
bundle exec rake test
```

Expected: `0 failures, 0 errors` (same count as before the merge, minus any pre-existing skips).

---

## Task 1: Extract GUI::Osc7

**Why:** `pane_local_cwd` / `cwd_from_osc7_uri` are byte-identical in both GUIs except Windows adds a Windows-path strip (`/C:/...` → `C:/...`). Extracting to a shared module gives macOS the strip for free (harmless — no macOS path matches `/[A-Za-z]:/`).

**Files:**
- Create: `lib/echoes/gui/osc7.rb`
- Create: `test/echoes/gui_osc7_test.rb`
- Modify: `lib/echoes/gui.rb` (lines ~107–124: remove 2 `self.` methods, add require + `extend`)
- Modify: `lib/echoes/gui_win32/core.rb` (lines ~65–82: remove 2 `self.` methods, add require + `extend`)
- Modify: `lib/echoes/gui_win32.rb` (add require)

- [ ] **Step 1: Write the failing tests**

Create `test/echoes/gui_osc7_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "echoes/gui/osc7"

class GuiOsc7Test < Test::Unit::TestCase
  include Echoes::GUI::Osc7

  def test_returns_nil_for_nil_uri
    assert_nil cwd_from_osc7_uri(nil)
  end

  def test_returns_nil_for_empty_string
    assert_nil cwd_from_osc7_uri("")
  end

  def test_returns_nil_for_non_file_uri
    assert_nil cwd_from_osc7_uri("https://example.com/path")
  end

  def test_returns_nil_for_nonexistent_path
    assert_nil cwd_from_osc7_uri("file://localhost/nonexistent/path/xyz123")
  end

  def test_accepts_localhost
    dir = Dir.pwd
    uri = "file://localhost#{URI::DEFAULT_PARSER.escape(dir)}"
    assert_equal dir, cwd_from_osc7_uri(uri)
  end

  def test_accepts_empty_host
    dir = Dir.pwd
    uri = "file://#{URI::DEFAULT_PARSER.escape(dir)}"
    assert_equal dir, cwd_from_osc7_uri(uri)
  end

  def test_rejects_remote_host
    assert_nil cwd_from_osc7_uri("file://otherhost/tmp")
  end

  if Echoes::Platform.windows?
    def test_strips_leading_slash_from_windows_path
      # /C:/Users/foo -> C:/Users/foo
      # We fake a URI that would parse to /C:/... on Windows
      dir = Dir.pwd  # e.g. C:/Users/kazto/src/echoes
      encoded = URI::DEFAULT_PARSER.escape("/" + dir.gsub("\\", "/"))
      uri = "file://localhost#{encoded}"
      result = cwd_from_osc7_uri(uri)
      assert result.nil? || !result.start_with?("/"), "should not start with / on Windows, got: #{result.inspect}"
    end
  end

  def test_pane_local_cwd_returns_nil_for_nil_pane
    assert_nil pane_local_cwd(nil)
  end
end
```

- [ ] **Step 2: Run — must fail with "cannot load such file"**

```bash
bundle exec ruby -Ilib:test test/echoes/gui_osc7_test.rb
```

Expected: `LoadError: cannot load such file -- echoes/gui/osc7`

- [ ] **Step 3: Create lib/echoes/gui/osc7.rb**

```ruby
# frozen_string_literal: true

require "uri"
require "socket"

module Echoes
  module GUI
    module Osc7
      module_function

      def pane_local_cwd(pane)
        uri_str = pane&.screen&.current_directory
        cwd_from_osc7_uri(uri_str)
      end

      def cwd_from_osc7_uri(uri_str)
        return nil if uri_str.nil? || uri_str.empty?

        uri = URI.parse(uri_str) rescue nil
        return nil unless uri && uri.scheme == "file"

        host = uri.host.to_s
        local_host = Socket.gethostname
        unless host.empty? || host == "localhost" ||
               host == local_host || host == local_host.split(".").first
          return nil
        end

        path = URI.decode_www_form_component(uri.path) rescue nil
        # Windows: file URI encodes C:\... as /C:/...; strip the leading slash.
        # Harmless on macOS/Linux: no path matches /[A-Za-z]:/.
        path = path[1..] if path&.match?(/\A\/[A-Za-z]:\//)
        path if path && !path.empty? && Dir.exist?(path)
      end
    end
  end
end
```

- [ ] **Step 4: Run — must pass**

```bash
bundle exec ruby -Ilib:test test/echoes/gui_osc7_test.rb
```

Expected: all tests pass, 0 failures.

- [ ] **Step 5: Wire delegation in gui_win32/core.rb**

In `lib/echoes/gui_win32/core.rb`, find the two `self.` methods (around line 65):

```ruby
    def self.pane_local_cwd(pane)
      uri_str = pane&.screen&.current_directory
      cwd_from_osc7_uri(uri_str)
    end

    def self.cwd_from_osc7_uri(uri_str)
      return nil if uri_str.nil? || uri_str.empty?
      uri = URI.parse(uri_str) rescue nil
      return nil unless uri && uri.scheme == 'file'
      host = uri.host.to_s
      local_host = Socket.gethostname
      unless host.empty? || host == 'localhost' ||
             host == local_host || host == local_host.split('.').first
        return nil
      end
      path = URI.decode_www_form_component(uri.path) rescue nil
      path = path[1..] if path && path.match?(/\A\/[A-Za-z]:\//)
      path if path && !path.empty? && Dir.exist?(path)
    end
```

Replace with:

```ruby
    extend Echoes::GUI::Osc7
```

And add at the top of the file (after `# frozen_string_literal: true`):

```ruby
require_relative "../gui/osc7"
```

- [ ] **Step 6: Wire delegation in gui.rb (macOS)**

In `lib/echoes/gui.rb`, find the two `self.` methods (around line 107):

```ruby
    def self.pane_local_cwd(pane)
      uri_str = pane&.screen&.current_directory
      cwd_from_osc7_uri(uri_str)
    end

    def self.cwd_from_osc7_uri(uri_str)
      return nil if uri_str.nil? || uri_str.empty?
      uri = URI.parse(uri_str) rescue nil
      return nil unless uri && uri.scheme == 'file'
      host = uri.host.to_s
      local_host = Socket.gethostname
      unless host.empty? || host == 'localhost' ||
             host == local_host || host == local_host.split('.').first
        return nil
      end
      path = URI.decode_www_form_component(uri.path) rescue nil
      path if path && !path.empty? && Dir.exist?(path)
    end
```

Replace with:

```ruby
    extend Echoes::GUI::Osc7
```

And add near the top of `lib/echoes/gui.rb` (after existing requires):

```ruby
require_relative "gui/osc7"
```

- [ ] **Step 7: Run full test suite — must stay green**

```bash
bundle exec rake test
```

Expected: same count as before, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/echoes/gui/osc7.rb test/echoes/gui_osc7_test.rb \
        lib/echoes/gui.rb lib/echoes/gui_win32/core.rb
git commit -m "refactor: extract GUI::Osc7 shared module

Removes duplicated pane_local_cwd / cwd_from_osc7_uri from both
gui.rb and gui_win32/core.rb. The shared module adds the Windows
path-strip (/ C:/... -> C:/...) which is now applied on all
platforms — harmless on macOS since no real path matches the regex."
```

---

## Task 2: Extract GUI::SearchController

**Why:** Search logic is copy-pasted across both GUIs and has drifted. macOS has a zero-width-regex infinite-loop guard (`break if idx < pos`); Windows does not — latent hang bug. Return types also differ (`search_next` returns `nil` on macOS, `bool` on Windows). The shared controller fixes both using the macOS guard and nil-safe cell reading from Windows, then both GUIs delegate.

**Files:**
- Create: `lib/echoes/gui/search_controller.rb`
- Create: `test/echoes/gui_search_controller_test.rb`
- Modify: `lib/echoes/gui.rb` — replace search instance vars + 9 methods with `@search` delegation
- Modify: `lib/echoes/gui_win32/core.rb` — init `@search`, replace `@search_mode` refs
- Modify: `lib/echoes/gui_win32/search.rb` — replace all methods with `@search` delegation
- Modify: `lib/echoes/gui_win32/rendering_capture_and_tab.rb` — replace `@search_mode`

- [ ] **Step 1: Write the failing tests**

Create `test/echoes/gui_search_controller_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "echoes/gui/search_controller"
require "echoes/cell"

class GuiSearchControllerTest < Test::Unit::TestCase
  def setup
    @sc = Echoes::GUI::SearchController.new
  end

  # --- state management ---

  def test_inactive_by_default
    assert_false @sc.active
  end

  def test_toggle_activates
    @sc.toggle
    assert_true @sc.active
  end

  def test_toggle_twice_deactivates
    @sc.toggle
    @sc.toggle
    assert_false @sc.active
  end

  def test_toggle_clears_query_on_activate
    @sc.toggle
    @sc.append_query("hello")
    @sc.toggle
    @sc.toggle
    assert_equal "", @sc.query
  end

  def test_cancel_deactivates
    @sc.toggle
    @sc.cancel
    assert_false @sc.active
  end

  def test_cancel_clears_matches
    @sc.toggle
    @sc.instance_variable_set(:@matches, [[0, 0, 3]])
    @sc.cancel
    assert_equal [], @sc.matches
  end

  def test_append_query
    @sc.append_query("fo")
    @sc.append_query("o")
    assert_equal "foo", @sc.query
  end

  def test_backspace_query
    @sc.append_query("foo")
    @sc.backspace_query
    assert_equal "fo", @sc.query
  end

  def test_toggle_regex
    assert_false @sc.regex_mode
    @sc.toggle_regex
    assert_true @sc.regex_mode
    @sc.toggle_regex
    assert_false @sc.regex_mode
  end

  def test_toggle_case_insensitive
    assert_false @sc.case_insensitive
    @sc.toggle_case_insensitive
    assert_true @sc.case_insensitive
  end

  # --- searching ---

  def make_row(chars)
    chars.chars.map { |c| Echoes::Cell.new(c) }
  end

  def make_screen(rows_text)
    screen = Object.new
    grid = rows_text.map { |text| make_row(text) }
    screen.define_singleton_method(:scrollback) { [] }
    screen.define_singleton_method(:grid) { grid }
    screen
  end

  def test_perform_finds_literal_match
    screen = make_screen(["hello world", "foo bar"])
    @sc.append_query("foo")
    @sc.perform(screen)
    assert_equal 1, @sc.matches.size
    assert_equal [1, 0, 3], @sc.matches.first
  end

  def test_perform_finds_multiple_matches
    screen = make_screen(["abab"])
    @sc.append_query("ab")
    @sc.perform(screen)
    assert_equal 2, @sc.matches.size
  end

  def test_perform_empty_query_clears_matches
    screen = make_screen(["hello"])
    @sc.append_query("hello")
    @sc.perform(screen)
    assert_equal 1, @sc.matches.size

    @sc.backspace_query while @sc.query.length > 0
    @sc.perform(screen)
    assert_equal 0, @sc.matches.size
  end

  def test_perform_case_sensitive_by_default
    screen = make_screen(["Hello"])
    @sc.append_query("hello")
    @sc.perform(screen)
    assert_equal 0, @sc.matches.size
  end

  def test_perform_case_insensitive
    screen = make_screen(["Hello"])
    @sc.toggle_case_insensitive
    @sc.append_query("hello")
    @sc.perform(screen)
    assert_equal 1, @sc.matches.size
  end

  def test_perform_regex_mode
    screen = make_screen(["abc123"])
    @sc.toggle_regex
    @sc.append_query('\d+')
    @sc.perform(screen)
    assert_equal 1, @sc.matches.size
    _, col, len = @sc.matches.first
    assert_equal 3, col
    assert_equal 3, len
  end

  def test_perform_invalid_regex_returns_no_matches
    screen = make_screen(["abc"])
    @sc.toggle_regex
    @sc.append_query('[invalid')
    @sc.perform(screen)
    assert_equal 0, @sc.matches.size
  end

  def test_perform_zero_width_regex_does_not_hang
    # \b is zero-width; without the guard this loops forever
    screen = make_screen(["hello world"])
    @sc.toggle_regex
    @sc.append_query('\b')
    # Must complete within 2 seconds
    completed = false
    t = Thread.new { @sc.perform(screen); completed = true }
    t.join(2)
    assert_true completed, "perform hung on zero-width regex"
  end

  def test_perform_handles_nil_cells
    row = [nil, Echoes::Cell.new("a"), nil]
    screen = Object.new
    screen.define_singleton_method(:scrollback) { [] }
    screen.define_singleton_method(:grid) { [row] }
    @sc.append_query("a")
    assert_nothing_raised { @sc.perform(screen) }
    assert_equal 1, @sc.matches.size
  end

  # --- navigation ---

  def test_next_match_returns_false_when_no_matches
    assert_false @sc.next_match
  end

  def test_prev_match_returns_false_when_no_matches
    assert_false @sc.prev_match
  end

  def test_next_match_cycles_forward
    screen = make_screen(["aaa"])
    @sc.append_query("a")
    @sc.perform(screen)
    assert_equal 2, @sc.index  # perform sets to last match
    @sc.next_match
    assert_equal 0, @sc.index
    @sc.next_match
    assert_equal 1, @sc.index
  end

  def test_prev_match_cycles_backward
    screen = make_screen(["aaa"])
    @sc.append_query("a")
    @sc.perform(screen)  # index = 2 (last)
    @sc.prev_match
    assert_equal 1, @sc.index
  end

  def test_next_match_returns_true_when_matches_exist
    screen = make_screen(["abc"])
    @sc.append_query("a")
    @sc.perform(screen)
    assert_true @sc.next_match
  end

  # --- match queries ---

  def test_match_at_returns_true_for_covered_col
    screen = make_screen(["foobar"])
    @sc.append_query("foo")
    @sc.perform(screen)
    assert_true @sc.match_at?(0, 0)
    assert_true @sc.match_at?(0, 1)
    assert_true @sc.match_at?(0, 2)
    assert_false @sc.match_at?(0, 3)
  end

  def test_current_match_at_targets_only_current_index
    screen = make_screen(["abab"])
    @sc.append_query("ab")
    @sc.perform(screen)  # index=1 (last)
    assert_false @sc.current_match_at?(0, 0)  # first match, not current
    assert_true @sc.current_match_at?(0, 2)   # second match, is current
  end

  def test_current_match_row_nil_when_no_matches
    assert_nil @sc.current_match_row
  end

  def test_current_match_row_returns_abs_row
    screen = make_screen(["hello", "world"])
    @sc.append_query("world")
    @sc.perform(screen)
    assert_equal 1, @sc.current_match_row
  end
end
```

- [ ] **Step 2: Run — must fail with "cannot load such file"**

```bash
bundle exec ruby -Ilib:test test/echoes/gui_search_controller_test.rb
```

Expected: `LoadError: cannot load such file -- echoes/gui/search_controller`

- [ ] **Step 3: Create lib/echoes/gui/search_controller.rb**

```ruby
# frozen_string_literal: true

module Echoes
  module GUI
    class SearchController
      attr_reader :active, :query, :matches, :index, :case_insensitive, :regex_mode

      def initialize
        @active = false
        @query = +""
        @matches = []
        @index = -1
        @case_insensitive = false
        @regex_mode = false
      end

      def toggle
        @active = !@active
        if @active
          @query = +""
          @matches = []
          @index = -1
        end
        self
      end

      def cancel
        @active = false
        @matches = []
        self
      end

      def append_query(chars)
        @query << chars
        self
      end

      def backspace_query
        @query.chop!
        self
      end

      def toggle_regex
        @regex_mode = !@regex_mode
        self
      end

      def toggle_case_insensitive
        @case_insensitive = !@case_insensitive
        self
      end

      # Returns true if there are matches to navigate, false otherwise.
      def next_match
        return false if @matches.empty?
        @index = (@index + 1) % @matches.size
        true
      end

      # Returns true if there are matches to navigate, false otherwise.
      def prev_match
        return false if @matches.empty?
        @index = (@index - 1) % @matches.size
        true
      end

      # Scans the given screen and populates matches. Does not scroll.
      def perform(screen)
        @matches = []
        @index = -1
        return if @query.empty?

        matcher = build_matcher(@query)
        return unless matcher

        screen.scrollback.each_with_index { |row, abs_row| scan_row(row, abs_row, matcher) }
        screen.grid.each_with_index { |row, i| scan_row(row, screen.scrollback.size + i, matcher) }
        @index = @matches.size - 1 if @matches.any?
      end

      # Returns true if any match covers (abs_row, col).
      def match_at?(abs_row, col)
        @matches.any? { |r, c, len| r == abs_row && col >= c && col < c + len }
      end

      # Returns true if the *current* match covers (abs_row, col).
      def current_match_at?(abs_row, col)
        return false if @index < 0 || @index >= @matches.size
        r, c, len = @matches[@index]
        r == abs_row && col >= c && col < c + len
      end

      # Returns the absolute screen row of the current match, or nil.
      def current_match_row
        return nil if @index < 0 || @index >= @matches.size
        @matches[@index][0]
      end

      # Return a plain Hash for serialization (e.g. multi-window state save).
      def to_h
        { active: @active, query: @query, matches: @matches, index: @index,
          case_insensitive: @case_insensitive, regex_mode: @regex_mode }
      end

      # Restore from a Hash produced by #to_h.
      def self.from_h(h)
        sc = new
        sc.instance_variable_set(:@active, h[:active])
        sc.instance_variable_set(:@query, +(h[:query] || ""))
        sc.instance_variable_set(:@matches, h[:matches] || [])
        sc.instance_variable_set(:@index, h[:index] || -1)
        sc.instance_variable_set(:@case_insensitive, h[:case_insensitive])
        sc.instance_variable_set(:@regex_mode, h[:regex_mode])
        sc
      end

      private

      def scan_row(row, abs_row, matcher)
        # nil-safe cell reading (handles sparse/nil cells)
        text = row.map { |cell| cell&.char.to_s }.join
        pos = 0
        while pos <= text.length && (hit = matcher.call(text, pos))
          idx, len = hit
          # Guard against zero-width matches (e.g. \b, ^, $, lookaheads)
          # spinning forever: bail if match didn't advance, force step of 1.
          break if idx < pos
          step = [len, 1].max
          @matches << [abs_row, idx, step]
          pos = idx + step
        end
      end

      def build_matcher(query)
        if @regex_mode
          flags = @case_insensitive ? Regexp::IGNORECASE : 0
          re = Regexp.new(query, flags) rescue nil
          return nil unless re
          ->(text, pos) {
            m = re.match(text, pos)
            m && [m.begin(0), m.end(0) - m.begin(0)]
          }
        elsif @case_insensitive
          needle = query.downcase
          len = needle.length
          ->(text, pos) {
            idx = text.downcase.index(needle, pos)
            idx && [idx, len]
          }
        else
          len = query.length
          ->(text, pos) {
            idx = text.index(query, pos)
            idx && [idx, len]
          }
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run — must pass**

```bash
bundle exec ruby -Ilib:test test/echoes/gui_search_controller_test.rb
```

Expected: all tests pass, 0 failures.

- [ ] **Step 5: Wire delegation in gui_win32/core.rb**

Add near top of `lib/echoes/gui_win32/core.rb`:

```ruby
require_relative "../gui/search_controller"
```

In `initialize`, replace the six `@search_*` instance variable assignments:

```ruby
      @search_mode = false
      @search_query = +""
      @search_matches = []
      @search_index = -1
      @search_regex_mode = false
      @search_case_insensitive = false
```

with:

```ruby
      @search = Echoes::GUI::SearchController.new
```

In the WndProc WM_CHAR section, replace:

```ruby
            if utf8_char && @search_mode
              handle_search_char(utf8_char)
```

with:

```ruby
            if utf8_char && @search.active
              handle_search_char(utf8_char)
```

In the WndProc WM_KEYDOWN section, replace:

```ruby
          if @search_mode && handle_search_keydown(vk, ctrl_pressed: ctrl_pressed, shift_pressed: shift_pressed)
```

with:

```ruby
          if @search.active && handle_search_keydown(vk, ctrl_pressed: ctrl_pressed, shift_pressed: shift_pressed)
```

- [ ] **Step 6: Replace gui_win32/search.rb with delegation**

Replace the entire contents of `lib/echoes/gui_win32/search.rb` with:

```ruby
# frozen_string_literal: true

module Echoes
  class GUI
    # All search logic lives in GUI::SearchController.
    # This file wires the Win32 key/char events into the shared controller
    # and performs the platform-specific scroll after a search.

    private

    private def toggle_search
      @search.toggle
      true
    end

    private def handle_search_char(chars)
      return false if chars.nil? || chars.empty?
      @search.append_query(chars)
      @search.perform(current_tab&.screen || return(false))
      scroll_to_search_match
      true
    end

    private def handle_search_keydown(vk, ctrl_pressed:, shift_pressed:)
      case vk
      when 0x1B  # Escape
        @search.cancel
        true
      when 0x0D  # Enter
        if shift_pressed
          @search.prev_match
        else
          @search.next_match
        end
        scroll_to_search_match
        true
      when 0x08  # Backspace
        @search.backspace_query
        @search.perform(current_tab&.screen || return(false))
        scroll_to_search_match
        true
      when 0x21  # Page Up
        @search.prev_match
        scroll_to_search_match
        true
      when 0x22  # Page Down
        @search.next_match
        scroll_to_search_match
        true
      when 0x4E  # N
        return false unless ctrl_pressed
        @search.next_match
        scroll_to_search_match
        true
      when 0x50  # P
        return false unless ctrl_pressed
        @search.prev_match
        scroll_to_search_match
        true
      when 0x49  # I
        return false unless ctrl_pressed
        @search.toggle_case_insensitive
        @search.perform(current_tab&.screen || return(false))
        scroll_to_search_match
        true
      when 0x52  # R
        return false unless ctrl_pressed
        @search.toggle_regex
        @search.perform(current_tab&.screen || return(false))
        scroll_to_search_match
        true
      else
        false
      end
    end

    private def perform_search
      tab = current_tab
      return unless tab
      @search.perform(tab.screen)
      scroll_to_search_match
    end

    private def scroll_to_search_match
      abs_row = @search.current_match_row
      return unless abs_row
      tab = current_tab
      return unless tab
      scrollback_size = tab.screen.scrollback.size
      scroll_target = tab.respond_to?(:scroll_offset=) ? tab : tab.active_pane
      if abs_row < scrollback_size
        scroll_target.scroll_offset = (scrollback_size - abs_row - (@rows / 2)).clamp(0, scrollback_size)
      else
        scroll_target.scroll_offset = 0
      end
    end

    private def scan_row_for_matches(row, abs_row, matcher)
      @search.send(:scan_row, row, abs_row, matcher)
    end

    private def search_next
      @search.next_match.tap { scroll_to_search_match }
    end

    private def search_prev
      @search.prev_match.tap { scroll_to_search_match }
    end

    private def search_match_at?(abs_row, col)
      @search.match_at?(abs_row, col)
    end

    private def current_search_match_at?(abs_row, col)
      @search.current_match_at?(abs_row, col)
    end

    private def build_search_matcher(query)
      @search.send(:build_matcher, query)
    end

    private def selected_text_from_buffer(sr, sc, er, ec)
      screen = current_tab.screen
      scrollback = screen.scrollback
      lines = []
      (sr..er).each do |abs_row|
        row = if abs_row < scrollback.size
                scrollback[abs_row]
              else
                screen.grid[abs_row - scrollback.size]
              end
        next unless row
        from = (abs_row == sr) ? sc : 0
        to   = (abs_row == er) ? ec : @cols - 1
        chars = row[from..to].reject { |c| c.width == 0 || c.multicell == :cont }.map(&:char)
        lines << chars.join.rstrip
      end
      lines.join("\n")
    end
  end
end
```

- [ ] **Step 7: Fix @search_mode in gui_win32/rendering_capture_and_tab.rb**

In `lib/echoes/gui_win32/rendering_capture_and_tab.rb`, find:

```ruby
      return nil unless is_active && @search_mode
```

Replace with:

```ruby
      return nil unless is_active && @search.active
```

- [ ] **Step 8: Wire delegation in gui.rb (macOS)**

Add near the top of `lib/echoes/gui.rb` (after existing requires):

```ruby
require_relative "gui/search_controller"
```

In `initialize`, replace the six `@search_*` variable assignments:

```ruby
      @search_mode = false
      @search_query = +""
      @search_matches = []
      @search_index = -1
      @search_regex_mode = false
      @search_case_insensitive = false
```

with:

```ruby
      @search = GUI::SearchController.new
```

In `save_window_state`, replace:

```ruby
      ws[:search_mode] = @search_mode
      ws[:search_query] = @search_query
      ws[:search_matches] = @search_matches
      ws[:search_index] = @search_index
```

with:

```ruby
      ws[:search] = @search
```

In `load_window_state`, replace:

```ruby
      @search_mode = ws[:search_mode]
      @search_query = ws[:search_query]
      @search_matches = ws[:search_matches]
      @search_index = ws[:search_index]
```

with:

```ruby
      @search = ws[:search] || GUI::SearchController.new
```

Replace the body of `toggle_search`:

```ruby
    def toggle_search
      @search_mode = !@search_mode
      if @search_mode
        @search_query = +""
        @search_matches = []
        @search_index = -1
      end
    end
```

with:

```ruby
    def toggle_search
      @search.toggle
    end
```

Replace the body of `perform_search`:

```ruby
    def perform_search
      @search_matches = []
      @search_index = -1
      return if @search_query.empty?
      tab = current_tab
      return unless tab
      screen = tab.screen
      matcher = build_search_matcher(@search_query)
      return unless matcher
      screen.scrollback.each_with_index do |row, abs_row|
        scan_row_for_matches(row, abs_row, matcher)
      end
      screen.grid.each_with_index do |row, grid_row|
        scan_row_for_matches(row, screen.scrollback.size + grid_row, matcher)
      end
      @search_index = @search_matches.size - 1 if @search_matches.any?
      scroll_to_match if @search_index >= 0
    end
```

with:

```ruby
    def perform_search
      tab = current_tab
      return unless tab
      @search.perform(tab.screen)
      scroll_to_match
    end
```

Replace the body of `build_search_matcher`:

```ruby
    def build_search_matcher(query)
      # ... (entire method body)
    end
```

with:

```ruby
    def build_search_matcher(query)
      @search.send(:build_matcher, query)
    end
```

Replace the body of `scan_row_for_matches`:

```ruby
    def scan_row_for_matches(row, abs_row, matcher)
      text = row.map(&:char).join
      # ... (entire method body)
    end
```

with:

```ruby
    def scan_row_for_matches(row, abs_row, matcher)
      @search.send(:scan_row, row, abs_row, matcher)
    end
```

Replace the body of `search_next`:

```ruby
    def search_next
      return if @search_matches.empty?
      @search_index = (@search_index + 1) % @search_matches.size
      scroll_to_match
    end
```

with:

```ruby
    def search_next
      @search.next_match
      scroll_to_match
    end
```

Replace the body of `search_prev`:

```ruby
    def search_prev
      return if @search_matches.empty?
      @search_index = (@search_index - 1) % @search_matches.size
      scroll_to_match
    end
```

with:

```ruby
    def search_prev
      @search.prev_match
      scroll_to_match
    end
```

Replace the body of `scroll_to_match`:

```ruby
    def scroll_to_match
      abs_row, = @search_matches[@search_index]
      tab = current_tab
      scrollback_size = tab.screen.scrollback.size
      if abs_row < scrollback_size
        tab.scroll_offset = scrollback_size - abs_row - (@rows / 2)
        tab.scroll_offset = tab.scroll_offset.clamp(0, scrollback_size)
      else
        tab.scroll_offset = 0
      end
    end
```

with:

```ruby
    def scroll_to_match
      abs_row = @search.current_match_row
      return unless abs_row
      tab = current_tab
      return unless tab
      scrollback_size = tab.screen.scrollback.size
      if abs_row < scrollback_size
        tab.scroll_offset = (scrollback_size - abs_row - (@rows / 2)).clamp(0, scrollback_size)
      else
        tab.scroll_offset = 0
      end
    end
```

Replace the body of `search_match_at?`:

```ruby
    def search_match_at?(abs_row, col)
      @search_matches.any? { |r, c, len| r == abs_row && col >= c && col < c + len }
    end
```

with:

```ruby
    def search_match_at?(abs_row, col)
      @search.match_at?(abs_row, col)
    end
```

Replace the body of `current_search_match_at?`:

```ruby
    def current_search_match_at?(abs_row, col)
      return false if @search_index < 0 || @search_index >= @search_matches.size
      r, c, len = @search_matches[@search_index]
      r == abs_row && col >= c && col < c + len
    end
```

with:

```ruby
    def current_search_match_at?(abs_row, col)
      @search.current_match_at?(abs_row, col)
    end
```

Replace all remaining `@search_mode` references in `gui.rb` with `@search.active`. Use grep to find them:

```bash
grep -n "@search_mode" lib/echoes/gui.rb
```

For each occurrence, replace `@search_mode` with `@search.active`. Common locations:
- `key_down` method: `if @search_mode` → `if @search.active`
- `draw_rect` / `draw_pane_content` / draw methods: `@search_mode &&` → `@search.active &&`
- Menu closures (setup_menu_bar area, lines ~752-758): `@search_mode` → `@search.active`
- `open_new_window` (line ~2168): replace the 6-line block with `@search = GUI::SearchController.new`

Replace all remaining `@search_query`, `@search_matches`, `@search_index`, `@search_regex_mode`, `@search_case_insensitive` references in `gui.rb`:

```bash
grep -n "@search_query\|@search_matches\|@search_index\|@search_regex_mode\|@search_case_insensitive" lib/echoes/gui.rb
```

The main occurrences are in `search_key_down` and draw methods. Replace with the corresponding reader:
- `@search_query` → `@search.query`
- `@search_matches` → `@search.matches`
- `@search_index` → `@search.index`
- `@search_regex_mode` → `@search.regex_mode`
- `@search_case_insensitive` → `@search.case_insensitive`

In `search_key_down`, replace assignments like `@search_mode = false` / `@search_matches = []` with controller method calls:
- `@search_mode = false; @search_matches = []` → `@search.cancel`
- `@search_query.chop!; perform_search` → `@search.backspace_query; perform_search`
- `@search_regex_mode = !@search_regex_mode; perform_search` → `@search.toggle_regex; perform_search`
- `@search_case_insensitive = !@search_case_insensitive; perform_search` → `@search.toggle_case_insensitive; perform_search`
- In the `else` branch where chars are appended: `@search_query << chars; perform_search` → `@search.append_query(chars); perform_search`

- [ ] **Step 9: Run full test suite — must stay green**

```bash
bundle exec rake test
```

Expected: same count as before, 0 failures.

- [ ] **Step 10: Commit**

```bash
git add lib/echoes/gui/search_controller.rb \
        test/echoes/gui_search_controller_test.rb \
        lib/echoes/gui.rb \
        lib/echoes/gui_win32/core.rb \
        lib/echoes/gui_win32/search.rb \
        lib/echoes/gui_win32/rendering_capture_and_tab.rb
git commit -m "refactor: extract GUI::SearchController shared class

Removes ~60 lines of duplicated search logic from gui.rb and
gui_win32/search.rb. The shared controller fixes two drift bugs
that existed only in Windows: the zero-width-regex infinite-loop
guard (present in macOS, missing in Windows), and the missing nil
guard in scroll_to_match. Also unifies the return-value API of
search_next/prev to bool on both platforms."
```

---

## Task 3: Extract GUI::Layout

**Why:** `tab_bar_height`, `grid_y_offset`, `tab_bar_y`, and the rows/cols calculation inside `handle_resize` / `handle_window_resize_pixels` are duplicated between both GUIs. Extracting to stateless module functions makes them testable and eliminates duplication. Windows currently lacks `grid_y_offset` (no bottom tab support); the shared version handles it but Windows simply always passes `:top`.

**Files:**
- Create: `lib/echoes/gui/layout.rb`
- Create: `test/echoes/gui_layout_test.rb`
- Modify: `lib/echoes/gui.rb` — delegate `tab_bar_height`, `grid_y_offset`, `tab_bar_y`; simplify `handle_resize`
- Modify: `lib/echoes/gui_win32/core.rb` — delegate `tab_bar_height`, `tab_bar_y`
- Modify: `lib/echoes/gui_win32/rendering_primitives.rb` — delegate rows/cols calculation

- [ ] **Step 1: Write the failing tests**

Create `test/echoes/gui_layout_test.rb`:

```ruby
# frozen_string_literal: true

require "test_helper"
require "echoes/gui/layout"

class GuiLayoutTest < Test::Unit::TestCase
  include Echoes::GUI::Layout

  CELL_W = 8.0
  CELL_H = 16.0

  # tab_bar_height
  def test_tab_bar_height_zero_when_one_tab
    assert_equal 0.0, tab_bar_height(1, CELL_H)
  end

  def test_tab_bar_height_zero_when_zero_tabs
    assert_equal 0.0, tab_bar_height(0, CELL_H)
  end

  def test_tab_bar_height_one_cell_when_multiple_tabs
    assert_equal CELL_H, tab_bar_height(2, CELL_H)
    assert_equal CELL_H, tab_bar_height(5, CELL_H)
  end

  # grid_y_offset
  def test_grid_y_offset_zero_when_tab_bar_bottom
    assert_equal 0.0, grid_y_offset(:bottom, CELL_H)
  end

  def test_grid_y_offset_equals_tab_bar_height_when_top
    tbh = CELL_H
    assert_equal tbh, grid_y_offset(:top, tbh)
  end

  def test_grid_y_offset_zero_when_no_tab_bar
    assert_equal 0.0, grid_y_offset(:top, 0.0)
  end

  # tab_bar_y
  def test_tab_bar_y_zero_when_top
    assert_equal 0.0, tab_bar_y(:top, CELL_H, 24)
  end

  def test_tab_bar_y_at_bottom_of_grid
    assert_equal CELL_H * 24, tab_bar_y(:bottom, CELL_H, 24)
  end

  # rows_cols_for
  def test_rows_cols_basic
    rows, cols = rows_cols_for(800.0, 400.0, CELL_W, CELL_H, 0.0)
    assert_equal 25, rows   # 400 / 16
    assert_equal 100, cols  # 800 / 8
  end

  def test_rows_cols_accounts_for_tab_bar
    rows, cols = rows_cols_for(800.0, 400.0, CELL_W, CELL_H, CELL_H)
    assert_equal 24, rows   # (400 - 16) / 16
    assert_equal 100, cols
  end

  def test_rows_cols_minimum_one
    rows, cols = rows_cols_for(1.0, 1.0, CELL_W, CELL_H, 0.0)
    assert_equal 1, rows
    assert_equal 1, cols
  end

  def test_rows_cols_fractional_cell_size
    # 801 / 8.0 = 100.125 -> 100
    rows, cols = rows_cols_for(801.0, 400.0, CELL_W, CELL_H, 0.0)
    assert_equal 100, cols
  end
end
```

- [ ] **Step 2: Run — must fail with "cannot load such file"**

```bash
bundle exec ruby -Ilib:test test/echoes/gui_layout_test.rb
```

Expected: `LoadError: cannot load such file -- echoes/gui/layout`

- [ ] **Step 3: Create lib/echoes/gui/layout.rb**

```ruby
# frozen_string_literal: true

module Echoes
  module GUI
    module Layout
      module_function

      # Height in pixels of the tab bar. Returns cell_height when more than
      # one tab is open; 0.0 otherwise (single-tab mode hides the bar).
      def tab_bar_height(tabs_count, cell_height)
        tabs_count > 1 ? cell_height : 0.0
      end

      # Vertical offset of the grid content area from the window top.
      # Zero when the tab bar is at the bottom; tab_bar_height when at the top.
      def grid_y_offset(tab_position, tab_bar_height)
        tab_position == :bottom ? 0.0 : tab_bar_height
      end

      # Y coordinate of the tab bar's top edge, measured from the window top.
      def tab_bar_y(tab_position, cell_height, rows)
        tab_position == :bottom ? cell_height * rows : 0.0
      end

      # Calculate the grid dimensions (rows, cols) for a given window size.
      # Returns [rows, cols], each clamped to a minimum of 1.
      def rows_cols_for(width, height, cell_width, cell_height, tab_bar_height)
        grid_height = height - tab_bar_height
        cols = [(width / cell_width).to_i, 1].max
        rows = [(grid_height / cell_height).to_i, 1].max
        [rows, cols]
      end
    end
  end
end
```

- [ ] **Step 4: Run — must pass**

```bash
bundle exec ruby -Ilib:test test/echoes/gui_layout_test.rb
```

Expected: all tests pass, 0 failures.

- [ ] **Step 5: Wire delegation in gui_win32/core.rb**

Add near top of `lib/echoes/gui_win32/core.rb`:

```ruby
require_relative "../gui/layout"
```

And add inside the class body (near other `include`/`extend` lines, or just before `initialize`):

```ruby
    include Echoes::GUI::Layout
```

Find and remove the existing `tab_bar_height` and `tab_bar_y` methods in `gui_win32/core.rb`:

```ruby
    def tab_bar_height
      return 0.0 unless @cell_height
      @tabs.size > 1 ? @cell_height : 0.0
    end

    def tab_bar_y
      0.0
    end
```

Replace with delegator methods that call the module function with the instance context:

```ruby
    def tab_bar_height
      return 0.0 unless @cell_height
      Layout.tab_bar_height(@tabs.size, @cell_height)
    end

    def tab_bar_y
      Layout.tab_bar_y(:top, @cell_height, @rows)
    end
```

(Windows does not yet support bottom tab position; `:top` is always correct here.)

- [ ] **Step 6: Wire delegation in gui_win32/rendering_primitives.rb**

Add near top of `lib/echoes/gui_win32/rendering_primitives.rb`:

```ruby
require_relative "../gui/layout"
```

Find `handle_window_resize_pixels` (around line 203). Replace the rows/cols calculation:

```ruby
      cols = (width / @cell_width).to_i
      tbh = tab_bar_height.to_i
      available_height = tbh > 0 ? height - tbh : height
      rows = (available_height / @cell_height).to_i
      ...
      return false if cols <= 0 || rows <= 0
      return false if cols == @cols && rows == @rows
      @cols = cols
      @rows = rows
```

with:

```ruby
      tbh = tab_bar_height
      rows, cols = Echoes::GUI::Layout.rows_cols_for(width.to_f, height.to_f, @cell_width, @cell_height, tbh)
      return false if cols == @cols && rows == @rows
      @cols = cols
      @rows = rows
```

- [ ] **Step 7: Wire delegation in gui.rb (macOS)**

Add near the top of `lib/echoes/gui.rb`:

```ruby
require_relative "gui/layout"
```

Add inside the `class GUI` body:

```ruby
    include GUI::Layout
```

Replace the `tab_bar_height` method body:

```ruby
    def tab_bar_height
      @tabs.size > 1 ? @cell_height : 0.0
    end
```

with:

```ruby
    def tab_bar_height
      GUI::Layout.tab_bar_height(@tabs.size, @cell_height)
    end
```

Replace `grid_y_offset`:

```ruby
    def grid_y_offset
      Echoes.config.tab_position == :bottom ? 0.0 : tab_bar_height
    end
```

with:

```ruby
    def grid_y_offset
      GUI::Layout.grid_y_offset(Echoes.config.tab_position, tab_bar_height)
    end
```

Replace `tab_bar_y`:

```ruby
    def tab_bar_y
      Echoes.config.tab_position == :bottom ? @cell_height * @rows : 0.0
    end
```

with:

```ruby
    def tab_bar_y
      GUI::Layout.tab_bar_y(Echoes.config.tab_position, @cell_height, @rows)
    end
```

Replace the rows/cols calculation inside `handle_resize`:

```ruby
    def handle_resize(w, h)
      tbh = tab_bar_height
      grid_height = h - tbh

      new_cols = (w / @cell_width).to_i
      new_rows = (grid_height / @cell_height).to_i
      new_cols = 1 if new_cols < 1
      new_rows = 1 if new_rows < 1

      return if new_rows == @rows && new_cols == @cols

      @rows = new_rows
      @cols = new_cols
      @tabs.each { |tab| tab.resize(@rows, @cols) }
    end
```

with:

```ruby
    def handle_resize(w, h)
      new_rows, new_cols = GUI::Layout.rows_cols_for(w.to_f, h.to_f, @cell_width, @cell_height, tab_bar_height)
      return if new_rows == @rows && new_cols == @cols

      @rows = new_rows
      @cols = new_cols
      @tabs.each { |tab| tab.resize(@rows, @cols) }
    end
```

- [ ] **Step 8: Run full test suite — must stay green**

```bash
bundle exec rake test
```

Expected: same count as before, 0 failures.

- [ ] **Step 9: Commit**

```bash
git add lib/echoes/gui/layout.rb test/echoes/gui_layout_test.rb \
        lib/echoes/gui.rb \
        lib/echoes/gui_win32/core.rb \
        lib/echoes/gui_win32/rendering_primitives.rb
git commit -m "refactor: extract GUI::Layout shared module

Removes duplicated tab_bar_height / grid_y_offset / tab_bar_y and
the inline rows/cols arithmetic from both gui.rb and gui_win32.
The shared Layout module is stateless (module_function) and fully
unit-tested. Win32 handle_window_resize_pixels now uses
Layout.rows_cols_for, matching the same clamping logic as macOS."
```

---

## Self-Review Checklist (completed)

- **Spec coverage:** Phase 0 (merge master) ✅ · Osc7 ✅ · SearchController ✅ · Layout ✅ · Selection/KeyBindings noted out of scope for this plan (Phase 1b, future).
- **Placeholder scan:** All steps contain complete code. No TBDs.
- **Type consistency:** `SearchController#perform(screen)` used consistently. `Layout.rows_cols_for` signature `(width, height, cell_width, cell_height, tab_bar_height)` used consistently in tests and delegation steps.
- **macOS safety:** Every macOS change is a method-body replacement or variable rename — no new logic in gui.rb except removing nil-crash in scroll_to_match (which is a bug fix, safe regardless of platform).
