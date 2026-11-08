import Foundation
import Synchronization
import TablesEngine

/// Runs a workbook's macros away from the main thread, and carries their
/// `MsgBox` and `InputBox` questions to the user and the answers back.
///
/// A macro runs against a copy of the workbook. Whatever it did comes back
/// whole when it finishes, to be applied as one change — and so undone as one.
@MainActor
@Observable
public final class MacroRunner {
    /// A question a running macro is waiting on.
    public struct Prompt: Identifiable, Sendable {
        public enum Kind: Sendable {
            /// `MsgBox`, with VBA's button-set code: 0 OK, 1 OK/Cancel, 3
            /// Yes/No/Cancel, 4 Yes/No, and so on.
            case message(buttons: Int)
            case input(defaultText: String)
            /// `Shell` or `FollowHyperlink` asking to open a link.
            case openLink(URL)
            /// `SendKeys`, whose keys the user is shown to type themselves.
            case sendKeys(String)
        }

        public let id = UUID()
        public var kind: Kind
        public var title: String?
        public var text: String
    }

    /// What a finished run hands back.
    public struct Outcome: Sendable {
        public var workbook: Workbook
        public var activeSheetID: Worksheet.ID
        public var selection: CellRange
        /// Why it stopped early, when it did. The workbook still carries
        /// whatever it had done by then.
        public var failure: String?
    }

    public private(set) var runningMacro: String?
    public var prompt: Prompt?
    /// What the last run printed with `Debug.Print`.
    public private(set) var output: [String] = []

    public var isRunning: Bool { runningMacro != nil }

    @ObservationIgnored private var cancellation = MacroCancellation()
    @ObservationIgnored private var promptChannel: MacroPromptChannel?

    public init() {}

    /// Runs `procedure` from `module`. Returns when the macro has finished,
    /// failed, or been stopped.
    public func run(
        _ procedure: String, in module: String, project: VBAProject, workbook: Workbook, workbookName: String,
        activeSheet: Worksheet.ID?, selection: CellRange, workingFolder: URL? = nil
    ) async -> Outcome {
        let cancellation = MacroCancellation()
        let channel = MacroPromptChannel(cancellation: cancellation)
        self.cancellation = cancellation
        promptChannel = channel
        runningMacro = procedure
        output = []
        defer {
            runningMacro = nil
            prompt = nil
            promptChannel = nil
        }

        let lines = Mutex<[String]>([])
        // The closures live only as long as the run, so holding the runner
        // strongly costs nothing.
        let show: @Sendable (Prompt.Kind, String?, String) -> Void = { kind, title, text in
            Task { @MainActor in self.prompt = Prompt(kind: kind, title: title, text: text) }
        }
        let interaction = VBAInteraction(
            messageBox: { text, buttons, title in
                let answer = channel.ask { show(.message(buttons: buttons), title, text) }
                // Stopping mid-question answers Cancel, or OK where there is none.
                return answer.button ?? (buttons & 0xF == 0 ? 1 : 2)
            },
            inputBox: { text, title, defaultText in
                channel.ask { show(.input(defaultText: defaultText), title, text) }.text
            },
            debugPrint: { line in lines.withLock { $0.append(line) } },
            openURL: { url in
                // The link opens on the main thread when the user agrees;
                // the macro only learns whether it did.
                channel.ask { show(.openLink(url), nil, url.absoluteString) }.button == 1
            },
            showSendKeys: { keys in
                _ = channel.ask { show(.sendKeys(keys), nil, keys) }
            }
        )

        let outcome = await Self.execute(
            procedure, in: module, project: project, workbook: workbook, workbookName: workbookName,
            activeSheet: activeSheet, selection: selection, workingFolder: workingFolder,
            interaction: interaction, cancellation: cancellation
        )
        output = lines.withLock { $0 }
        return outcome
    }

    /// Asks a running macro to stop at its next statement.
    public func stop() {
        cancellation.cancel()
        promptChannel?.answer(MacroPromptAnswer())
    }

    /// Hands the user's answer to the waiting macro.
    public func answer(button: Int? = nil, text: String? = nil) {
        prompt = nil
        promptChannel?.answer(MacroPromptAnswer(button: button, text: text))
    }

    /// The interpreter recurses as deeply as the macro does, so it gets a
    /// thread of its own with room for that, rather than a pool thread —
    /// which it would also be wrong to block while a question is up.
    private nonisolated static func execute(
        _ procedure: String, in module: String, project: VBAProject, workbook: Workbook, workbookName: String,
        activeSheet: Worksheet.ID?, selection: CellRange, workingFolder: URL?, interaction: VBAInteraction,
        cancellation: MacroCancellation
    ) async -> Outcome {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                let host = VBAExcelHost(workbook: workbook, name: workbookName, activeSheet: activeSheet,
                                        selection: selection, interaction: interaction)
                var failure: String?
                // Without a folder, file statements say files are unavailable
                // rather than the whole macro failing to start.
                let files = workingFolder.flatMap { try? VBAFileSystem(root: $0) }
                do {
                    let interpreter = try VBAInterpreter(project: project, host: host)
                    interpreter.isCancelled = { cancellation.isCancelled }
                    interpreter.fileSystem = files
                    _ = try interpreter.run(procedure, in: module)
                } catch let error as VBAError {
                    failure = Self.describe(error)
                } catch VBAControl.cancelled {
                    failure = String(localized: "Macros.Stopped", bundle: #bundle)
                } catch VBAControl.end {
                    failure = nil
                } catch {
                    failure = error.localizedDescription
                }
                // Files a macro left open are written out however it ended,
                // before anything can show the folder.
                files?.closeAll()
                continuation.resume(returning: Outcome(
                    workbook: host.finishedWorkbook, activeSheetID: host.activeSheetID,
                    selection: host.selection, failure: failure
                ))
            }
            thread.stackSize = 16 << 20
            thread.name = "Macro"
            thread.start()
        }
    }

    public nonisolated static func describe(_ error: VBAError) -> String {
        let message = error.number == 0 ? error.description : "\(error.description) (\(error.number))"
        guard let module = error.module, let line = error.line else { return message }
        return String(format: String(localized: "Macros.Failed.Location", bundle: #bundle), message, module, line)
    }
}

/// The flag a running macro checks between statements.
public final class MacroCancellation: Sendable {
    private let flag = Mutex(false)

    public var isCancelled: Bool { flag.withLock { $0 } }

    public func cancel() { flag.withLock { $0 = true } }
}

public struct MacroPromptAnswer: Sendable {
    public var button: Int?
    public var text: String?
}

/// Where a macro's thread waits for the user. The macro blocks in `ask`
/// until the main thread calls `answer`; an answer with nobody waiting —
/// Stop pressed between questions — is dropped rather than left to answer
/// the next one.
public final class MacroPromptChannel: Sendable {
    private struct State {
        var isWaiting = false
        var answer: MacroPromptAnswer?
    }

    private let state = Mutex(State())
    private let semaphore = DispatchSemaphore(value: 0)
    public let cancellation: MacroCancellation

    public init(cancellation: MacroCancellation) {
        self.cancellation = cancellation
    }

    public func ask(presenting present: @Sendable () -> Void) -> MacroPromptAnswer {
        guard !cancellation.isCancelled else { return MacroPromptAnswer() }
        state.withLock { $0 = State(isWaiting: true) }
        present()
        semaphore.wait()
        return state.withLock { state in
            defer { state = State() }
            return state.answer ?? MacroPromptAnswer()
        }
    }

    public func answer(_ answer: MacroPromptAnswer) {
        let delivered = state.withLock { state -> Bool in
            guard state.isWaiting, state.answer == nil else { return false }
            state.answer = answer
            return true
        }
        if delivered { semaphore.signal() }
    }
}
