import Foundation

/// Semantic version with an optional pre-release tag, e.g. "0.9.0-beta.2".
public struct AppVersion: Comparable, CustomStringConvertible {
    public let core: [Int]
    public let prerelease: [String]
    public let description: String
    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let pieces = text.split(separator: "-", maxSplits: 1).map(String.init)
        guard let first = pieces.first else { return nil }
        let numbers = first.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(numbers.count), numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        core = numbers.map { $0! } + Array(repeating: 0, count: 3 - numbers.count)
        prerelease = pieces.count > 1 ? pieces[1].split(separator: ".").map(String.init) : []
        description = text
    }
    public static func == (a: AppVersion, b: AppVersion) -> Bool { a.core == b.core && a.prerelease == b.prerelease }
    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        if a.core != b.core { return a.core.lexicographicallyPrecedes(b.core) }
        // A release outranks its pre-releases: 1.0.0-beta < 1.0.0.
        if a.prerelease.isEmpty != b.prerelease.isEmpty { return !a.prerelease.isEmpty }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (_?, nil): return true
            case (nil, _?): return false
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// The subset of a GitHub release the updater needs.
public struct Release: Decodable, Equatable {
    public struct Asset: Decodable, Equatable {
        public var name: String
        public var browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name; case browserDownloadURL = "browser_download_url" }
        public init(name: String, browserDownloadURL: URL) { self.name = name; self.browserDownloadURL = browserDownloadURL }
    }
    public var tagName: String
    public var htmlURL: URL
    public var draft: Bool
    public var body: String?
    public var assets: [Asset]
    enum CodingKeys: String, CodingKey { case tagName = "tag_name"; case htmlURL = "html_url"; case draft, body, assets }
    public init(tagName: String, htmlURL: URL, draft: Bool = false, body: String? = nil, assets: [Asset]) {
        self.tagName = tagName; self.htmlURL = htmlURL; self.draft = draft; self.body = body; self.assets = assets
    }
    public var version: AppVersion? { AppVersion(tagName) }
    /// The downloadable app archive.
    public var archive: Asset? { assets.first { $0.name.hasSuffix(".zip") } }
}

public enum UpdateCheck {
    /// The newest published release that is newer than `current` and ships an app archive.
    public static func newest(in releases: [Release], newerThan current: AppVersion) -> Release? {
        releases
            .filter { !$0.draft && $0.archive != nil }
            .compactMap { release in release.version.map { (release, $0) } }
            .filter { $0.1 > current }
            .max { $0.1 < $1.1 }?.0
    }
    public static func decode(_ data: Data) throws -> [Release] {
        do { return try JSONDecoder().decode([Release].self, from: data) }
        catch { throw EinkError.message("The update feed could not be read.") }
    }
}

public enum BundleSwap {
    /// Bash script run detached: waits for `pid` to exit, swaps `replacement` into `target` (rolling back on failure),
    /// then opens the target. Arguments: pid target replacement [app arguments…]. `EINK_OPEN` overrides `open` for tests.
    public static let script = """
    pid=$1; target=$2; replacement=$3; shift 3
    for _ in $(seq 1 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
    kill -0 "$pid" 2>/dev/null && exit 1
    status=0
    if [ -n "$replacement" ]; then
      rm -rf "$target.previous"
      mv "$target" "$target.previous" || exit 1
      if mv "$replacement" "$target" 2>/dev/null; then rm -rf "$target.previous"; else mv "$target.previous" "$target"; status=2; fi
    fi
    xattr -dr com.apple.quarantine "$target" 2>/dev/null
    ${EINK_OPEN:-open} "$target" --args "$@"
    exit $status
    """
}
