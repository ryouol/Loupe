import Darwin
import Foundation

/// Resolves which process owns a listening TCP port via libproc — the
/// adapter attributes per-process telemetry to llama-server without being
/// told its PID. Root-free for same-user processes, which is the case that
/// matters (the user launched both).
public enum ListeningPortResolver {
    public static func pid(
        listeningAt host: String, port: UInt16, requiredUID: uid_t = geteuid()
    ) -> Int32? {
        guard let requestedAddress = RequestedAddress(host: host) else { return nil }
        var pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(pidCount) * 2)
        pidCount = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard pidCount > 0 else { return nil }

        for pid in pids.prefix(Int(pidCount)) where pid > 0 {
            if owner(of: pid) == requiredUID,
                ownsListener(pid: pid, address: requestedAddress, port: port)
            {
                return pid
            }
        }
        return nil
    }

    private static func owner(of pid: Int32) -> uid_t? {
        var information = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actual = withUnsafeMutablePointer(to: &information) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expected)
        }
        guard actual == expected else { return nil }
        return information.pbi_uid
    }

    private static func ownsListener(
        pid: Int32, address: RequestedAddress, port: UInt16
    ) -> Bool {
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
            // insi_lport is big-endian. Match the complete requested local
            // endpoint, not merely a port that may belong to a different
            // address family or interface.
            let localPort = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if localPort == port, tcp.tcpsi_state == TSI_S_LISTEN,
                address.matches(tcp.tcpsi_ini)
            {
                return true
            }
        }
        return false
    }

    private enum RequestedAddress {
        case ipv4(in_addr)
        case ipv6(in6_addr)

        init?(host: String) {
            var ipv4 = in_addr()
            if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
                self = .ipv4(ipv4)
                return
            }
            var ipv6 = in6_addr()
            if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
                self = .ipv6(ipv6)
                return
            }
            return nil
        }

        func matches(_ socket: in_sockinfo) -> Bool {
            switch self {
            case .ipv4(let requested):
                guard socket.insi_vflag & UInt8(INI_IPV4) != 0 else { return false }
                return socket.insi_laddr.ina_46.i46a_addr4.s_addr == requested.s_addr
            case .ipv6(let requested):
                guard socket.insi_vflag & UInt8(INI_IPV6) != 0 else { return false }
                let local = socket.insi_laddr.ina_6
                return withUnsafeBytes(of: local) { localBytes in
                    withUnsafeBytes(of: requested) { requestedBytes in
                        localBytes.elementsEqual(requestedBytes)
                    }
                }
            }
        }
    }
}
