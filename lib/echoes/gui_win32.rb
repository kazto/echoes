# frozen_string_literal: true

require_relative 'gui/backend'   # Must load before core.rb defines Backend::Win32
require_relative 'win32'
require_relative 'window_registry'
require_relative 'tab'
require_relative 'pane'
require_relative 'preferences'
require_relative 'profile'
require_relative 'configuration'
require_relative 'shake_detector'
require_relative 'gui_win32/core'
require_relative 'gui_win32/menu'
require_relative 'gui_win32/window_and_input'
require_relative 'gui_win32/rendering_primitives'
require_relative 'gui_win32/rendering_panes'
require_relative 'gui_win32/rendering_capture_and_tab'
require_relative 'gui_win32/search'
