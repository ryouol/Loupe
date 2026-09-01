import Foundation
import LoupeCore
import SwiftUI

private enum LegalDocument: String, CaseIterable, Identifiable {
    case privacy = "Privacy notice"
    case terms = "Terms of use"
    case notices = "Third-party notices"

    var id: String { rawValue }

    var resourceName: String {
        switch self {
        case .privacy: return "Privacy"
        case .terms: return "Terms"
        case .notices: return "ThirdPartyNotices"
        }
    }

    var symbol: String {
        switch self {
        case .privacy: return "hand.raised"
        case .terms: return "doc.text"
        case .notices: return "shippingbox"
        }
    }

    func contents(in bundle: Bundle = .main) -> String {
        var url =
            bundle.url(forResource: resourceName, withExtension: "txt", subdirectory: "Legal")
            ?? bundle.url(forResource: resourceName, withExtension: "txt")
        #if DEBUG
            if url == nil {
                url = URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources/Legal/\(resourceName).txt")
            }
        #endif
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This bundled document is unavailable. Do not distribute this build."
        }
        return text
    }
}

public struct AboutView: View {
    @State private var selectedDocument: LegalDocument?

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 18) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Loupe")
                            .font(.largeTitle.weight(.semibold))
                        Text("Version \(Loupe.version)")
                            .foregroundStyle(.secondary)
                        Text("Local-first evidence for Apple Silicon inference")
                            .font(.headline)
                    }
                }

                GroupBox("Privacy by default") {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            "No account or analytics SDK",
                            systemImage: "person.crop.circle.badge.xmark")
                        Label("No automatic session upload", systemImage: "icloud.slash")
                        Label(
                            "Built-in adapters omit prompt and generated text",
                            systemImage: "text.badge.checkmark")
                        Text(
                            "Session names, adapter errors, model identifiers, timing, and "
                                + "benchmark prompt corpora can still be sensitive. Export only "
                                + "to a destination you trust."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Documents") {
                    VStack(spacing: 0) {
                        ForEach(LegalDocument.allCases) { document in
                            Button {
                                selectedDocument = document
                            } label: {
                                HStack {
                                    Label(document.rawValue, systemImage: document.symbol)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)
                            if document != LegalDocument.allCases.last {
                                Divider()
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                }

                Label(
                    "Commercial release still requires an approved seller identity, support "
                        + "contact, privacy notice, customer terms, and license inventory.",
                    systemImage: "checklist"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .navigationSubtitle("About and legal")
        .sheet(item: $selectedDocument) { document in
            LegalDocumentSheet(document: document)
        }
    }
}

private struct LegalDocumentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: LegalDocument

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(attributedContents)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
            .navigationTitle(document.rawValue)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
        .frame(minWidth: 620, minHeight: 500)
    }

    private var attributedContents: AttributedString {
        let contents = document.contents()
        return (try? AttributedString(markdown: contents)) ?? AttributedString(contents)
    }
}
