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
    assert_equal [2, 1, 2, 7], normalize_selection([2, 7], [2, 1])
  end

  def test_normalize_anchor_above_endpoint
    assert_equal [1, 3, 4, 6], normalize_selection([1, 3], [4, 6])
  end

  def test_normalize_anchor_below_endpoint
    assert_equal [1, 3, 4, 6], normalize_selection([4, 6], [1, 3])
  end

  def test_normalize_same_row_anchor_col_equal_to_endpoint
    assert_equal [5, 3, 5, 3], normalize_selection([5, 3], [5, 3])
  end

  # --- cell_in_range? ---

  def test_cell_in_range_single_row_selection
    assert_true  cell_in_range?(3, 2, 3, 2, 3, 5)
    assert_true  cell_in_range?(3, 5, 3, 2, 3, 5)
    assert_false cell_in_range?(3, 1, 3, 2, 3, 5)
    assert_false cell_in_range?(3, 6, 3, 2, 3, 5)
    assert_false cell_in_range?(2, 3, 3, 2, 3, 5)
    assert_false cell_in_range?(4, 3, 3, 2, 3, 5)
  end

  def test_cell_in_range_multi_row_start_row
    assert_true  cell_in_range?(2, 3,  2, 3, 5, 7)
    assert_true  cell_in_range?(2, 10, 2, 3, 5, 7)
    assert_false cell_in_range?(2, 2,  2, 3, 5, 7)
  end

  def test_cell_in_range_multi_row_end_row
    assert_true  cell_in_range?(5, 7, 2, 3, 5, 7)
    assert_true  cell_in_range?(5, 0, 2, 3, 5, 7)
    assert_false cell_in_range?(5, 8, 2, 3, 5, 7)
  end

  def test_cell_in_range_multi_row_middle_row
    assert_true cell_in_range?(3, 0,   2, 3, 5, 7)
    assert_true cell_in_range?(3, 100, 2, 3, 5, 7)
    assert_true cell_in_range?(4, 0,   2, 3, 5, 7)
  end

  def test_cell_in_range_row_outside_selection
    assert_false cell_in_range?(1, 5, 2, 3, 5, 7)
    assert_false cell_in_range?(6, 5, 2, 3, 5, 7)
  end
end
