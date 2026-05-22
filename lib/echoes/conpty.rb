# frozen_string_literal: true

require 'fiddle'

module Echoes
  class ConPTY
    KERNEL32 = Fiddle.dlopen('kernel32.dll') rescue nil

    P = Fiddle::TYPE_VOIDP
    L = Fiddle::TYPE_LONG
    I = Fiddle::TYPE_INT
    V = Fiddle::TYPE_VOID
    U = Fiddle::TYPE_INT
    S = Fiddle::TYPE_SIZE_T
    UP = Fiddle::TYPE_UINTPTR_T

    def self.new_func(name, args, ret)
      return nil unless KERNEL32
      begin
        Fiddle::Function.new(KERNEL32[name], args, ret)
      rescue => e
        warn "echoes conpty: failed to load #{name}: #{e.message}"
        nil
      end
    end

    # ConPTY API functions (introduced in Windows 10 1809)
    CreatePseudoConsole = new_func('CreatePseudoConsole', [L, P, P, L, P], L) # returns HRESULT
    ClosePseudoConsole  = new_func('ClosePseudoConsole', [P], V)
    ResizePseudoConsole = new_func('ResizePseudoConsole', [P, L], L)

    # Proc Thread Attribute List APIs
    InitializeProcThreadAttributeList = new_func('InitializeProcThreadAttributeList', [P, U, U, P], I)
    UpdateProcThreadAttribute         = new_func('UpdateProcThreadAttribute', [P, U, UP, UP, S, P, P], I)
    DeleteProcThreadAttributeList     = new_func('DeleteProcThreadAttributeList', [P], V)

    # Pipes & Process APIs
    CreatePipe           = new_func('CreatePipe', [P, P, P, U], I)
    CreateProcessW       = new_func('CreateProcessW', [P, P, P, P, I, U, P, P, P, P], I)
    CloseHandle          = new_func('CloseHandle', [P], I)
    GetLastError         = new_func('GetLastError', [], U)
    GetExitCodeProcess   = new_func('GetExitCodeProcess', [P, P], I)
    TerminateProcess     = new_func('TerminateProcess', [P, U], I)
    ReadFile             = new_func('ReadFile', [P, P, U, P, P], I)
    WriteFile            = new_func('WriteFile', [P, P, U, P, P], I)
    PeekNamedPipe        = new_func('PeekNamedPipe', [P, P, U, P, P, P], I)

    # Constants
    S_OK = 0
    PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016
    PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x00020002
    EXTENDED_STARTUPINFO_PRESENT       = 0x00080000
    DETACHED_PROCESS                   = 0x00000008
    STILL_ACTIVE                        = 259

    # Size of COORD: {short X, short Y} (4 bytes total)
    def self.make_coord(cols, rows)
      [cols, rows].pack('s2').unpack1('L')
    end

    attr_reader :h_pc, :h_process, :h_process_id, :h_thread, :pipe_in_w, :pipe_out_r

    def initialize
      @h_pc = 0
      @h_process = 0
      @h_process_id = 0
      @h_thread = 0
      @pipe_in_w = 0
      @pipe_out_r = 0
    end

    # Spawns the specified shell process (e.g. powershell.exe) under a new Pseudo Console
    def spawn(command_line, cols: 80, rows: 24)
      # Create pipes for ConPTY communication
      # pipe_in: host writes to pipe_in_w -> ConPTY reads from pipe_in_r
      # pipe_out: ConPTY writes to pipe_out_w -> host reads from pipe_out_r
      pipe_in_r = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
      pipe_in_w = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
      pipe_out_r = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
      pipe_out_w = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
      h_pipe_in_r = h_pipe_in_w = h_pipe_out_r = h_pipe_out_w = 0

      begin
        raise_last_error("CreatePipe") unless CreatePipe.call(pipe_in_r, pipe_in_w, nil, 0) != 0
        raise_last_error("CreatePipe") unless CreatePipe.call(pipe_out_r, pipe_out_w, nil, 0) != 0

        # Extract 64-bit integer HANDLE values safely
        h_pipe_in_r  = pipe_in_r[0, 8].unpack1('Q')
        h_pipe_in_w  = pipe_in_w[0, 8].unpack1('Q')
        h_pipe_out_r = pipe_out_r[0, 8].unpack1('Q')
        h_pipe_out_w = pipe_out_w[0, 8].unpack1('Q')

        @pipe_in_w = h_pipe_in_w
        @pipe_out_r = h_pipe_out_r

        # 2. Create the Pseudo Console
        h_pc_ptr = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        h_pc_ptr[0, 8] = "\x00" * 8
        size = self.class.make_coord(cols, rows)
        hresult = CreatePseudoConsole.call(
          size,
          h_pipe_in_r,
          h_pipe_out_w,
          0,
          h_pc_ptr
        )

        raise "ConPTY: CreatePseudoConsole failed with HRESULT #{hresult}" if hresult != S_OK

        @h_pc = h_pc_ptr[0, 8].unpack1('Q')

        # 3. Spawn child process (e.g. powershell.exe) with ConPTY attached
        # Prepare Startup Info Ex struct containing the ProcThreadAttributeList
        size_list = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
        size_list[0, 8] = "\x00" * 8
        InitializeProcThreadAttributeList.call(nil, 1, 0, size_list)
        list_size = size_list[0, 8].unpack1('Q') # Ensure correct 64-bit size unpack

        attr_list = Fiddle::Pointer.malloc(list_size, Fiddle::RUBY_FREE)
        attr_list[0, list_size] = "\x00" * list_size
        raise_last_error("InitializeProcThreadAttributeList") unless InitializeProcThreadAttributeList.call(attr_list, 1, 0, size_list) != 0

        begin
          raise_last_error("UpdateProcThreadAttribute") unless UpdateProcThreadAttribute.call(
            attr_list,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            @h_pc,
            Fiddle::SIZEOF_VOIDP,
            nil,
            nil
          ) != 0

          # Build STARTUPINFOEXW. On 64-bit Windows, STARTUPINFOW is 104 bytes
          # and the trailing lpAttributeList pointer makes STARTUPINFOEXW 112.
          startup_info_size = Fiddle::SIZEOF_VOIDP == 8 ? 104 : 68
          startup_info_ex_size = startup_info_size + Fiddle::SIZEOF_VOIDP
          si_ex = Fiddle::Pointer.malloc(startup_info_ex_size, Fiddle::RUBY_FREE)
          si_ex[0, startup_info_ex_size] = "\x00" * startup_info_ex_size
          si_ex[0, 4] = [startup_info_ex_size].pack('L') # STARTUPINFOEXW cbSize
          si_ex[startup_info_size, Fiddle::SIZEOF_VOIDP] = [attr_list.to_i].pack(Fiddle::SIZEOF_VOIDP == 8 ? 'Q' : 'L')

          # Build PROCESS_INFORMATION (24 bytes)
          pi = Fiddle::Pointer.malloc(24, Fiddle::RUBY_FREE)
          pi[0, 24] = "\x00" * 24

          cmd_w = cmd_to_wstring(command_line)

          # Spawn
          success = CreateProcessW.call(
            nil,
            cmd_w,
            nil, nil,
            0,
            EXTENDED_STARTUPINFO_PRESENT,
            nil, nil,
            si_ex,
            pi
          )

          raise_last_error("CreateProcessW") if success == 0

          @h_process = pi[0, 8].unpack1('Q')
          @h_thread = pi[8, 8].unpack1('Q')
          @h_process_id = pi[16, 4].unpack1('L')

          # The pseudoconsole owns these ends after the child has been attached.
          close_handle(h_pipe_in_r)
          close_handle(h_pipe_out_w)
          h_pipe_in_r = h_pipe_out_w = 0
        ensure
          DeleteProcThreadAttributeList.call(attr_list)
        end
      rescue
        close_handle(@pipe_in_w)
        close_handle(@pipe_out_r)
        close_handle(h_pipe_in_r)
        close_handle(h_pipe_out_w)
        ClosePseudoConsole.call(@h_pc) if @h_pc && @h_pc != 0
        @pipe_in_w = @pipe_out_r = @h_pc = 0
        raise
      end

      true
    end

    def resize(cols, rows)
      return unless @h_pc && @h_pc != 0
      size = self.class.make_coord(cols, rows)
      ResizePseudoConsole.call(@h_pc, size)
    end

    def read_available_output(max = 4096)
      return '' unless @pipe_out_r && @pipe_out_r != 0
      available_ptr = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      available_ptr[0, 4] = "\x00" * 4
      ok = PeekNamedPipe.call(@pipe_out_r, nil, 0, nil, available_ptr, nil)
      return '' if ok == 0
      available = available_ptr[0, 4].unpack1('L')
      return '' if available == 0

      read_len = [available, max].min
      buffer = Fiddle::Pointer.malloc(read_len, Fiddle::RUBY_FREE)
      read_ptr = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      read_ptr[0, 4] = "\x00" * 4
      ok = ReadFile.call(@pipe_out_r, buffer, read_len, read_ptr, nil)
      return '' if ok == 0
      bytes_read = read_ptr[0, 4].unpack1('L')
      buffer[0, bytes_read]
    end

    def write(bytes)
      return 0 unless @pipe_in_w && @pipe_in_w != 0
      data = bytes.to_s
      buffer = Fiddle::Pointer[data]
      written_ptr = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      written_ptr[0, 4] = "\x00" * 4
      ok = WriteFile.call(@pipe_in_w, buffer, data.bytesize, written_ptr, nil)
      ok == 0 ? 0 : written_ptr[0, 4].unpack1('L')
    end

    def alive?
      return false unless @h_process && @h_process != 0
      exit_code = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      exit_code[0, 4] = "\x00" * 4
      return false if GetExitCodeProcess.call(@h_process, exit_code) == 0
      exit_code.to_str(4).unpack1('L') == STILL_ACTIVE
    end

    def close
      close_handles
    end

    def kill
      TerminateProcess.call(@h_process, 0) if @h_process && @h_process != 0
      close_handles
    end

    private

    def close_handles
      close_handle(@h_process)
      close_handle(@h_thread)
      ClosePseudoConsole.call(@h_pc) if @h_pc && @h_pc != 0
      close_handle(@pipe_in_w)
      close_handle(@pipe_out_r)
      @h_process = 0
      @h_process_id = 0
      @h_thread = 0
      @h_pc = 0
      @pipe_in_w = 0
      @pipe_out_r = 0
    end

    def close_handle(handle)
      CloseHandle.call(handle) if handle && handle != 0
    end

    def raise_last_error(function_name)
      code = GetLastError ? GetLastError.call : 0
      raise "ConPTY: #{function_name} failed with Windows error #{code}"
    end

    def cmd_to_wstring(str)
      data = (str + "\x00").encode('UTF-16LE')
      buffer = Fiddle::Pointer.malloc(data.bytesize, Fiddle::RUBY_FREE)
      buffer[0, data.bytesize] = data
      buffer
    end
  end
end
