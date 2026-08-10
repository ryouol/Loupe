import Darwin
import Foundation

/// Resolves which process owns a listening TCP port via libproc — the
/// adapter attributes per-process telemetry to llama-server without being
/// told its PID. Root-free for same-user processes, which is the case that
/// matters (the user launched both).
public enum ListeningPortResolver {
    public static func pid(listeningOn port: UInt16) -> Int32? {
        var pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(pidCount) * 2)
        pidCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard pidCount > 0 else { return nil }

        for pid in pids.prefix(Int(pidCount)) where pid > 0 {
            if ownsListeningPort(pid: pid, port: port) {
                return pid
            }
        }
        return nil
    }

    private static func ownsListeningPort(pid: Int32, port: UInt16) -> Bool {
        let fdsSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard fdsSize > 0 else { return false }
        let fdCount = Int(fdsSize) / MemoryLayout<proc_fdinfo>.size
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, fdsSize)
        guard filled > 0 else { return false }

        for fd in fds.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.size)
        where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
            var socketInfo = socket_fdinfo()
            let size = proc_pidfdinfo(
                pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo,
                Int32(MemoryLayout<socket_fdinfo>.size))
            guard size == MemoryLayout<socket_fdinfo>.size else { continue }
            let socket = socketInfo.psi
            guard socket.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = socket.soi_proto.pri_tcp
            // insi_lport is big-endian; TSI_S_LISTEN == 1.
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if localPort == port && tcp.tcpsi_state == 1 {
                return true
            }
        }
        return false
    }
}
