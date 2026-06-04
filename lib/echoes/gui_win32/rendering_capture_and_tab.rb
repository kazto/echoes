# frozen_string_literal: true

require_relative "../gui/selection"

module Echoes
  class GUI::Backend::Win32
    private

    private def draw_tab_bar(hdc, tbh, ty)
      width, = paint_target_size
      return if width <= 0

      # Draw background
      rect_ptr = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
      rect_ptr[0, Win32::RECT_SIZE] = [0, ty.to_i, width, (ty + tbh).to_i].pack('l4')
      Win32::FillRect.call(hdc, rect_ptr, @tab_bg_brush)

      tab_count = @tabs.size
      return if tab_count == 0

      tab_w = (width.to_f / tab_count).to_i
      @tabs.each_with_index do |tab, i|
        x = i * tab_w
        is_active = (i == @active_tab)

        if is_active
          rect_ptr[0, Win32::RECT_SIZE] = [x, ty.to_i, x + tab_w, (ty + tbh).to_i].pack('l4')
          Win32::FillRect.call(hdc, rect_ptr, @tab_active_bg_brush)
        end

        # Tab title
        label = tab.respond_to?(:title) ? tab.title : "Tab #{i + 1}"
        label = "#{label} " if label.length < 12

        Win32::SetTextColor.call(hdc, @tab_fg)
        old_bk_mode = Win32::SetBkMode.call(hdc, Win32::TRANSPARENT)
        begin
          tw, th = text_extent(hdc, label)
          tx = x + (tab_w - tw) / 2
          ty_text = ty + (tbh - th) / 2

          draw_text_run(hdc, tx.to_i, ty_text.to_i, label, @hfont)
        ensure
          Win32::SetBkMode.call(hdc, old_bk_mode)
        end

        # Draw separator
        if i < tab_count - 1
          fill_rect_color(hdc, x + tab_w - 1, ty.to_i + 4, x + tab_w, (ty + tbh).to_i - 4, @tab_active_bg)
        end
      end
    end

    private def draw_multicell_text(hdc, cell, x, y, fg_color, bg_color)
      mc = cell.multicell
      return if mc[:sixel]

      block_w = mc[:cols].to_i * @cell_width
      block_h = mc[:rows].to_i * @cell_height
      fill_rect_color(hdc, x, y, x + block_w, y + block_h, bg_color)

      text = cell.char.to_s
      return if text.empty? || text == " "

      font = create_multicell_font(mc, bold: cell.bold, italic: cell.italic)
      old_font = Win32::SelectObject.call(hdc, font)
      old_bk_mode = Win32::SetBkMode.call(hdc, Win32::TRANSPARENT)
      begin
        text_w, text_h = text_extent(hdc, text)
        draw_x, draw_y = aligned_text_origin(
          x, y, block_w, block_h, text_w, text_h,
          halign: mc[:halign],
          valign: mc[:valign]
        )
        Win32::SetTextColor.call(hdc, fg_color)
        wstr = Win32.to_wstring(text)
        Win32::TextOutW.call(hdc, draw_x, draw_y, Fiddle::Pointer[wstr], wstr.bytesize / 2 - 1)
        draw_text_decorations(
          hdc,
          draw_x,
          draw_y,
          text_w,
          fg_color,
          underline: cell.underline,
          strikethrough: cell.strikethrough,
          height: text_h
        )
      ensure
        Win32::SetBkMode.call(hdc, old_bk_mode)
        Win32::SelectObject.call(hdc, old_font) if old_font
        Win32::DeleteObject.call(font) if font
      end
    end

    private def create_multicell_font(mc, bold:, italic:)
      scale = effective_multicell_scale(mc)
      base_height = @font_size ? @font_size.to_i : 16
      create_font(
        weight: bold ? 700 : 400,
        italic: italic,
        height: [(base_height * scale).round, 1].max,
        family: mc[:family]
      )
    end

    private def effective_multicell_scale(mc)
      scale = mc[:scale].to_f
      if mc[:frac_d].to_i > 0 && mc[:frac_n].to_i > 0
        scale *= mc[:frac_n].to_f / mc[:frac_d].to_f
      end
      scale
    end

    private def text_extent(hdc, text)
      size_ptr = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
      size_ptr[0, 8] = "\x00" * 8
      wstr = Win32.to_wstring(text)
      Win32::GetTextExtentPoint32W.call(hdc, Fiddle::Pointer[wstr], wstr.bytesize / 2 - 1, size_ptr)
      [size_ptr[0, 4].unpack1('L'), size_ptr[4, 4].unpack1('L')]
    end

    private def aligned_text_origin(x, y, block_w, block_h, text_w, text_h, halign:, valign:)
      draw_x = case halign
               when 1 then x + block_w - text_w
               when 2 then x + (block_w - text_w) / 2
               else x
               end
      draw_y = case valign
               when 1 then y + block_h - text_h
               when 2 then y + (block_h - text_h) / 2
               else y
               end
      [draw_x, draw_y]
    end

    private def fill_rect_color(hdc, left, top, right, bottom, color)
      brush = Win32::CreateSolidBrush.call(color)
      begin
        rect_ptr = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
        rect_ptr[0, Win32::RECT_SIZE] = [left, top, right, bottom].pack('l4')
        Win32::FillRect.call(hdc, rect_ptr, brush)
      ensure
        Win32::DeleteObject.call(brush) if brush
      end
    end

    private def draw_text_decorations(hdc, x, y, width, color, underline:, strikethrough:, height: @cell_height)
      rects = decoration_rects(x, y, width, height: height, underline: underline, strikethrough: strikethrough)
      return if rects.empty?

      brush = Win32::CreateSolidBrush.call(color)
      begin
        rects.each do |rect|
          rect_ptr = Fiddle::Pointer.malloc(Win32::RECT_SIZE, Fiddle::RUBY_FREE)
          rect_ptr[0, Win32::RECT_SIZE] = rect.pack('l4')
          Win32::FillRect.call(hdc, rect_ptr, brush)
        end
      ensure
        Win32::DeleteObject.call(brush) if brush
      end
    end

    private def decoration_rects(x, y, width, height: @cell_height, underline:, strikethrough:)
      rects = []
      rects << [x, y + height - 2, x + width, y + height - 1] if underline
      rects << [x, y + (height / 2), x + width, y + (height / 2) + 1] if strikethrough
      rects
    end

    private def blit_kitty_placement(hdc, pl, px, py, pane_rows)
      return unless Win32::StretchDIBits

      img = pl[:image]
      return unless img && img[:rgba] && img[:width].to_i > 0 && img[:height].to_i > 0
      return if pl[:anchor_row] + pl[:cell_rows] <= 0
      return if pl[:anchor_row] >= pane_rows

      width = img[:width].to_i
      height = img[:height].to_i
      bitmap = rgba_to_bgra(img[:rgba], width, height)
      return unless bitmap

      bitmap_info = bitmap_info_header(width, height, bitmap.bytesize)
      x = px + pl[:anchor_col] * @cell_width + pl[:x_off].to_i
      y = py + pl[:anchor_row] * @cell_height + pl[:y_off].to_i
      draw_w = pl[:cell_cols] * @cell_width
      draw_h = pl[:cell_rows] * @cell_height

      Win32::StretchDIBits.call(
        hdc,
        x, y, draw_w, draw_h,
        0, 0, width, height,
        Fiddle::Pointer[bitmap],
        Fiddle::Pointer[bitmap_info],
        Win32::DIB_RGB_COLORS,
        Win32::SRCCOPY
      )
    end

    private def bitmap_info_header(width, height, image_size)
      [
        40, width, -height, 1, 32, Win32::BI_RGB, image_size, 0, 0, 0, 0
      ].pack('LllvvLLllLL')
    end

    private def rgba_to_bgra(rgba, width, height)
      return nil unless rgba && rgba.bytesize == width * height * 4

      bgra = String.new(capacity: rgba.bytesize, encoding: Encoding::BINARY)
      rgba.scan(/.{4}/m) do |px|
        bgra << px.getbyte(2) << px.getbyte(1) << px.getbyte(0) << px.getbyte(3)
      end
      bgra
    end

    def self.capture_format_for(path)
      File.extname(path).downcase == '.png' ? :png : :pdf
    end

    private def capture_pane_to_png(pane, path)
      return false unless @cell_width && @cell_height

      rect = pane_rect_for(pane)
      return false unless rect

      width = rect[:w] * @cell_width
      height = rect[:h] * @cell_height
      return false if width <= 0 || height <= 0

      is_active = pane == current_tab&.active_pane
      bytes = case self.class.capture_format_for(path)
              when :png
                png_bytes_for_pane_capture(pane, width, height, is_active)
              else
                pdf_bytes_for_pane_capture(pane, width, height, is_active)
              end
      return false unless bytes

      File.binwrite(path, bytes)
      true
    rescue StandardError => e
      warn "echoes capture: #{e.class}: #{e.message}"
      false
    end

    private def pane_rect_for(pane)
      tab = current_tab
      return nil unless tab

      tab.pane_tree.layout(0, 0, @cols, @rows).find { |rect| rect[:pane] == pane }
    end

    private def png_bytes_for_pane_capture(pane, width, height, is_active)
      bgra = capture_pane_bgra(pane, width, height, is_active)
      return nil unless bgra

      rgba = bgra_to_rgba_opaque(bgra, width, height)
      encode_png_rgba(width, height, rgba)
    end

    private def pdf_bytes_for_pane_capture(pane, width, height, is_active)
      bgra = capture_pane_bgra(pane, width, height, is_active)
      return nil unless bgra

      rgb = bgra_to_rgb_opaque(bgra, width, height)
      encode_pdf_rgb_image(width, height, rgb)
    end

    private def capture_pane_bgra(pane, width, height, is_active)
      return nil unless Win32::GetDIBits

      screen_dc = nil
      mem_dc = nil
      bitmap = nil
      old_bitmap = nil

      screen_dc = Win32::GetDC.call(@hwnd || 0)
      return nil if !screen_dc || Win32.null_pointer?(screen_dc)

      mem_dc = create_compatible_dc(screen_dc)
      return nil if !mem_dc || Win32.null_pointer?(mem_dc)

      bitmap = create_compatible_bitmap(screen_dc, width, height)
      return nil if !bitmap || Win32.null_pointer?(bitmap)

      old_bitmap = select_gdi_object(mem_dc, bitmap)
      draw_pane_content(mem_dc, pane, 0, 0, width, height, is_active)
      select_gdi_object(mem_dc, old_bitmap) if old_bitmap
      old_bitmap = nil

      bitmap_bgra(screen_dc, bitmap, width, height)
    ensure
      select_gdi_object(mem_dc, old_bitmap) if mem_dc && old_bitmap
      delete_gdi_object(bitmap) if bitmap && !Win32.null_pointer?(bitmap)
      delete_dc(mem_dc) if mem_dc && !Win32.null_pointer?(mem_dc)
      Win32::ReleaseDC.call(@hwnd || 0, screen_dc) if screen_dc && !Win32.null_pointer?(screen_dc)
    end

    private def bitmap_bgra(hdc, bitmap, width, height)
      bytes = width * height * 4
      pixels = Fiddle::Pointer.malloc(bytes, Fiddle::RUBY_FREE)
      pixels[0, bytes] = "\x00" * bytes
      info = bitmap_info_header(width, height, bytes)
      copied = Win32::GetDIBits.call(
        hdc,
        bitmap,
        0,
        height,
        pixels,
        Fiddle::Pointer[info],
        Win32::DIB_RGB_COLORS
      )
      return nil if copied == 0

      pixels[0, bytes]
    end

    private def bgra_to_rgba_opaque(bgra, width, height)
      return nil unless bgra && bgra.bytesize == width * height * 4

      rgba = String.new(capacity: bgra.bytesize, encoding: Encoding::BINARY)
      bgra.scan(/.{4}/m) do |px|
        alpha = px.getbyte(3)
        alpha = 255 if alpha == 0
        rgba << px.getbyte(2) << px.getbyte(1) << px.getbyte(0) << alpha
      end
      rgba
    end

    private def bgra_to_rgb_opaque(bgra, width, height)
      return nil unless bgra && bgra.bytesize == width * height * 4

      rgb = String.new(capacity: width * height * 3, encoding: Encoding::BINARY)
      bgra.scan(/.{4}/m) do |px|
        rgb << px.getbyte(2) << px.getbyte(1) << px.getbyte(0)
      end
      rgb
    end

    private def encode_pdf_rgb_image(width, height, rgb)
      return nil unless width.positive? && height.positive?
      return nil unless rgb && rgb.bytesize == width * height * 3

      image = Zlib::Deflate.deflate(rgb)
      content = "q\n#{width} 0 0 #{height} 0 0 cm\n/Im0 Do\nQ\n".b
      objects = [
        "<< /Type /Catalog /Pages 2 0 R >>\n".b,
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>\n".b,
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{width} #{height}] " \
          "/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R >>\n".b,
        "<< /Type /XObject /Subtype /Image /Width #{width} /Height #{height} " \
          "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode " \
          "/Length #{image.bytesize} >>\nstream\n".b + image + "\nendstream\n".b,
        "<< /Length #{content.bytesize} >>\nstream\n".b + content + "endstream\n".b
      ]

      pdf = "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".b
      offsets = [0]
      objects.each_with_index do |obj, index|
        offsets << pdf.bytesize
        pdf << "#{index + 1} 0 obj\n".b << obj << "endobj\n".b
      end

      xref_offset = pdf.bytesize
      pdf << "xref\n0 #{objects.size + 1}\n".b
      pdf << "0000000000 65535 f \n".b
      offsets.drop(1).each do |offset|
        pdf << format("%010d 00000 n \n", offset).b
      end
      pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\n".b
      pdf << "startxref\n#{xref_offset}\n%%EOF\n".b
      pdf
    end

    private def encode_png_rgba(width, height, rgba)
      return nil unless width.positive? && height.positive?
      return nil unless rgba && rgba.bytesize == width * height * 4

      raw = String.new(capacity: height * (1 + width * 4), encoding: Encoding::BINARY)
      row_bytes = width * 4
      height.times do |row|
        raw << 0
        raw << rgba.byteslice(row * row_bytes, row_bytes)
      end

      "\x89PNG\r\n\x1A\n".b +
        png_chunk("IHDR", [width, height, 8, 6, 0, 0, 0].pack("NNCCCCC")) +
        png_chunk("IDAT", Zlib::Deflate.deflate(raw)) +
        png_chunk("IEND", "")
    end

    private def png_chunk(type, data)
      body = type + data
      [data.bytesize].pack("N") + body + [Zlib.crc32(body)].pack("N")
    end

    private def cell_selected?(src_row, col)
      if (tab = current_tab) && (pane = tab.active_pane)
        copy_mode = pane.copy_mode
        if copy_mode && copy_mode.active && copy_mode.selecting?
          sel_start, sel_end = [copy_mode.selection_start, copy_mode.selection_end].sort_by { |p| [p[0], p[1]] }
          cm_row = src_row - pane.screen.scrollback.size
          if cm_row >= sel_start[0] && cm_row <= sel_end[0]
            if cm_row == sel_start[0] && cm_row == sel_end[0]
              return col >= sel_start[1] && col <= sel_end[1]
            elsif cm_row == sel_start[0]
              return col >= sel_start[1]
            elsif cm_row == sel_end[0]
              return col <= sel_end[1]
            else
              return true
            end
          end
        end
      end

      range = Echoes::GUI::Selection.normalize_selection(@selection_anchor, @selection_end)
      return false unless range

      Echoes::GUI::Selection.cell_in_range?(src_row, col, *range)
    end

    private def search_colors_for_cell(is_active, abs_row, col)
      return nil unless is_active && @search.active
      return [@default_fg, @search_current_bg] if current_search_match_at?(abs_row, col)
      return [@default_fg, @search_match_bg] if search_match_at?(abs_row, col)

      nil
    end
  end
end
