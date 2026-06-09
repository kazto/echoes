# frozen_string_literal: true

module Echoes
  class GUI
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

