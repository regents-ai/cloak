import CloakControl
import CloakSupervisor
import SwiftUI

/// Cloak's runtime status pane inside Settings (`Settings → Status`):
/// current phase, fix actions if attention is needed, rewording model download,
/// release/model/memory/check readouts, and technical details on demand.
struct DetailsView: View {
    let supervisor: Supervisor
    let download: ModelDownload
    let showTour: () -> Void
    @State private var memory: Memory?
    @State private var verification: ReleaseVerification?
    @State private var recentCrash: DiagnosticReport.CrashInfo?
    @State private var showingDiagnostics = false
    @State private var showVerifySteps = false
    @State private var technical = false

    var body: some View {
        let status = supervisor.status
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 10) {
                        Label(supervisor.phase.title, systemImage: supervisor.phase.symbol)
                            .foregroundStyle(status.state == .needsAttention ? Color.orange : Color.primary)
                        switch supervisor.phase {
                        case .running, .preparing:
                            Button("Pause") { supervisor.send(.pause) }
                                .controlSize(.small)
                        case .paused, .ready:
                            Button("Start") { supervisor.send(.start) }
                                .controlSize(.small)
                        case .stopping, .needsAttention:
                            EmptyView()
                        }
                    }
                }
                if supervisor.phase.state == .preparing {
                    StartupProgressView(supervisor: supervisor)
                        .padding(.vertical, 2)
                }
                if let reason = status.reason {
                    let fix = Fix(for: reason, download: download)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reason.title(with: fix))
                            Text(reason.remedy(with: fix))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        Spacer(minLength: 0)
                        if case .needsAttention = supervisor.phase {
                            switch fix {
                            case .start?: Button(Fix.start.title) { supervisor.send(.start) }
                            case .repair?:
                                HStack(spacing: 6) {
                                    Button(Fix.showModel.title, action: Fix.showModel)
                                    Button(Fix.repair.title) { download.repair() }
                                        .buttonStyle(.borderedProminent)
                                }
                            case .showModel?: Button(Fix.showModel.title, action: Fix.showModel)
                            case .download?, nil: EmptyView()
                            }
                        }
                    }
                }
            } footer: {
                Text("Tor and the local rewriter start automatically when you send a Tor chat.")
            }
            if download.state != .installed {
                DownloadSection(download: download)
            }
            if let crash = recentCrash {
                Section {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Recent crash report found (\(crash.processName))")
                                .font(.callout.weight(.medium))
                            Text("Recorded locally on \(crash.date.formatted(date: .abbreviated, time: .shortened)). Cloak collects zero telemetry — you can inspect and copy a redacted report to share.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Button("Inspect Report…") { showingDiagnostics = true }
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section {
                LabeledContent("Release", value: status.release)
                LabeledContent("Rewriter", value: supervisor.resting ? "\(status.model.label), unloaded" : status.model.label)
                LabeledContent("Memory", value: memory.map { $0.total.map(Memory.text) ?? "Can't be measured" } ?? "Measuring…")
                LabeledContent("Last check", value: lastCheck(status.check))
                LabeledContent("Diagnostics") {
                    Button("Create Redacted Report…") { showingDiagnostics = true }
                        .controlSize(.small)
                }
                LabeledContent("Welcome Tour") {
                    Button("Open Tour…", action: showTour)
                        .controlSize(.small)
                }
                LabeledContent("Credits & Licenses") {
                    Button("Open Credits…") { AppDelegate.current.showCredits() }
                        .controlSize(.small)
                }
            }
            verificationSection
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { technical.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(technical ? 90 : 0))
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        Text("Technical details")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hover(RoundedRectangle(cornerRadius: 6), outset: 4)
                .accessibilityValue(technical ? "Expanded" : "Collapsed")
                if technical {
                    Text(status.detail)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onReturn { download.refresh() }
        .sheet(isPresented: $showingDiagnostics) {
            DiagnosticReportSheet(supervisor: supervisor)
        }
        .task {
            verification = await ReleaseVerification.inspectCurrentBundle()
            recentCrash = await Task.detached(priority: .utility) {
                DiagnosticReport.latestCrash()
            }.value
        }
        .task {
            repeat {
                let sample = await supervisor.readMemory()
                guard !Task.isCancelled else { break }
                memory = sample
            } while (try? await Task.sleep(for: .seconds(3))) != nil
        }
    }

    @ViewBuilder
    private var verificationSection: some View {
        Section {
            if let v = verification {
                LabeledContent("App Binary SHA-256") {
                    if let sha = v.binarySHA256 {
                        HStack(spacing: 4) {
                            Text(sha)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 230, alignment: .trailing)
                            CopyButton("Copy SHA-256", side: 26, text: sha)
                                .overhanging()
                        }
                    } else {
                        Text("Unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Apple Signature (CDHash)") {
                    if let cdHash = v.cdHash {
                        HStack(spacing: 6) {
                            if let team = v.teamID {
                                Text("Team \(team)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(team == ReleaseVerification.expectedTeamID ? .green : .orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        (team == ReleaseVerification.expectedTeamID ? Color.green : Color.orange).opacity(0.14),
                                        in: Capsule()
                                    )
                            }
                            Text(cdHash)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 165, alignment: .trailing)
                            CopyButton("Copy CDHash", side: 26, text: cdHash)
                                .overhanging()
                        }
                    } else {
                        Text("Unsigned dev build")
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Compare Against") {
                    HStack(spacing: 8) {
                        Button {
                            NSWorkspace.shared.open(ReleaseVerification.githubReleasesURL)
                        } label: {
                            Label("GitHub Releases", systemImage: "arrow.up.right.square")
                        }
                        .controlSize(.small)
                        Button {
                            NSWorkspace.shared.open(ReleaseVerification.websiteInstallURL)
                        } label: {
                            Label("regents.sh/cloak/install", systemImage: "arrow.up.right.square")
                        }
                        .controlSize(.small)
                    }
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showVerifySteps.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showVerifySteps ? 90 : 0))
                            .frame(width: 12)
                            .accessibilityHidden(true)
                        Text("Verify independently in macOS Terminal")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .hover(RoundedRectangle(cornerRadius: 6), outset: 4)
                .accessibilityValue(showVerifySteps ? "Expanded" : "Collapsed")

                if showVerifySteps {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Don't rely on an app alone to verify itself. Run macOS's built-in tools in Terminal and match the output against GitHub Releases (SHA256SUMS.txt) and regents.sh/cloak/install:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(v.verificationCommands, id: \.label) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.label)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 6) {
                                    Text(item.command)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer(minLength: 4)
                                    CopyButton("Copy command", side: 24, text: item.command)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                LabeledContent("App Binary SHA-256") {
                    Text("Calculating…")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Release Verification")
        } footer: {
            Text("Computed live from this app bundle on disk. Compare with SHA256SUMS.txt on GitHub Releases and regents.sh/cloak/install.")
                .foregroundStyle(.secondary)
        }
    }

    private func lastCheck(_ check: StatusDocument.Check?) -> String {
        guard let check else { return "Not yet" }
        let time = check.at.formatted(date: .omitted, time: .shortened)
        return check.passed ? "Passed at \(time)" : "Failed at \(time)"
    }
}
