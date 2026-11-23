import SwiftUI

@main
struct PastebotBridgeApp: App {
    @State private var controller = BridgeController()

    var body: some Scene {
        MenuBarExtra {
            StatusView(controller: controller)
        } label: {
            Image(systemName: controller.isHealthy ? "doc.on.clipboard" : "exclamationmark.triangle")
        }
        .menuBarExtraStyle(.window)
    }
}

extension BridgeController {
    var isHealthy: Bool {
        // Fine as long as nothing is blocked or failing and at least one clipboard manager is present.
        let databasesOK = sources.allSatisfy { source in
            switch source.status {
            case .ok, .unknown, .notInstalled: true
            case .accessDenied, .error: false
            }
        } && !sources.allSatisfy { $0.status == .notInstalled }
        return databasesOK && cloudStatus.accountProblem == nil && cloudStatus.error == nil
    }
}

struct StatusView: View {
    @Bindable var controller: BridgeController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pastebot Bridge").font(.headline)

            section("Clipboard history") { databaseRows }
            section("iCloud") { cloudRow }

            Divider()

            Toggle("Launch at login", isOn: Binding(
                get: { controller.launchAtLogin },
                set: { controller.setLaunchAtLogin($0) }
            ))
            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    @ViewBuilder
    private var databaseRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(controller.sources) { source in
                databaseRow(source)
            }
            if controller.sources.allSatisfy({ $0.status == .notInstalled }) {
                Text("Install Pastebot, or turn on Clipboard History in Alfred's Features › Clipboard History.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if controller.sources.contains(where: { $0.status == .accessDenied }) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Add Pastebot Bridge in Privacy & Security › Full Disk Access. It will connect automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Full Disk Access Settings") { controller.openFullDiskAccessSettings() }
                }
            }
            if let lastChange = controller.lastChange {
                Text("Last change \(lastChange, format: .relative(presentation: .named))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func databaseRow(_ source: SourceStatus) -> some View {
        let name = source.kind.displayName
        switch source.status {
        case .unknown:
            Label("\(name): checking…", systemImage: "hourglass")
        case .ok(let count):
            Label("\(name): \(count) clips", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notInstalled:
            Label("\(name): not found", systemImage: "minus.circle").foregroundStyle(.secondary)
        case .accessDenied:
            Label("\(name): needs Full Disk Access", systemImage: "lock.fill").foregroundStyle(.orange)
        case .error(let message):
            Label("\(name): \(message)", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var cloudRow: some View {
        let status = controller.cloudStatus
        VStack(alignment: .leading, spacing: 4) {
            if let problem = status.accountProblem {
                Label(problem, systemImage: "exclamationmark.icloud.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { controller.retryCloud() }
            } else if !status.started {
                Label("Connecting…", systemImage: "icloud")
            } else if status.pending > 0 {
                Label("Uploading \(status.pending) changes…", systemImage: "icloud.and.arrow.up")
            } else {
                Label("\(status.uploaded) clips in iCloud", systemImage: "checkmark.icloud.fill").foregroundStyle(.green)
            }
            if status.deletedOnPhone > 0 {
                Text("\(status.deletedOnPhone) deleted on iPhone (still on this Mac, not uploaded)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = status.error {
                Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if let lastUpload = status.lastUpload {
                Text("Last upload \(lastUpload, format: .relative(presentation: .named))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Clip contents are stored as encrypted fields in your private iCloud database.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
