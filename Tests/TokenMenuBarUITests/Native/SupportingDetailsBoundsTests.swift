import AppKit
import SwiftUI
import Testing
import TokenMenuBarCore
import TokenMenuBarTestSupport

@testable import TokenMenuBarUI

// AppKit draws the triangle left of the group's own bounds, so the card and tab padding around a group is what has to
// keep it reachable.
@Test @MainActor func supportingDisclosureKeepsItsHitTargetInsideTheTabPadding() async throws {
  let fixture = NativeHosting(
    SupportingDetails("Details", id: "details", state: DisclosureState()) { Text("Supporting detail") }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 11)
      .padding(.horizontal, PopoverGeometry.contentPadding),
    width: 400, height: 100)
  defer { fixture.close() }
  fixture.show()
  await mainActorTurn()
  let accessibility = await Task.detached {
    let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
    var windows: CFTypeRef?
    return AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
  }.value
  try #require(accessibility == .success)
  var visited: Set<ObjectIdentifier> = []
  let disclosures = disclosureFrames(in: fixture.view, visited: &visited)
  #expect(!disclosures.isEmpty)
  for frame in disclosures {
    #expect(!frame.isEmpty)
    #expect(frame.minX >= fixture.view.accessibilityFrame().minX)
    #expect(frame.maxX <= fixture.view.accessibilityFrame().maxX)
  }
}

@MainActor private func disclosureFrames(in element: AnyObject, visited: inout Set<ObjectIdentifier>) -> [CGRect] {
  guard visited.insert(ObjectIdentifier(element)).inserted else { return [] }
  if element.accessibilityIdentifier?() == "disclosure-details", let frame = element.accessibilityFrame?() {
    return [frame]
  }
  return (element.accessibilityChildren?() ?? []).flatMap {
    disclosureFrames(in: $0 as AnyObject, visited: &visited)
  }
}
