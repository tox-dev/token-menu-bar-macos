import Foundation
import TokenMenuBarCore

public struct ProviderSettingsFocusRequest: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let provider: ProviderID?

  public init(id: UUID = UUID(), provider: ProviderID?) {
    self.id = id
    self.provider = provider
  }
}
