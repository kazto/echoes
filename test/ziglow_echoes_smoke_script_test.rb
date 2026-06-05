# frozen_string_literal: true

require "test_helper"

class ZiglowEchoesSmokeScriptTest < Test::Unit::TestCase
  SCRIPT_PATH = File.expand_path("../script/ziglow_echoes_smoke.ps1", __dir__)

  test "sends resolved ziglow paths to cmd instead of user-cwd-relative paths" do
    script = File.read(SCRIPT_PATH)

    assert_include(script, "function Resolve-SmokePath")
    assert_include(script, "[System.IO.Path]::IsPathRooted($Path)")
    assert_include(script, '$command = "$(Quote-CmdArgument $ziglowExePath) $(Quote-CmdArgument $ziglowInputPath)"')
  end

  test "positions the Echoes window before taking screenshots" do
    script = File.read(SCRIPT_PATH)

    assert_include(script, "SetWindowPos")
    assert_include(script, "[int]$WindowX = 40")
    assert_include(script, "[int]$WindowY = 40")
    assert_include(script, "[int]$WindowWidth = 1000")
    assert_include(script, "[int]$WindowHeight = 600")
    assert_operator(
      script.index("[NativeZiglowEchoesSmoke]::SetWindowPos"),
      :<,
      script.index("$initial = Capture '01-initial.png'")
    )
  end

  test "captures the window handle instead of copying an absolute screen rectangle" do
    script = File.read(SCRIPT_PATH)

    assert_include(script, "PrintWindow")
    assert_include(script, "PW_RENDERFULLCONTENT")
    assert_include(script, "$hdc = $g.GetHdc()")
    assert_not_include(script, "CopyFromScreen")
  end
end
