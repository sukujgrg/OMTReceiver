import SwiftUI

enum AppInformationPage: String, CaseIterable, Identifiable, Hashable {
    case gettingStarted = "Getting Started"
    case privacy = "Privacy Policy"
    case licences = "Third-Party Licences"

    var id: String { rawValue }
    var resource: String {
        switch self {
        case .gettingStarted: return "GettingStarted"
        case .privacy: return "PrivacyPolicy"
        case .licences: return "ThirdPartyNotices"
        }
    }
    var accessibilityID: String {
        switch self {
        case .gettingStarted: return "information-help"
        case .privacy: return "information-privacy"
        case .licences: return "information-licences"
        }
    }
}

struct AppInformationView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("An independent Open Media Transport receiver for Apple TV.")
                    Text(version).foregroundStyle(.secondary)
                }
                Section("Information") {
                    ForEach(AppInformationPage.allCases) { page in
                        NavigationLink(value: page) { Text(page.rawValue) }
                            .accessibilityIdentifier(page.accessibilityID)
                    }
                }
            }
            .navigationTitle("About OMT Receiver")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("information-done")
                }
            }
            .navigationDestination(for: AppInformationPage.self) { page in
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        ForEach(Array(document(page).components(separatedBy: "\n\n").enumerated()), id: \.offset) { index, paragraph in
                            Text(paragraph)
                                .font(page == .licences ? .body.monospaced() : .body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .focusable()
                                .focusEffectDisabled()
                                .accessibilityIdentifier(page.accessibilityID + "-paragraph-\(index)")
                        }
                    }
                    .padding(60)
                    .frame(maxWidth: 1400)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(page.accessibilityID + "-document")
                }
                .background(Color.black.ignoresSafeArea())
                .navigationTitle(page.rawValue)
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        let build = info["CFBundleVersion"] as? String ?? ""
        return "Version \(version) (\(build))"
    }

    private func document(_ page: AppInformationPage) -> String {
        guard let url = Bundle.main.url(forResource: page.resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This document is unavailable. Visit https://sukujgrg.github.io/OMTReceiver/ for support."
        }
        return text
    }
}
