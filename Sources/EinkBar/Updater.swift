import AppKit
import EinkCore
import EinkMac

/// Checks GitHub Releases and installs a newer app archive in place.
enum Updater {
    /// Signed into the installed bundle at build time; never read from an incoming archive.
    static var expectedTeamID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "EinkExpectedTeamID") as? String)
            .flatMap { $0.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) == nil ? nil : $0 }
    }
    static var feed: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "EinkReleasesURL") as? String).flatMap(URL.init(string:))
    }
    static var currentVersion: AppVersion? { AppVersion(EinkEnvironment.version) }

    static func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        guard let feed, let current = currentVersion else {
            return completion(.failure(EinkError.message("Update checks are available in packaged builds only.")))
        }
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("E-Ink-Mode/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: Result<Release?, Error>
            if let error { result = .failure(EinkError.message("Could not reach the update server: \(error.localizedDescription)")) }
            else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                result = .failure(EinkError.message("The update server answered \(http.statusCode). Try again later."))
            } else {
                result = Result { UpdateCheck.newest(in: try UpdateCheck.decode(data ?? Data()), newerThan: current) }
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Downloads, verifies, and stages `release`, then swaps the bundle after this process exits.
    static func install(_ release: Release, relaunchActive: Bool, completion: @escaping (Error?) -> Void) {
        guard let archive = release.archive?.browserDownloadURL, let expected = release.version else {
            return completion(EinkError.message("This release has no app download."))
        }
        let target = Bundle.main.bundleURL
        guard let teamID = expectedTeamID else {
            return completion(EinkError.message("This copy has no trusted publisher identity. Install a signed release manually."))
        }
        guard let current = currentVersion, expected > current else {
            return completion(EinkError.message("The offered update is not newer than the installed version."))
        }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            return completion(EinkError.message("E-Ink Mode can't replace itself in \(target.deletingLastPathComponent().path). Download the update from the release page instead."))
        }
        URLSession.shared.downloadTask(with: archive) { file, _, error in
            func finish(_ error: Error?) { DispatchQueue.main.async { completion(error) } }
            guard let file, error == nil else { return finish(EinkError.message("Download failed: \(error?.localizedDescription ?? "unknown error")")) }
            do {
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent("eink-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                try run("/usr/bin/ditto", ["-x", "-k", file.path, staging.path])
                guard let app = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "app" }), let bundle = Bundle(url: app) else {
                    throw EinkError.message("The download doesn't contain the app.")
                }
                guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else { throw EinkError.message("The download is a different app.") }
                guard let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init),
                      version == expected else { throw EinkError.message("The download's version doesn't match the release.") }
                let requirement = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"local.eink.mode\""
                try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
                try run("/usr/bin/codesign", ["--verify", "--strict", "-R=\(requirement)", app.path])
                try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
                try relaunch(replacing: target, with: app, arguments: relaunchActive ? ["--activate"] : [])
                finish(nil)
            } catch { finish(error) }
        }.resume()
    }

    /// Starts a detached helper that waits for this process to exit, optionally swaps bundles, and opens the app.
    static func relaunch(replacing target: URL, with replacement: URL?, arguments: [String] = []) throws {
        let argv = ["/bin/bash", "-c", BundleSwap.script, "eink-relaunch", String(ProcessInfo.processInfo.processIdentifier),
                    target.path, replacement?.path ?? ""] + arguments
        // A new session keeps the helper alive after this app exits.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes); defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
        for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == STDIN_FILENO ? O_RDONLY : O_WRONLY, 0)
        }
        var cArgs = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/bash", &actions, &attributes, &cArgs, environ)
        guard result == 0 else { throw EinkError.message("Could not start the relaunch helper (\(result)).") }
    }

    @discardableResult
    static func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: tool); process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw EinkError.message("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}
