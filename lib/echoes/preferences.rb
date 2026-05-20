# frozen_string_literal: true

require 'rbconfig'
require 'fileutils'

module Echoes
  # Thin wrapper around configuration persistence.
  # On macOS, it wraps `[NSUserDefaults initWithSuiteName:]` saving in `~/Library/Preferences/<SUITE>.plist`.
  # On Windows, it falls back to a JSON file saved in `~/.config/echoes/preferences.json`.
  module Preferences
    is_macos = RbConfig::CONFIG['host_os'] =~ /darwin/

    if is_macos
      require_relative 'objc'
      SUITE = 'jp.dio.echoes'

      def self.defaults
        @defaults ||= begin
          obj = ObjC::MSG_PTR.call(ObjC.cls('NSUserDefaults'), ObjC.sel('alloc'))
          ObjC::MSG_PTR_1.call(obj, ObjC.sel('initWithSuiteName:'), ObjC.nsstring(SUITE))
        end
      end

      # Returns the stored Float for `key`, or `default` if the key isn't
      # set. We round-trip through `objectForKey:` so we can distinguish
      # "missing" from "set to 0.0" — `doubleForKey:` collapses both.
      def self.fetch_double(key, default:)
        obj = ObjC::MSG_PTR_1.call(defaults, ObjC.sel('objectForKey:'), ObjC.nsstring(key.to_s))
        return default if obj.null?
        ObjC::MSG_RET_D.call(obj, ObjC.sel('doubleValue'))
      end

      def self.set_double(key, value)
        ObjC::MSG_VOID_D_1.call(defaults, ObjC.sel('setDouble:forKey:'),
                                value.to_f, ObjC.nsstring(key.to_s))
      end

      def self.delete(key)
        ObjC::MSG_VOID_1.call(defaults, ObjC.sel('removeObjectForKey:'),
                              ObjC.nsstring(key.to_s))
      end
    else
      require 'json'
      CONFIG_DIR = File.join(Dir.home, '.config', 'echoes')
      PREFS_PATH = File.join(CONFIG_DIR, 'preferences.json')

      def self.defaults
        @defaults ||= begin
          FileUtils.mkdir_p(CONFIG_DIR) unless Dir.exist?(CONFIG_DIR)
          if File.exist?(PREFS_PATH)
            JSON.parse(File.read(PREFS_PATH)) rescue {}
          else
            {}
          end
        end
      end

      def self.save_defaults
        File.write(PREFS_PATH, JSON.pretty_generate(defaults))
      rescue => e
        warn "echoes preferences: failed to save preferences: #{e.message}"
      end

      # Returns the stored Float for `key`, or `default` if the key isn't set.
      def self.fetch_double(key, default:)
        defaults[key.to_s]&.to_f || default
      end

      def self.set_double(key, value)
        defaults[key.to_s] = value.to_f
        save_defaults
      end

      def self.delete(key)
        defaults.delete(key.to_s)
        save_defaults
      end
    end
  end
end
