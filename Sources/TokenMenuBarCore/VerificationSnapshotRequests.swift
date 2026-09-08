import Darwin
import Foundation

public final class VerificationSnapshotRequests {
  private let source: any DispatchSourceFileSystemObject

  @MainActor public init(snapshotURL: URL, onRequest: @escaping @MainActor @Sendable () -> Void) throws {
    try FileManager.default.createDirectory(
      at: snapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let descriptor = open(Self.requestURL(snapshotURL).path, O_EVTONLY | O_CREAT | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
    var delivered: off_t = 0
    let deliverPending: @MainActor @Sendable () -> Void = {
      var attributes = stat()
      precondition(fstat(descriptor, &attributes) == 0)
      guard attributes.st_size > delivered else { return }
      delivered = attributes.st_size
      onRequest()
    }
    source.setRegistrationHandler { MainActor.assumeIsolated { deliverPending() } }
    source.setEventHandler { MainActor.assumeIsolated { deliverPending() } }
    source.setCancelHandler { close(descriptor) }
    source.activate()
  }

  deinit { source.cancel() }

  public static func send(to snapshotURL: URL) throws {
    let file = try FileHandle(forWritingTo: requestURL(snapshotURL))
    defer { try? file.close() }
    try file.seekToEnd()
    try file.write(contentsOf: Data([0]))
  }

  private static func requestURL(_ snapshotURL: URL) -> URL {
    snapshotURL.appendingPathExtension("request")
  }
}
