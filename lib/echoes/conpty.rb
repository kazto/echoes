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
    UpdateProcThreadAttribute         = new_func('UpdateProcThreadAttribute', [P, U, L, P, L, P, P], I)
    DeleteProcThreadAttributeList     = new_func('DeleteProcThreadAttributeList', [P], V)

    # Pipes & Process APIs
    CreatePipe           = new_func('CreatePipe', [P, P, P, U], I)
    CreateProcessW       = new_func('CreateProcessW', [P, P, P, P, I, U, P, P, P, P], I)
    CloseHandle          = new_func('CloseHandle', [P], I)
    GetExitCodeProcess   = new_func('GetExitCodeProcess', [P, P], I)
    TerminateProcess     = new_func('TerminateProcess', [P, U], I)
    ReadFile             = new_func('ReadFile', [P, P, U, P, P], I)
    WriteFile            = new_func('WriteFile', [P, P, U, P, P], I)

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

    attr_reader :h_pc, :h_process, :h_thread, :pipe_in_w, :pipe_out_r

    def initialize
      @h_pc = 0
      @h_process = 0
      @h_thread = 0
      @pipe_in_w = 0
      @pipe_out_r = 0
    end

    # Spawns the specified shell process (e.g. powershell.exe) under a new Pseudo Console
    def spawn(command_line, cols: 80, rows: 24)
      # 1. Create SECURITY_ATTRIBUTES for inheritable pipes
      sec_attr = Fiddle::Pointer.malloc(24, Fiddle::RUBY_FREE)
      sec_attr[0, 24] = "\x00" * 24
      sec_attr[0, 4] = [24].pack('L') # nLength = 24
      sec_attr[8, 8] = [0].pack('Q')  # lpSecurityDescriptor = NULL
      sec_attr[16, 4] = [1].pack('L') # bInheritHandle = TRUE (1)

      # Create pipes for ConPTY communication
      # pipe_in: host writes to pipe_in_w -> ConPTY reads from pipe_in_r
      # pipe_out: ConPTY writes to pipe_out_w -> host reads from pipe_out_r
      pipe_in_r = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
      pipe_in_w = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
      pipe_out_r = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
      pipe_out_w = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)

      raise "ConPTY: CreatePipe failed" unless CreatePipe.call(pipe_in_r, pipe_in_w, sec_attr, 0) != 0
      raise "ConPTY: CreatePipe failed" unless CreatePipe.call(pipe_out_r, pipe_out_w, sec_attr, 0) != 0

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

      if hresult != S_OK
        # Cleanup pipes
        CloseHandle.call(h_pipe_in_r)
        CloseHandle.call(h_pipe_in_w)
        CloseHandle.call(h_pipe_out_r)
        CloseHandle.call(h_pipe_out_w)
        raise "ConPTY: CreatePseudoConsole failed with HRESULT #{hresult}"
      end

      @h_pc = h_pc_ptr[0, 8].unpack1('Q')

      # 3. Spawn child process (e.g. powershell.exe) with ConPTY attached
      # Prepare Startup Info Ex struct containing the ProcThreadAttributeList
      size_list = Fiddle::Pointer.malloc(8, Fiddle::RUBY_FREE)
      size_list[0, 8] = "\x00" * 8
      InitializeProcThreadAttributeList.call(nil, 2, 0, size_list)
      list_size = size_list[0, 8].unpack1('Q') # Ensure correct 64-bit size unpack

      attr_list = Fiddle::Pointer.malloc(list_size, Fiddle::RUBY_FREE)
      attr_list[0, list_size] = "\x00" * list_size
      raise "ConPTY: InitializeProcThreadAttributeList failed" unless InitializeProcThreadAttributeList.call(attr_list, 2, 0, size_list) != 0

      begin
        # 1. Update PseudoConsole attribute
        raise "ConPTY: UpdateProcThreadAttribute failed" unless UpdateProcThreadAttribute.call(
          attr_list,
          0,
          PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
          @h_pc,
          8,
          nil,
          nil
        ) != 0

        # 2. Update Handle List attribute (only inherit h_pipe_in_r and h_pipe_out_w)
        handle_array = Fiddle::Pointer.malloc(16, Fiddle::RUBY_FREE)
        handle_array[0, 8] = [h_pipe_in_r].pack('Q')
        handle_array[8, 8] = [h_pipe_out_w].pack('Q')

        raise "ConPTY: UpdateProcThreadAttribute for Handle List failed" unless UpdateProcThreadAttribute.call(
          attr_list,
          0,
          PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
          handle_array,
          16,
          nil,
          nil
        ) != 0

        # Build STARTUPINFOEXW (112 bytes for 64-bit Windows)
        si_ex = Fiddle::Pointer.malloc(112, Fiddle::RUBY_FREE)
        si_ex[0, 112] = "\x00" * 112
        si_ex[0, 4] = [112].pack('L') # cbSize
        si_ex[104, 8] = [attr_list.to_i].pack('Q') # AttributeList

        # Build PROCESS_INFORMATION (24 bytes)
        pi = Fiddle::Pointer.malloc(24, Fiddle::RUBY_FREE)
        pi[0, 24] = "\x00" * 24

        cmd_w = cmd_to_wstring(command_line)

        # Spawn
        success = CreateProcessW.call(
          nil,
          cmd_w,
          nil, nil,
          1, # inheritHandles = TRUE (1) (required for ConPTY pipes to be inherited by child)
          EXTENDED_STARTUPINFO_PRESENT,
          nil, nil,
          si_ex,
          pi
        )

        raise "ConPTY: CreateProcessW failed" if success == 0

        # Close client-side pipe handles now that child process has inherited/associated them
        CloseHandle.call(h_pipe_in_r)
        CloseHandle.call(h_pipe_out_w)

        @h_process = pi[0, 8].unpack1('Q')
        @h_thread = pi[8, 8].unpack1('Q')
      ensure
        DeleteProcThreadAttributeList.call(attr_list)
      end

      true
    end

    def resize(cols, rows)
      return unless @h_pc && @h_pc != 0
      size = self.class.make_coord(cols, rows)
      ResizePseudoConsole.call(@h_pc, size)
    end

    def alive?
      return false unless @h_process && @h_process != 0
      exit_code = Fiddle::Pointer.malloc(4, Fiddle::RUBY_FREE)
      exit_code[0, 4] = "\x00" * 4
      return false if GetExitCodeProcess.call(@h_process, exit_code) == 0
      exit_code.to_str(4).unpack1('L') == STILL_ACTIVE
    end

    def kill
      return unless @h_process && @h_process != 0
      TerminateProcess.call(@h_process, 0)
      CloseHandle.call(@h_process)
      CloseHandle.call(@h_thread)
      ClosePseudoConsole.call(@h_pc) if @h_pc && @h_pc != 0
      CloseHandle.call(@pipe_in_w) if @pipe_in_w && @pipe_in_w != 0
      CloseHandle.call(@pipe_out_r) if @pipe_out_r && @pipe_out_r != 0
      @h_process = 0
      @h_thread = 0
      @h_pc = 0
    end

    private

    def cmd_to_wstring(str)
      (str + "\x00").encode('UTF-16LE')
    end
  end
end
