# frozen_string_literal: true

require_relative "platform"

module Echoes
  module ShellBackend
    module_function

    def for_platform(os = Platform.host_os, windows_backend: :popen)
      if Platform.windows?(os)
        windows_backend == :conpty ? WindowsConPTYBackend : WindowsPopenBackend
      elsif Platform.macos?(os)
        MacPtyBackend
      else
        UnixPtyBackend
      end
    end
  end

  class WindowsPopenBackend
    attr_reader :read_io, :write_io, :pid

    def initialize(command:, env:, rows:, cols:, px_width: 0, px_height: 0)
      require "open3"

      spawn_args = command.is_a?(Array) ? command : [command]
      @write_io, @read_io, @wait_thread =
        if env
          Open3.popen2e(env, *spawn_args)
        else
          Open3.popen2e(*spawn_args)
        end
      @pid = @wait_thread.pid
      install_winsize_accessors(rows, cols)
    end

    def write(bytes)
      @write_io.write(bytes)
    end

    def read_available_output(max)
      @read_io.read_nonblock(max)
    end

    def resize(rows, cols, px_width: 0, px_height: 0)
      @read_io.winsize = [rows, cols]
    end

    def refresh_size(rows, cols, px_width: 0, px_height: 0)
      resize(rows, cols, px_width: px_width, px_height: px_height)
    end

    def alive?
      @wait_thread&.alive?
    end

    def interrupt
      write("\x03")
    rescue IOError, SystemCallError
    end

    def close
      @write_io.close rescue nil
      @read_io.close rescue nil
      begin
        Process.kill(:KILL, @pid) if @wait_thread&.alive?
      rescue Errno::ESRCH
      ensure
        @wait_thread = nil
      end
    end

    private

    def install_winsize_accessors(rows, cols)
      pty_rows = rows
      pty_cols = cols
      [@read_io, @write_io].each do |io|
        io.define_singleton_method(:winsize) { [pty_rows, pty_cols] }
        io.define_singleton_method(:winsize=) do |size|
          pty_rows = size[0]
          pty_cols = size[1]
        end
      end
    end
  end

  class WindowsConPTYBackend
    attr_reader :read_io, :write_io, :pid

    def initialize(command:, env:, rows:, cols:, px_width: 0, px_height: 0, conpty: nil)
      require_relative "conpty"

      @conpty = conpty || ConPTY.new
      @console_encoding = self.class.windows_console_encoding
      command_line = command.is_a?(Array) ? self.class.windows_command_line(command) : command
      @conpty.spawn(command_line, cols: cols, rows: rows, env: env)
      @pid = @conpty.h_process_id.to_i
      @closed = false
      @conpty_output_ended_with_cr = false
      @read_io = WindowsConPTYIO.new(self, readable: true, rows: rows, cols: cols)
      @write_io = WindowsConPTYIO.new(self, readable: false, rows: rows, cols: cols)
    end

    def write(bytes)
      @conpty.write(encode_console_input(bytes))
    end

    def read_available_output(max)
      output = @conpty.read_available_output(max)
      output = normalize_conpty_clear_multiline_repaint(output)
      output = normalize_conpty_repaint(output)
      output = normalize_conpty_home_erase_repaint(output)
      output = normalize_conpty_resize_repaint(output)
      decode_console_output(normalize_output_newlines(output))
    end

    def resize(rows, cols, px_width: 0, px_height: 0)
      @conpty.resize(cols, rows)
      @read_io.winsize = [rows, cols]
      @write_io.winsize = [rows, cols]
    end

    def refresh_size(rows, cols, px_width: 0, px_height: 0)
      resize(rows, cols, px_width: px_width, px_height: px_height)
    end

    def alive?
      @conpty.alive?
    end

    def interrupt
      write("\x03")
    rescue IOError, SystemCallError
    end

    def close
      @closed = true
      @conpty.kill
    end

    def closed?
      @closed
    end

    private

    def self.windows_console_encoding
      require "fiddle"
      kernel32 = Fiddle.dlopen("kernel32.dll")
      get_oem_cp = Fiddle::Function.new(kernel32["GetOEMCP"], [], Fiddle::TYPE_UINT)
      Encoding.find("CP#{get_oem_cp.call}")
    rescue StandardError
      Encoding.find("locale")
    end

    def self.windows_command_line(argv)
      argv.map { |arg| quote_windows_arg(arg.to_s) }.join(" ")
    end

    def self.quote_windows_arg(arg)
      return '""' if arg.empty?
      return arg unless arg.match?(/[\s"]/)

      quoted = +"\""
      backslashes = 0
      arg.each_char do |char|
        if char == "\\"
          backslashes += 1
        elsif char == '"'
          quoted << ("\\" * (backslashes * 2 + 1))
          quoted << '"'
          backslashes = 0
        else
          quoted << ("\\" * backslashes)
          quoted << char
          backslashes = 0
        end
      end
      quoted << ("\\" * (backslashes * 2))
      quoted << '"'
    end

    def encode_console_input(bytes)
      bytes.to_s.dup.force_encoding("UTF-8")
    end

    def decode_console_output(bytes)
      decode_mixed_console_output(bytes.to_s.b)
    end

    def decode_mixed_console_output(bytes)
      output = +""
      i = 0

      while i < bytes.bytesize
        byte = bytes.getbyte(i)
        if byte < 0x80
          output << byte
          i += 1
        elsif (utf8 = read_utf8_char(bytes, i))
          output << utf8
          i += utf8.bytesize
        else
          len = console_encoded_char_length(bytes, i)
          output << bytes.byteslice(i, len).force_encoding(@console_encoding).encode(
            "UTF-8",
            invalid: :replace,
            undef: :replace
          )
          i += len
        end
      end

      output
    end

    def read_utf8_char(bytes, offset)
      first = bytes.getbyte(offset)
      len =
        if first && first >= 0xC2 && first <= 0xDF
          2
        elsif first && first >= 0xE0 && first <= 0xEF
          3
        elsif first && first >= 0xF0 && first <= 0xF4
          4
        end
      return nil unless len && offset + len <= bytes.bytesize

      candidate = bytes.byteslice(offset, len)
      return nil unless candidate.bytes.drop(1).all? { |byte| byte >= 0x80 && byte <= 0xBF }

      candidate = candidate.dup.force_encoding("UTF-8")
      candidate.valid_encoding? ? candidate : nil
    end

    def console_encoded_char_length(bytes, offset)
      byte = bytes.getbyte(offset)
      if @console_encoding == Encoding::Windows_31J &&
         byte &&
         ((byte >= 0x81 && byte <= 0x9F) || (byte >= 0xE0 && byte <= 0xFC)) &&
         offset + 1 < bytes.bytesize
        2
      else
        1
      end
    end

    CMD_INPUT_REPAINT_PREFIX = "\e[?25l\e[2J\e[m\e[H".b
    CMD_CLEAR_MULTILINE_REPAINT = /\e\[\?25l\e\[2J\e\[m\e\[H(?=.*\r?\n).*?(?:\e\[\d+;\d+H|\e\[H)(?:\e\]0;[^\a]*\a)?\e\[\?25h/m.freeze

    def normalize_conpty_clear_multiline_repaint(output)
      output.gsub(CMD_CLEAR_MULTILINE_REPAINT, "".b)
    end

    def normalize_conpty_repaint(output)
      return output unless output.start_with?(CMD_INPUT_REPAINT_PREFIX)

      output.byteslice(CMD_INPUT_REPAINT_PREFIX.bytesize..) || "".b
    end

    CMD_INPUT_HOME_ERASE_REPAINT = /\A\e\[\?25l\e\[H( +)\e\[H\e\[\?25h\z/.freeze
    CMD_HOME_MULTILINE_REPAINT = /\A\e\[\?25l\e\[H(?=.*\r?\n).*?(?:\e\[\d+;\d+H|\e\[H)\e\[\?25h\z/m.freeze

    def normalize_conpty_home_erase_repaint(output)
      return "".b if output.match?(CMD_HOME_MULTILINE_REPAINT)

      if (match = CMD_INPUT_HOME_ERASE_REPAINT.match(output))
        "\b \b" * match[1].bytesize
      else
        output
      end
    end

    CMD_RESIZE_REPAINT = /\A\e\[\?25l\e\[8;\d+;\d+t\e\[H.*(?:\e\[K(?:\r?\n)?)+\e\[\d+;\d+H\e\[\?25h\z/m.freeze

    def normalize_conpty_resize_repaint(output)
      output.match?(CMD_RESIZE_REPAINT) ? "".b : output
    end

    def normalize_output_newlines(output)
      normalized = +"".b
      output.each_byte do |byte|
        if byte == 10
          normalized << "\r" unless @conpty_output_ended_with_cr
          normalized << "\n"
        else
          normalized << byte
        end
        @conpty_output_ended_with_cr = byte == 13
      end
      normalized
    end
  end

  class WindowsConPTYIO
    attr_accessor :winsize

    def initialize(backend, readable:, rows:, cols:)
      @backend = backend
      @readable = readable
      @winsize = [rows, cols]
    end

    def readpartial(max)
      raise IOError, "not opened for reading" unless @readable
      data = @backend.read_available_output(max)
      raise IO::WaitReadable if data.empty?
      data
    end

    def write(bytes)
      raise IOError, "not opened for writing" if @readable
      @backend.write(bytes)
    end

    def print(*args)
      write(args.join)
    end

    def flush
      nil
    end

    def close
      @backend.close
    end

    def closed?
      @backend.closed?
    end
  end

  class UnixPtyBackend
    attr_reader :read_io, :write_io, :pid

    def initialize(command:, env:, rows:, cols:, px_width: 0, px_height: 0)
      require "pty"

      spawn_args = command.is_a?(Array) ? command : [command]
      @read_io, @write_io, @pid = PTY.spawn(*(env ? [env, *spawn_args] : spawn_args))
      resize(rows, cols, px_width: px_width, px_height: px_height)
    end

    def write(bytes)
      @write_io.write(bytes)
    end

    def read_available_output(max)
      @read_io.read_nonblock(max)
    end

    def resize(rows, cols, px_width: 0, px_height: 0)
      @read_io.winsize = [rows, cols, px_width, px_height]
    end

    def refresh_size(rows, cols, px_width: 0, px_height: 0)
      resize(rows, cols, px_width: px_width, px_height: px_height)
    end

    def alive?
      Process.waitpid(@pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      false
    end

    def interrupt
      Process.kill(:INT, @pid)
    rescue Errno::ESRCH
    end

    def close
      @write_io.close rescue nil
      @read_io.close rescue nil
      Process.kill(:HUP, @pid) rescue nil
    end
  end

  class MacPtyBackend < UnixPtyBackend
    DARWIN_TIOCSCTTY = 0x20007461
    DARWIN_TIOCSPGRP = 0x80047476

    def initialize(command:, env:, rows:, cols:, px_width: 0, px_height: 0)
      require "pty"

      spawn_args = command.is_a?(Array) ? command : [command]
      master, slave = PTY.open
      slave.winsize = [rows, cols, px_width, px_height]
      @pid = fork do
        master.close
        Process.setsid rescue nil
        slave.ioctl(DARWIN_TIOCSCTTY, 0) rescue nil
        slave.ioctl(DARWIN_TIOCSPGRP, [Process.getpgrp].pack("i!")) rescue nil
        STDIN.reopen(slave)
        STDOUT.reopen(slave)
        STDERR.reopen(slave)
        slave.close rescue nil
        if env
          exec(env, *spawn_args)
        else
          exec(*spawn_args)
        end
      end
      slave.close
      @read_io = master
      @write_io = master
    end
  end
end
