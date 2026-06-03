# frozen_string_literal: true

module Echoes
  class GUI
    private

    private def toggle_search
      @search.toggle
      true
    end

    private def handle_search_char(chars)
      return false if chars.nil? || chars.empty?
      screen = current_tab&.screen
      return false unless screen
      @search.append_query(chars)
      @search.perform(screen)
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
        screen = current_tab&.screen
        return false unless screen
        @search.backspace_query
        @search.perform(screen)
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
        screen = current_tab&.screen
        return false unless screen
        @search.toggle_case_insensitive
        @search.perform(screen)
        scroll_to_search_match
        true
      when 0x52  # R
        return false unless ctrl_pressed
        screen = current_tab&.screen
        return false unless screen
        @search.toggle_regex
        @search.perform(screen)
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
