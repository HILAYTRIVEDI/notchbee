#if os(macOS)
import Darwin

enum EngineListener {
    static func processOwnsListener(pid: Int32, endpoint: T3LoopbackEndpoint) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / stride + 32)
        let count = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return false }
        return descriptors.prefix(Int(count) / stride).contains { descriptor in
            guard descriptor.proc_fdtype == PROX_FDTYPE_SOCKET else { return false }
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_protocol == IPPROTO_TCP else { return false }
            let tcp = info.psi.soi_proto.pri_tcp
            let address = tcp.tcpsi_ini
            guard tcp.tcpsi_state == TSI_S_LISTEN,
                  address.insi_lport == Int32(endpoint.port.bigEndian) else { return false }
            switch endpoint.address {
            case .ipv4:
                guard address.insi_vflag & UInt8(INI_IPV4) != 0 else { return false }
                let ip = address.insi_laddr.ina_46.i46a_addr4.s_addr
                return ip == INADDR_LOOPBACK.bigEndian
            case .ipv6:
                guard address.insi_vflag & UInt8(INI_IPV6) != 0 else { return false }
                var ip = address.insi_laddr.ina_6
                return withUnsafeBytes(of: &ip) { bytes in
                    bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
                }
            }
        }
    }
}
#endif
