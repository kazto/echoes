# frozen_string_literal: true

require_relative "lib/echoes/version"

Gem::Specification.new do |spec|
  spec.name = "echoes"
  spec.version = Echoes::VERSION
  spec.authors = ["Akira Matsuda"]
  spec.email = ["ronnie@dio.jp"]

  spec.summary = "A pure-Ruby terminal emulator with AppKit and ConPTY backends."
  spec.description = <<~DESC
    Echoes is a pure-Ruby terminal emulator with a macOS AppKit GUI
    and an in-progress Windows ConPTY shell backend. It includes
    first-class integrations for rubish (in-process shell) and rvim
    (in-process vim editor) panes on supported platforms, plus a
    private OSC namespace for in-pane Ruby tools that want to drive UI
    features (gradient backgrounds, rectangular fills,
    proportional-font text) other terminals can't. Written in pure
    Ruby on top of native APIs via Fiddle.
  DESC
  spec.homepage = "https://github.com/amatsuda/echoes"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/amatsuda/echoes"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.post_install_message = <<~MSG
    To launch Echoes from Spotlight / Dock / Cmd-Space, run:

        echoes install

    On macOS this drops thin Echoes.app and EchoesEmbed.app shortcuts
    in ~/Applications/ that exec into the real gem-bundled launchers.
    On Windows this writes an echoes.bat wrapper to ~/bin by default.
    Re-run `echoes install` after each `gem update echoes` to refresh
    the shortcuts; `echoes uninstall` removes them.
  MSG

  # Uncomment to register a new dependency of your gem
  spec.add_dependency 'syslog'
  spec.add_dependency 'fiddle'

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
