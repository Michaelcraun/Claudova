import AppKit
import Foundation
import Observation

/// App-level state: the open design workspace, its build status, and the build loop that runs
/// after each Claude turn.
@MainActor
@Observable
final class AppModel {
    enum Status: Equatable {
        case idle
        case preparing(String)
        case ready
        case failed(String)

        var isBusy: Bool {
            if case .preparing = self { true } else { false }
        }
    }

    private(set) var workspace: Workspace?
    /// All designs, newest first (stable while you click around, unlike last-opened order).
    private(set) var designs: [Workspace] = []
    private(set) var status: Status = .idle
    /// Output of the most recent build, for display when something goes wrong.
    private(set) var buildLog: String = ""
    /// URL of the most recently built model file.
    private(set) var modelURL: URL?

    /// The conversation with Claude for the open workspace.
    let chat: ChatStore

    private let manager: WorkspaceManager?
    private let builder: any ModelBuilding
    private var started = false
    /// The build in progress, if any; builds never overlap.
    private var currentBuild: Task<Void, Never>?

    init(
        manager: WorkspaceManager? = try? .makeDefault(),
        chat: ChatStore = ChatStore(),
        builder: any ModelBuilding = ModelBuilder()
    ) {
        self.manager = manager
        self.chat = chat
        self.builder = builder
        chat.onSessionStarted = { [weak self] sessionID in
            self?.saveSessionID(sessionID)
        }
        chat.onTranscriptChanged = { [weak self] items in
            guard let self, let workspace = self.workspace else { return }
            try? self.manager?.saveTranscript(items, for: workspace)
        }
        chat.afterTurn = { [weak self] result, remainingFixes in
            await self?.afterClaudeTurn(result, remainingFixes: remainingFixes) ?? .none
        }
    }

    private func saveSessionID(_ sessionID: String) {
        guard var workspace, let manager else { return }
        workspace.metadata.claudeSessionID = sessionID
        try? manager.save(workspace)
        self.workspace = workspace
        refreshDesigns()
    }

    // MARK: - Workspaces

    /// Opens the most recently used workspace, creating one if none exist, and makes sure it's built.
    func start() async {
        guard !started else { return }
        started = true
        guard let manager else {
            status = .failed(WorkspaceError.templateMissing.localizedDescription)
            return
        }
        do {
            let workspace = try manager.list().first ?? manager.create(named: manager.nextUntitledName())
            await open(workspace)
        } catch {
            status = .failed(error.localizedDescription)
        }
        #if DEBUG
        // For driving the app in tests/demos without UI scripting:
        //   open Claudova.app --args -ClaudovaAutoSend "make a 20 mm cube"
        if let message = UserDefaults.standard.string(forKey: "ClaudovaAutoSend") {
            chat.send(message)
        }
        #endif
    }

    func open(_ workspace: Workspace) async {
        guard let manager else { return }
        let opened = (try? manager.markOpened(workspace)) ?? workspace
        manager.refreshAppOwnedFiles(in: opened)
        self.workspace = opened
        chat.open(opened, transcript: manager.loadTranscript(for: opened))
        refreshDesigns()
        modelURL = FileManager.default.fileExists(atPath: opened.modelOutputURL.path) ? opened.modelOutputURL : nil

        let needsBuild = !FileManager.default.fileExists(atPath: opened.buildDirectoryURL.path)
            || !ModelBuilder.isOutputUpToDate(opened)
        if needsBuild {
            await build(message: modelURL == nil ? "Preparing workspace (first build)…" : "Building model…")
        } else {
            manager.refreshCadovaSkill(in: opened)
            status = .ready
        }
    }

    func revealWorkspaceInFinder() {
        guard let workspace else { return }
        reveal(workspace)
    }

    func reveal(_ design: Workspace) {
        NSWorkspace.shared.activateFileViewerSelecting([design.mainSourceURL])
    }

    // MARK: - Design management

    /// Designs can't be switched, created or deleted while Claude is working on the open one.
    var canSwitchDesigns: Bool { !chat.isRunning }

    func refreshDesigns() {
        designs = (manager?.list() ?? []).sorted { $0.metadata.createdAt > $1.metadata.createdAt }
    }

    func openDesign(id: Workspace.ID) async {
        guard id != workspace?.id, canSwitchDesigns,
              let design = designs.first(where: { $0.id == id }) else { return }
        await open(design)
    }

    /// Creates a new, empty design and opens it.
    func createDesign() async {
        guard canSwitchDesigns, let manager else { return }
        do {
            let design = try manager.create(named: manager.nextUntitledName())
            await open(design)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func rename(_ design: Workspace, to name: String) {
        guard let manager, let renamed = try? manager.rename(design, to: name) else { return }
        if renamed.id == workspace?.id { workspace = renamed }
        refreshDesigns()
    }

    /// Moves a design to the Trash. If it was open, opens the next most recent one (or a new one).
    func delete(_ design: Workspace, moveToTrash: Bool = true) async {
        guard let manager else { return }
        let wasOpen = design.id == workspace?.id
        guard !wasOpen || canSwitchDesigns else { return }
        do {
            try manager.delete(design, moveToTrash: moveToTrash)
        } catch {
            status = .failed("Couldn't delete \(design.name): \(error.localizedDescription)")
            return
        }
        refreshDesigns()
        guard wasOpen else { return }
        workspace = nil
        modelURL = nil
        if let next = manager.list().first {  // most recently opened
            await open(next)
        } else {
            await createDesign()
        }
    }

    // MARK: - Building

    /// Builds the open workspace with `swift run`. If a build is already running, waits for it
    /// and then builds again (the sources may have changed since it started).
    func build(message: String = "Building model…") async {
        while let current = currentBuild {
            await current.value
        }
        let task = Task { await performBuild(message: message) }
        currentBuild = task
        await task.value
        currentBuild = nil
    }

    private func performBuild(message: String) async {
        guard let workspace else { return }
        status = .preparing(message)
        buildLog = ""
        do {
            let outcome = try await builder.build(workspace, onLine: nil)
            guard workspace.id == self.workspace?.id else { return }
            buildLog = outcome.result.output
            if outcome.succeeded {
                manager?.refreshCadovaSkill(in: workspace)
                modelURL = outcome.modelURL
                status = .ready
            } else {
                status = .failed(ModelBuilder.errorSummary(from: outcome.result.output))
            }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - Build loop

    /// Runs after each Claude turn: makes sure the model file matches the code, and if the code
    /// doesn't build, asks Claude to fix it (bounded by `ChatStore.maxAutomaticFollowUps`).
    func afterClaudeTurn(_ result: ClaudeEvent.TurnResult, remainingFixes: Int) async -> TurnFollowUp {
        guard let workspace else { return .none }

        // Usually Claude ran `swift run` after its last edit, so there's nothing to do.
        if ModelBuilder.isOutputUpToDate(workspace), currentBuild == nil {
            if status != .ready { status = .ready }
            return .none
        }

        await build()
        guard case .failed(let errors) = status else { return .none }

        // Don't auto-fix after Claude itself errored (rate limits, crashes): it would likely fail
        // again, and the user should decide.
        if result.isError || remainingFixes <= 0 {
            return .notice(
                "The model doesn't build. Click the warning in the toolbar for details, or ask Claude to fix it.",
                isError: true
            )
        }
        let attempt = ChatStore.maxAutomaticFollowUps - remainingFixes + 1
        return .send(
            prompt: Self.fixPrompt(errors: errors),
            notice: "The model didn't build, so I asked Claude to fix it (attempt \(attempt) of \(ChatStore.maxAutomaticFollowUps))."
        )
    }

    static func fixPrompt(errors: String) -> String {
        """
        [Automatic message from the Claudova app, not the user]
        After your last turn the app ran `swift run`, and the model failed to build:

        ```
        \(errors)
        ```

        Fix the code so the model builds, run `swift run` to confirm, and then tell the user \
        briefly what was wrong.
        """
    }
}
