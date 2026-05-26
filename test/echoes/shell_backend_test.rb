# encoding: UTF-8
# frozen_string_literal: true

require "test_helper"
require "echoes/shell_backend"
require "echoes/conpty"
require "fileutils"

class Echoes::ShellBackendTest < Test::Unit::TestCase
  test "selects Windows popen backend on Windows" do
    assert_equal(
      Echoes::WindowsPopenBackend,
      Echoes::ShellBackend.for_platform("mswin")
    )
  end

  test "selects Windows ConPTY backend when requested" do
    assert_equal(
      Echoes::WindowsConPTYBackend,
      Echoes::ShellBackend.for_platform("mswin", windows_backend: :conpty)
    )
  end

  test "selects Mac pty backend on macOS" do
    assert_equal(
      Echoes::MacPtyBackend,
      Echoes::ShellBackend.for_platform("darwin")
    )
  end

  test "selects Unix pty backend on other Unix platforms" do
    assert_equal(
      Echoes::UnixPtyBackend,
      Echoes::ShellBackend.for_platform("linux")
    )
  end

  class FakeConPTY
    attr_reader :spawn_args, :resizes, :writes, :killed

    def initialize(outputs = [])
      @pipe_out_r = 111
      @pipe_in_w = 222
      @h_process = 333
      @h_process_id = 444
      @resizes = []
      @writes = []
      @killed = false
      @outputs = outputs
    end

    attr_reader :pipe_out_r, :pipe_in_w, :h_process, :h_process_id

    def spawn(command, cols:, rows:, env: nil)
      @spawn_args = [command, cols, rows, env]
    end

    def resize(cols, rows)
      @resizes << [cols, rows]
    end

    def write(bytes)
      @writes << bytes
    end

    def read_available_output(max)
      @outputs.empty? ? "x" * max : @outputs.shift
    end

    def alive?
      true
    end

    def kill
      @killed = true
    end
  end

  test "ConPTY backend exposes the shell backend contract" do
    conpty = FakeConPTY.new
    backend = Echoes::WindowsConPTYBackend.new(
      command: "powershell.exe",
      env: nil,
      rows: 24,
      cols: 80,
      conpty: conpty
    )

    assert_equal(["powershell.exe", 80, 24, nil], conpty.spawn_args)
    assert_equal(444, backend.pid)
    assert_equal("xxxxx", backend.read_available_output(5))

    backend.write("abc")
    backend.resize(30, 100)
    assert_equal(["abc"], conpty.writes)
    assert_equal([[100, 30]], conpty.resizes)
    assert_true(backend.alive?)

    backend.close
    assert_true(conpty.killed)
  end

  test "ConPTY backend decodes locale encoded output as UTF-8" do
    cp932 = "日本語".encode("Windows-31J").b
    conpty = FakeConPTY.new([cp932])
    backend = Echoes::WindowsConPTYBackend.new(
      command: "cmd.exe",
      env: nil,
      rows: 24,
      cols: 80,
      conpty: conpty
    )

    assert_equal("日本語", backend.read_available_output(16_384))
  ensure
    backend&.close
  end

  test "ConPTY backend encodes UTF-8 input for the console code page" do
    conpty = FakeConPTY.new
    backend = Echoes::WindowsConPTYBackend.new(
      command: "cmd.exe",
      env: nil,
      rows: 24,
      cols: 80,
      conpty: conpty
    )

    backend.write("日本語")

    assert_equal(["cmd.exe", 80, 24, nil], conpty.spawn_args)
    assert_equal(["日本語".encode("Windows-31J").b], conpty.writes.map(&:b))
  ensure
    backend&.close
  end

  test "ConPTY backend strips cmd input repaint prefix" do
    conpty = FakeConPTY.new(["\e[?25l\e[2J\e[m\e[Hd\e]0;cmd\a\e[?25h"])
    backend = Echoes::WindowsConPTYBackend.new(
      command: "cmd.exe",
      env: nil,
      rows: 24,
      cols: 80,
      conpty: conpty
    )

    assert_equal("d\e]0;cmd\a\e[?25h", backend.read_available_output(16_384))
  ensure
    backend&.close
  end

  test "ConPTY backend translates cmd home erase repaint to backspace echo" do
    conpty = FakeConPTY.new(["\e[?25l\e[H  \e[H\e[?25h"])
    backend = Echoes::WindowsConPTYBackend.new(
      command: "cmd.exe",
      env: nil,
      rows: 24,
      cols: 80,
      conpty: conpty
    )

    assert_equal("\b \b\b \b", backend.read_available_output(16_384))
  ensure
    backend&.close
  end

  test "ConPTY backend drops cmd resize repaint" do
    repaint = "\e[?25l\e[8;40;120t\e[Hdir\e[K\r\n" \
              "\e[K\r\n\e[K\r\n\e[K\e[2;1H\e[?25h"
    conpty = FakeConPTY.new([repaint])
    backend = Echoes::WindowsConPTYBackend.new(
      command: "cmd.exe",
      env: nil,
      rows: 24,
      cols: 80,
      conpty: conpty
    )

    assert_equal("", backend.read_available_output(16_384))
  ensure
    backend&.close
  end

  test "ConPTY backend normalizes lone line feeds" do
    conpty = FakeConPTY.new(["a\nb\r\nc\r", "\nd"])
    backend = Echoes::WindowsConPTYBackend.new(
      command: "cmd.exe",
      env: nil,
      rows: 24,
      cols: 80,
      conpty: conpty
    )

    assert_equal("a\r\nb\r\nc\r", backend.read_available_output(16_384))
    assert_equal("\nd", backend.read_available_output(16_384))
  ensure
    backend&.close
  end

  test "Windows process tree terminator kills descendants deepest first" do
    killed = []
    terminator = Echoes::WindowsProcessTreeTerminator.new(
      processes: [
        {pid: 10, parent_pid: 1},
        {pid: 20, parent_pid: 10},
        {pid: 30, parent_pid: 20},
        {pid: 40, parent_pid: 10},
        {pid: 50, parent_pid: 99}
      ],
      terminate_process: ->(pid) { killed << pid }
    )

    terminator.kill_descendants(10)

    assert_equal([30, 20, 40], killed)
  end

  test "Windows ConPTY backend talks to cmd.exe" do
    omit("Windows only") unless TestHelper::IS_WINDOWS

    backend = Echoes::WindowsConPTYBackend.new(
      command: "cmd.exe",
      env: nil,
      rows: 24,
      cols: 80
    )
    begin
      output = drain_backend_output(backend, until_match: /C:\\.*>/)
      assert_match(/C:\\.*>/, output)

      backend.write("echo echoes-conpty\r\n")
      output = drain_backend_output(backend, until_match: /echoes-conpty/)
      assert_match(/echoes-conpty/, output)
    ensure
      backend.close
    end
  end

  test "Windows ConPTY backend displays Japanese filenames from cmd output" do
    omit("Windows only") unless TestHelper::IS_WINDOWS

    dir = File.join(Dir.pwd, "tmp", "jp-encoding-test")
    name = "日本語.txt"
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), "")

    backend = Echoes::WindowsConPTYBackend.new(
      command: "cmd.exe",
      env: nil,
      rows: 24,
      cols: 100
    )
    begin
      drain_backend_output(backend, until_match: /C:\\.*>/)

      backend.write("cd /d #{dir}\r\n")
      drain_backend_output(backend, until_match: /#{Regexp.escape(dir)}>/i)

      backend.write("dir /b\r\n")
      output = drain_backend_output(backend, until_match: /#{Regexp.escape(name)}/)
      assert_true(output.valid_encoding?)
      assert_match(/#{Regexp.escape(name)}/, output)
    ensure
      backend.close
      FileUtils.rm_f(File.join(dir, name))
      FileUtils.rmdir(dir) rescue nil
    end
  end

  test "Windows ConPTY backend passes explicit environment" do
    omit("Windows only") unless TestHelper::IS_WINDOWS

    env = ENV.to_h.merge("ECHOES_CONPTY_ENV_TEST" => "ok")
    backend = Echoes::WindowsConPTYBackend.new(
      command: "cmd.exe",
      env: env,
      rows: 24,
      cols: 80
    )
    begin
      drain_backend_output(backend, until_match: /C:\\.*>/)
      backend.write("echo %ECHOES_CONPTY_ENV_TEST%\r\n")
      output = drain_backend_output(backend, until_match: /ok/)
      assert_match(/ok/, output)
    ensure
      backend.close
    end
  end

  test "Windows ConPTY backend keeps prompt when cmd echoes first input" do
    omit("Windows only") unless TestHelper::IS_WINDOWS

    backend = Echoes::WindowsConPTYBackend.new(
      command: "cmd.exe",
      env: nil,
      rows: 10,
      cols: 80
    )
    screen = Echoes::Screen.new(rows: 10, cols: 80)
    parser = Echoes::Parser.new(screen)
    begin
      drain_backend_output(backend, until_match: /C:\\.*>/, parser: parser)

      backend.write("d")
      drain_backend_output(backend, until_match: /d/, parser: parser)

      assert_match(/C:\\.*>d\z/, screen.to_text)
    ensure
      backend.close
    end
  end

  test "Windows ConPTY backend edits echoed cmd input with delete backspace" do
    omit("Windows only") unless TestHelper::IS_WINDOWS

    backend = Echoes::WindowsConPTYBackend.new(
      command: "cmd.exe",
      env: nil,
      rows: 10,
      cols: 80
    )
    screen = Echoes::Screen.new(rows: 10, cols: 80)
    parser = Echoes::Parser.new(screen)
    begin
      drain_backend_output(backend, until_match: /C:\\.*>/, parser: parser)

      backend.write("dir")
      drain_backend_output(backend, until_match: /r/, parser: parser)
      assert_match(/C:\\.*>dir\z/, screen.to_text)

      3.times do
        backend.write("\x7F")
        drain_backend_output(backend, until_match: /\b \b/, parser: parser)
      end

      assert_match(/C:\\.*>\z/, screen.to_text)
    ensure
      backend.close
    end
  end

  private

  def drain_backend_output(backend, until_match:, attempts: 30, parser: nil)
    output = +""
    attempts.times do
      chunk = backend.read_available_output(16_384)
      output << chunk if chunk && !chunk.empty?
      parser&.feed(chunk) if chunk && !chunk.empty?
      break if output.match?(until_match)
      sleep 0.1
    end
    output
  end
end
