# frozen_string_literal: true

require "test_helper"
require "echoes/preferences"
require "tmpdir"

class Echoes::PreferencesTest < Test::Unit::TestCase
  # Round-trips a key through the platform backend. Each test uses a
  # fresh random key to avoid colliding with user preferences.

  def test_fetch_double_returns_default_when_key_is_unset
    key = unique_key
    assert_equal 99.5, Echoes::Preferences.fetch_double(key, default: 99.5)
  end

  def test_set_then_fetch_round_trip
    key = unique_key
    Echoes::Preferences.set_double(key, 17.25)
    assert_equal 17.25, Echoes::Preferences.fetch_double(key, default: 0.0)
  ensure
    Echoes::Preferences.delete(key)
  end

  def test_delete_clears_a_set_key
    key = unique_key
    Echoes::Preferences.set_double(key, 42.0)
    Echoes::Preferences.delete(key)
    assert_equal(-1.0, Echoes::Preferences.fetch_double(key, default: -1.0))
  end

  def test_zero_is_distinguishable_from_missing
    key = unique_key
    Echoes::Preferences.set_double(key, 0.0)
    assert_equal 0.0, Echoes::Preferences.fetch_double(key, default: 99.0)
  ensure
    Echoes::Preferences.delete(key)
  end

  def test_json_backend_honors_echoes_config_home
    Dir.mktmpdir("echoes-prefs") do |dir|
      backend = Echoes::Preferences::JsonBackend.new(
        env: {"ECHOES_CONFIG_HOME" => dir},
        home: File.join(dir, "home")
      )

      assert_equal(File.join(dir, "preferences.json"), backend.prefs_path)
      backend.set_double(:font_size, 18.5)

      reloaded = Echoes::Preferences::JsonBackend.new(
        env: {"ECHOES_CONFIG_HOME" => dir},
        home: File.join(dir, "home")
      )
      assert_equal 18.5, reloaded.fetch_double(:font_size, default: 0.0)
    end
  end

  def test_json_backend_uses_appdata_on_windows
    omit("Windows path selection only") unless TestHelper::IS_WINDOWS

    Dir.mktmpdir("echoes-appdata") do |dir|
      backend = Echoes::Preferences::JsonBackend.new(
        env: {"APPDATA" => dir},
        home: File.join(dir, "home")
      )

      assert_equal(File.join(dir, "Echoes"), backend.config_dir)
      assert_equal(File.join(dir, "Echoes", "preferences.json"), backend.prefs_path)
    end
  end

  private

  def unique_key
    "echoes_test_#{Process.pid}_#{rand(1_000_000)}"
  end
end
