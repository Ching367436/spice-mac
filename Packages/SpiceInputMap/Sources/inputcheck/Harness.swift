import Foundation

private struct UnwrapFailure: Error {}

/// Minimal dependency-free test harness (XCTest/swift-testing are unavailable with
/// Command Line Tools). Run with `swift run inputcheck`.
final class TestRunner {
    private var passed = 0
    private var failed = 0
    private var currentFailures: [String] = []

    func test(_ name: String, _ body: () throws -> Void) {
        currentFailures = []
        do { try body() } catch { currentFailures.append("threw unexpected error: \(error)") }
        if currentFailures.isEmpty {
            passed += 1; print("  ok   \(name)")
        } else {
            failed += 1; print("  FAIL \(name)")
            for f in currentFailures { print("        - \(f)") }
        }
    }

    func expect(_ cond: Bool, _ message: @autoclosure () -> String, _ line: UInt = #line) {
        if !cond { currentFailures.append("line \(line): \(message())") }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ line: UInt = #line) {
        if actual != expected { currentFailures.append("line \(line): expected \(expected), got \(actual)") }
    }

    func finishAndExit() -> Never {
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}

/// Hex formatting helper for readable failure messages.
func hex(_ v: Int) -> String { "0x" + String(v, radix: 16, uppercase: true) }
