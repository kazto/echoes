# frozen_string_literal: true

require "test_helper"

unless Echoes::Platform.macos?
  # macOS 以外のプラットフォームではロードを行わないようにする
  return
end

Echoes.load_gui_backend

module AppKitTestHelper
  def create_pasteboard_with_file_urls(*paths)
    objc = Echoes::ObjC
    pb = objc::MSG_PTR_1.call(
      objc.cls('NSPasteboard'),
      objc.sel('pasteboardWithName:'),
      objc.nsstring("com.echoes.test.#{object_id}")
    )

    urls = paths.map do |path|
      objc::MSG_PTR_1.call(
        objc.cls('NSURL'),
        objc.sel('fileURLWithPath:'),
        objc.nsstring(path)
      )
    end

    ns_array = objc::MSG_PTR.call(objc.cls('NSMutableArray'), objc.sel('array'))
    urls.each do |url|
      objc::MSG_VOID_1.call(ns_array, objc.sel('addObject:'), url)
    end

    objc::MSG_VOID.call(pb, objc.sel('clearContents'))
    objc::MSG_PTR_1.call(pb, objc.sel('writeObjects:'), ns_array)

    pb
  end
end
