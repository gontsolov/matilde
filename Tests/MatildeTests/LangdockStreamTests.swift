import XCTest
@testable import Matilde

final class LangdockStreamTests: XCTestCase {
    private func event(_ content: String = "", finish: String? = nil, refusal: String? = nil) throws -> String {
        var delta: [String: Any] = ["content": content]
        if let refusal { delta["refusal"] = refusal }
        var choice: [String: Any] = ["index": 0, "delta": delta]
        if let finish { choice["finish_reason"] = finish }
        return "data: " + String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [choice]]), as: UTF8.self)
    }

    func testIncrementalEscapesAndSurrogatePairNeverExposeJSON() throws {
        var stream = LangdockReplyStream()
        let json = #"{"answer":"Hello\n\"you\" \uD83C\uDF31","replacement":"New text"}"#
        let expected = "Hello\n\"you\" 🌱"
        var previous = ""
        for character in json {
            try stream.consume(event(String(character)))
            XCTAssertTrue(expected.hasPrefix(stream.answer))
            XCTAssertTrue(stream.answer.hasPrefix(previous))
            previous = stream.answer
        }
        XCTAssertEqual(stream.answer, expected)
        XCTAssertThrowsError(try stream.completedResponse())
        try stream.consume(event(finish: "stop"))
        try stream.consume("data: [DONE]")
        let reply = try LangdockClient.decodeReply(stream.completedResponse())
        XCTAssertEqual(reply.answer, expected)
        XCTAssertEqual(reply.replacement, "New text")
    }

    func testTruncationRefusalAndInvalidPayloadCannotComplete() throws {
        for reason in ["length", "content_filter"] {
            var stream = LangdockReplyStream()
            try stream.consume(event(#"{"answer":"Partial","replacement":null}"#, finish: reason))
            try stream.consume("data: [DONE]")
            XCTAssertThrowsError(try stream.completedResponse())
        }
        var refused = LangdockReplyStream()
        try refused.consume(event(finish: "stop", refusal: "Refused"))
        try refused.consume("data: [DONE]")
        XCTAssertEqual(refused.answer, "")
        XCTAssertThrowsError(try refused.completedResponse())
        var invalid = LangdockReplyStream()
        XCTAssertThrowsError(try invalid.consume("data: {\"error\":\"private details\"}"))
        try invalid.consume(event(#"{"answer":"unfinished"#, finish: "stop"))
        try invalid.consume("data: [DONE]")
        XCTAssertThrowsError(try LangdockClient.decodeReply(invalid.completedResponse()))
    }

    func testKeepalivesUsageAndBoundedContent() throws {
        var stream = LangdockReplyStream()
        try stream.consume(": keepalive")
        try stream.consume("data: {\"choices\":[]}")
        try stream.consume(event(#"{"answer":"Fine","replacement":null}"#, finish: "stop"))
        try stream.consume("data: [DONE]")
        XCTAssertEqual(try LangdockClient.decodeReply(stream.completedResponse()).answer, "Fine")
        var oversized = LangdockReplyStream()
        XCTAssertThrowsError(try oversized.consume(event(String(repeating: "x", count: 32_001))))
    }
}
