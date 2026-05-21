# frozen_string_literal: true

require 'rbconfig'

module Echoes
  module Platform
    WINDOWS_RE = /mswin|mingw|cygwin/i
    MACOS_RE = /darwin/i

    module_function

    def host_os
      RbConfig::CONFIG['host_os'].to_s
    end

    def windows?(os = host_os)
      os.to_s.match?(WINDOWS_RE)
    end

    def macos?(os = host_os)
      os.to_s.match?(MACOS_RE)
    end

    def unix?(os = host_os)
      !windows?(os)
    end

    def default_shell(os = host_os, env: ENV, executable_lookup: method(:find_executable))
      return '/bin/bash' unless windows?(os)

      comspec = env['COMSPEC'].to_s
      return comspec unless comspec.empty?

      executable_lookup.call('pwsh') || 'powershell.exe'
    end

    def find_executable(name, env: ENV)
      paths = env.fetch('PATH', '').split(File::PATH_SEPARATOR)
      exts = windows? ? env.fetch('PATHEXT', '.EXE;.BAT;.CMD').split(';') : ['']
      paths.each do |dir|
        exts.each do |ext|
          path = File.join(dir, name.end_with?(ext.downcase, ext.upcase) ? name : "#{name}#{ext.downcase}")
          return path if File.executable?(path)
        end
      end
      nil
    end
  end
end
