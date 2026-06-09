# frozen_string_literal: true

require "test_helper"
require "echoes/gui/layout"

class GuiLayoutTest < Test::Unit::TestCase
  include Echoes::GUI::Layout

  CELL_W = 8.0
  CELL_H = 16.0

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

  def test_grid_y_offset_zero_when_tab_bar_bottom
    assert_equal 0.0, grid_y_offset(:bottom, CELL_H)
  end

  def test_grid_y_offset_equals_tab_bar_height_when_top
    assert_equal CELL_H, grid_y_offset(:top, CELL_H)
  end

  def test_grid_y_offset_zero_when_no_tab_bar
    assert_equal 0.0, grid_y_offset(:top, 0.0)
  end

  def test_tab_bar_y_zero_when_top
    assert_equal 0.0, tab_bar_y(:top, CELL_H, 24)
  end

  def test_tab_bar_y_at_bottom_of_grid
    assert_equal CELL_H * 24, tab_bar_y(:bottom, CELL_H, 24)
  end

  def test_rows_cols_basic
    rows, cols = rows_cols_for(800.0, 400.0, CELL_W, CELL_H, 0.0)
    assert_equal 25, rows
    assert_equal 100, cols
  end

  def test_rows_cols_accounts_for_tab_bar
    rows, cols = rows_cols_for(800.0, 400.0, CELL_W, CELL_H, CELL_H)
    assert_equal 24, rows
    assert_equal 100, cols
  end

  def test_rows_cols_minimum_one
    rows, cols = rows_cols_for(1.0, 1.0, CELL_W, CELL_H, 0.0)
    assert_equal 1, rows
    assert_equal 1, cols
  end

  def test_rows_cols_fractional_cell_size
    rows, cols = rows_cols_for(801.0, 400.0, CELL_W, CELL_H, 0.0)
    assert_equal 100, cols
  end
end
