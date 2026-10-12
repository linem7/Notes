import GRDB
import Testing

struct SkeletonTests {
    /// 确认 GRDB 和它背后的 SQLite 能用（NoteStore 在 ARCHITECTURE §3.2）。
    @Test func sqliteWorksThroughGRDB() throws {
        let dbQueue = try DatabaseQueue()
        let count = try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE doc(body TEXT)")
            try db.execute(sql: "INSERT INTO doc(body) VALUES ('hello world'), ('goodbye')")
            return try Int.fetchOne(db, sql: "SELECT count(*) FROM doc WHERE body LIKE 'hello%'")
        }
        #expect(count == 1)
    }
}
