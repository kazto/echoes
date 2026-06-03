# frozen_string_literal: true

require "test_helper"
require "echoes/gui/search_controller"
require "echoes/cell"

class GuiSearchControllerTest < Test::Unit::TestCase
  def setup
    @sc = Echoes::GUI::SearchController.new
  end

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
    screen = make_screen(["hello world"])
    @sc.toggle_regex
    @sc.append_query('\b')
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
    assert_equal 2, @sc.index
    @sc.next_match
    assert_equal 0, @sc.index
    @sc.next_match
    assert_equal 1, @sc.index
  end

  def test_prev_match_cycles_backward
    screen = make_screen(["aaa"])
    @sc.append_query("a")
    @sc.perform(screen)
    @sc.prev_match
    assert_equal 1, @sc.index
  end

  def test_next_match_returns_true_when_matches_exist
    screen = make_screen(["abc"])
    @sc.append_query("a")
    @sc.perform(screen)
    assert_true @sc.next_match
  end

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
    @sc.perform(screen)
    assert_false @sc.current_match_at?(0, 0)
    assert_true @sc.current_match_at?(0, 2)
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
