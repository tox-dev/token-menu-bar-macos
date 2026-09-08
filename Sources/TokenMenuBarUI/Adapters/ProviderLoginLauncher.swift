import Foundation
import TokenMenuBarCore

public enum ProviderLoginLauncher {
  public static func make(
    directory: URL, enabled: Bool, configurationDirectories: [ProviderLoginCommand: URL] = [:],
    open: @escaping @MainActor (URL) async throws -> Void
  ) -> (@MainActor (ProviderLoginCommand) async throws -> Void)? {
    guard enabled else { return nil }
    return { command in
      let url = try await Task.detached(priority: .userInitiated) {
        try command.write(in: directory, configurationDirectory: configurationDirectories[command])
      }.value
      try await open(url)
    }
  }
}
