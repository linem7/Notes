import Foundation
import Testing
@testable import NotesCore

struct LinkDetectorTests {
    @Test func findsHttpAndHttpsLinksInOrder() {
        let text = "看看 https://example.com/a 和 http://example.org/b?x=1，再说"
        #expect(LinkDetector.links(in: text).map(\.absoluteString) == ["https://example.com/a", "http://example.org/b?x=1"])
    }

    @Test func duplicatesAreRemoved() {
        let text = "https://example.com/a https://example.com/a https://example.com/b"
        #expect(LinkDetector.links(in: text).map(\.absoluteString) == ["https://example.com/a", "https://example.com/b"])
    }

    @Test func onlyTheFirstFiveAreKept() {
        let text = (1...8).map { "https://example.com/\($0)" }.joined(separator: " ")
        let links = LinkDetector.links(in: text)
        #expect(links.count == 5)
        #expect(links.last?.absoluteString == "https://example.com/5")
    }

    @Test func nonHttpLinksAndBareDomainsAreIgnored() {
        let text = "mail me@example.com, ftp://example.com/x, example.com, file:///tmp/a"
        #expect(LinkDetector.links(in: text).isEmpty)
    }

    @Test func emptyTextHasNoLinks() {
        #expect(LinkDetector.links(in: "").isEmpty)
        #expect(LinkDetector.links(in: "没有链接").isEmpty)
    }
}
