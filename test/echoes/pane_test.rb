# frozen_string_literal: true

require "test_helper"

class Echoes::PaneTest < Test::Unit::TestCase
  setup do
    @pane = Echoes::Pane.new(command: TestHelper::CAT_COMMAND, rows: 24, cols: 80)
  end

  teardown do
    @pane.close
  end

  test "initialize creates screen with given dimensions" do
    assert_instance_of(Echoes::Screen, @pane.screen)
    assert_equal(24, @pane.screen.rows)
    assert_equal(80, @pane.screen.cols)
  end

  test "initialize creates parser" do
    assert_instance_of(Echoes::Parser, @pane.parser)
  end

  test "initialize spawns pty" do
    assert_not_nil(@pane.pty_read)
    assert_not_nil(@pane.pty_write)
    assert_not_nil(@pane.pty_pid)
  end

  test "initialize sets winsize" do
    assert_equal([24, 80], @pane.pty_read.winsize)
  end

  test "initialize sets scroll defaults" do
    assert_equal(0, @pane.scroll_offset)
    assert_equal(0.0, @pane.scroll_accum)
  end

  test "initialize sets title from command basename" do
    expected = TestHelper::IS_WINDOWS ? File.basename(TestHelper::CAT_COMMAND) : "cat"
    assert_equal(expected, @pane.title)
  end

  test "initialize sets copy_mode to nil" do
    assert_nil(@pane.copy_mode)
  end

  test "alive? returns true for running process" do
    assert_equal(true, @pane.alive?)
  end

  test "alive? returns false after process exits" do
    pane = Echoes::Pane.new(command: TestHelper::TRUE_COMMAND, rows: 5, cols: 10)
    sleep(TestHelper::IS_WINDOWS ? 2.0 : 0.2)
    assert_equal(false, pane.alive?)
    pane.close
  end

  test "resize changes screen dimensions" do
    @pane.resize(30, 100)
    assert_equal(30, @pane.screen.rows)
    assert_equal(100, @pane.screen.cols)
  end

  test "resize updates pty winsize" do
    @pane.resize(30, 100)
    assert_equal([30, 100], @pane.pty_read.winsize)
  end

  test "close closes pty streams" do
    @pane.close
    assert_equal(true, @pane.pty_write.closed?)
    assert_equal(true, @pane.pty_read.closed?)
  end

  test "close can be called multiple times" do
    assert_nothing_raised do
      @pane.close
      @pane.close
    end
  end

  test "process_output feeds data to parser" do
    @pane.process_output("hello")
    # The parser should have processed the data and put it on screen
    text = @pane.screen.grid[0].map(&:char).join.strip
    assert_equal("hello", text)
  end

  test "pty communication" do
    assert_equal(true, @pane.alive?, "Process should be alive before communication")
    sleep(TestHelper::IS_WINDOWS ? 2.0 : 0.2)

    # Drain cmd.exe startup output before checking the echoed command.
    if TestHelper::IS_WINDOWS
      15.times do
        chunk = @pane.read_available_output
        break if chunk&.end_with?(">")
        sleep 0.1
      end
    end

    @pane.pty_write.print("hello\r\n")
    @pane.pty_write.flush rescue nil
    output = +""
    if TestHelper::IS_WINDOWS
      30.times do
        chunk = @pane.read_available_output
        output << chunk if chunk && !chunk.empty?
        break if output.include?("hello")
        sleep 0.1
      end
      assert_match(/hello/, output)
    else
      sleep 0.1
      output = @pane.read_available_output
      assert_match(/hello/, output)
    end
  end
end
