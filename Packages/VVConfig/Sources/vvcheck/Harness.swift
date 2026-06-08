import Foundation

private struct UnwrapFailure: Error {}

/// A minimal, dependency-free test harness so the package can be verified with just
/// the Swift toolchain (no Xcode / XCTest). Each `test` runs a closure; assertion
/// failures and thrown errors are recorded, and the process exits non-zero if any
/// test fails.
final class TestRunner {
    private var passed = 0
    private var failed = 0
    private var currentFailures: [String] = []

    func test(_ name: String, _ body: () throws -> Void) {
        currentFailures = []
        do {
            try body()
        } catch {
            currentFailures.append("threw unexpected error: \(error)")
        }
        if currentFailures.isEmpty {
            passed += 1
            print("  ok   \(name)")
        } else {
            failed += 1
            print("  FAIL \(name)")
            for f in currentFailures { print("        - \(f)") }
        }
    }

    func expect(_ cond: Bool, _ message: @autoclosure () -> String, _ line: UInt = #line) {
        if !cond { currentFailures.append("line \(line): \(message())") }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ line: UInt = #line) {
        if actual != expected {
            currentFailures.append("line \(line): expected \(expected), got \(actual)")
        }
    }

    func expectNil<T>(_ value: T?, _ line: UInt = #line) {
        if value != nil { currentFailures.append("line \(line): expected nil, got \(value!)") }
    }

    func unwrap<T>(_ value: T?, _ line: UInt = #line) throws -> T {
        guard let v = value else {
            currentFailures.append("line \(line): unexpected nil")
            throw UnwrapFailure()
        }
        return v
    }

    func expectThrows<E: Equatable & Error>(_ expectedError: E, _ line: UInt = #line, _ body: () throws -> Void) {
        do {
            try body()
            currentFailures.append("line \(line): expected to throw \(expectedError), but did not")
        } catch let e as E {
            if e != expectedError {
                currentFailures.append("line \(line): expected \(expectedError), threw \(e)")
            }
        } catch {
            currentFailures.append("line \(line): expected \(expectedError), threw different error \(error)")
        }
    }

    /// Print a summary and terminate the process with the appropriate exit code.
    func finishAndExit() -> Never {
        print("\n\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
