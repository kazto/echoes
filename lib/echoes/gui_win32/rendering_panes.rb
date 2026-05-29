# frozen_string_literal: true

module Echoes
  class GUI
    private

    private def wire_screen_handlers(pane)
      pane.screen.clipboard_handler = method(:handle_clipboard)
      pane.screen.glyph_measurer = method(:measure_glyph)
      pane.screen.capture_handler = ->(path) { capture_pane_to_png(pane, path) }
      pane.screen.display_info_handler = -> { display_info_json(pane) }
      pane.screen.open_window_handler = ->(args) { open_window_from_osc(pane, args) }
      pane.screen.notification_handler = ->(title, message) { post_notification(pane, title, message) }
      pane.screen.cell_pixel_width = @cell_width if @cell_width
      pane.screen.cell_pixel_height = @cell_height if @cell_height
      pane.refresh_pty_pixel_size if @cell_width && @cell_height
    end

    private def positive_env_integer(key, env = ENV)
      value = env[key]
      return nil if value.nil? || value.empty?

      integer = Integer(value, exception: false)
      integer if integer && integer.positive?
    end

    private def command_from_env(env = ENV)
      encoded = env['ECHOES_OPEN_WINDOW_PROGRAM']
      return nil if encoded.nil? || encoded.empty?

      decoded = encoded.delete("\r\n\t ").unpack1('m0')
      argv = JSON.parse(decoded)
      argv if argv.is_a?(Array) && !argv.empty?
    rescue StandardError
      nil
    end

    private def initial_window_rect_from_env(env = ENV)
      return explicit_window_rect_from_env(env) if window_rect_env?(env)

      saved_window_rect || default_window_rect
    end

    private def window_rect_env?(env = ENV)
      %w[ECHOES_WINDOW_X ECHOES_WINDOW_Y ECHOES_WINDOW_W ECHOES_WINDOW_H].any? { |key| env.key?(key) }
    end

    private def explicit_window_rect_from_env(env = ENV)
      {
        x: Integer(env.fetch('ECHOES_WINDOW_X', 100), exception: false) || 100,
        y: Integer(env.fetch('ECHOES_WINDOW_Y', 100), exception: false) || 100,
        w: positive_env_integer('ECHOES_WINDOW_W', env) || 800,
        h: positive_env_integer('ECHOES_WINDOW_H', env) || 600
      }
    end

    private def default_window_rect
      # Calculate window size based on desired rows/cols plus tab bar height
      # Estimate cell size before fonts are loaded
      estimated_cell_w = 8
      estimated_cell_h = 16
      tab_bar_h = estimated_cell_h + 4  # Always include tab bar

      client_w = (@cols || 80) * estimated_cell_w
      client_h = (@rows || 24) * estimated_cell_h + tab_bar_h

      # Add room for title bar, borders, and menu (approximate)
      window_w = client_w + 16
      window_h = client_h + 40

      {x: 100, y: 100, w: window_w, h: window_h}
    end

    WINDOW_RECT_PREFERENCE_KEYS = {
      x: :window_x,
      y: :window_y,
      w: :window_w,
      h: :window_h
    }.freeze

    private def saved_window_rect
      defaults = default_window_rect
      rect = WINDOW_RECT_PREFERENCE_KEYS.transform_values do |key|
        Preferences.fetch_double(key, default: nil)
      end
      return nil unless rect.values.all?

      normalized = rect.transform_values(&:to_i)
      return nil unless normalized[:w].positive? && normalized[:h].positive?

      defaults.merge(normalized)
    end

    private def save_window_rect
      return false unless @window_rect_autosave
      return false unless (rect = current_window_rect)

      WINDOW_RECT_PREFERENCE_KEYS.each do |field, key|
        Preferences.set_double(key, rect[field])
      end
      true
    end

    private def current_window_rect
      return nil unless Win32::GetWindowRect && @hwnd && !Win32.null_pointer?(@hwnd)

      rect = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
      rect[0, Win32::RECT_SIZE] = "\x00" * Win32::RECT_SIZE
      return nil if Win32::GetWindowRect.call(@hwnd, rect) == 0

      left, top, right, bottom = rect[0, Win32::RECT_SIZE].unpack('l4')
      width = right - left
      height = bottom - top
      return nil if width <= 0 || height <= 0

      {x: left, y: top, w: width, h: height}
    end

    private def post_notification(pane, title, message)
      effective_title = (title && !title.empty? && title) || pane&.title || Echoes.config.window_title

      # Attempt native notification
      if Win32.show_notification(@hwnd, effective_title, message)
        return
      end

      # Fallback to window title
      text = message.to_s.empty? ? effective_title.to_s : "#{effective_title} - #{message}"
      set_window_title(text)
    rescue StandardError => e
      warn "echoes notification: #{e.class}: #{e.message}"
    end

    private def display_info_json(_pane)
      current_handle = Win32.monitor_from_window(@hwnd)
      entries = Win32.display_monitors.each_with_index.map do |monitor, index|
        {
          "index" => index,
          "x" => monitor[:x],
          "y" => monitor[:y],
          "w" => monitor[:w],
          "h" => monitor[:h],
          "work_x" => monitor[:work_x],
          "work_y" => monitor[:work_y],
          "work_w" => monitor[:work_w],
          "work_h" => monitor[:work_h],
          "dpi_x" => monitor[:dpi_x] || Win32::DEFAULT_DPI.to_i,
          "dpi_y" => monitor[:dpi_y] || Win32::DEFAULT_DPI.to_i,
          "backing_scale_factor" => monitor[:scale] || 1.0,
          "primary" => !!monitor[:primary],
          "current" => current_handle && monitor[:handle] == current_handle
        }
      end
      JSON.generate(entries)
    rescue StandardError => e
      warn "echoes display-info: #{e.class}: #{e.message}"
      "[]"
    end

    private def open_window_from_osc(_pane, args_str)
      params = parse_open_window_args(args_str)
      program_b64 = params['program']
      return false if program_b64.nil? || program_b64.empty?

      argv = decode_open_window_argv(program_b64)
      return false unless argv

      open_external_window(
        argv: argv,
        display_index: (params['display'] || '0').to_i,
        fullscreen: params['fullscreen'] == 'yes'
      )
    rescue StandardError => e
      warn "echoes open-window: #{e.class}: #{e.message}"
      false
    end

    private def parse_open_window_args(args_str)
      params = {}
      args_str.to_s.split(':').each do |pair|
        key, value = pair.split('=', 2)
        next if key.nil? || key.empty? || value.nil?

        params[key] = value
      end
      params
    end

    private def decode_open_window_argv(program_b64)
      json = program_b64.delete("\r\n\t ").unpack1('m0')
      argv = JSON.parse(json)
      return nil unless argv.is_a?(Array) && !argv.empty?

      argv.map(&:to_s)
    rescue StandardError
      nil
    end

    private def open_external_window(argv:, display_index:, fullscreen:)
      monitor = Win32.display_monitors[display_index]
      monitor ||= Win32.display_monitors.first
      return false unless monitor

      rect = fullscreen ? monitor_rect(monitor) : monitor_work_rect(monitor)
      cell_w = @cell_width || 10
      cell_h = @cell_height || 20
      rows = [(rect[:h] / cell_h).floor, 5].max
      cols = [(rect[:w] / cell_w).floor, 20].max
      env = child_env_for_open_window.merge(
        'ECHOES_OPEN_WINDOW_PROGRAM' => [JSON.generate(argv)].pack('m0'),
        'ECHOES_ROWS' => rows.to_s,
        'ECHOES_COLS' => cols.to_s,
        'ECHOES_WINDOW_X' => rect[:x].to_i.to_s,
        'ECHOES_WINDOW_Y' => rect[:y].to_i.to_s,
        'ECHOES_WINDOW_W' => rect[:w].to_i.to_s,
        'ECHOES_WINDOW_H' => rect[:h].to_i.to_s
      )
      pid = spawn_external_echoes(env)
      Process.detach(pid) if pid
      !!pid
    end

    private def monitor_rect(monitor)
      {x: monitor[:x], y: monitor[:y], w: monitor[:w], h: monitor[:h]}
    end

    private def monitor_work_rect(monitor)
      {x: monitor[:work_x], y: monitor[:work_y], w: monitor[:work_w], h: monitor[:work_h]}
    end

    private def child_env_for_open_window
      env = ENV.to_h
      env['PATH'] = merge_windows_path(env['PATH'])
      env['USERPROFILE'] ||= Dir.home
      env['TERM'] ||= Echoes.config.term
      env
    end

    private def merge_windows_path(parent_path)
      defaults = [
        ENV['SystemRoot'] && File.join(ENV['SystemRoot'], 'System32'),
        ENV['SystemRoot']
      ].compact
      seen = {}
      (parent_path.to_s.split(';') + defaults).filter_map do |path|
        next if path.empty?
        key = path.downcase
        next if seen[key]

        seen[key] = true
        path
      end.join(';')
    end

    private def spawn_external_echoes(env)
      Process.spawn(env, *external_echoes_command)
    end

    private def external_echoes_command
      exe = File.expand_path('../../exe/echoes', __dir__)
      target = File.exist?(exe) ? exe : $PROGRAM_NAME
      [RbConfig.ruby, target]
    end

    private def set_window_title(title)
      return if !@hwnd || Win32.null_pointer?(@hwnd)

      Win32::SetWindowTextW.call(@hwnd, Fiddle::Pointer[Win32.to_wstring(title.to_s)])
      WindowRegistry.update_title(Process.pid, title.to_s)
    end

    private def handle_clipboard(action, text)
      case action
      when :set
        Win32.set_clipboard_text(@hwnd, text)
        nil
      when :get
        Win32.get_clipboard_text(@hwnd)
      end
    end

    private def paste_from_clipboard
      str = Win32.get_clipboard_text(@hwnd)
      return if str.nil? || str.empty?

      paste_text_to_active_pane(str)
    rescue Errno::EIO, IOError
    end

    private def paste_text_to_active_pane(str)
      pane = current_tab&.active_pane
      return false unless pane
      return false if str.nil? || str.empty?

      if pane.screen.bracketed_paste_mode?
        write_pane_input(pane, "\e[200~")
        write_pane_input(pane, str)
        write_pane_input(pane, "\e[201~")
      else
        write_pane_input(pane, str)
      end
      true
    end

    private def copy_to_clipboard
      sr, sc, er, ec = selection_range
      return unless sr

      text = selected_text_from_buffer(sr, sc, er, ec)
      return if text.empty?

      Win32.set_clipboard_text(@hwnd, text)
    end

    private def selection_range
      pane = current_tab&.active_pane
      copy_mode = pane&.copy_mode
      return nil unless copy_mode && copy_mode.active && copy_mode.selecting?

      (sr, sc), (er, ec) = [copy_mode.selection_start, copy_mode.selection_end].sort_by { |p| [p[0], p[1]] }
      scrollback_size = pane.screen.scrollback.size
      sr += scrollback_size
      er += scrollback_size
      [sr, sc, er, ec]
    end

    private def measure_glyph(text, family, scale, frac_n, frac_d)
      hdc = Win32::GetDC.call(@hwnd || 0)
      return 0.0 if !hdc || Win32.null_pointer?(hdc)

      font = create_multicell_font({scale: scale, frac_n: frac_n, frac_d: frac_d, family: family}, bold: false, italic: false)
      old_font = Win32::SelectObject.call(hdc, font)
      begin
        text_extent(hdc, text).first.to_f
      ensure
        Win32::SelectObject.call(hdc, old_font) if old_font
        Win32::DeleteObject.call(font) if font
        Win32::ReleaseDC.call(@hwnd || 0, hdc)
      end
    end

    private def draw_pane_content(hdc, pane, px, py, pw, ph, is_active)
      screen = pane.screen
      scrollback = screen.scrollback
      visible_start = scrollback.size - pane.scroll_offset
      pane_rows = screen.rows
      pane_cols = screen.cols

      clear_pane_background(hdc, px, py, pw, ph)
      if screen.respond_to?(:background) && screen.background
        draw_pane_background(hdc, screen.background, px, py, pane_cols, pane_rows)
      end
      if screen.respond_to?(:bg_fills) && screen.bg_fills && !screen.bg_fills.empty?
        draw_pane_fills(hdc, screen.bg_fills, px, py, pane_cols, pane_rows)
      end

      pane_rows.times do |r|
        y = py + r * @cell_height
        src = visible_start + r
        row = if src < scrollback.size
                scrollback[src]
              elsif src - scrollback.size < screen.grid.size
                screen.grid[src - scrollback.size]
              end
        next unless row

        c = 0
        while c < pane_cols
          cell = row[c]
          unless cell
            c += 1
            next
          end
          if cell.width.to_i == 0 || cell.multicell == :cont
            c += 1
            next
          end

          fg_val = cell.fg
          bg_val = cell.bg
          default_fg = @default_fg
          default_bg = @default_bg

          if cell.inverse
            fg_val, bg_val = bg_val, fg_val
            default_fg, default_bg = default_bg, default_fg
          end

          fg_color = resolve_color(fg_val, default_fg)
          bg_color = resolve_color(bg_val, default_bg)

          if cell.bold && fg_val.is_a?(Integer) && fg_val < 8
            fg_color = @colors[fg_val + 8] || fg_color
          end

          selected = is_active && cell_selected?(src, c)
          if selected
            fg_color, bg_color = bg_color, fg_color
          end
          if (search_colors = search_colors_for_cell(is_active, src, c))
            fg_color, bg_color = search_colors
          end

          if cell.multicell.is_a?(Hash)
            draw_multicell_text(hdc, cell, px + c * @cell_width, y, fg_color, bg_color)
            c += cell.multicell[:cols].to_i.clamp(1, pane_cols - c)
            next
          end

          cell_width = [cell.width.to_i, 1].max
          run_length = cell_width
          run_str = cell.char || " "

          while (c + run_length) < pane_cols
            next_cell = row[c + run_length]
            break unless next_cell
            break if [next_cell.width.to_i, 1].max != cell_width || next_cell.multicell

            n_fg_val = next_cell.fg
            n_bg_val = next_cell.bg
            n_inverse = next_cell.inverse
            n_bold = next_cell.bold
            n_italic = next_cell.italic
            n_underline = next_cell.underline
            n_strikethrough = next_cell.strikethrough

            if n_inverse
              n_fg_val, n_bg_val = n_bg_val, n_fg_val
            end

            n_fg_color = resolve_color(n_fg_val, n_inverse ? default_bg : default_fg)
            n_bg_color = resolve_color(n_bg_val, n_inverse ? default_fg : default_bg)

            if n_bold && n_fg_val.is_a?(Integer) && n_fg_val < 8
              n_fg_color = @colors[n_fg_val + 8] || n_fg_color
            end

            n_selected = is_active && cell_selected?(src, c + run_length)
            if n_selected
              n_fg_color, n_bg_color = n_bg_color, n_fg_color
            end
            if (n_search_colors = search_colors_for_cell(is_active, src, c + run_length))
              n_fg_color, n_bg_color = n_search_colors
            end

            break if n_fg_color != fg_color ||
                     n_bg_color != bg_color ||
                     n_bold != cell.bold ||
                     n_italic != cell.italic ||
                     n_underline != cell.underline ||
                     n_strikethrough != cell.strikethrough

            run_str += next_cell.char || " "
            run_length += cell_width
          end

          Win32::SetTextColor.call(hdc, fg_color)
          Win32::SetBkColor.call(hdc, bg_color)

          cx = px + c * @cell_width
          run_font = font_for_cell(cell)
          run_x = cx
          font_runs_for_text(run_font, run_str, bold: cell.bold, italic: cell.italic).each do |text, font|
            draw_text_run(hdc, run_x, y, text, font)
            run_x += text.length * cell_width * @cell_width
          end
          draw_text_decorations(
            hdc,
            cx,
            y,
            run_length * @cell_width,
            fg_color,
            underline: cell.underline,
            strikethrough: cell.strikethrough
          )

          c += run_length
        end
      end

      screen.placements.each do |pl|
        blit_kitty_placement(hdc, pl, px, py, pane_rows)
      end

      # IMEインライン変換の描画
      if is_active && @marked_text && pane.scroll_offset == 0
        mx = px + screen.cursor.col * @cell_width
        my = py + screen.cursor.row * @cell_height

        ime_bg = (130 << 16) | (65 << 8) | 30
        ime_fg = 0xFFFFFF

        Win32::SetTextColor.call(hdc, ime_fg)
        Win32::SetBkColor.call(hdc, ime_bg)
        draw_ime_marked_text(hdc, mx, my, @marked_text, @cell_height)
      end

      # カーソルの描画
      if pane.scroll_offset == 0 && screen.cursor.visible
        cx = screen.cursor.col
        cy = screen.cursor.row
        if cx >= 0 && cx < pane_cols && cy >= 0 && cy < pane_rows
          style = screen.cursor_style rescue 0
          cursor_rect = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)

          case style
          when 3, 4 # underline
            cursor_rect[0, Win32::RECT_SIZE] = [px + cx * @cell_width, py + cy * @cell_height + @cell_height - 2, px + (cx + 1) * @cell_width, py + (cy + 1) * @cell_height].pack('l4')
          when 5, 6 # bar
            cursor_rect[0, Win32::RECT_SIZE] = [px + cx * @cell_width, py + cy * @cell_height, px + cx * @cell_width + 2, py + (cy + 1) * @cell_height].pack('l4')
          else # block (0, 1, 2)
            cursor_rect[0, Win32::RECT_SIZE] = [px + cx * @cell_width, py + cy * @cell_height, px + (cx + 1) * @cell_width, py + (cy + 1) * @cell_height].pack('l4')
          end

          if is_active
            Win32::InvertRect.call(hdc, cursor_rect)
          else
            Win32::FrameRect.call(hdc, cursor_rect, @inactive_border_brush)
          end
        end
      end
    end

    private def clear_pane_background(hdc, px, py, pw, ph)
      fill_rect_color(hdc, px, py, px + pw, py + ph, @default_bg)
    end

    private def draw_pane_background(hdc, spec, px, py, pane_cols, pane_rows)
      colors = spec[:colors]
      return if !colors || colors.empty?

      width = pane_cols * @cell_width
      height = pane_rows * @cell_height
      case spec[:type]
      when :flat
        fill_rect_color(hdc, px, py, px + width, py + height, rgba_to_color(colors.first))
      when :linear
        return if colors.size < 2

        draw_linear_gradient(
          hdc,
          px,
          py,
          width,
          height,
          colors,
          spec[:angle].to_f
        )
      end
    end

    private def draw_pane_fills(hdc, fills, px, py, pane_cols, pane_rows)
      fills.each do |fill|
        rect = fill[:rect]
        rgba = fill[:color]
        next unless rect && rgba && rect.size == 4

        r1, c1, r2, c2 = rect
        r1 = r1.clamp(0, pane_rows - 1)
        r2 = r2.clamp(0, pane_rows - 1)
        c1 = c1.clamp(0, pane_cols - 1)
        c2 = c2.clamp(0, pane_cols - 1)
        next if r1 > r2 || c1 > c2

        left = px + c1 * @cell_width
        top = py + r1 * @cell_height
        right = px + (c2 + 1) * @cell_width
        bottom = py + (r2 + 1) * @cell_height
        fill_rect_color(hdc, left, top, right, bottom, rgba_to_color(rgba))
      end
    end

    private def draw_linear_gradient(hdc, x, y, width, height, colors, angle)
      return if width <= 0 || height <= 0
      return if !colors || colors.empty?

      # GDI+ Fallback to scanline if GDIPLUS not available, initialization failed,
      # or if we're in a test environment using a Symbol as mock HDC.
      if hdc.is_a?(Symbol) || !Win32::GdipCreateFromHDC || !Win32.gdiplus_startup
        horizontal = Math.cos(angle * Math::PI / 180.0).abs >= Math.sin(angle * Math::PI / 180.0).abs
        steps = horizontal ? width : height
        steps = [steps, 1].max

        steps.times do |i|
          t = steps == 1 ? 0.0 : i.to_f / (steps - 1)
          color = gradient_color_at(colors, t)
          if horizontal
            fill_rect_color(hdc, x + i, y, x + i + 1, y + height, color)
          else
            fill_rect_color(hdc, x, y + i, x + width, y + i + 1, color)
          end
        end
        return
      end

      # GDI+ implementation
      graphics_ptr = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)
      return if Win32::GdipCreateFromHDC.call(hdc, graphics_ptr) != 0
      graphics = Win32.pointer_value(graphics_ptr)

      begin
        rect = [x, y, width, height].pack('l4')
        brush_ptr = Fiddle::Pointer.malloc(Fiddle::SIZEOF_VOIDP, Fiddle::RUBY_FREE)

        # GDI+ CreateLineBrushFromRectWithAngleI:
        # rect, startColor, endColor, angle, isAngleScalable, wrapMode, lineGradient
        c1 = rgba_to_gdiplus_color(colors.first)
        c2 = rgba_to_gdiplus_color(colors.last)

        status = Win32::GdipCreateLineBrushFromRectWithAngleI.call(
          Fiddle::Pointer[rect], c1, c2, angle.to_f, 1, Win32::WrapModeTile, brush_ptr
        )
        return if status != 0
        brush = Win32.pointer_value(brush_ptr)

        begin
          # Multi-stop support
          if colors.size > 2
            color_array = colors.map { |c| rgba_to_gdiplus_color(c) }.pack('L*')
            pos_array = colors.each_with_index.map { |_, i| i.to_f / (colors.size - 1) }.pack('f*')
            Win32::GdipSetLinePresetBlend.call(brush, Fiddle::Pointer[color_array], Fiddle::Pointer[pos_array], colors.size)
          end

          Win32::GdipFillRectangleI.call(graphics, brush, x, y, width, height)
        ensure
          Win32::GdipDeleteBrush.call(brush)
        end
      ensure
        Win32::GdipDeleteGraphics.call(graphics)
      end
    end

    private def rgba_to_gdiplus_color(rgba)
      r, g, b, a = rgba
      r = (r <= 1.0 ? r * 255 : r).round.clamp(0, 255)
      g = (g <= 1.0 ? g * 255 : g).round.clamp(0, 255)
      b = (b <= 1.0 ? b * 255 : b).round.clamp(0, 255)
      a = (a.nil? ? 255 : (a <= 1.0 ? a * 255 : a)).round.clamp(0, 255)
      (a << 24) | (r << 16) | (g << 8) | b
    end

    private def gradient_color_at(colors, t)
      return rgba_to_color(colors.first) if colors.size == 1

      position = t.clamp(0.0, 1.0) * (colors.size - 1)
      index = position.floor
      index = colors.size - 2 if index >= colors.size - 1
      local_t = position - index
      start_rgb = rgba_to_rgb(colors[index])
      end_rgb = rgba_to_rgb(colors[index + 1])
      interpolate_color(start_rgb, end_rgb, local_t)
    end

    private def interpolate_color(start_rgb, end_rgb, t)
      r = (start_rgb[0] + (end_rgb[0] - start_rgb[0]) * t).round
      g = (start_rgb[1] + (end_rgb[1] - start_rgb[1]) * t).round
      b = (start_rgb[2] + (end_rgb[2] - start_rgb[2]) * t).round
      (b << 16) | (g << 8) | r
    end

    private def rgba_to_color(rgba)
      r, g, b = rgba_to_rgb(rgba)
      (b << 16) | (g << 8) | r
    end

    private def rgba_to_rgb(rgba)
      rgb = rgba[0, 3].map do |component|
        value = component.to_f
        value <= 1.0 ? (value * 255).round : value.round
      end
      alpha = rgba[3].nil? ? 1.0 : rgba[3].to_f
      alpha /= 255.0 if alpha > 1.0
      alpha = alpha.clamp(0.0, 1.0)
      return rgb if alpha >= 1.0

      base = colorref_to_rgb(@default_bg || 0)
      rgb.zip(base).map { |component, base_component| (component * alpha + base_component * (1.0 - alpha)).round }
    end

    private def colorref_to_rgb(color)
      value = color.to_i
      [value & 0xFF, (value >> 8) & 0xFF, (value >> 16) & 0xFF]
    end
  end
end
