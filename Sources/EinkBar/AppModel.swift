import AppKit
import ServiceManagement
import EinkCore
import EinkMac

enum UpdateState: Equatable {
    case idle, checking, upToDate, installing
    case available(Release)
    case failed(String)
}

/// Main-thread UI state around the shared controller. All controller work runs on one serial queue.
final class AppModel: ObservableObject {
    @Published var status: Status?
    @Published var error: String?
    @Published var busy = false
    @Published var needsRecovery = false
    @Published var loginEnabled = false
    @Published var hotkeyMessage = ""
    @Published var update: UpdateState = .idle
    /// Seconds left in the first-run preview, while it runs.
    @Published var previewRemaining: Int?
    @Published var clickToFlip = UserDefaults.standard.bool(forKey: "clickToFlip") {
        didSet { UserDefaults.standard.set(clickToFlip, forKey: "clickToFlip"); changed?() }
    }
    @Published var stats: FocusStats?
    /// Swaps the dot menu bar icon for a wildcat head.
    @Published var wildcatMode = UserDefaults.standard.bool(forKey: "wildcatMode") {
        didSet { UserDefaults.standard.set(wildcatMode, forKey: "wildcatMode"); changed?() }
    }
    @Published var focusSound = UserDefaults.standard.object(forKey: "focusSound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(focusSound, forKey: "focusSound") }
    }
    @Published var menuBarCountdown = UserDefaults.standard.object(forKey: "menuBarCountdown") as? Bool ?? true {
        didSet { UserDefaults.standard.set(menuBarCountdown, forKey: "menuBarCountdown"); changed?() }
    }
    @Published var autoCheckUpdates = UserDefaults.standard.object(forKey: "autoCheckUpdates") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheckUpdates, forKey: "autoCheckUpdates") }
    }
    let controller: Controller
    private let work = DispatchQueue(label: "local.eink.operations")
    private var pending = 0
    private var previewTimer: Timer?
    var changed: (() -> Void)?
    /// Called when an action the person chose fails (background polls stay quiet).
    var onUserError: ((String) -> Void)?

    init(controller: Controller) { self.controller = controller }

    var active: Bool { status?.active == true }
    var colorRemaining: TimeInterval? { status?.temporaryColorRemaining() }
    var focus: FocusSession? { status?.focusing == true ? status?.state.focus : nil }
    var focusSettings: FocusSettings { status?.configuration.focus ?? FocusSettings() }
    var schedule: ScheduleStatus? { status.map { ScheduleStatus(configuration: $0.configuration, state: $0.state) } }
    var hasBrightness: Bool { status?.system.values.keys.contains { $0.hasPrefix("brightness:") } == true }

    func load() {
        perform(checkLegacy: false, quiet: true) {
            let status = try self.controller.status()
            DispatchQueue.main.async { self.needsRecovery = status.active }
        }
        refreshLogin()
    }
    /// Operations queue serially; none are dropped, so a restore is never lost behind a poll.
    func perform(checkLegacy: Bool = true, quiet: Bool = false, _ operation: @escaping () throws -> Void = {}) {
        pending += 1; busy = true
        work.async {
            var failure: String?
            do { if checkLegacy { try EinkEnvironment.checkLegacy() }; try operation() }
            catch { failure = error.localizedDescription }
            let result = Result { try self.controller.status() }
            let stats = try? self.controller.focusStats()
            DispatchQueue.main.async {
                self.pending -= 1; self.busy = self.pending > 0
                if let failure { self.error = failure; if !quiet { self.onUserError?(failure) } }
                else if case .success = result { self.error = nil } // a successful operation clears stale problems
                switch result {
                case .success(let status): self.status = status; if let stats { self.stats = stats }
                case .failure(let error): self.error = error.localizedDescription
                }
                self.changed?()
            }
        }
    }
    func poll() {
        guard !busy else { return } // polls are the only droppable work
        perform(quiet: true) { if !self.needsRecovery { try self.controller.tick() } }
        refreshLogin()
    }
    func toggle() {
        guard !needsRecovery, previewRemaining == nil else { return }
        perform { try self.controller.toggle() }
    }
    func setActive(_ on: Bool) {
        guard !needsRecovery else { return }
        perform { try self.controller.setMode(on) }
    }
    func startFocus(sessions: Int? = nil) {
        guard !needsRecovery, previewRemaining == nil else { return }
        perform { try self.controller.startFocus(sessions: sessions) }
    }
    func stopFocus() { perform { try self.controller.stopFocus() } }
    func skipBreak() { perform { try self.controller.skipBreak() } }
    func startColor(minutes: Double = 5) { perform { try self.controller.startTemporaryColor(for: minutes * 60) } }
    func endColor() { perform { try self.controller.endTemporaryColor() } }
    func change(_ update: @escaping (inout Configuration) throws -> Void) { perform { try self.controller.edit(update) } }
    func restoreDisplay() {
        perform {
            try self.controller.setMode(false)
            DispatchQueue.main.async { self.needsRecovery = false; self.error = nil }
        }
    }
    func recover(resume: Bool) {
        perform {
            if resume { try self.controller.resume() } else { try self.controller.setMode(false) }
            DispatchQueue.main.async { self.needsRecovery = false; self.error = nil }
        }
    }

    // MARK: First-run preview — grayscale only, never saved, always ends on its own.
    func startPreview(seconds: Int = 10) {
        guard !active, previewRemaining == nil, !needsRecovery else { return }
        previewRemaining = seconds
        perform { try self.controller.setMode(true, manual: false, profile: Configuration()) }
        previewTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let left = self.previewRemaining else { return }
            if left <= 1 { self.endPreview() } else { self.previewRemaining = left - 1 }
        }
        RunLoop.main.add(previewTimer!, forMode: .common)
    }
    func endPreview() {
        guard previewRemaining != nil else { return }
        previewTimer?.invalidate(); previewTimer = nil; previewRemaining = nil
        perform { try self.controller.setMode(false, manual: false) }
    }

    // MARK: Login item
    func refreshLogin() { loginEnabled = SMAppService.mainApp.status == .enabled }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            refreshLogin()
            if SMAppService.mainApp.status == .requiresApproval {
                error = "Approve E-Ink Mode in System Settings → General → Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { self.error = error.localizedDescription; refreshLogin() }
    }
}
