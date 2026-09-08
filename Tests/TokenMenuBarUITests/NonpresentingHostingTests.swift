import AppKit
import SwiftUI
import Testing

@Test @MainActor func localRenderingNeverAttachesAWindow() {
  let hosting = host(Text("Rendered without a desktop window"))
  let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
  if let bitmap { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }

  #expect(bitmap != nil)
  #expect(hosting.window == nil)
}

@Test @MainActor func localRenderingDoesNotRetainItsHost() {
  weak var released: NSHostingView<Text>?
  autoreleasepool {
    let hosting = host(Text("Temporary render"))
    released = hosting
    #expect(released != nil)
  }

  #expect(released == nil)
}
