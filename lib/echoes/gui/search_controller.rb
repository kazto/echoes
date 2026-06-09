# frozen_string_literal: true

module Echoes
  class GUI
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

      def next_match
        return false if @matches.empty?
        @index = (@index + 1) % @matches.size
        true
      end

      def prev_match
        return false if @matches.empty?
        @index = (@index - 1) % @matches.size
        true
      end

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

      def match_at?(abs_row, col)
        @matches.any? { |r, c, len| r == abs_row && col >= c && col < c + len }
      end

      def current_match_at?(abs_row, col)
        return false if @index < 0 || @index >= @matches.size
        r, c, len = @matches[@index]
        r == abs_row && col >= c && col < c + len
      end

      def current_match_row
        return nil if @index < 0 || @index >= @matches.size
        @matches[@index][0]
      end

      def to_h
        { active: @active, query: @query, matches: @matches, index: @index,
          case_insensitive: @case_insensitive, regex_mode: @regex_mode }
      end

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
        text = row.map { |cell| cell&.char.to_s }.join
        pos = 0
        while pos <= text.length && (hit = matcher.call(text, pos))
          idx, len = hit
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
