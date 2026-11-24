import Core
import Foundation

public actor ScriptedAIChatTransport: AIChatTransport {
    public struct Reply: Sendable {
        let status: Int
        let events: [String]
        let eventPrefix: String

        public init(status: Int = 200, events: [String] = [], sse: Bool = true) {
            self.status = status
            self.events = events
            eventPrefix = sse ? "data: " : ""
        }
    }

    private var replies: [Reply]
    public private(set) var requests: [URLRequest] = []

    public init(_ replies: [Reply]) { self.replies = replies }

    public func stream(_ request: URLRequest) async throws -> (Int, AsyncThrowingStream<String, Error>) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.badServerResponse) }
        let reply = replies.removeFirst()
        return (reply.status, AsyncThrowingStream { stream in
            for event in reply.events { stream.yield(reply.eventPrefix + event) }
            stream.finish()
        })
    }

    public nonisolated static func event(_ event: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
    }

    public nonisolated static func completed(_ items: [[String: Any]]) -> String {
        event(["type": "response.completed", "response": ["output": items]])
    }

    public nonisolated static func message(_ text: String) -> [String: Any] {
        ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]
    }

    public nonisolated static func call(_ tool: AIWorkspaceTool, id: String = "test-call", _ arguments: [String: Any]) -> [String: Any] {
        ["type": "function_call", "name": tool.rawValue, "call_id": id, "arguments": event(arguments)]
    }
}
