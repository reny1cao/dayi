import AppKit
import ApplicationServices
import Observation
import PolishCore
import PolishStore
import SwiftUI

enum AppError: Error, LocalizedError {
    case accessibilityRequired, hotKey(OSStatus)
    var errorDescription: String? {
        switch self {
        case .accessibilityRequired: L10n.tr("请在系统设置 → 隐私与安全性 → 辅助功能中授权 Dayi。")
        // Only the system's reason. What the failure *means* — 没有覆盖其他应用的快捷键 — is the
        // product's sentence, and every surface that shows this puts it in front rather than
        // printing it twice.
        case .hotKey(let code): L10n.format("系统报告的原因：注册失败（%@）。", String(describing: code))
        }
    }
}

@MainActor @Observable
final class AppModel {
    let jobs: PolishJobs
    private(set) var lastEvent: StatusEvent?
    private(set) var trusted = AXIsProcessTrusted()
    private(set) var blockedReason: String?
    /// The `OSStatus` message from a hot key that never registered. `blockedReason` says which
    /// precondition failed; this says what the system reported, which is what a person needs
    /// to tell a conflicting app apart from a missing entitlement.
    private(set) var hotKeyFailure: String?
    let history = PolishHistory()
    let settings = ModelSettings()
    let prompts = PromptSettings()
    /// The activity window's single source of truth. It is built here and attached at the end
    /// of `init`, because it reads back through this model and cannot exist before it.
    let activity = ActivityStore()
    /// How long each running job has been waiting, in seconds. Measured latency spans
    /// 2.3–19.3s, so "still running" is not an answer: the number is the answer.
    private(set) var runningElapsed: [UUID: Double] = [:]
    /// What is kept on disk and for how long, in one sentence the window can show. A person
    /// has to be able to see that their drafts are being written down.
    private(set) var storageNote: String?
    @ObservationIgnored private var jobSkills: [UUID: UUID] = [:]
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var capture: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let hud = StatusHUD()
    @ObservationIgnored private var jobStates: [UUID: JobState] = [:]

    private struct JobState: Equatable {
        let compute: ComputeState
        let application: ApplicationState
    }

    /// Whether the status item is resident in the menu bar. This is ordinary observable
    /// state rather than `@AppStorage` because SwiftUI will not insert a `MenuBarExtra` whose
    /// `isInserted:` binding comes from `@AppStorage` declared on the `App`: the scene is
    /// built before that storage resolves and the item never appears at all, however the key
    /// reads afterwards (measured on macOS 26.6 — the stored value was `true` and the icon
    /// was absent). Seeding it here makes the value available on the first scene evaluation,
    /// which is the only moment the insertion is decided.
    var menuBarVisible: Bool {
        didSet { UserDefaults.standard.set(menuBarVisible, forKey: SettingsDefaults.menuBarVisible) }
    }

    init() {
        UserDefaults.standard.register(defaults: [SettingsDefaults.menuBarVisible: true])
        menuBarVisible = UserDefaults.standard.bool(forKey: SettingsDefaults.menuBarVisible)
        // The configuration is read per request, so a profile saved in the window applies to
        // the next press without a restart.
        let settings = self.settings
        let prompts = self.prompts
        jobs = PolishJobs.completing { input in
            let (configuration, selection) = try await MainActor.run { (try settings.configuration(), try prompts.selection()) }
            let polisher = Polisher(configuration: configuration, template: selection.template)
            return try await polisher.complete(input)
        }
        do {
            hotKey = try GlobalHotKey { [weak self] id in
                guard let self else { return }
                if id == 1 { self.trigger() } else { self.undo() }
            }
        } catch {
            hotKeyFailure = error.localizedDescription
            blockedReason = L10n.tr("快捷键未注册")
        }
        observeJobs()
        watchPermission()
        Task { [weak self] in await self?.openStorage() }
        activity.attach(self)
    }

    /// The database opens off the launch path. Until it is ready every record stays in
    /// memory, so a press during startup behaves exactly like a press afterwards.
    private func openStorage() async {
        do {
            let location = try Database.applicationSupportLocation()
            let opened = try await PolishStorageBootstrap.open(location)
            await prompts.attach(opened.skills, defaultSkillID: opened.skillID)
            await settings.attach(opened.preferences)
            // Both of these land before the first purge. The retention the person chose is
            // what that purge is meant to enforce, and a rebound hot key has to reach the
            // live registration rather than wait for the next launch.
            await RetentionSettings.shared.attach(preferences: opened.preferences, records: opened.records)
            await HotKeyBindings.shared.attach(opened.preferences)
            let retention = RetentionSettings.shared.policy
            storageNote = Self.storageNote(for: opened.location, retention: retention)
            await history.attach(opened.records, purging: retention)
        } catch {
            history.report(error)
        }
    }

    private static func storageNote(for url: URL?, retention: RetentionPolicy) -> String? {
        guard let url else { return nil }
        let path = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        let days = { (seconds: TimeInterval?) in seconds.map { Int($0 / 86_400) } }
        guard let age = days(retention.maxAge), let text = days(retention.textMaxAge),
              let count = retention.maxCount else { return L10n.format("历史保存在 %@。", String(describing: path)) }
        return L10n.format("历史保存在 %@：超过 %@ 天或 %@ 条的记录会删除，正文在 %@ 天后清除。", String(describing: path), String(describing: age), String(describing: count), String(describing: text))
    }

    /// The one line the menu bar shows without opening anything.
    var status: ResidentStatus {
        if let blockedReason { return .blocked(blockedReason) }
        guard trusted else { return .blocked(L10n.tr("未授权辅助功能")) }
        guard settings.isConfigured else { return .blocked(L10n.tr("未配置模型")) }
        let running = jobs.jobs.filter { $0.computeState == .running }.count
        if running > 0 { return .running(running) }
        let attention = jobs.jobs.filter(needsAttention).count
        if attention > 0 { return .attention(attention) }
        return .ready
    }

    /// The precondition banners read this rather than calling `AXIsProcessTrusted()` again:
    /// the polled value is the one the rest of the app is acting on.
    var accessibilityTrusted: Bool { trusted }

    func trigger() {
        // Capture can spend seconds waking a Chromium host. A press during that wait belongs to
        // the same input; starting a second capture would read it twice.
        guard capture == nil else { return }
        let application = NSWorkspace.shared.frontmostApplication
        let startedAt = Date()
        capture = Task { [weak self] in
            defer { self?.capture = nil }
            guard let self else { return }
            // Whatever was in front when the key went down. An error thrown before a target
            // exists still has to say which application the press was about.
            let frontmost = application?.localizedName
            var website: WebsiteSource?
            do {
                let target = try await AXTextTarget.captureFocused(in: application) { [weak self] host in
                    self?.present(.waking(host))
                }
                website = target.website
                if let host = target.websiteIconHost { WebsiteIconStore.shared.fetchIfMissing(host) }
                // A second press in the original target applies a waiting result instead of generating again.
                // Context validation remains inside PolishJobs; no write targets the status window.
                if jobs.applyWaitingResult(to: target.id) {
                    present(.applying(target.label))
                } else {
                    guard settings.isConfigured else { throw PolishError.invalidConfiguration("模型；请在设置里选一个") }
                    let selection = try prompts.selection()
                    let polisher = try Polisher(configuration: settings.configuration(), template: selection.template)
                    let id = try jobs.start(target: target, model: settings.profile.label, website: target.website,
                                            completing: { try await polisher.complete($0) })
                    jobSkills[id] = selection.skillID
                    recordTargetFacts(of: target, for: id)
                    present(.polishing(target.label))
                }
            } catch {
                let event = StatusEvent.failure(error, app: frontmost)
                let failure: RecordedFailure?
                if let focus = error as? FocusReadError { failure = .focusRead(focus.code) }
                else if let appError = error as? AppError {
                    switch appError {
                    case .accessibilityRequired: failure = .accessibilityRequired
                    case .hotKey(let code): failure = .hotKey(code)
                    }
                } else { failure = RecordedFailure(error) }
                history.recordFailure(in: frontmost ?? L10n.tr("输入区"), message: event.text,
                                      startedAt: startedAt, failure: failure, website: website)
                present(event)
            }
        }
    }

    /// The AX role, the write capability and the selected range exist only on the target, and
    /// from the next line on the target belongs to `PolishJobs`, which keeps it private. The
    /// inspector's 目标 section is the one place this product's hardest constraint becomes
    /// visible, so the facts are copied out at the moment of capture. Nothing is persisted: an
    /// element handle outlives neither the target process nor this one.
    private func recordTargetFacts(of target: AXTextTarget, for id: UUID) {
        guard let range = target.capturedRange else { return }
        TargetFactsLog.shared.record(
            TargetFacts(role: target.role, isWeb: target.isWeb,
                        supportsBackgroundWrite: target.supportsBackgroundWrite,
                        location: range.location, length: range.length),
            for: id)
    }

    private func undo() {
        guard let job = jobs.jobs.last(where: { $0.applicationState == .applied }) else {
            present(.nothingToUndo())
            return
        }
        jobs.undo(job.id)
        present(.undoing(job.targetLabel))
    }

    /// The one deep link this app needs. Sending a person hunting through System Settings is
    /// the difference between fixing the permission now and never fixing it.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func needsAttention(_ job: PolishJob) -> Bool {
        if job.computeState == .failed || job.applicationState == .uncertain { return true }
        return job.computeState == .succeeded && [.pending, .blocked].contains(job.applicationState)
    }

    /// Every state change reaches the same feedback path, whether a hot key or a window
    /// button caused it. The observation re-registers because tracking fires once.
    private func observeJobs() {
        withObservationTracking {
            _ = jobs.jobs.map { JobState(compute: $0.computeState, application: $0.applicationState) }
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.emitJobEvents()
                self?.observeJobs()
            }
        }
    }

    private func emitJobEvents() {
        var current: [UUID: JobState] = [:]
        for job in jobs.jobs {
            let state = JobState(compute: job.computeState, application: job.applicationState)
            current[job.id] = state
            guard jobStates[job.id] != state else { continue }
            // Every state change is recorded, including the first one, so a job that is
            // interrupted is still on disk as an attempt that was under way.
            history.save(PolishRecord(job: job, skillID: jobSkills[job.id]))
            guard let event = event(for: job) else { continue }
            present(event)
        }
        jobStates = current
        refreshElapsed()
    }

    /// Recomputes the running seconds and keeps the tick alive only while something is
    /// running. A permanent timer would redraw the table once a second for a window that is
    /// usually showing nothing but finished rows.
    private func refreshElapsed() {
        let now = Date()
        var elapsed: [UUID: Double] = [:]
        for job in jobs.jobs where job.computeState == .running {
            elapsed[job.id] = now.timeIntervalSince(job.createdAt)
        }
        if runningElapsed != elapsed { runningElapsed = elapsed }
        if elapsed.isEmpty {
            ticker?.cancel()
            ticker = nil
        } else if ticker == nil {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    refreshElapsed()
                }
            }
        }
    }

    private func event(for job: PolishJob) -> StatusEvent? {
        if job.computeState == .failed { return .requestFailed(job.targetLabel, reason: job.message) }
        switch job.applicationState {
        case .pending: return nil
        case .applying: return .applying(job.targetLabel)
        case .applied: return .applied(job.targetLabel)
        case .undone: return .undone(job.targetLabel)
        case .uncertain: return .uncertain(job.targetLabel)
        case .blocked: return .waiting(job.targetLabel)
        }
    }

    /// Authorisation can be granted while the app runs, and the indicator has to say so.
    private func watchPermission() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                if AXIsProcessTrusted() != trusted { trusted.toggle() }
            }
        }
    }

    /// The HUD is the whole of the feedback for a press, and the menu bar's 最近 line is the
    /// whole of its afterlife. 0.2.4 also pinned an orange sentence to the window; that
    /// sentence is now a precondition banner or an inspector line, both derived from state
    /// rather than from a copy of it that could go stale.
    private func present(_ event: StatusEvent) {
        lastEvent = event
        hud.show(event)
    }
}
