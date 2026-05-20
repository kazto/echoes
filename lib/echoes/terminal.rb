# frozen_string_literal: true

require 'rbconfig'
is_windows = RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/

if is_windows
  require_relative 'conpty'
else
  require 'pty'
end
require 'io/console'

module Echoes
  class Terminal
    attr_reader :screen

    def initialize(command: Echoes.config.shell, rows: nil, cols: nil)
      size = IO.console&.winsize || [24, 80]
      @rows = rows || size[0]
      @cols = cols || size[1]
      @command = command
      @screen = Screen.new(rows: @rows, cols: @cols)
      @parser = Parser.new(@screen, writer: ->(s) { @write_io&.write(s) rescue nil })
    end

    def run
      is_windows = RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/

      if is_windows
        conpty = ConPTY.new
        conpty.spawn(@command, cols: @cols, rows: @rows)

        msvcrt = Fiddle.dlopen('ucrtbase.dll') rescue Fiddle.dlopen('msvcrt.dll')
        _open_osfhandle = Fiddle::Function.new(
          msvcrt['_open_osfhandle'],
          [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT],
          Fiddle::TYPE_INT
        )

        fd_read = _open_osfhandle.call(conpty.pipe_out_r, 0 | 0x8000) # O_RDONLY | O_BINARY
        @read_io = IO.for_fd(fd_read, 'r')

        fd_write = _open_osfhandle.call(conpty.pipe_in_w, 1 | 0x8000) # O_WRONLY | O_BINARY
        @write_io = IO.for_fd(fd_write, 'w')
        @pid = conpty.h_process.to_i

        setup_signal_handlers

        STDIN.raw do
          reader = Thread.new { read_loop }
          write_loop
          reader.kill
        end

        conpty.kill
      else
        PTY.spawn(@command) do |read_io, write_io, pid|
          @read_io = read_io
          @write_io = write_io
          @pid = pid

          @read_io.winsize = [@rows, @cols]

          setup_signal_handlers

          STDIN.raw do
            reader = Thread.new { read_loop }
            write_loop
            reader.kill
          end
        end
      end
    end

    private

    def read_loop
      loop do
        data = @read_io.read_nonblock(4096)
        @parser.feed(data)
        render
      rescue IO::WaitReadable
        IO.select([@read_io])
        retry
      rescue EOFError, Errno::EIO
        break
      end
    end

    def write_loop
      loop do
        data = STDIN.read_nonblock(4096)
        @write_io.write(data)
      rescue IO::WaitReadable
        IO.select([STDIN])
        retry
      rescue EOFError, Errno::EIO
        break
      end
    end

    def render
      buf = +"\e[H"
      last_fg = nil
      last_bg = nil
      last_bold = false
      last_underline = false
      last_inverse = false

      @screen.grid.each_with_index do |row, r|
        row.each do |cell|
          if cell.fg != last_fg || cell.bg != last_bg || cell.bold != last_bold ||
             cell.underline != last_underline || cell.inverse != last_inverse
            codes = [0]
            codes << 1 if cell.bold
            codes << 2 if cell.faint
            codes << 3 if cell.italic
            codes << 4 if cell.underline
            codes << 5 if cell.blink
            codes << 7 if cell.inverse
            codes << 8 if cell.concealed
            codes << 9 if cell.strikethrough
            if cell.fg.is_a?(Array)
              codes.push(38, 2, *cell.fg)
            elsif cell.fg
              codes << (cell.fg < 8 ? cell.fg + 30 : cell.fg - 8 + 90)
            end
            if cell.bg.is_a?(Array)
              codes.push(48, 2, *cell.bg)
            elsif cell.bg
              codes << (cell.bg < 8 ? cell.bg + 40 : cell.bg - 8 + 100)
            end
            buf << "\e[#{codes.join(';')}m"
            last_fg = cell.fg
            last_bg = cell.bg
            last_bold = cell.bold
            last_underline = cell.underline
            last_inverse = cell.inverse
          end
          buf << cell.char
        end
        buf << "\r\n" unless r == @screen.rows - 1
      end

      buf << "\e[0m"
      buf << "\e[#{@screen.cursor.row + 1};#{@screen.cursor.col + 1}H"
      buf << (@screen.cursor.visible ? "\e[?25h" : "\e[?25l")
      STDOUT.write(buf)
    end

    def setup_signal_handlers
      is_windows = RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/
      return if is_windows

      Signal.trap(:WINCH) do
        if IO.console
          @rows, @cols = IO.console.winsize
          @screen.resize(@rows, @cols)
          @read_io.winsize = [@rows, @cols]
          render
        end
      end
    end
  end
end
