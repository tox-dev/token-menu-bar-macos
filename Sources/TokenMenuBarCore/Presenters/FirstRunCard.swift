public struct FirstRunCard: Equatable, Sendable {
  public let detected: [ProviderID]

  public init(detected: [ProviderID]) {
    self.detected = detected
  }

  public var title: String {
    detected.isEmpty
      ? "No providers detected yet" : "Detected: \(detected.map(\.displayName).joined(separator: ", "))"
  }

  public var description: String {
    detected.isEmpty
      ? "Sign in to a supported CLI or editor, then review the providers to choose what the menu bar shows."
      : "Review the providers to choose what the menu bar shows."
  }
}
