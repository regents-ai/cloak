import AppKit
import CloakControl
import CloakSupervisor
import SwiftUI

/// User-initiated, inspectable diagnostic report sheet. Nothing is sent over
/// the network — the user can review every redacted line before copying it
/// into a GitHub issue, Patchbay thread, or email.
struct DiagnosticReportSheet: View {
    let supervisor: Supervisor
    @Environment(\.dismiss) private var dismiss

    @State private var report: DiagnosticReport.Result?
    @State private var copied = false

    private static let githubNewIssueURL = URL(string: "https://github.com/regents-ai/cloak/issues/new")!
    private static let patchbayURL = URL(string: "https://regents.sh/patchbay/cloak")!

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Redacted Diagnostic Report")
                        .font(.headline)
                    Text("Zero telemetry — nothing leaves your Mac unless you copy and share it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let report {
                    HStack(spacing: 6) {
                        badge(
                            symbol: "checkmark.shield",
                            tint: .green,
                            label: "Redacted"
                        )
                        if report.crash != nil {
                            badge(
                                symbol: "exclamationmark.triangle.fill",
                                tint: .orange,
                                label: "Crash included"
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            if let report {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Usernames, IPs, wallet addresses, keys, and chat transcripts are excluded or scrubbed. Review every line below before sharing:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ScrollView {
                        Text(report.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                }
                .padding(18)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Collecting local status, recent logs, and any macOS crash report…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    NSWorkspace.shared.open(Self.githubNewIssueURL)
                } label: {
                    Label("GitHub Issue", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)

                Button {
                    NSWorkspace.shared.open(Self.patchbayURL)
                } label: {
                    Label("Patchbay", systemImage: "arrow.up.right.square")
                }
                .controlSize(.small)

                Spacer()

                if let report {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.text, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied" : "Copy Report", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 680, height: 560)
        .task {
            let status = supervisor.status
            let checkSummary: String =
                if let check = status.check {
                    "\(check.passed ? "Passed" : "Failed") (\(check.at.formatted(date: .abbreviated, time: .shortened)))"
                } else {
                    "Not run"
                }
            report = await DiagnosticReport.generate(
                release: status.release,
                build: status.build,
                phaseTitle: supervisor.phase.title,
                reason: status.reason?.rawValue,
                rewriterModel: status.model.label,
                rewriterResting: supervisor.resting,
                lastCheckSummary: checkSummary,
                statusDetail: status.detail
            )
        }
    }

    private func badge(symbol: String, tint: Color, label: String) -> some View {
        Label(label, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}
