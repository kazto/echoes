# frozen_string_literal: true

require 'fileutils'
require 'json'
require_relative 'platform'

module Echoes
  # Thin wrapper around configuration persistence.
  # On macOS, it wraps `[NSUserDefaults initWithSuiteName:]` saving in
  # `~/Library/Preferences/<SUITE>.plist`.
  # On Windows, it falls back to a JSON file saved in
  # `%APPDATA%/Echoes/preferences.json`.
  module Preferences
    SUITE = 'jp.dio.echoes'

    if Platform.macos?
      require_relative 'objc'

      class MacOSBackend
        def defaults
          @defaults ||= begin
            obj = ObjC::MSG_PTR.call(ObjC.cls('NSUserDefaults'), ObjC.sel('alloc'))
            ObjC::MSG_PTR_1.call(obj, ObjC.sel('initWithSuiteName:'), ObjC.nsstring(SUITE))
          end
        end

        # Returns the stored Float for `key`, or `default` if the key isn't
        # set. We round-trip through `objectForKey:` so we can distinguish
        # "missing" from "set to 0.0"; `doubleForKey:` collapses both.
        def fetch_double(key, default:)
          obj = ObjC::MSG_PTR_1.call(defaults, ObjC.sel('objectForKey:'), ObjC.nsstring(key.to_s))
          return default if obj.null?
          ObjC::MSG_RET_D.call(obj, ObjC.sel('doubleValue'))
        end

        def set_double(key, value)
          ObjC::MSG_VOID_D_1.call(defaults, ObjC.sel('setDouble:forKey:'),
                                  value.to_f, ObjC.nsstring(key.to_s))
        end

        def delete(key)
          ObjC::MSG_VOID_1.call(defaults, ObjC.sel('removeObjectForKey:'),
                                ObjC.nsstring(key.to_s))
        end
      end
    end

    class JsonBackend
      attr_reader :config_dir, :prefs_path

      def initialize(env: ENV, home: Dir.home)
        @config_dir = if env['ECHOES_CONFIG_HOME']
                        env['ECHOES_CONFIG_HOME']
                      elsif Platform.windows?
                        File.join(env['APPDATA'] || File.join(home, 'AppData', 'Roaming'), 'Echoes')
                      else
                        File.join(home, '.config', 'echoes')
                      end
        @prefs_path = File.join(@config_dir, 'preferences.json')
      end

      def defaults
        @defaults ||= begin
          FileUtils.mkdir_p(config_dir) unless Dir.exist?(config_dir)
          if File.exist?(prefs_path)
            JSON.parse(File.read(prefs_path)) rescue {}
          else
            {}
          end
        end
      end

      def save_defaults
        File.write(prefs_path, JSON.pretty_generate(defaults))
      rescue => e
        warn "echoes preferences: failed to save preferences: #{e.message}"
      end

      # Returns the stored Float for `key`, or `default` if the key isn't set.
      def fetch_double(key, default:)
        defaults[key.to_s]&.to_f || default
      end

      def set_double(key, value)
        defaults[key.to_s] = value.to_f
        save_defaults
      end

      def delete(key)
        defaults.delete(key.to_s)
        save_defaults
      end
    end

    def self.backend
      @backend ||= Platform.macos? ? MacOSBackend.new : JsonBackend.new
    end

    def self.fetch_double(key, default:)
      backend.fetch_double(key, default: default)
    end

    def self.set_double(key, value)
      backend.set_double(key, value)
    end

    def self.delete(key)
      backend.delete(key)
    end
  end
end
