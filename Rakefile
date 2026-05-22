# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require_relative "lib/echoes/platform"

CORE_TEST_FILES = FileList[
  "test/echoes_test.rb",
  "test/echoes/cell_test.rb",
  "test/echoes/cli_test.rb",
  "test/echoes/client_test.rb",
  "test/echoes/configuration_test.rb",
  "test/echoes/copy_mode_test.rb",
  "test/echoes/cursor_test.rb",
  "test/echoes/embedded_shell_test.rb",
  "test/echoes/gui_test.rb",
  "test/echoes/iterm2_images_test.rb",
  "test/echoes/installer_test.rb",
  "test/echoes/keybind_test.rb",
  "test/echoes/kitty_graphics_test.rb",
  "test/echoes/parser_test.rb",
  "test/echoes/pane_test.rb",
  "test/echoes/pane_tree_test.rb",
  "test/echoes/platform_test.rb",
  "test/echoes/preferences_test.rb",
  "test/echoes/profile_test.rb",
  "test/echoes/screen_test.rb",
  "test/echoes/shell_backend_test.rb",
  "test/echoes/shake_detector_test.rb",
  "test/echoes/sixel_decoder_test.rb",
  "test/echoes/tab_test.rb",
  "test/echoes/terminal_test.rb",
]

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  if Echoes::Platform.windows?
    t.test_files = CORE_TEST_FILES
  else
    t.test_files = FileList["test/**/*_test.rb"]
  end
end

namespace :test do
  desc "Run OS-independent core tests"
  Rake::TestTask.new(:core) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = CORE_TEST_FILES
  end
end

task default: :test

desc "Sync .app Info.plist CFBundleVersion with Echoes::VERSION"
task :app do
  # The .app bundles (Echoes.app, EchoesEmbed.app) are committed
  # to the repo, including their MacOS/ launcher scripts which
  # locate `lib/` and `exe/echoes` from the script's own path —
  # no per-machine rewrite needed. The one thing that drifts on a
  # version bump is each bundle's Info.plist CFBundleVersion. This
  # task patches that line in place; everything else (launchers,
  # bundle id, package type) is left alone so any hand-edits the
  # bundles have picked up survive.
  require_relative "lib/echoes/version"
  version = Echoes::VERSION

  plists = %w[Echoes.app/Contents/Info.plist EchoesEmbed.app/Contents/Info.plist]
  plists.each do |path|
    unless File.exist?(path)
      warn "skipping #{path}: not found"
      next
    end
    text = File.read(path)
    new_text = text.sub(
      %r{(<key>CFBundleVersion</key>\s*<string>)[^<]*(</string>)},
      "\\1#{version}\\2"
    )
    if text == new_text
      puts "#{path}: already at #{version}"
    else
      File.write(path, new_text)
      puts "#{path}: CFBundleVersion → #{version}"
    end
  end
end
