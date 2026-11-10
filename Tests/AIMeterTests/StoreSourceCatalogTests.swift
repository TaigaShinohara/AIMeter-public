import XCTest
@testable import AIMeter

final class StoreSourceCatalogTests: XCTestCase {
    func testProviderAndSourceIDsAreUniqueAndResolvable() {
        let services = StoreSourceCatalog.services
        let sources = services.flatMap(\.sources)
        XCTAssertEqual(Set(services.map(\.id)).count, services.count)
        XCTAssertEqual(Set(sources.map(\.id)).count, sources.count)
        for service in services {
            XCTAssertEqual(StoreSourceCatalog.service(id: service.id), service)
            XCTAssertFalse(service.displayName.isEmpty)
            XCTAssertTrue(service.sources.contains { $0.requirement == .primary })
            for source in service.sources {
                XCTAssertEqual(StoreSourceCatalog.source(id: source.id), source)
                XCTAssertFalse(source.displayName.isEmpty)
                XCTAssertFalse(source.missingDescription.isEmpty)
            }
        }
        XCTAssertNil(StoreSourceCatalog.service(id: "unknown"))
        XCTAssertNil(StoreSourceCatalog.source(id: "unknown"))
    }

    func testGeminiAndClaudeHaveIndependentSources() throws {
        let gemini = try XCTUnwrap(StoreSourceCatalog.service(id: "gemini"))
        XCTAssertEqual(gemini.sources.map(\.id), ["gemini.brain", "gemini.chats"])
        XCTAssertTrue(gemini.sources.allSatisfy { $0.requirement == .primary && $0.selectionKind == .directory })

        let logs = try XCTUnwrap(StoreSourceCatalog.source(id: "claude.logs"))
        let settings = try XCTUnwrap(StoreSourceCatalog.source(id: "claude.settings"))
        XCTAssertEqual(logs.requirement, .primary)
        XCTAssertEqual(logs.selectionKind, .directory)
        XCTAssertEqual(settings.requirement, .optional)
        XCTAssertEqual(settings.selectionKind, .file)
    }

    func testWindsurfSelectsDirectoryForDatabaseAndAdjacentWAL() throws {
        let source = try XCTUnwrap(StoreSourceCatalog.source(id: "windsurf.databaseDirectory"))
        XCTAssertEqual(source.requirement, .primary)
        XCTAssertEqual(source.selectionKind, .directory)
        XCTAssertTrue(source.missingDescription.contains("隣接"))
    }
}
