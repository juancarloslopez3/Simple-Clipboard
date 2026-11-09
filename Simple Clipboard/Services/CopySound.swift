import AppKit

/// Plays the copy-feedback sound (`playSoundOnCopy`). Shared by the two events
/// that count as "a copy": selecting an item/snippet inside the app (`PasteService.feedback`)
/// and an external ⌘C being captured into history (`HistoryStore.capture`). Owned once by
/// `AppModel` and injected into both, so there's a single sound and no double-play — internal
/// copies suppress the monitor (`acknowledgeChange`), so only one of the two paths fires per copy.
///
/// Holds a **private copy** of the system "Pop" sound, retained for the app's lifetime. We
/// deliberately don't call `NSSound(named:)` per copy: that returns a globally shared, cached
/// instance whose state gets stuck after the first play (`isPlaying` stays true), so every
/// subsequent `play()` no-ops and no sound is heard. Owning a private instance and `stop()`-ing
/// before each `play()` makes it replay reliably on every copy (and on rapid back-to-back copies).
@MainActor
final class CopySound {
    private let sound = NSSound(named: "Pop")?.copy() as? NSSound

    /// Play the feedback sound if `playSoundOnCopy` is enabled; a no-op otherwise.
    func play() {
        guard Pref.playSoundOnCopy, let sound else { return }
        sound.stop()   // reset so the sound restarts on every copy (see the type note)
        sound.play()
    }
}
