import Foundation

// MARK: - SongPlaybackVersions

/// Audio/video counterparts for a YouTube Music song.
struct SongPlaybackVersions: Equatable {
    var audio: Song?
    var video: Song?

    var hasVideoVersion: Bool {
        self.video != nil
    }
}
