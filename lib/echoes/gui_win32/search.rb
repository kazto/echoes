# frozen_string_literal: true

module Echoes
  class GUI
    private

    private def toggle_search
      @search_mode = !@search_mode
      if @search_mode
        @search_query = +""
        @search_matches = []
        @search_index = -1
      end
      true
    end

    private def handle_search_char(chars)
      return false if chars.nil? || chars.empty?

      @search_query << chars
      perform_search
      true
    end

    private def handle_search_keydown(vk, ctrl_pressed:, shift_pressed:)
      case vk
      when 0x1B
        @search_mode = false
        @search_matches = []
        true
      when 0x0D
        shift_pressed ? search_prev : search_next
        true
      when 0x08
        @search_query.chop!
        perform_search
        true
      when 0x21
        search_prev
        true
      when 0x22
        search_next
        true
      when 0x4E
        return false unless ctrl_pressed

        search_next
        true
      when 0x50
        return false unless ctrl_pressed

        search_prev
        true
      when 0x49
        return false unless ctrl_pressed

        @search_case_insensitive = !@search_case_insensitive
        perform_search
        true
      when 0x52
        return false unless ctrl_pressed

        @search_regex_mode = !@search_regex_mode
        perform_search
        true
      else
        false
      end
    end

    private def perform_search
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

    private def scan_row_for_matches(row, abs_row, matcher)
      text = row.map { |cell| cell&.char.to_s }.join
      pos = 0
      while pos <= text.length && (hit = matcher.call(text, pos))
        idx, len = hit
        break if idx < pos

        step = [len, 1].max
        @search_matches << [abs_row, idx, step]
        pos = idx + step
      end
    end

    private def search_next
      return false if @search_matches.empty?

      @search_index = (@search_index + 1) % @search_matches.size
      scroll_to_match
      true
    end

    private def search_prev
      return false if @search_matches.empty?

      @search_index = (@search_index - 1) % @search_matches.size
      scroll_to_match
      true
    end

    private def scroll_to_match
      return false if @search_index < 0 || @search_index >= @search_matches.size

      abs_row, = @search_matches[@search_index]
      tab = current_tab
      return false unless tab

      scrollback_size = tab.screen.scrollback.size
      scroll_target = tab.respond_to?(:scroll_offset=) ? tab : tab.active_pane
      if abs_row < scrollback_size
        scroll_target.scroll_offset = (scrollback_size - abs_row - (@rows / 2)).clamp(0, scrollback_size)
      else
        scroll_target.scroll_offset = 0
      end
      true
    end

    private def search_match_at?(abs_row, col)
      @search_matches.any? { |row, start, len| row == abs_row && col >= start && col < start + len }
    end

    private def current_search_match_at?(abs_row, col)
      return false if @search_index < 0 || @search_index >= @search_matches.size

      row, start, len = @search_matches[@search_index]
      row == abs_row && col >= start && col < start + len
    end

    private def build_search_matcher(query)
      if @search_regex_mode
        flags = @search_case_insensitive ? Regexp::IGNORECASE : 0
        re = Regexp.new(query, flags) rescue nil
        return nil unless re
        ->(text, pos) {
          m = re.match(text, pos)
          m && [m.begin(0), m.end(0) - m.begin(0)]
        }
      elsif @search_case_insensitive
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
        to = (abs_row == er) ? ec : @cols - 1
        chars = row[from..to].reject { |c| c.width == 0 || c.multicell == :cont }.map(&:char)
        lines << chars.join.rstrip
      end
      lines.join("\n")
    end
  end
end
