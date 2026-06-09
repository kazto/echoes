# frozen_string_literal: true

module Echoes
  # Thin platform-agnostic orchestrator. Owns no native state itself;
  # delegates run() to the platform backend selected by Platform.gui_backend.
  class GUI
    extend GUI::Osc7

    def initialize(command: Echoes.config.shell, rows: Echoes.config.rows, cols: Echoes.config.cols, font_size: nil)
      @backend = Platform.gui_backend.new(
        command: command, rows: rows, cols: cols, font_size: font_size
      )
    end

    def run
      @backend.run
    end

    def select_tab(n)
      target = (n == 9) ? @tabs.size - 1 : n - 1
      return false if target < 0 || target >= @tabs.size
      return false if target == @active_tab

      @active_tab = target
      true
    end

    def compute_drop_index(x, tab_w, num_tabs)
      return 0 if num_tabs <= 0 || tab_w <= 0

      ((x + tab_w / 2.0) / tab_w).to_i.clamp(0, num_tabs)
    end

    def transfer_tab(src_ws, src_index, dst_ws, dst_index)
      same = src_ws.equal?(dst_ws)
      return false if same && (dst_index == src_index || dst_index == src_index + 1)

      src_tabs = src_ws[:tabs]
      return false if src_index < 0 || src_index >= src_tabs.size

      tab = src_tabs.delete_at(src_index)
      dst_index -= 1 if same && src_index < dst_index

      dst_tabs = dst_ws[:tabs]
      dst_index = dst_index.clamp(0, dst_tabs.size)
      dst_tabs.insert(dst_index, tab)

      dst_ws[:active_tab] = dst_index
      src_ws[:active_tab] = src_ws[:active_tab].clamp(0, [src_tabs.size - 1, 0].max) unless same
      true
    end

    def encode_tab_drag_token(view_ptr, tab_index)
      "#{view_ptr}:#{tab_index}"
    end

    def decode_tab_drag_token(str)
      return nil if str.nil? || str.empty?

      parts = str.split(':')
      return nil unless parts.size == 2

      vp = Integer(parts[0], 10) rescue nil
      ti = Integer(parts[1], 10) rescue nil
      return nil if vp.nil? || ti.nil? || ti < 0

      [vp, ti]
    end

    # capture_format_for exists on both platform backends; forward from the
    # thin orchestrator so callers using Echoes::GUI.capture_format_for still work.
    def self.capture_format_for(path)
      Platform.gui_backend.capture_format_for(path)
    end
  end
end
