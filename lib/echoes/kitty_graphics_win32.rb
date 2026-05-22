# frozen_string_literal: true

require 'fiddle'
require_relative 'win32'

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
      S = Fiddle::SIZEOF_VOIDP

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
      GdiplusShutdown = new_func(GDIPLUS, 'GdiplusShutdown', [P], V)
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
        token_ptr = Fiddle::Pointer.malloc(S, Fiddle::RUBY_FREE)
        if GdiplusStartup.call(token_ptr, input, nil) == 0
          @token = pointer_value(token_ptr)
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
        return nil unless available?
        startup
        return nil unless @token

        h_mem = nil
        stream = nil
        bitmap = nil

        begin
          # 1. Allocate HGLOBAL memory and create an IStream over it.
          h_mem = Win32::GlobalAlloc.call(Win32::GMEM_MOVEABLE, bytes.bytesize)
          return nil if Win32.null_pointer?(h_mem)

          mem = Win32::GlobalLock.call(h_mem)
          return nil if Win32.null_pointer?(mem)
          begin
            mem[0, bytes.bytesize] = bytes
          ensure
            Win32::GlobalUnlock.call(h_mem)
          end

          stream_ptr = Fiddle::Pointer.malloc(S, Fiddle::RUBY_FREE)
          stream_ptr[0, S] = "\x00" * S
          return nil unless CreateStreamOnHGlobal.call(h_mem, 0, stream_ptr) == 0
          stream = Fiddle::Pointer.new(pointer_value(stream_ptr))

          # 2. Load Bitmap
          bitmap_ptr = Fiddle::Pointer.malloc(S, Fiddle::RUBY_FREE)
          bitmap_ptr[0, S] = "\x00" * S
          return nil unless GdipCreateBitmapFromStream.call(stream, bitmap_ptr) == 0
          bitmap = Fiddle::Pointer.new(pointer_value(bitmap_ptr))

          # 3. Query dimensions
          w_ptr = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
          h_ptr = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
          return nil unless GdipGetImageWidth.call(bitmap, w_ptr) == 0
          return nil unless GdipGetImageHeight.call(bitmap, h_ptr) == 0

          width = w_ptr[0, 4].unpack1('L')
          height = h_ptr[0, 4].unpack1('L')
          return nil if width <= 0 || height <= 0

          # 4. Lock bits to read 32bpp ARGB. In little-endian memory this
          # arrives as BGRA, so convert to the renderer's RGBA contract.
          rect = [0, 0, width, height].pack('l4')
          bmp_data = Fiddle::Pointer.malloc(32, Fiddle::RUBY_FREE)
          bmp_data[0, 32] = "\x00" * 32

          pixel_format_32bpp_argb = 0x0026200A
          image_lock_mode_read = 1

          return nil unless GdipBitmapLockBits.call(bitmap, rect, image_lock_mode_read, pixel_format_32bpp_argb, bmp_data) == 0

          begin
            stride = bmp_data[8, 4].unpack1('l')
            scan0 = Fiddle::Pointer.new(pointer_value(bmp_data + 16))
            rgba = bgra_to_rgba(scan0, width, height, stride)
            {rgba: rgba, width: width, height: height}
          ensure
            GdipBitmapUnlockBits.call(bitmap, bmp_data)
          end
        ensure
          GdipDisposeImage.call(bitmap) if bitmap && !bitmap.null?
          release_com_object(stream) if stream && !stream.null?
          Win32::GlobalFree.call(h_mem) if h_mem && !Win32.null_pointer?(h_mem)
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

      def available?
        [
          GdiplusStartup, GdiplusShutdown, GdipCreateBitmapFromStream,
          GdipDisposeImage, GdipGetImageWidth, GdipGetImageHeight,
          GdipBitmapLockBits, GdipBitmapUnlockBits, CreateStreamOnHGlobal,
          Win32::GlobalAlloc, Win32::GlobalFree, Win32::GlobalLock,
          Win32::GlobalUnlock
        ].all?
      end

      def pointer_value(ptr)
        if S == 8
          ptr[0, S].unpack1('Q')
        else
          ptr[0, S].unpack1('L')
        end
      end

      def bgra_to_rgba(scan0, width, height, stride)
        rgba = String.new(capacity: width * height * 4, encoding: Encoding::BINARY)
        row_bytes = width * 4
        height.times do |row|
          offset = stride.negative? ? (height - 1 - row) * stride.abs : row * stride
          bgra = (scan0 + offset)[0, row_bytes]
          bgra.scan(/.{4}/m) do |px|
            rgba << px.getbyte(2) << px.getbyte(1) << px.getbyte(0) << px.getbyte(3)
          end
        end
        rgba
      end

      def release_com_object(ptr)
        vtable = Fiddle::Pointer.new(pointer_value(ptr))
        release_addr = pointer_value(vtable + (2 * S))
        release = Fiddle::Function.new(Fiddle::Pointer.new(release_addr), [P], L)
        release.call(ptr)
      end
    end
  end
end
