import Foundation
import Testing
@testable import NotchpilotCore

@MainActor
struct T3SecurityTests {
    @Test(arguments: ["http://localhost:3773", "http://127.0.0.2:3773", "http://127.0.0.1",
                      "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1:3773/other"])
    func rejectsAmbiguousOrInvalidEndpoints(origin: String) {
        #expect(URL(string: origin).flatMap(T3LoopbackEndpoint.init) == nil)
    }

    @Test func frameSizeLimit() throws {
        let ping = Data(#"{"_tag":"Ping"}"#.utf8)
        var frame = ping + Data(repeating: 32, count: T3Client.maximumMessageBytes - ping.count)
        _ = try T3Client.decodeFrame(frame)
        frame.append(32)
        #expect(throws: T3Client.ClientError.messageTooLarge) { try T3Client.decodeFrame(frame) }
    }

    @Test func chunkLimit() throws {
        func frame(_ count: Int) -> Data {
            let values = Array(repeating: "{}", count: count).joined(separator: ",")
            return Data(#"{"_tag":"Chunk","requestId":"1","values":["#.utf8)
                + Data(values.utf8) + Data("]}".utf8)
        }
        _ = try T3Client.decodeFrame(frame(T3Client.maximumChunkItems))
        #expect(throws: T3Client.ClientError.messageTooLarge) {
            try T3Client.decodeFrame(frame(T3Client.maximumChunkItems + 1))
        }
    }
}
