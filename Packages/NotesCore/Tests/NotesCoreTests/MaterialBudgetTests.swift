import Testing
@testable import NotesCore

struct MaterialBudgetTests {
    private let marker = MaterialBudget.truncationMarker
    private func text(_ count: Int) -> String { String(repeating: "字", count: count) }

    @Test func textAtTheLimitIsKeptWhole() {
        let result = MaterialBudget.default.apply(source: text(20_000), materialTexts: [text(20_000)])
        #expect(result.source == text(20_000))
        #expect(result.materials == [text(20_000)])
    }

    @Test func oneOverTheLimitIsCutAndMarked() {
        let result = MaterialBudget.default.apply(source: text(20_001), materialTexts: [text(20_001)])
        #expect(result.source == text(20_000) + marker)
        #expect(result.materials == [text(20_000) + marker])
    }

    @Test func totalCapSharesTheBudgetInOrder() {
        // 4 个 Material 各 20,000：前三个用满 60,000，第四个只剩标注
        let result = MaterialBudget.default.apply(source: "", materialTexts: Array(repeating: text(20_000), count: 4))
        #expect(result.materials == [text(20_000), text(20_000), text(20_000), marker])
    }

    @Test func totalCapCutsTheMaterialThatCrossesIt() {
        let result = MaterialBudget.default.apply(source: "", materialTexts: [text(20_000), text(20_000), text(15_000), text(10_000)])
        #expect(result.materials == [text(20_000), text(20_000), text(15_000), text(5_000) + marker])
    }

    @Test func exactlyFillingTheTotalIsNotMarked() {
        let result = MaterialBudget.default.apply(source: "", materialTexts: [text(20_000), text(20_000), text(20_000)])
        #expect(result.materials == [text(20_000), text(20_000), text(20_000)])
    }

    @Test func materialsWithoutTextStayNilAndCostNothing() {
        let result = MaterialBudget.default.apply(source: "hi", materialTexts: [nil, text(5), nil])
        #expect(result.materials == [nil, text(5), nil])
        #expect(result.source == "hi")
    }

    @Test func emptyTextAfterTheTotalIsExhaustedIsNotMarked() {
        let result = MaterialBudget.default.apply(source: "", materialTexts: [text(20_000), text(20_000), text(20_000), ""])
        #expect(result.materials.last == "")
    }

    @Test func sourceIsIndependentOfMaterials() {
        let result = MaterialBudget.default.apply(source: text(20_000), materialTexts: Array(repeating: text(20_000), count: 3))
        #expect(result.source == text(20_000))
    }
}
