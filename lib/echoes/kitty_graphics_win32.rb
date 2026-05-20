# frozen_string_literal: true

require 'fiddle'

module Echoes
  module KittyGraphics
    # GDI+ or WIC backed PNG decoder on Windows, matching the interface
    # of AppKitPng in macOS.
    module GdiPlusPng
      GDIPLUS = Fiddle.dlopen('gdiplus.dll') rescue nil
      OLE32   = Fiddle.dlopen('ole32.dll') rescue nil

      P = Fiddle::TYPE_VOIDP
      I = Fiddle::TYPE_INT
      L = Fiddle::TYPE_LONG
      V = Fiddle::TYPE_VOID

      def self.new_func(lib, name, args, ret)
        return nil unless lib
        begin
          Fiddle::Function.new(lib[name], args, ret)
        rescue => e
          warn "echoes gdiplus: failed to load #{name}: #{e.message}"
          nil
        end
      end

      GdiplusStartup = new_func(GDIPLUS, 'GdiplusStartup', [P, P, P], I)
      GdiplusShutdown = new_func(GDIPLUS, 'GdiplusShutdown', [L], V)
      GdipCreateBitmapFromStream = new_func(GDIPLUS, 'GdipCreateBitmapFromStream', [P, P], I)
      GdipDisposeImage = new_func(GDIPLUS, 'GdipDisposeImage', [P], I)
      GdipGetImageWidth = new_func(GDIPLUS, 'GdipGetImageWidth', [P, P], I)
      GdipGetImageHeight = new_func(GDIPLUS, 'GdipGetImageHeight', [P, P], I)
      GdipBitmapLockBits = new_func(GDIPLUS, 'GdipBitmapLockBits', [P, P, I, I, P], I)
      GdipBitmapUnlockBits = new_func(GDIPLUS, 'GdipBitmapUnlockBits', [P, P], I)

      CreateStreamOnHGlobal = new_func(OLE32, 'CreateStreamOnHGlobal', [P, I, P], I)

      # GDI+ startup input structure size (24 bytes for 64-bit)
      # {GdiplusVersion=1, DebugEventCallback=nil, SuppressBackgroundThread=0, SuppressExternalCodecs=0}
      def self.startup
        return if @token
        input = Fiddle::Pointer.malloc(24, Fiddle::RUBY_FREE)
        input[0, 4] = [1].pack('L') # GdiplusVersion
        token_ptr = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        if GdiplusStartup.call(token_ptr, input, nil) == 0
          @token = token_ptr.to_str(8).unpack1('Q')
        end
      end

      def self.shutdown
        return unless @token
        GdiplusShutdown.call(@token)
        @token = nil
      end

      module_function

      def decode(bytes)
        return nil if bytes.nil? || bytes.bytesize.zero?
        startup

        # 1. Allocate global memory and create IStream
        h_mem = Fiddle::Pointer.malloc(bytes.bytesize, Fiddle::RUBY_FREE)
        h_mem[0, bytes.bytesize] = bytes
        stream_ptr = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        
        return nil unless CreateStreamOnHGlobal.call(h_mem, 1, stream_ptr) == 0
        stream = Fiddle::Pointer.new(stream_ptr.ptr)

        # 2. Load Bitmap
        bitmap_ptr = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        return nil unless GdipCreateBitmapFromStream.call(stream, bitmap_ptr) == 0
        bitmap = Fiddle::Pointer.new(bitmap_ptr.ptr)

        # 3. Query dimensions
        w_ptr = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
        h_ptr = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
        GdipGetImageWidth.call(bitmap, w_ptr)
        GdipGetImageHeight.call(bitmap, h_ptr)
        
        width = w_ptr.to_str(4).unpack1('L')
        height = h_ptr.to_str(4).unpack1('L')

        # 4. Lock bits to read RGBA8
        rect = [0, 0, width, height].pack('l4') # Gdiplus Rect
        # BitmapData structure (32 bytes)
        # {Width, Height, Stride, PixelFormat, Scan0, Reserved}
        bmp_data = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
        
        pixel_format_32bpp_argb = 2498570 # PixelFormat32bppARGB
        image_lock_mode_read = 1
        
        return nil unless GdipBitmapLockBits.call(bitmap, rect, image_lock_mode_read, pixel_format_32bpp_argb, bmp_data) == 0
        
        begin
          scan0 = Fiddle::Pointer.new(bmp_data[16, 8].unpack1('Q'))
          rgba = scan0.to_str(width * height * 4)
          {rgba: rgba, width: width, height: height}
        ensure
          GdipBitmapUnlockBits.call(bitmap, bmp_data)
          GdipDisposeImage.call(bitmap)
        end
      end

      def from_rgb(bytes, width, height)
        # Match signatures - Windows converts using decode or direct copy
        return nil if bytes.nil? || width <= 0 || height <= 0
        return nil if bytes.bytesize != width * height * 3
        # Expand 24-bit RGB to 32-bit RGBA
        rgba = +''
        bytes.scan(/.{3}/m) do |rgb|
          rgba << rgb << "\xFF".b
        end
        {rgba: rgba, width: width, height: height}
      end

      def from_rgba(bytes, width, height)
        return nil if bytes.nil? || width <= 0 || height <= 0
        return nil if bytes.bytesize != width * height * 4
        {rgba: bytes, width: width, height: height}
      end
    end
  end
end
