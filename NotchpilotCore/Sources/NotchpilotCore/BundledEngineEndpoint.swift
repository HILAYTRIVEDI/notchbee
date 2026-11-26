import Foundation

struct T3LoopbackEndpoint: Equatable, Sendable {
    enum Address: Sendable { case ipv4, ipv6 }

    let address: Address
    let port: UInt16

    init?(origin: URL) {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let port = parts.port, let tcpPort = UInt16(exactly: port), tcpPort != 0,
              parts.scheme == "http" || parts.scheme == "https",
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        switch parts.host {
        case "127.0.0.1": address = .ipv4
        case "[::1]", "::1": address = .ipv6
        default: return nil
        }
        self.port = tcpPort
    }
}

public struct BundledEngineEndpoint: Sendable {
    let origin: URL
    let pid: Int32
    let bootstrapToken: String

    /// The runtime record is only a hint. Verify socket ownership before sending credentials.
    public init?(runtimeRecord: Data, childPID: Int32, bootstrapToken: String) {
        struct Runtime: Decodable {
            let origin: URL
            let pid: Int32
            let port: UInt16
        }
        guard childPID > 1, bootstrapToken.utf8.count >= 32,
              let record = try? JSONDecoder().decode(Runtime.self, from: runtimeRecord),
              record.pid == childPID, record.origin.scheme == "http",
              let endpoint = T3LoopbackEndpoint(origin: record.origin),
              endpoint.address == .ipv4, endpoint.port == record.port else { return nil }
        self.origin = record.origin
        self.pid = childPID
        self.bootstrapToken = bootstrapToken
    }

    @concurrent
    func verify() async throws {
        #if os(macOS)
        if let endpoint = T3LoopbackEndpoint(origin: origin),
           EngineListener.processOwnsListener(pid: pid, endpoint: endpoint) { return }
        #endif
        throw EngineListenerError.ownership
    }
}

enum EngineListenerError: LocalizedError {
    case ownership

    var errorDescription: String? {
        "Connection refused. The engine process does not own the local server port."
    }
}
final class EngineProbeNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
