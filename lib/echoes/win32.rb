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

    # Type aliases matching Win32 / Fiddle
    P  = Fiddle::TYPE_VOIDP
    L  = Fiddle::TYPE_LONG
    I  = Fiddle::TYPE_INT
    V  = Fiddle::TYPE_VOID
    D  = Fiddle::TYPE_DOUBLE
    U  = Fiddle::TYPE_INT # UINT

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
    InvalidateRect    = new_func(USER32, 'InvalidateRect', [P, P, I], I)
    BeginPaint        = new_func(USER32, 'BeginPaint', [P, P], P)
    EndPaint          = new_func(USER32, 'EndPaint', [P, P], I)
    GetClientRect     = new_func(USER32, 'GetClientRect', [P, P], I)
    FrameRect         = new_func(USER32, 'FrameRect', [P, P, P], I)
    SetWindowTextW    = new_func(USER32, 'SetWindowTextW', [P, P], I)
    GetKeyState       = new_func(USER32, 'GetKeyState', [I], I)
    InvertRect        = new_func(USER32, 'InvertRect', [P, P], I)
    OpenClipboard     = new_func(USER32, 'OpenClipboard', [P], I)
    CloseClipboard    = new_func(USER32, 'CloseClipboard', [], I)
    EmptyClipboard    = new_func(USER32, 'EmptyClipboard', [], I)
    SetClipboardData  = new_func(USER32, 'SetClipboardData', [U, P], P)
    GetClipboardData  = new_func(USER32, 'GetClipboardData', [U], P)

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
    CreateFontW       = new_func(GDI32, 'CreateFontW', [I, I, I, I, I, L, L, L, L, L, L, L, L, P], P)
    GetTextExtentPoint32W = new_func(GDI32, 'GetTextExtentPoint32W', [P, P, I, P], I)

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
    WM_LBUTTONDOWN     = 0x0201
    WM_LBUTTONUP       = 0x0202
    WM_MOUSEMOVE       = 0x0200
    WM_RBUTTONDOWN     = 0x0204
    WM_KEYDOWN         = 0x0100
    WM_KEYUP           = 0x0101
    WM_CHAR            = 0x0102

    # IME Messages
    WM_IME_STARTCOMPOSITION = 0x010D
    WM_IME_ENDCOMPOSITION   = 0x010E
    WM_IME_COMPOSITION      = 0x010F

    # IME Composition String Flags
    GCS_COMPSTR             = 0x0008

    # Background modes
    TRANSPARENT        = 1
    OPAQUE             = 2

    # Clipboard formats
    CF_UNICODETEXT     = 13

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
  end
end
