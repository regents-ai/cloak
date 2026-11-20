import CloakSupervisor
import SwiftUI

/// The model's download (`ModelDownload`), in the Details window while the
/// model's files are not all in place: its size, where it comes from and
/// what that host sees, said before the button; then how far it has come,
/// why it stopped, and Download or Continue, Pause and Cancel. A download
/// certain to fail has its button disabled, with the reason beside it.
struct DownloadSection: View {
    let download: ModelDownload
    @State private var confirmingCancel = false

    var body: some View {
        let host = download.hosts.joined(separator: " and ")
        Section("Download") {
            LabeledContent("Size", value: Self.text(download.total))
            LabeledContent("From", value: host)
            Text("This download goes straight from this Mac to \(host) and its download servers, so they see this Mac's internet address. Messages Cloak sends take another route.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if download.isUnderWay || download.done > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(download.done), total: Double(max(download.total, 1)))
                        .accessibilityLabel("Download")
                        .accessibilityValue("\(Self.text(download.done)) of \(Self.text(download.total))")
                    HStack {
                        Text(status)
                        Spacer()
                        Text("\(Self.text(download.done)) of \(Self.text(download.total))")
                            .monospacedDigit()
                            .accessibilityHidden(true)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            if let note = Self.note(download) {
                Label(note, systemImage: "exclamationmark.circle.fill")
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if !download.isUnderWay, let block = download.blocked {
                    Text(Self.text(block))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if download.isUnderWay || download.hasPartials {
                    Button("Cancel") { confirmingCancel = true }
                }
                if download.isUnderWay {
                    Button("Pause") { download.pause() }
                } else {
                    Button(download.done > 0 ? "Continue" : "Download") { download.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(download.blocked != nil)
                }
            }
        }
        .confirmationDialog("Cancel the download?", isPresented: $confirmingCancel) {
            Button("Cancel Download", role: .destructive) { download.cancel() }
            Button("Keep Downloading", role: .cancel) {}
        } message: {
            Text("What has downloaded so far is deleted from this Mac.")
        }
    }

    private var status: String {
        switch download.state {
        case .downloading: "Downloading"
        case .waitingForNetwork: "Waiting for the network"
        case .retrying: "Trying again"
        case .stopped(.mismatch), .stopped(.failed): "Stopped"
        case .stopped(.paused), .stopped(nil), .installed: "Paused"
        }
    }

    /// Why `download` stopped, said without claiming a cause it cannot know:
    /// here and under its row in Settings' Local Llama.
    static func note(_ download: ModelDownload) -> String? {
        let host = download.hosts.joined(separator: " and ")
        return switch download.state {
        case .stopped(.mismatch):
            "A downloaded file didn't match the one Cloak expects, so it was deleted."
        case .stopped(.failed(let problem)):
            switch problem {
            case .network:
                "The download kept losing its connection. This usually means the network is unsteady."
            case .status(let code) where [401, 403, 429].contains(code):
                "\(host) refused the download (\(code)). This usually means it's limiting downloads from this address for a while."
            case .status(let code) where [404, 410].contains(code):
                "\(host) doesn't have the file (\(code)). It may have moved."
            case .status(let code) where (500...599).contains(code):
                "\(host) had a problem (\(code)). This usually passes within a few minutes."
            case .status(let code):
                "\(host) answered with an error (\(code))."
            case .write:
                "The download couldn't be saved. This usually means the disk is full."
            case .other(let description):
                "The download stopped: \(description)"
            }
        default:
            nil
        }
    }

    static func text(_ block: ModelDownload.Block) -> String {
        switch block {
        case .mac: "This Mac can't run the model."
        case .disk(let needed, let free): "Needs \(text(needed)) of space; \(text(free)) is free."
        }
    }

    static func text(_ bytes: Int) -> String {
        Int64(bytes).formatted(.byteCount(style: .file))
    }
}
