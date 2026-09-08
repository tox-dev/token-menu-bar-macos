import Charts
import SwiftUI
import TokenMenuBarCore

public struct UpdatingBadge: View {
  public init() {}

  public var body: some View {
    Text("Updating").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(
      .thinMaterial, in: Capsule())
  }
}
