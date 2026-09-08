import Darwin
import Foundation

/// The libproc calls need a live process table; what they return is parsed in ProcessScanner.swift.
public struct LibprocProcessScanner: ProcessScanner {
  public init() {}

  public func processes() -> [ProcessEntry] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
    return pids.prefix(max(count, 0)).compactMap { pid in
      var path = [UInt8](repeating: 0, count: 4096)
      guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
      let executable = String(decoding: path.prefix { $0 != 0 }, as: UTF8.self)
      guard AntigravityLanguageServers.isCandidate(path: executable) else { return nil }
      return ProcessEntry(pid: pid, path: executable, arguments: ProcessArguments.parse(procargs(pid)))
    }
  }

  private func procargs(_ pid: pid_t) -> Data {
    var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > 0 else { return Data() }
    var buffer = Data(count: size)
    let status = buffer.withUnsafeMutableBytes { sysctl(&name, 3, $0.baseAddress, &size, nil, 0) }
    return status == 0 ? buffer.prefix(size) : Data()
  }

  public func listeningPorts(pid: pid_t) -> [UInt16] {
    let stride = MemoryLayout<proc_fdinfo>.stride
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return [] }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride)
    let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
    return fds.prefix(max(Int(filled), 0) / stride).compactMap { fd in
      guard fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { return nil }
      var info = socket_fdinfo()
      let wanted = Int32(MemoryLayout<socket_fdinfo>.size)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, wanted) == wanted else { return nil }
      return ListeningSocket.port(of: info)
    }
  }
}
