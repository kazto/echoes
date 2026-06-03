# frozen_string_literal: true

require "test_helper"
require "echoes/gui/osc7"

class GuiOsc7Test < Test::Unit::TestCase
  include Echoes::GUI::Osc7

  def test_returns_nil_for_nil_uri
    assert_nil cwd_from_osc7_uri(nil)
  end

  def test_returns_nil_for_empty_string
    assert_nil cwd_from_osc7_uri("")
  end

  def test_returns_nil_for_non_file_uri
    assert_nil cwd_from_osc7_uri("https://example.com/path")
  end

  def test_returns_nil_for_nonexistent_path
    assert_nil cwd_from_osc7_uri("file://localhost/nonexistent/path/xyz123")
  end

  unless Echoes::Platform.windows?
    def test_accepts_localhost
      dir = Dir.pwd
      uri = "file://localhost#{URI::DEFAULT_PARSER.escape(dir)}"
      assert_equal dir, cwd_from_osc7_uri(uri)
    end

    def test_accepts_empty_host
      dir = Dir.pwd
      uri = "file://#{URI::DEFAULT_PARSER.escape(dir)}"
      assert_equal dir, cwd_from_osc7_uri(uri)
    end
  end

  def test_rejects_remote_host
    assert_nil cwd_from_osc7_uri("file://otherhost/tmp")
  end

  if Echoes::Platform.windows?
    def test_strips_leading_slash_from_windows_path
      dir = Dir.pwd  # e.g. C:/Users/kazto/src/echoes
      encoded = URI::DEFAULT_PARSER.escape("/" + dir.gsub("\\", "/"))
      uri = "file://localhost#{encoded}"
      result = cwd_from_osc7_uri(uri)
      assert result.nil? || !result.start_with?("/"), "should not start with / on Windows, got: #{result.inspect}"
    end
  end

  def test_pane_local_cwd_returns_nil_for_nil_pane
    assert_nil pane_local_cwd(nil)
  end
end
