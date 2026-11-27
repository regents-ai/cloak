#if DARKBLOOM
import CloakDarkbloom
import CloakSupervisor
import SwiftUI

/// Payout-ranked eligible models, download progress, and model switching.
struct DarkbloomModelsSection: View {
    let mode: DarkbloomMode
    let flashDownload: Bool
    let onRequestSwitch: () -> Void
    let onRequestCancelDownload: (String) -> Void

    @State private var showAllModels = false
    @State private var hoveringDownloadPrompt = false

    var body: some View {
        let fitting = mode.eligibleModels
        let selectedID = mode.recommended?.id
        let topPreview: [DarkbloomSnapshot.Model] = {
            guard !showAllModels, fitting.count > 3 else { return fitting }
            var shown = Array(fitting.prefix(3))
            for candidate in fitting where candidate.id == selectedID || candidate.downloaded || mode.isModelServing(candidate) {
                if !shown.contains(where: { $0.id == candidate.id }) {
                    shown.append(candidate)
                }
            }
            return shown
        }()
        let hiddenCount = max(0, fitting.count - topPreview.count)

        Section {
            if fitting.isEmpty {
                Text(noModel)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(topPreview) { entry in
                    let isSelected = entry.id == selectedID
                    let isTopEarner = mode.pricing != nil && fitting.count > 1 && entry.id == mode.topEarnerID
                    modelRow(entry, isSelected: isSelected, isTopEarner: isTopEarner)
                }
                if hiddenCount > 0 || showAllModels && fitting.count > 3 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { showAllModels.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(showAllModels ? 90 : 0))
                                .frame(width: 12)
                                .accessibilityHidden(true)
                            Text(
                                showAllModels
                                    ? "Show fewer models"
                                    : "Show \(hiddenCount) more fitting \(hiddenCount == 1 ? "model" : "models")"
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .hover(RoundedRectangle(cornerRadius: 6), outset: 4)
                    .accessibilityValue(showAllModels ? "Expanded" : "Collapsed")
                }
            }
        } header: {
            HStack(spacing: 2) {
                Text("Model")
                InfoButton("About Model", note: modelNote)
                Spacer(minLength: 0)
                if mode.pricing != nil, fitting.count > 1 {
                    Text("Ranked by payout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(_ entry: DarkbloomSnapshot.Model, isSelected: Bool, isTopEarner: Bool) -> some View {
        let price = mode.price(for: entry)
        let tipText = modelTooltip(entry, price: price)
        LabeledContent {
            modelAction(entry, isSelected: isSelected)
        } label: {
            Button {
                mode.selectModel(entry.id)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.displayName)
                                .fontWeight(isSelected ? .medium : .regular)
                                .lineLimit(1)
                            if mode.isModelServing(entry) {
                                Text("Serving")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.14), in: Capsule())
                            } else if isTopEarner {
                                Text("Top Earner")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.green.opacity(0.14), in: Capsule())
                            }
                        }
                        Text(modelSubtitle(entry, price: price))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .tip(tipText)
    }

    private func modelSubtitle(_ entry: DarkbloomSnapshot.Model, price: DarkbloomPricing.Price?) -> String {
        var parts: [String] = []
        if let size = entry.sizeGb {
            parts.append("\(size.formatted(.number.precision(.fractionLength(1)))) GB")
        }
        if let price {
            parts.append(price.compactRate)
        }
        return parts.joined(separator: " · ")
    }

    private func modelTooltip(_ entry: DarkbloomSnapshot.Model, price: DarkbloomPricing.Price?) -> String {
        var parts: [String] = []
        if let price {
            parts.append("Darkbloom payout rate: \(price.compactRate) tokens (in | out, 0% platform cut).")
        }
        if let desc = entry.description, !desc.isEmpty {
            parts.append(desc)
        }
        return parts.joined(separator: " ")
    }

    @ViewBuilder
    private func modelAction(_ model: DarkbloomSnapshot.Model, isSelected: Bool) -> some View {
        if let op = mode.activeDownload(for: model.id) {
            HStack(spacing: 6) {
                Group {
                    if let progress = op.progress {
                        ProgressView(value: progress)
                            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                    } else {
                        ProgressView(value: nil as Double?)
                    }
                }
                .frame(width: 90)
                .accessibilityLabel("Download")
                if let progress = op.progress {
                    Text(progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 28, alignment: .trailing)
                }
                if op.cancellable {
                    SymbolButton("Cancel Download", symbol: "xmark.circle") { onRequestCancelDownload(op.id) }
                        .overhanging()
                }
            }
        } else if model.downloaded {
            if isSelected, mode.isOn, !mode.isModelServing(model) {
                Button("Switch", action: onRequestSwitch)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .tip("Downloaded")
                    .accessibilityLabel("Downloaded")
            }
        } else if isSelected {
            let emphasized = hoveringDownloadPrompt || flashDownload
            Button {
                mode.downloadModel(model.id)
            } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .scaleEffect(flashDownload ? 1.08 : (hoveringDownloadPrompt ? 1.03 : 1.0))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: emphasized ? 2.5 : 0)
                    .padding(-3)
                    .opacity(emphasized ? 1 : 0)
            )
            .shadow(
                color: Color.accentColor.opacity(flashDownload ? 0.85 : (hoveringDownloadPrompt ? 0.45 : 0)),
                radius: flashDownload ? 10 : 6
            )
            .animation(.easeInOut(duration: 0.18), value: flashDownload)
            .animation(.easeInOut(duration: 0.18), value: hoveringDownloadPrompt)
        } else {
            Button("Download") { mode.downloadModel(model.id) }
                .controlSize(.small)
        }
    }

    private var noModel: String {
        if mode.snapshot?.catalogError != nil { return "Darkbloom's model list is unavailable." }
        if mode.room == nil { return "Darkbloom doesn't say what fits." }
        return "No model fits beside Cloak."
    }

    private var modelNote: String {
        let room = mode.snapshot?.memory.pinBudgetGb.map {
            " (\($0.formatted(.number.precision(.fractionLength(0)))) GB Darkbloom budget)"
        } ?? ""
        return "Darkbloom models that fit beside Cloak, which reserves \(Memory.text(mode.cloakMemory))\(room). Ranked highest payout first using Darkbloom's live token pricing (0% platform cut)."
    }
}
#endif
