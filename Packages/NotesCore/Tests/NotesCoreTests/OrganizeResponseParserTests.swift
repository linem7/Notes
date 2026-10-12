import Foundation
import Testing
@testable import NotesCore

struct OrganizeResponseParserTests {
    private func parse(_ raw: String, input: String = "first line\nsecond line", materialCount: Int = 0) -> [Draft] {
        OrganizeResponseParser.parse(raw, input: input, materialCount: materialCount)
    }

    private let normal = """
    {"notes": [{"title": "Send the signed contract to Alex", "due": "2026-10-15", "time": "15:00", \
    "detail": "- Sign page 3\\n- Email to alex@example.com", "materials": [1, 2]}]}
    """

    @Test func parsesANormalResponse() {
        let drafts = parse(normal, materialCount: 3)
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "Send the signed contract to Alex")
        #expect(drafts[0].due == DueDate(day: "2026-10-15", time: "15:00"))
        #expect(drafts[0].detail == "- Sign page 3\n- Email to alex@example.com")
        #expect(drafts[0].materialIndices == [0, 1])
        #expect(drafts[0].isSelected)
    }

    @Test func stripsCodeFencesAndSurroundingChatter() {
        let fenced = "Sure! Here you go:\n```json\n\(normal)\n```\nHope that helps."
        let drafts = parse(fenced, materialCount: 3)
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "Send the signed contract to Alex")
        #expect(drafts[0].due == DueDate(day: "2026-10-15", time: "15:00"))
        #expect(drafts[0].materialIndices == [0, 1])
    }

    @Test func parsesSeveralNotesInOrder() {
        let raw = """
        {"notes": [{"title": "A", "due": null, "time": null, "detail": "", "materials": []},
                   {"title": "B", "due": "2026-11-01", "time": null, "detail": "- x", "materials": [2]}]}
        """
        let drafts = parse(raw, materialCount: 2)
        #expect(drafts.map(\.title) == ["A", "B"])
        #expect(drafts[0].due == nil)
        #expect(drafts[1].due == DueDate(day: "2026-11-01", time: nil))
    }

    // MARK: 日期

    @Test(arguments: ["tomorrow", "2026-13-01", "2026-02-30", "26-10-15", "2026/10/15", "", "2026-10-15T09:00"])
    func invalidDueIsTreatedAsEmpty(due: String) {
        let raw = "{\"notes\": [{\"title\": \"A\", \"due\": \"\(due)\", \"time\": \"09:00\"}]}"
        #expect(parse(raw)[0].due == nil)
    }

    @Test(arguments: ["25:00", "9:00", "09:60", "noon", "09:00:00"])
    func invalidTimeKeepsTheDayOnly(time: String) {
        let raw = "{\"notes\": [{\"title\": \"A\", \"due\": \"2026-10-15\", \"time\": \"\(time)\"}]}"
        #expect(parse(raw)[0].due == DueDate(day: "2026-10-15", time: nil))
    }

    @Test func timeWithoutDueIsDropped() {
        let raw = "{\"notes\": [{\"title\": \"A\", \"due\": null, \"time\": \"09:00\"}]}"
        #expect(parse(raw)[0].due == nil)
    }

    @Test func leapDayIsValid() {
        let raw = "{\"notes\": [{\"title\": \"A\", \"due\": \"2028-02-29\"}]}"
        #expect(parse(raw)[0].due == DueDate(day: "2028-02-29", time: nil))
    }

    // MARK: materials：0-based、越界丢弃、缺失或空 = 全部

    @Test func materialNumbersAreConvertedFromOneBasedToZeroBased() {
        let raw = "{\"notes\": [{\"title\": \"A\", \"materials\": [3, 1]}]}"
        #expect(parse(raw, materialCount: 3)[0].materialIndices == [0, 2])
    }

    @Test func outOfRangeMaterialNumbersAreDropped() {
        let raw = "{\"notes\": [{\"title\": \"A\", \"materials\": [0, 1, 4, -2, 2]}]}"
        #expect(parse(raw, materialCount: 3)[0].materialIndices == [0, 1])
    }

    @Test func duplicateMaterialNumbersAreMerged() {
        let raw = "{\"notes\": [{\"title\": \"A\", \"materials\": [2, 2, 1]}]}"
        #expect(parse(raw, materialCount: 3)[0].materialIndices == [0, 1])
    }

    @Test(arguments: [
        "{\"notes\": [{\"title\": \"A\"}]}",
        "{\"notes\": [{\"title\": \"A\", \"materials\": []}]}",
        "{\"notes\": [{\"title\": \"A\", \"materials\": null}]}",
        "{\"notes\": [{\"title\": \"A\", \"materials\": [7, 8]}]}",
        "{\"notes\": [{\"title\": \"A\", \"materials\": [\"a\", 1.5]}]}",
    ])
    func missingOrEmptyMaterialsMeanAll(raw: String) {
        #expect(parse(raw, materialCount: 3)[0].materialIndices == [0, 1, 2])
    }

    @Test func noMaterialsAtAllGivesEmptyIndices() {
        #expect(parse("{\"notes\": [{\"title\": \"A\", \"materials\": [1]}]}", materialCount: 0)[0].materialIndices == [])
    }

    // MARK: 丢弃和 fallback

    @Test func notesWithoutATitleAreDropped() {
        let raw = "{\"notes\": [{\"title\": \"  \"}, {\"detail\": \"x\"}, {\"title\": \"Keep\"}, 5, \"x\"]}"
        #expect(parse(raw).map(\.title) == ["Keep"])
    }

    @Test(arguments: [
        "{\"notes\": []}",
        "{\"notes\": [{\"title\": \"\"}]}",
        "{\"other\": 1}",
        "{\"notes\": \"nope\"}",
    ])
    func emptyNotesFallBack(raw: String) {
        let drafts = parse(raw, materialCount: 2)
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "first line")
        #expect(drafts[0].detail == raw)
        #expect(drafts[0].materialIndices == [0, 1])
        #expect(drafts[0].due == nil)
        #expect(drafts[0].isSelected)
    }

    @Test func nonJSONFallsBackWithTheRawTextAsDetail() {
        let drafts = parse("Sorry, I can't help with that.", materialCount: 1)
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "first line")
        #expect(drafts[0].detail == "Sorry, I can't help with that.")
        #expect(drafts[0].materialIndices == [0])
    }

    @Test func truncatedJSONFallsBack() {
        // finish_reason: length 会把 JSON 截在半路
        let raw = "{\"notes\": [{\"title\": \"A\", \"due\": \"2026-10-15\", \"detail\": \"- one\\n- tw"
        let drafts = parse(raw, materialCount: 2)
        #expect(drafts.count == 1)
        #expect(drafts[0].title == "first line")
        #expect(drafts[0].detail == raw)
        #expect(drafts[0].materialIndices == [0, 1])
    }

    @Test func truncatedAfterTheFirstNoteStillFallsBack() {
        // 有 `}` 但整体不是合法 JSON
        let raw = "{\"notes\": [{\"title\": \"A\"}, {\"title\": \"B\", \"detail\": \"x"
        let drafts = parse(raw)
        #expect(drafts.count == 1)
        #expect(drafts[0].detail == raw)
    }

    @Test func fallbackTitleIsTheFirstNonEmptyLineLimitedTo80Characters() {
        let long = String(repeating: "x", count: 200)
        #expect(parse("oops", input: "\n  \n\(long)\nmore")[0].title == String(repeating: "x", count: 80))
        #expect(parse("oops", input: "  hello  \nworld")[0].title == "hello")
    }

    @Test func fallbackWithEmptyInputStillHasATitle() {
        #expect(parse("oops", input: "  \n")[0].title == "Untitled")
    }

    @Test func emptyResponseFallsBack() {
        let drafts = parse("", materialCount: 1)
        #expect(drafts.count == 1)
        #expect(drafts[0].detail == "")
        #expect(drafts[0].materialIndices == [0])
    }
}
