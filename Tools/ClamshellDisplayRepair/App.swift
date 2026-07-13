import SwiftUI

@main
struct ClamshellDisplayRepairApp: App {
    var body: some Scene {
        WindowGroup("Clamshell Display Repair") {
            RepairView()
        }
        .windowResizability(.contentSize)
    }
}

private struct RepairResult {
    let output: String
    let succeeded: Bool
}

@MainActor
private final class RepairModel: ObservableObject {
    @Published var output = "Reading display state…"
    @Published var isRunning = false
    @Published var lastActionSucceeded: Bool?

    func refresh() {
        run("--status")
    }

    func repair() {
        run("--repair")
    }

    func enableBuiltInDisplay() {
        run("--enable-built-in")
    }

    private func run(_ argument: String) {
        guard !isRunning else { return }
        isRunning = true
        lastActionSucceeded = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.invokeHelper(argument)
            DispatchQueue.main.async { [weak self] in
                self?.output = result.output
                self?.lastActionSucceeded = result.succeeded
                self?.isRunning = false
            }
        }
    }

    nonisolated private static func invokeHelper(_ argument: String) -> RepairResult {
        guard let helper = Bundle.main.url(
            forAuxiliaryExecutable: "ClamshellDisplayRepair") else {
            return RepairResult(
                output: "The bundled repair helper is missing.",
                succeeded: false)
        }

        let standardOutput = Pipe()
        let standardError = Pipe()
        let process = Process()
        process.executableURL = helper
        process.arguments = [argument]
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return RepairResult(output: error.localizedDescription, succeeded: false)
        }

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        let error = String(decoding: errorData, as: UTF8.self)
        let message = [output, error]
            .filter { !$0.isEmpty }
            .joined(separator: output.isEmpty || error.isEmpty ? "" : "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return RepairResult(
            output: message.isEmpty ? "No output from repair helper." : message,
            succeeded: process.terminationStatus == 0)
    }
}

private struct RepairView: View {
    @StateObject private var model = RepairModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "laptopcomputer.and.arrow.down")
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Clamshell Display Repair")
                        .font(.title2.bold())
                    Text("Removes a stranded built-in display after Screen Sharing disconnects.")
                        .foregroundStyle(.secondary)
                }
            }

            Text(model.output)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(width: 590, alignment: .topLeading)
                .frame(minHeight: 105, alignment: .topLeading)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            if model.lastActionSucceeded == false {
                Label("No display change was made.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Refresh") { model.refresh() }
                Spacer()
                Button("Re-enable Built-in") { model.enableBuiltInDisplay() }
                    .help("Recovery control for the current login session")
                Button("Repair Closed-Lid Display") { model.repair() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(model.isRunning)

            Text("Repair runs only when the lid is closed, an external display is active, and the built-in display is incorrectly active. It applies only to the current login session.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .overlay {
            if model.isRunning {
                ProgressView()
                    .controlSize(.large)
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .task { model.refresh() }
    }
}
