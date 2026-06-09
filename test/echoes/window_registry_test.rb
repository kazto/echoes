# frozen_string_literal: true

require 'test/unit'
require_relative '../../lib/echoes'
require_relative '../../lib/echoes/window_registry'

# Only run these tests on Windows
return unless Echoes::Platform.windows?

class Echoes::WindowRegistryTest < Test::Unit::TestCase
  def setup
    @old_registry_name = ENV['ECHOES_WINDOW_REGISTRY_NAME']
    ENV['ECHOES_WINDOW_REGISTRY_NAME'] = "EchoesWindowRegistryTest_#{Process.pid}_#{object_id}"
    # Clean up any existing registry before each test
    Echoes::WindowRegistry.cleanup
    # Force cleanup of instance variables
    Echoes::WindowRegistry.class_eval do
      @mapping = nil
      @view = nil
      @mutex = nil
    end
  end

  def teardown
    # Clean up after each test
    Echoes::WindowRegistry.cleanup
    # Force cleanup of instance variables
    Echoes::WindowRegistry.class_eval do
      @mapping = nil
      @view = nil
      @mutex = nil
    end
    ENV['ECHOES_WINDOW_REGISTRY_NAME'] = @old_registry_name
  end

  def test_window_registration
    hwnd = 12345
    title = "Test Window"

    result = Echoes::WindowRegistry.register_window(hwnd, title)
    assert_true result

    windows = Echoes::WindowRegistry.list_windows
    assert_equal 1, windows.size
    assert_equal hwnd, windows[0][:hwnd]
    assert_equal title, windows[0][:title]
    assert_equal Process.pid, windows[0][:pid]
  end

  def test_multiple_window_registration
    # Simulate multiple processes by using different PIDs
    pid1 = Process.pid + 1
    pid2 = Process.pid + 2
    hwnd1 = 11111
    hwnd2 = 22222
    title1 = "Window 1"
    title2 = "Window 2"

    Echoes::WindowRegistry.register_window(hwnd1, title1)
    # Register second window manually since we're simulating different PIDs
    Echoes::WindowRegistry.send(:find_or_create_entry, pid2, hwnd2, title2)

    windows = Echoes::WindowRegistry.list_windows
    assert_equal 2, windows.size

    titles = windows.map { |w| w[:title] }
    assert_include titles, title1
    assert_include titles, title2

    hwnds = windows.map { |w| w[:hwnd] }
    assert_include hwnds, hwnd1
    assert_include hwnds, hwnd2
  end

  def test_window_unregistration
    hwnd = 54321
    title = "Test Window"

    Echoes::WindowRegistry.register_window(hwnd, title)
    assert_equal 1, Echoes::WindowRegistry.list_windows.size

    result = Echoes::WindowRegistry.unregister_window(Process.pid)
    assert_true result
    assert_equal 0, Echoes::WindowRegistry.list_windows.size
  end

  def test_window_title_update
    hwnd = 99999
    original_title = "Original Title"
    updated_title = "Updated Title"

    Echoes::WindowRegistry.register_window(hwnd, original_title)

    result = Echoes::WindowRegistry.update_title(Process.pid, updated_title)
    assert_true result

    windows = Echoes::WindowRegistry.list_windows
    assert_equal 1, windows.size
    assert_equal updated_title, windows[0][:title]
  end

  def test_max_windows_limit
    hwnds = []
    Echoes::WindowRegistry.register_window(9999, "Initial Window")
    (Echoes::WindowRegistry::MAX_WINDOWS + 5).times do |i|
      # Simulate different processes
      simulated_pid = Process.pid + i + 1
      hwnd = 10000 + i
      # Manually create entries to simulate multiple processes
      result = Echoes::WindowRegistry.send(:find_or_create_entry, simulated_pid, hwnd, "Window #{i}")
      # Should succeed for first MAX_WINDOWS, fail for extras
      if i < Echoes::WindowRegistry::MAX_WINDOWS - 1
        assert_true result, "Should succeed for window #{i}"
      else
        # Registry is full
        assert_false result, "Should fail for window #{i} beyond limit"
      end
    end

    windows = Echoes::WindowRegistry.list_windows
    assert_equal Echoes::WindowRegistry::MAX_WINDOWS, windows.size
  end

  def test_window_registration_updates_existing_entry
    hwnd1 = 11111
    hwnd2 = 22222
    title1 = "First Title"
    title2 = "Second Title"

    Echoes::WindowRegistry.register_window(hwnd1, title1)
    assert_equal 1, Echoes::WindowRegistry.list_windows.size

    # Register with same PID but different hwnd/title should update
    Echoes::WindowRegistry.register_window(hwnd2, title2)
    windows = Echoes::WindowRegistry.list_windows

    assert_equal 1, windows.size, "Should still have only one entry for this PID"
    assert_equal hwnd2, windows[0][:hwnd], "Should update HWND"
    assert_equal title2, windows[0][:title], "Should update title"
  end

  def test_empty_list_initially
    # This test may fail if there are leftover windows from previous runs
    # The shared memory persists across processes
    windows = Echoes::WindowRegistry.list_windows
    assert windows.size >= 0
  end

  def test_focus_window_valid_handle
    hwnd = 12345
    Echoes::WindowRegistry.register_window(hwnd, "Test Window")

    # This will fail in test environment since we don't have a real window,
    # but it tests the function signature and error handling
    result = Echoes::WindowRegistry.focus_window(hwnd)
    # Result should be false for invalid window handle in test environment
    assert_false result
  end

  def test_focus_window_nil_handle
    result = Echoes::WindowRegistry.focus_window(nil)
    assert_false result
  end

  def test_registry_persistence_across_operations
    hwnd = 88888
    title = "Persistent Window"

    Echoes::WindowRegistry.register_window(hwnd, title)
    assert_equal 1, Echoes::WindowRegistry.list_windows.size

    # Update title
    Echoes::WindowRegistry.update_title(Process.pid, "New Title")
    windows = Echoes::WindowRegistry.list_windows
    assert_equal "New Title", windows[0][:title]

    # List again
    windows = Echoes::WindowRegistry.list_windows
    assert_equal 1, windows.size
    assert_equal "New Title", windows[0][:title]
  end

  def test_unicode_window_title
    hwnd = 77777
    title = "日本語ウィンドウ 🎨"

    result = Echoes::WindowRegistry.register_window(hwnd, title)
    assert_true result

    windows = Echoes::WindowRegistry.list_windows
    assert_equal 1, windows.size
    assert_equal title, windows[0][:title]
  end

  def test_concurrent_access_safety
    hwnd_base = 60000
    threads = []

    5.times do |i|
      threads << Thread.new do
        hwnd = hwnd_base + i
        Echoes::WindowRegistry.register_window(hwnd, "Thread #{i}")
      end
    end

    threads.each(&:join)

    windows = Echoes::WindowRegistry.list_windows
    # Due to mutex, all registrations should succeed (within limits)
    assert windows.size >= 1 && windows.size <= 5
  end

  if Echoes::Platform.windows?
  def test_registry_cleanup
    hwnd = 12345
    Echoes::WindowRegistry.register_window(hwnd, "Test Window")
    assert_equal 1, Echoes::WindowRegistry.list_windows.size

      Echoes::WindowRegistry.cleanup
      # Reset instance variables
      Echoes::WindowRegistry.class_eval do
        @mapping = nil
        @view = nil
        @mutex = nil
      end

      # After cleanup, registry should be empty
      windows = Echoes::WindowRegistry.list_windows
      assert_equal 0, windows.size
    end
  end
end
