# frozen_string_literal: true

module Echoes
  class GUI
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
