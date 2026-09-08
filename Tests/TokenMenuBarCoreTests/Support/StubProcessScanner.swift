import Darwin
import Foundation
import TokenMenuBarCore

struct StubProcessScanner: ProcessScanner {
  let entries: [ProcessEntry]
  let ports: [pid_t: [UInt16]]

  init(_ entries: [ProcessEntry] = [], ports: [pid_t: [UInt16]] = [:]) {
    self.entries = entries
    self.ports = ports
  }

  func processes() -> [ProcessEntry] { entries }

  func listeningPorts(pid: pid_t) -> [UInt16] { ports[pid, default: []] }
}

let antigravityServer = ProcessEntry(
  pid: 4242, path: "/Applications/Antigravity.app/Contents/Resources/bin/language_server_macos_arm",
  arguments: ["language_server_macos_arm", "--csrf_token", "csrf-1", "--app_data_dir", "antigravity"])

let antigravityCLI = ProcessEntry(pid: 4343, path: "/opt/homebrew/bin/agy", arguments: ["agy", "quota"])
