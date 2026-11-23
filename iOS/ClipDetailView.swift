import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ClipDetailView: View {
    let clip: Clip
    var onDelete: (() -> Void)?
    @State private var confirmDelete = false
    @State private var showImageViewer = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if clip.hasImage {
                    Button { showImageViewer = true } label: {
                        ClipImage(id: clip.id, maxPixel: 2048)
                            .frame(maxWidth: .infinity, minHeight: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.footnote.weight(.semibold))
                                    .padding(8)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .padding(8)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View full image")
                    .accessibilityHint("Opens the image full screen. Pinch to zoom.")
                }

                if let text = clip.text {
                    Text(text)
                        .font(clip.kind == .text ? .body : .body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if clip.textTruncated {
                    Label("This clip is longer than the 20 MB synced from your Mac.",
                          systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }

                metadata
            }
            .padding()
            .themedText()
        }
        .themedBackground()
        .navigationTitle(clip.kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Keeps the clip's actions in their own capsule, apart from Settings / iCloud.
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let url = clip.webURL {
                    Link(destination: url) { Image(systemName: "safari") }
                        .accessibilityLabel("Open in Safari")
                }
                if let text = clip.text {
                    ShareLink(item: text)
                }
                CopyButton(clip: clip)
                if onDelete != nil {
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .fullScreenCover(isPresented: $showImageViewer) {
            ImageViewer(clipID: clip.id)
        }
        .confirmationDialog("Delete this clip from iCloud and all your devices? It stays in your clipboard history on your Mac.",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Clip", role: .destructive) { onDelete?() }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            LabeledContent("Copied", value: clip.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let source = clip.sourceName { LabeledContent("From", value: source) }
            LabeledContent("Via", value: clip.clipboardManager.displayName)
            if let text = clip.text { LabeledContent("Characters", value: text.count.formatted()) }
            DisclosureGroup("Formats (\(clip.types.count))") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(clip.types, id: \.self) { Text($0).font(.caption.monospaced()) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

extension ClipKind {
    var title: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .file: "File"
        case .image: "Image"
        case .other: "Clip"
        }
    }
}

/// Copies the clip's text, or its image, from the offline copy.
struct CopyButton: View {
    let clip: Clip
    @State private var copied = false

    var body: some View {
        Button {
            Task { await copy() }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
    }

    private func copy() async {
        let item: [String: Any]
        if let text = clip.text {
            item = [UTType.utf8PlainText.identifier: text]
        } else if clip.hasImage, let image = ImageLoader.fullImage(id: clip.id) {
            item = [UTType.image.identifier: image]
        } else {
            return
        }
        // localOnly keeps the copy off Universal Clipboard, so it isn't sent back to the Mac
        // (where Pastebot or Alfred would record it as a new clip).
        UIPasteboard.general.setItems([item], options: [.localOnly: true])
        copied = true
        try? await Task.sleep(for: .seconds(1.5))
        copied = false
    }
}

/// A clip's image from the offline copy.
struct ClipImage: View {
    let id: String
    let maxPixel: Int
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: "\(id)-\(maxPixel)") {
            image = await ImageLoader.image(id: id, maxPixel: maxPixel)
            failed = image == nil && !Task.isCancelled
        }
    }
}
