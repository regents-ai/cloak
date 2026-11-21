import AppKit
import CloakControl
import CloakSupervisor

/// The one fix Cloak offers for a failure, wherever the failure shows: the
/// menu's header, Details, Chat's waiting row and the Wallet's. Only a fix
/// that can work: Start where it is not certain to stop again; the way to
/// the model's download while its files are not in place, and Start once
/// they are; the model's folder when its files have changed; none where
/// Cloak can do nothing (docs/state-machines.md, section 9).
enum Fix: Equatable {
    /// Start again.
    case start
    /// The way to the model's download, in Details.
    case download(underWay: Bool)
    /// Reveal the model's folder in Finder; nothing in it is changed.
    case showModel

    /// The fix for `reason`, with the files of the model that rewords as
    /// `download` last found them; nil where Cloak has none to offer.
    @MainActor
    init?(for reason: Reason, download: ModelDownload) {
        switch reason {
        // A download that finished since the start that stopped leaves
        // nothing missing.
        case .modelMissing: self = download.state == .installed ? .start : .download(underWay: download.isUnderWay)
        case .modelChanged: self = .showModel
        case .torUnavailable, .torStopped, .workerUnavailable, .workerStopped, .guestFailed, .checkFailed: self = .start
        case .unsupportedHardware, .partMissing, .partChanged: return nil
        }
    }

    /// Whether a Start now is certain to stop again for `reason`: where the
    /// rule has no fix, or the fix is the download. A changed model's folder
    /// may have been put right by hand since, which Cloak cannot see, so
    /// Start stays open for it.
    @MainActor
    static func startStops(for reason: Reason, download: ModelDownload) -> Bool {
        switch Fix(for: reason, download: download) {
        case .start?, .showModel?: false
        case .download?, nil: true
        }
    }

    var title: String {
        switch self {
        case .start: "Start Again"
        case .download(let underWay): underWay ? "Downloading Model…" : "Download Model…"
        case .showModel: "Show in Finder"
        }
    }

    /// Reveals the folder of the model that rewords; nothing in it is
    /// changed.
    @MainActor
    static func showModel() {
        NSWorkspace.shared.activateFileViewerSelecting([Launch.layout.model(Launch.manifest.rewordingModel)])
    }
}
