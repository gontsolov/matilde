import Foundation

/// Accumulates OpenAI-compatible SSE deltas, retaining JSON validation for the final reply.
struct LangdockReplyStream {
    private(set) var done = false
    private var content = ""
    private var finish: String?
    private var refused = false

    mutating func consume(_ line: String) throws {
        guard !done, line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { done = true; return }
        struct Chunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable { let content: String?; let refusal: String? }
                let index: Int
                let delta: Delta
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else {
            throw ReviewError.message("Langdock returned an unreadable reply stream. Try again.")
        }
        for choice in chunk.choices where choice.index == 0 {
            content += choice.delta.content ?? ""
            refused = refused || choice.delta.refusal != nil
            if let reason = choice.finish_reason { finish = reason }
        }
        guard content.utf8.count <= 32_000 else {
            throw ReviewError.message("Langdock’s reply was too large.")
        }
    }

    var answer: String {
        guard !refused,
              let start = content.range(of: #"\A\s*\{\s*"answer"\s*:\s*""#, options: .regularExpression) else { return "" }
        let tail = content[start.upperBound...]
        var escaped = false
        var raw = ""
        for character in tail {
            if character == "\"", !escaped { break }
            raw.append(character)
            if escaped { escaped = false } else if character == "\\" { escaped = true }
        }
        // A token may end inside an escape or UTF-16 surrogate pair. Hold that
        // suffix until the next delta instead of flashing raw JSON or replacement glyphs.
        for _ in 0...12 {
            if let value = try? JSONDecoder().decode(String.self, from: Data(("\"" + raw + "\"").utf8)) {
                return String(value.prefix(8000))
            }
            if raw.isEmpty { break }
            raw.removeLast()
        }
        return ""
    }

    func completedResponse() throws -> Data {
        guard done, finish == "stop", !refused else {
            throw ReviewError.message("Langdock’s reply was interrupted. Try again.")
        }
        return try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": content], "finish_reason": "stop"]]
        ])
    }
}
