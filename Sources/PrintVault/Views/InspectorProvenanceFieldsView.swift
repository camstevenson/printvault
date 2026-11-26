import SwiftUI

struct InspectorProvenanceFieldsView: View {
    @Binding var sourceURLDraft: String
    @Binding var designerDraft: String
    @Binding var licenseDraft: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Source URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(
                    "Source URL",
                    text: $sourceURLDraft,
                    prompt: Text("https://printables.com/model/...")
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Designer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "Designer",
                        text: $designerDraft,
                        prompt: Text("Creator or handle")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("License")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        TextField(
                            "License",
                            text: $licenseDraft,
                            prompt: Text("e.g. CC BY 4.0")
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                        Menu("Choose Common License", systemImage: "chevron.down.circle") {
                            ForEach(DownloadProvenanceService.commonLicenses, id: \.self) { preset in
                                Button(preset) {
                                    licenseDraft = preset
                                }
                            }
                            if !licenseDraft.isEmpty {
                                Divider()
                                Button("Clear License", role: .destructive, action: clearLicense)
                            }
                        }
                        .labelStyle(.iconOnly)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Choose a common 3D printing license")
                    }
                }
            }
        }
    }

    private func clearLicense() {
        licenseDraft = ""
    }
}
