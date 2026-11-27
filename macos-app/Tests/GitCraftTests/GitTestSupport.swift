import Foundation
import XCTest

/// Runs `git` in `directory` and returns what it printed. A non-zero exit fails the calling test.
@discardableResult
func git(
    _ arguments: [String],
    in directory: URL,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = directory
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    XCTAssertEqual(
        process.terminationStatus, 0,
        "git \(arguments.joined(separator: " ")) failed: \(output)",
        file: file, line: line
    )
    return output
}

/// A new, not yet created folder in the temporary directory, named `<prefix>-<UUID>`.
func temporaryFolderURL(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

/// Creates an empty repository at `url` on `main`, with a commit identity set.
@discardableResult
func initTestRepository(at url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try git(["init", "-b", "main"], in: url)
    try git(["config", "user.name", "GitCraft Tests"], in: url)
    try git(["config", "user.email", "tests@gitcraft.local"], in: url)
    return url
}

/// Creates a repository at `url` holding a `README.md`. With `commit` it is committed as
/// "initial"; without, it is left untracked.
@discardableResult
func makeTestRepository(at url: URL, commit: Bool = true) throws -> URL {
    try initTestRepository(at: url)
    try "hello\n".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    if commit {
        try git(["add", "README.md"], in: url)
        try git(["commit", "-m", "initial"], in: url)
    }
    return url
}
