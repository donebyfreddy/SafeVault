import XCTest

// XCTest's assertion autoclosures cannot contain `await`. These variants can.

func XCTAssertEqualA<T: Equatable>(
    _ a: @autoclosure () async throws -> T, _ b: @autoclosure () throws -> T,
    _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        let x = try await a(), y = try b()
        XCTAssertEqual(x, y, message(), file: file, line: line)
    } catch { XCTFail("threw \(error)", file: file, line: line) }
}

func XCTAssertTrueA(
    _ a: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do { let v = try await a(); XCTAssertTrue(v, message(), file: file, line: line) } catch { XCTFail("threw \(error)", file: file, line: line) }
}

func XCTAssertFalseA(
    _ a: @autoclosure () async throws -> Bool, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do { let v = try await a(); XCTAssertFalse(v, message(), file: file, line: line) } catch { XCTFail("threw \(error)", file: file, line: line) }
}

func XCTAssertNilA<T>(
    _ a: @autoclosure () async throws -> T?, _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath, line: UInt = #line
) async {
    do { let v = try await a(); XCTAssertNil(v, message(), file: file, line: line) } catch { XCTFail("threw \(error)", file: file, line: line) }
}

func unwrapA<T>(
    _ a: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line
) async throws -> T {
    guard let v = try await a() else {
        XCTFail("unexpected nil", file: file, line: line)
        throw VaultErrorForTests.nilValue
    }
    return v
}

enum VaultErrorForTests: Error { case nilValue }
