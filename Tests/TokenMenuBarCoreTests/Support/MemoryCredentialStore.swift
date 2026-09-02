import Foundation
import TokenMenuBarCore

// One double for all five credential seams: each provider reads its own type, but the behaviour under test is the
// same everywhere — hand back what was stored, or throw what the case asked for.
final class MemoryCredentialStore<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value?
  private var reads = 0
  var loadError: (any Error)?
  var saveError: (any Error)?
  private(set) var saved: [Value] = []

  init(_ value: Value?) {
    stored = value
  }

  var description: String { "memory" }
  var readCount: Int { lock.withLock { reads } }

  func read() throws -> Value? {
    lock.withLock { reads += 1 }
    if let loadError { throw loadError }
    return lock.withLock { stored }
  }

  func write(_ value: Value) throws {
    if let saveError { throw saveError }
    lock.withLock {
      stored = value
      saved.append(value)
    }
  }
}

extension MemoryCredentialStore: ClaudeCredentialStore where Value == ClaudeOAuthCredentials {
  func load() throws -> ClaudeOAuthCredentials? { try read() }
  func save(_ credentials: ClaudeOAuthCredentials) throws { try write(credentials) }
}

extension MemoryCredentialStore: CodexAuthStore where Value == CodexAuth {
  func load() throws -> CodexAuth? { try read() }
  func save(_ auth: CodexAuth) throws { try write(auth) }
}

extension MemoryCredentialStore: GeminiAuthStore where Value == GeminiAuth {
  func load() throws -> GeminiAuth? { try read() }
  func save(_ auth: GeminiAuth) throws { try write(auth) }
}

extension MemoryCredentialStore: CursorAuthStore where Value == CursorAuth {
  func load() throws -> CursorAuth? { try read() }
}

extension MemoryCredentialStore: CopilotAuthStore where Value == CopilotAuth {
  func load() throws -> CopilotAuth? { try read() }
}

typealias MemoryClaudeStore = MemoryCredentialStore<ClaudeOAuthCredentials>
typealias MemoryCodexStore = MemoryCredentialStore<CodexAuth>
typealias MemoryGeminiStore = MemoryCredentialStore<GeminiAuth>
typealias MemoryCursorStore = MemoryCredentialStore<CursorAuth>
typealias MemoryCopilotStore = MemoryCredentialStore<CopilotAuth>
