import Darwin
import Foundation
import Testing
import TokenMenuBarTestSupport

@testable import TokenMenuBarCore

@Test func antigravityDiscoveryPairsCandidatesWithTheirListeningPorts() {
  let windsurf = ProcessEntry(
    pid: 1, path: "/Applications/Windsurf.app/Contents/Resources/app/bin/language_server_macos_arm",
    arguments: ["language_server_macos_arm", "--csrf_token", "other", "--app_data_dir", "windsurf"])
  let tokenless = ProcessEntry(
    pid: 2, path: "/Applications/Antigravity.app/Contents/Resources/bin/language_server_macos_arm",
    arguments: ["language_server_macos_arm", "--app_data_dir", "antigravity"])
  let hyphenated = ProcessEntry(
    pid: 3, path: "/Applications/Gemini.app/Contents/Resources/bin/language-server",
    arguments: ["language-server", "--csrf_token=csrf-3", "--app_data_dir=antigravity-ide"])
  let cli = ProcessEntry(pid: 4, path: "/usr/local/bin/antigravity-cli", arguments: ["antigravity-cli"])
  let silent = ProcessEntry(pid: 5, path: "/opt/homebrew/bin/agy", arguments: ["agy"])
  let scanner = StubProcessScanner(
    [
      windsurf, tokenless, antigravityServer, hyphenated, cli, silent,
      ProcessEntry(pid: 6, path: "/bin/zsh", arguments: []),
    ],
    ports: [1: [9000], 2: [9001], 4242: [4321, 1234], 3: [7000], 4: [8000]])

  #expect(
    AntigravityLanguageServers.discover(using: scanner) == [
      LocalLanguageServer(pid: 4242, port: 1234, csrfToken: "csrf-1"),
      LocalLanguageServer(pid: 4242, port: 4321, csrfToken: "csrf-1"),
      LocalLanguageServer(pid: 3, port: 7000, csrfToken: "csrf-3"),
      LocalLanguageServer(pid: 4, port: 8000, csrfToken: nil),
    ])
}

@Test(
  arguments: [
    (["--csrf_token", "a"], "a"), (["--csrf_token=b"], "b"), (["--csrf_token"], nil), (["--other", "c"], nil),
  ])
func antigravityDiscoveryReadsFlagValuesInBothForms(arguments: [String], expected: String?) {
  #expect(AntigravityLanguageServers.value(of: "--csrf_token", in: arguments) == expected)
}

private func procargs(argc: Int32, path: String, arguments: [String], environment: [String]) -> Data {
  var data = withUnsafeBytes(of: argc) { Data($0) }
  data.append(contentsOf: Data(path.utf8) + [0, 0, 0])
  for item in arguments + environment { data.append(contentsOf: Data(item.utf8) + [0]) }
  return data
}

@Test(
  arguments: [
    (
      "full layout", procargs(argc: 3, path: "/bin/ls", arguments: ["ls", "-l", ""], environment: ["HOME=/x"]),
      ["ls", "-l", ""]
    ),
    ("no environment", procargs(argc: 1, path: "/bin/ls", arguments: ["ls"], environment: []), ["ls"]),
    ("no arguments", procargs(argc: 0, path: "/bin/ls", arguments: [], environment: ["A=1"]), []),
    ("empty buffer", Data(), []),
    ("path without terminator", Data([1, 0, 0, 0, 0x2F, 0x62, 0x69, 0x6E]), []),
  ])
func antigravityDiscoveryParsesProcArgs(name: String, buffer: Data, expected: [String]) {
  #expect(ProcessArguments.parse(buffer) == expected)
}

private func socketInfo(kind: Int32, state: Int32, port: UInt16) -> socket_fdinfo {
  var info = socket_fdinfo()
  info.psi.soi_kind = kind
  info.psi.soi_proto.pri_tcp.tcpsi_state = state
  info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport = Int32(port.bigEndian)
  return info
}

@Test func antigravityDiscoveryKeepsListeningTCPSocketsOnly() {
  #expect(
    ListeningSocket.port(of: socketInfo(kind: Int32(SOCKINFO_TCP), state: Int32(TSI_S_LISTEN), port: 8080)) == 8080)
  #expect(
    ListeningSocket.port(of: socketInfo(kind: Int32(SOCKINFO_TCP), state: Int32(TSI_S_ESTABLISHED), port: 8080)) == nil)
  #expect(ListeningSocket.port(of: socketInfo(kind: Int32(SOCKINFO_IN), state: Int32(TSI_S_LISTEN), port: 8080)) == nil)
}
