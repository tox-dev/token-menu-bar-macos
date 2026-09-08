import Darwin
import Foundation

public struct ProcessEntry: Sendable, Equatable {
  public let pid: pid_t
  public let path: String
  public let arguments: [String]

  public init(pid: pid_t, path: String, arguments: [String]) {
    self.pid = pid
    self.path = path
    self.arguments = arguments
  }
}

/// `ps` and `lsof` trigger a TCC prompt on macOS 26, so the process table is read through libproc instead.
public protocol ProcessScanner: Sendable {
  func processes() -> [ProcessEntry]
  func listeningPorts(pid: pid_t) -> [UInt16]
}

public struct LocalLanguageServer: Sendable, Equatable {
  public let pid: pid_t
  public let port: UInt16
  public let csrfToken: String?

  public init(pid: pid_t, port: UInt16, csrfToken: String?) {
    self.pid = pid
    self.port = port
    self.csrfToken = csrfToken
  }
}

public enum AntigravityLanguageServers {
  static let serverPrefixes = ["language_server", "language-server"]
  static let cliNames: Set<String> = ["agy", "antigravity-cli"]
  static let appDataDirs: Set<String> = ["antigravity", "antigravity-ide"]

  static func isCandidate(path: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    return cliNames.contains(name) || serverPrefixes.contains(where: name.hasPrefix)
  }

  enum Role: Equatable {
    case languageServer(csrfToken: String)
    case cli

    var csrfToken: String? {
      if case .languageServer(let token) = self { return token }
      return nil
    }
  }

  public static func discover(using scanner: any ProcessScanner) -> [LocalLanguageServer] {
    scanner.processes().flatMap { process -> [LocalLanguageServer] in
      guard let role = role(of: process) else { return [] }
      return scanner.listeningPorts(pid: process.pid).sorted().map {
        LocalLanguageServer(pid: process.pid, port: $0, csrfToken: role.csrfToken)
      }
    }
  }

  /// The IDE's language server needs its CSRF token and names its app data directory; the CLI needs neither.
  static func role(of process: ProcessEntry) -> Role? {
    guard isCandidate(path: process.path) else { return nil }
    let name = (process.path as NSString).lastPathComponent
    if cliNames.contains(name) { return .cli }
    guard serverPrefixes.contains(where: name.hasPrefix),
      let token = value(of: "--csrf_token", in: process.arguments),
      let directory = value(of: "--app_data_dir", in: process.arguments), appDataDirs.contains(directory)
    else { return nil }
    return .languageServer(csrfToken: token)
  }

  static func value(of flag: String, in arguments: [String]) -> String? {
    for (index, argument) in arguments.enumerated() {
      if argument.hasPrefix("\(flag)=") { return String(argument.dropFirst(flag.count + 1)) }
      if argument == flag, arguments.indices.contains(index + 1) { return arguments[index + 1] }
    }
    return nil
  }
}

enum ProcessArguments {
  /// KERN_PROCARGS2 lays out argc, the executable path, NUL padding, then argc NUL-terminated arguments before the
  /// environment.
  static func parse(_ buffer: Data) -> [String] {
    guard buffer.count > 4 else { return [] }
    let argc = Int(buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    let rest = buffer.dropFirst(4)
    guard let pathEnd = rest.firstIndex(of: 0) else { return [] }
    return rest[pathEnd...].drop { $0 == 0 }
      .split(separator: 0, maxSplits: argc, omittingEmptySubsequences: false)
      .prefix(argc)
      .map { String(decoding: $0, as: UTF8.self) }
  }
}

enum ListeningSocket {
  static func port(of info: socket_fdinfo) -> UInt16? {
    let tcp = info.psi.soi_proto.pri_tcp
    guard info.psi.soi_kind == Int32(SOCKINFO_TCP), tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { return nil }
    return UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
  }
}
