# frozen_string_literal: true

require 'fiddle'

module Echoes
  module Win32
    # Load core Win32 system libraries
    USER32   = Fiddle.dlopen('user32.dll') rescue nil
    GDI32    = Fiddle.dlopen('gdi32.dll') rescue nil
    KERNEL32 = Fiddle.dlopen('kernel32.dll') rescue nil
    DWRITE   = Fiddle.dlopen('dwrite.dll') rescue nil
    IMM32    = Fiddle.dlopen('imm32.dll') rescue nil
    SHELL32  = Fiddle.dlopen('shell32.dll') rescue nil

    # Type aliases matching Win32 / Fiddle
    P  = Fiddle::TYPE_VOIDP
    L  = Fiddle::TYPE_LONG
    I  = Fiddle::TYPE_INT
    V  = Fiddle::TYPE_VOID
    D  = Fiddle::TYPE_DOUBLE
    U  = Fiddle::TYPE_INT # UINT
    S  = Fiddle::TYPE_SIZE_T

    # Fiddle functions setup helper
    def self.new_func(lib, name, args, ret)
      return nil unless lib
      begin
        Fiddle::Function.new(lib[name], args, ret)
      rescue => e
        warn "echoes win32: failed to load function #{name}: #{e.message}"
        nil
      end
    end

    # --- User32 Functions ---
    RegisterClassExW  = new_func(USER32, 'RegisterClassExW', [P], I)
    CreateWindowExW   = new_func(USER32, 'CreateWindowExW', [L, P, P, L, I, I, I, I, P, P, P, P], P)
    DestroyWindow     = new_func(USER32, 'DestroyWindow', [P], I)
    ShowWindow        = new_func(USER32, 'ShowWindow', [P, I], I)
    UpdateWindow      = new_func(USER32, 'UpdateWindow', [P], I)
    SetFocus          = new_func(USER32, 'SetFocus', [P], P)
    GetMessageW       = new_func(USER32, 'GetMessageW', [P, P, U, U], I)
    PeekMessageW      = new_func(USER32, 'PeekMessageW', [P, P, U, U, U], I)
    TranslateMessage  = new_func(USER32, 'TranslateMessage', [P], I)
    DispatchMessageW  = new_func(USER32, 'DispatchMessageW', [P], L)
    DefWindowProcW    = new_func(USER32, 'DefWindowProcW', [P, U, P, P], L)
    PostQuitMessage   = new_func(USER32, 'PostQuitMessage', [I], V)
    GetDC             = new_func(USER32, 'GetDC', [P], P)
    ReleaseDC         = new_func(USER32, 'ReleaseDC', [P, P], I)
    InvalidateRect    = new_func(USER32, 'InvalidateRect', [P, P, I], I)
    BeginPaint        = new_func(USER32, 'BeginPaint', [P, P], P)
    EndPaint          = new_func(USER32, 'EndPaint', [P, P], I)
    GetClientRect     = new_func(USER32, 'GetClientRect', [P, P], I)
    FrameRect         = new_func(USER32, 'FrameRect', [P, P, P], I)
    FillRect          = new_func(USER32, 'FillRect', [P, P, P], I)
    SetWindowTextW    = new_func(USER32, 'SetWindowTextW', [P, P], I)
    GetKeyState       = new_func(USER32, 'GetKeyState', [I], I)
    InvertRect        = new_func(USER32, 'InvertRect', [P, P], I)
    OpenClipboard     = new_func(USER32, 'OpenClipboard', [P], I)
    CloseClipboard    = new_func(USER32, 'CloseClipboard', [], I)
    EmptyClipboard    = new_func(USER32, 'EmptyClipboard', [], I)
    SetClipboardData  = new_func(USER32, 'SetClipboardData', [U, P], P)
    GetClipboardData  = new_func(USER32, 'GetClipboardData', [U], P)
    LoadCursorW       = new_func(USER32, 'LoadCursorW', [P, P], P)
    SetCursor         = new_func(USER32, 'SetCursor', [P], P)

    # --- Shell32 Functions ---
    ShellExecuteW     = new_func(SHELL32, 'ShellExecuteW', [P, P, P, P, P, I], P)
    DragAcceptFiles   = new_func(SHELL32, 'DragAcceptFiles', [P, I], V)
    DragQueryFileW    = new_func(SHELL32, 'DragQueryFileW', [P, U, P, U], U)
    DragFinish        = new_func(SHELL32, 'DragFinish', [P], V)

    # --- Kernel32 Functions ---
    GlobalAlloc       = new_func(KERNEL32, 'GlobalAlloc', [U, S], P)
    GlobalFree        = new_func(KERNEL32, 'GlobalFree', [P], P)
    GlobalLock        = new_func(KERNEL32, 'GlobalLock', [P], P)
    GlobalUnlock      = new_func(KERNEL32, 'GlobalUnlock', [P], I)
    GlobalSize        = new_func(KERNEL32, 'GlobalSize', [P], S)

    # --- Imm32 (IME) Functions ---
    ImmGetContext            = new_func(IMM32, 'ImmGetContext', [P], P)
    ImmReleaseContext        = new_func(IMM32, 'ImmReleaseContext', [P, P], I)
    ImmGetCompositionStringW = new_func(IMM32, 'ImmGetCompositionStringW', [P, L, P, L], L)

    # --- GDI32 Functions ---
    CreateSolidBrush  = new_func(GDI32, 'CreateSolidBrush', [L], P)
    DeleteObject      = new_func(GDI32, 'DeleteObject', [P], I)
    SelectObject      = new_func(GDI32, 'SelectObject', [P, P], P)
    SetTextColor      = new_func(GDI32, 'SetTextColor', [P, L], L)
    SetBkColor        = new_func(GDI32, 'SetBkColor', [P, L], L)
    SetBkMode         = new_func(GDI32, 'SetBkMode', [P, I], I)
    TextOutW          = new_func(GDI32, 'TextOutW', [P, I, I, P, I], I)
    ExtTextOutW       = new_func(GDI32, 'ExtTextOutW', [P, I, I, U, P, P, I, P], I)
    CreateCompatibleDC = new_func(GDI32, 'CreateCompatibleDC', [P], P)
    DeleteDC          = new_func(GDI32, 'DeleteDC', [P], I)
    CreateCompatibleBitmap = new_func(GDI32, 'CreateCompatibleBitmap', [P, I, I], P)
    BitBlt            = new_func(GDI32, 'BitBlt', [P, I, I, I, I, P, I, I, L], I)
    CreateFontW       = new_func(GDI32, 'CreateFontW', [I, I, I, I, I, L, L, L, L, L, L, L, L, P], P)
    GetTextExtentPoint32W = new_func(GDI32, 'GetTextExtentPoint32W', [P, P, I, P], I)
    GetGlyphIndicesW  = new_func(GDI32, 'GetGlyphIndicesW', [P, P, I, P, U], U)
    StretchDIBits     = new_func(GDI32, 'StretchDIBits', [P, I, I, I, I, I, I, I, I, P, P, U, L], I)

    # Win32 Constants
    CS_VREDRAW         = 0x0001
    CS_HREDRAW         = 0x0002
    WS_OVERLAPPEDWINDOW = 0x00CF0000
    WS_VISIBLE         = 0x10000000
    SW_SHOWNORMAL      = 1

    # Windows Messages
    WM_DESTROY         = 0x0002
    WM_SIZE            = 0x0005
    WM_PAINT           = 0x000F
    WM_CLOSE           = 0x0010
    WM_ERASEBKGND      = 0x0014
    WM_SETCURSOR       = 0x0020
    WM_SETFOCUS        = 0x0007
    WM_KILLFOCUS       = 0x0008
    WM_LBUTTONDOWN     = 0x0201
    WM_LBUTTONUP       = 0x0202
    WM_MOUSEMOVE       = 0x0200
    WM_MOUSEWHEEL      = 0x020A
    WM_RBUTTONDOWN     = 0x0204
    WM_DROPFILES       = 0x0233
    WM_KEYDOWN         = 0x0100
    WM_KEYUP           = 0x0101
    WM_CHAR            = 0x0102

    # IME Messages
    WM_IME_STARTCOMPOSITION = 0x010D
    WM_IME_ENDCOMPOSITION   = 0x010E
    WM_IME_COMPOSITION      = 0x010F

    # IME Composition String Flags
    GCS_COMPSTR             = 0x0008
    GCS_RESULTSTR           = 0x0800

    # Background modes
    TRANSPARENT        = 1
    OPAQUE             = 2
    SRCCOPY            = 0x00CC0020
    DIB_RGB_COLORS     = 0
    BI_RGB             = 0
    GGI_MARK_NONEXISTING_GLYPHS = 0x0001
    WHEEL_DELTA       = 120
    WHEEL_SCROLL_LINES = 3

    # Clipboard formats
    CF_UNICODETEXT     = 13
    GMEM_MOVEABLE      = 0x0002
    GMEM_ZEROINIT      = 0x0040

    VK_CONTROL         = 0x11
    IDC_IBEAM          = 32513

    # Struct sizes
    WNDCLASSEXW_SIZE   = 80
    MSG_SIZE           = 48
    PAINTSTRUCT_SIZE   = 72
    RECT_SIZE          = 16

    # Convert Ruby UTF-8 string to Win32 wide character string (UTF-16LE, null terminated)
    def self.to_wstring(str)
      return nil unless str
      (str + "\x00").encode('UTF-16LE')
    end

    # Convert Win32 wide character string pointer to Ruby UTF-8 string
    def self.from_wstring(ptr)
      return nil if ptr.null?
      ptr.to_str.force_encoding('UTF-16LE').encode('UTF-8').split("\x00", 2).first
    end

    def self.clipboard_available?
      [
        OpenClipboard, CloseClipboard, EmptyClipboard, SetClipboardData,
        GetClipboardData, GlobalAlloc, GlobalFree, GlobalLock, GlobalUnlock,
        GlobalSize
      ].all?
    end

    def self.set_clipboard_text(hwnd, text)
      return false unless clipboard_available?

      wide = to_wstring(text.to_s)
      handle = nil
      return false if OpenClipboard.call(hwnd) == 0

      begin
        return false if EmptyClipboard.call == 0

        handle = GlobalAlloc.call(GMEM_MOVEABLE | GMEM_ZEROINIT, wide.bytesize)
        return false if null_pointer?(handle)

        dest = GlobalLock.call(handle)
        return false if null_pointer?(dest)

        begin
          dest[0, wide.bytesize] = wide
        ensure
          GlobalUnlock.call(handle)
        end

        stored = SetClipboardData.call(CF_UNICODETEXT, handle)
        if null_pointer?(stored)
          false
        else
          handle = nil
          true
        end
      ensure
        GlobalFree.call(handle) if handle && !null_pointer?(handle)
        CloseClipboard.call
      end
    end

    def self.get_clipboard_text(hwnd)
      return nil unless clipboard_available?
      return nil if OpenClipboard.call(hwnd) == 0

      begin
        handle = GetClipboardData.call(CF_UNICODETEXT)
        return nil if null_pointer?(handle)

        ptr = GlobalLock.call(handle)
        return nil if null_pointer?(ptr)

        begin
          bytes = GlobalSize.call(handle)
          return nil if bytes <= 0

          raw = ptr[0, bytes]
          nul_at = utf16_nul_index(raw)
          raw = raw[0...nul_at] if nul_at
          return "" if raw.empty?
          raw.force_encoding('UTF-16LE').encode('UTF-8')
        ensure
          GlobalUnlock.call(handle)
        end
      ensure
        CloseClipboard.call
      end
    end

    def self.open_url(url, hwnd: 0)
      return false unless ShellExecuteW

      result = ShellExecuteW.call(
        hwnd || 0,
        Fiddle::Pointer[to_wstring('open')],
        Fiddle::Pointer[to_wstring(url.to_s)],
        nil,
        nil,
        SW_SHOWNORMAL
      )
      result.to_i > 32
    end

    def self.file_drop_available?
      DragAcceptFiles && DragQueryFileW && DragFinish
    end

    def self.dropped_file_paths(hdrop)
      return [] unless file_drop_available?

      count = DragQueryFileW.call(hdrop, 0xFFFFFFFF, nil, 0)
      count.times.filter_map do |index|
        len = DragQueryFileW.call(hdrop, index, nil, 0)
        next if len <= 0

        buf = Fiddle::Pointer.malloc((len + 1) * 2, Fiddle::RUBY_FREE)
        buf[0, (len + 1) * 2] = "\x00" * ((len + 1) * 2)
        copied = DragQueryFileW.call(hdrop, index, buf, len + 1)
        next if copied <= 0

        raw = buf[0, copied * 2]
        raw.force_encoding('UTF-16LE').encode('UTF-8')
      end
    ensure
      DragFinish.call(hdrop) if DragFinish && hdrop && !null_pointer?(hdrop)
    end

    def self.null_pointer?(ptr)
      ptr.nil? || (ptr.respond_to?(:null?) ? ptr.null? : ptr.to_i == 0)
    end

    def self.utf16_nul_index(raw)
      max = raw.bytesize - 1
      i = 0
      while i < max
        return i if raw.getbyte(i) == 0 && raw.getbyte(i + 1) == 0
        i += 2
      end
      nil
    end
  end
end
