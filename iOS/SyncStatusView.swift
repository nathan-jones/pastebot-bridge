import SwiftUI

/// iCloud sync status and actions, opened from the cloud button.
struct SyncStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRedownload = false
    private let model = ClipsModel.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Group {
                        if let problem = model.accountProblem {
                            Label(problem, systemImage: "exclamationmark.icloud").foregroundStyle(.orange)
                        } else if model.isSyncing {
                            Label("Syncing…", systemImage: "arrow.triangle.2.circlepath.icloud")
                        } else {
                            Label("Synced with iCloud", systemImage: "checkmark.icloud").foregroundStyle(.green)
                        }
                        LabeledContent("Clips", value: model.allClips.count.formatted())
                        LabeledContent("Last synced") {
                            if let lastSynced = model.lastSynced {
                                Text(lastSynced, format: .relative(presentation: .named))
                            } else {
                                Text("Never")
                            }
                        }
                        if let error = model.errorMessage {
                            Text(error).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    .themedRow(raised: true)
                } header: {
                    Text("iCloud")
                } footer: {
                    Text("Pastebot Bridge on your Mac uploads clips to your private iCloud database, with clip contents stored as encrypted fields. This device keeps a copy for offline use.")
                }

                Section {
                    Group {
                        Button("Sync Now") { Task { await CloudSync.shared.fetchNow() } }
                            .foregroundStyle(.tint)
                            .disabled(model.isSyncing)
                        Button("Re-download Everything", role: .destructive) { confirmRedownload = true }
                            .foregroundStyle(.red)
                    }
                    .themedRow(raised: true)
                }
            }
            .themedText()
            .themedBackground()
            .navigationTitle("iCloud Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Delete the copy on this device and download all clips again?",
                                isPresented: $confirmRedownload, titleVisibility: .visible) {
                Button("Re-download", role: .destructive) {
                    Task { await CloudSync.shared.redownloadEverything() }
                }
            }
        }
        .themedRoot()
    }
}
