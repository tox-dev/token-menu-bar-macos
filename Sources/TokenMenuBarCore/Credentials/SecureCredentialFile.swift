import Darwin
import Foundation

func writeCredentialData(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
  let destination = url.resolvingSymlinksInPath()
  let temporary = destination.deletingLastPathComponent()
    .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
  do {
    try data.write(to: temporary, options: .withoutOverwriting)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
    guard rename(temporary.path, destination.path) == 0 else {
      throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
  } catch {
    try? fileManager.removeItem(at: temporary)
    throw error
  }
}
