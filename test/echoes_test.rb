# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class EchoesTest < Test::Unit::TestCase
  test "VERSION" do
    assert do
      ::Echoes.const_defined?(:VERSION)
    end
  end

  test "has all components" do
    assert { ::Echoes.const_defined?(:Cell) }
    assert { ::Echoes.const_defined?(:Cursor) }
    assert { ::Echoes.const_defined?(:Screen) }
    assert { ::Echoes.const_defined?(:Parser) }
    assert { ::Echoes.const_defined?(:Terminal) }
  end

  test "does not load gui backend by default" do
    ruby = RbConfig.ruby
    _out, err, status = Open3.capture3(
      ruby,
      "-Ilib",
      "-e",
      "require 'echoes'; exit(Echoes.const_defined?(:GUI, false) ? 1 : 0)"
    )
    assert_true(status.success?, err)
  end
end
