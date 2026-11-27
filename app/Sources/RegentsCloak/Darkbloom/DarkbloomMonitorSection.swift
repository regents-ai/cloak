#if DARKBLOOM
import CloakDarkbloom
import SwiftUI

/// Isolated 2-second SSE live telemetry section so heartbeat and metric
/// updates never re-evaluate the outer DarkbloomView form or sibling sections.
struct DarkbloomMonitorSection: View {
    let mode: DarkbloomMode

    var body: some View {
        if let snapshot = mode.snapshot {
            let loadedModels = snapshot.models.filter(\.loaded)
            let routableCount = snapshot.models.filter { $0.registration == "routable" }.count
            let memoryUsed = loadedModels.compactMap(\.memoryGb).reduce(0, +)
            let live = snapshot.liveMetrics
            Section("Live Monitor") {
                LabeledContent("Provider Health") {
                    if snapshot.state == "running" {
                        if mode.setup.job?.mode == .onlyMe {
                            Label("Local Only · Healthy", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if routableCount > 0 {
                            Label("Routable (\(routableCount) model\(routableCount == 1 ? "" : "s"))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if snapshot.providerStatus == "untrusted" {
                            Label("Awaiting Verification", systemImage: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                        } else {
                            Text(snapshot.providerStatus?.capitalized ?? "Joining Network")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(snapshot.state.capitalized)
                            .foregroundStyle(.secondary)
                    }
                }
                if let budget = snapshot.memory.pinBudgetGb {
                    LabeledContent("Model Memory") {
                        if snapshot.state == "running", memoryUsed == 0 {
                            Text("0.0 / \(budget, format: .number.precision(.fractionLength(1))) GB · loads on demand")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(memoryUsed, format: .number.precision(.fractionLength(1))) / \(budget, format: .number.precision(.fractionLength(1))) GB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let tps = live?.resolvedTPS {
                    LabeledContent("Throughput") {
                        Text("\(tps, format: .number.precision(.fractionLength(1))) tok/s")
                            .monospacedDigit()
                    }
                }
                if let served = live?.resolvedRequests ?? snapshot.activity?.resolvedRequests {
                    LabeledContent("Served Requests") {
                        if let active = live?.resolvedActive, active > 0 {
                            Text("\(served.formatted()) (\(active) active)")
                                .monospacedDigit()
                        } else {
                            Text(served.formatted())
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let sessionEarned = snapshot.activity?.earningsMicroUsd, sessionEarned > 0 {
                    LabeledContent("Session Settled") {
                        Text(DarkbloomCloudEarnings.formatMicroUSD(sessionEarned))
                            .fontWeight(.medium)
                            .foregroundStyle(.green)
                            .monospacedDigit()
                    }
                }
                if let tokens = snapshot.activity?.resolvedTokens, tokens > 0 {
                    LabeledContent("Output Tokens") {
                        Text(tokens.formatted())
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let uptime = live?.uptimeSeconds {
                    LabeledContent("Daemon Uptime") {
                        Text(Duration.seconds(uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else if let startedAt = snapshot.activity?.startedAt, startedAt > 0, snapshot.state == "running" {
                    let startDate = Date(timeIntervalSince1970: startedAt)
                    LabeledContent("Daemon Uptime") {
                        Text(timerInterval: startDate...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else if let since = mode.connectedSince {
                    LabeledContent("Stream Connected") {
                        Text(timerInterval: since...Date.distantFuture, countsDown: false)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                if let beat = mode.lastHeartbeat {
                    DarkbloomHeartbeatRow(beat: beat)
                }
            }
        }
    }
}

private struct DarkbloomHeartbeatRow: View {
    let beat: Date

    var body: some View {
        TimelineView(.periodic(from: beat, by: 5)) { context in
            let age = max(0, Int(context.date.timeIntervalSince(beat)))
            LabeledContent("Last Heartbeat") {
                Text(age < 5 ? "Just now" : "\(age)s ago")
                    .monospacedDigit()
                    .foregroundStyle(age > 15 ? .orange : .secondary)
            }
        }
    }
}
#endif
