import Foundation
import Darwin

public final class Store {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func locked<T>(_ action: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw EinkError.message("Cannot open the E-Ink state lock.") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw EinkError.message("Cannot lock E-Ink state.") }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
    public func read<T: Decodable>(_ name: String, default fallback: T) throws -> T {
        let path = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path.path) else { return fallback }
        do { return try JSONDecoder().decode(T.self, from: Data(contentsOf: path)) }
        catch { throw EinkError.message("Cannot read \(name). Preserve this file for recovery: \(error.localizedDescription)") }
    }
    public func write<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let path = directory.appendingPathComponent(name)
        try encoder.encode(value).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        let fd = open(path.path, O_RDONLY)
        if fd >= 0 { defer { close(fd) }; guard fsync(fd) == 0 else { throw EinkError.message("Cannot flush \(name) to disk.") } }
    }
}
