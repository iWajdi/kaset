import Foundation

// MARK: - Audio / Video Version Switching

@MainActor
extension PlayerService {
    var activePlaybackVideoId: String? {
        self.pendingPlayVideoId ?? SingletonPlayerWebView.shared.currentVideoId ?? self.currentTrack?.videoId
    }

    var isPlayingVideoVersion: Bool {
        if self.canUseNativePlaybackVersionSwitch, self.nativePlaybackVersionMode == .video {
            return true
        }

        guard let track = self.playbackVersionSourceTrack,
              let activePlaybackVideoId = self.activePlaybackVideoId
        else {
            return false
        }

        return self.isPlayingVideoVersion(track: track, activePlaybackVideoId: activePlaybackVideoId)
    }

    var canTogglePlaybackVersion: Bool {
        self.currentTrack != nil && self.currentEpisode == nil && !self.isResolvingPlaybackVersion
    }

    func togglePlaybackVersion() async {
        guard let track = self.playbackVersionSourceTrack,
              self.currentEpisode == nil,
              !self.isResolvingPlaybackVersion
        else {
            return
        }

        self.isResolvingPlaybackVersion = true
        defer { self.isResolvingPlaybackVersion = false }

        do {
            let playingVideoVersion = (self.activePlaybackVideoId.map {
                self.isPlayingVideoVersion(track: track, activePlaybackVideoId: $0)
            } ?? false) || self.nativePlaybackVersionMode == .video
            let nativeTarget: NativePlaybackVersionMode = playingVideoVersion ? .song : .video

            if await self.switchNativePlaybackVersionIfAvailable(to: nativeTarget, sourceTrack: track) {
                return
            }

            let versions = try await self.resolvePlaybackVersions(for: track)

            if playingVideoVersion {
                guard let audioSong = versions.audio ?? self.fallbackAudioSong(from: track, versions: versions) else {
                    self.logger.info("No audio version found for '\(track.title)'")
                    return
                }
                self.applyPlaybackVersion(displaySong: audioSong, playbackVideoId: audioSong.videoId)
            } else {
                guard let videoSong = versions.video else {
                    self.updateVideoAvailability(hasVideo: false)
                    self.logger.info("No official video version found for '\(track.title)'")
                    return
                }

                let displaySong = versions.audio
                    ?? self.fallbackAudioSong(from: track, versions: versions)
                    ?? self.displaySongByPairing(track, audio: nil, video: videoSong)
                self.applyPlaybackVersion(displaySong: displaySong, playbackVideoId: videoSong.videoId)
            }
        } catch {
            self.logger.warning("Failed to toggle playback version: \(error.localizedDescription)")
        }
    }

    func prepareToShowVideoMode() {
        self.beginNativePlaybackVersionSwitch(to: .video)
    }

    func updateNativePlaybackVersionStatus(mode: NativePlaybackVersionMode?, canSwitch: Bool) {
        self.nativePlaybackVersionMode = mode
        self.canUseNativePlaybackVersionSwitch = canSwitch
        if canSwitch {
            self.currentTrackHasVideo = true
        }
    }

    func beginNativePlaybackVersionSwitch(to target: NativePlaybackVersionMode) {
        self.nativePlaybackVersionSwitchTarget = target
        self.nativePlaybackVersionSwitchGraceUntil = Date().addingTimeInterval(5)
    }

    func clearNativePlaybackVersionSwitchGrace() {
        self.nativePlaybackVersionSwitchTarget = nil
        self.nativePlaybackVersionSwitchGraceUntil = nil
    }

    var isNativePlaybackVersionSwitchGraceActive: Bool {
        guard let graceUntil = self.nativePlaybackVersionSwitchGraceUntil else { return false }
        if graceUntil > Date() {
            return true
        }
        self.clearNativePlaybackVersionSwitchGrace()
        return false
    }
}

private extension PlayerService {
    var playbackVersionSourceTrack: Song? {
        guard let currentTrack else { return nil }
        guard let currentQueueSong = self.queue[safe: self.currentIndex] else { return currentTrack }

        if currentQueueSong.isPlaybackVariant(videoId: self.activePlaybackVideoId)
            || currentQueueSong.isPlaybackVariant(videoId: currentTrack.videoId)
            || currentTrack.isPlaybackVariant(videoId: currentQueueSong.videoId)
        {
            return currentQueueSong
        }

        return currentTrack
    }

    func isPlayingVideoVersion(track: Song, activePlaybackVideoId: String) -> Bool {
        if track.videoVersionVideoId == activePlaybackVideoId {
            return true
        }

        return track.musicVideoType == .omv && track.videoId == activePlaybackVideoId
    }

    func switchNativePlaybackVersionIfAvailable(
        to target: NativePlaybackVersionMode,
        sourceTrack: Song
    ) async -> Bool {
        guard SingletonPlayerWebView.shared.webView != nil else { return false }

        self.beginNativePlaybackVersionSwitch(to: target)
        let switched = await SingletonPlayerWebView.shared.switchNativePlaybackVersion(to: target)
        guard switched else {
            self.clearNativePlaybackVersionSwitchGrace()
            return false
        }

        let displaySong = self.queue[safe: self.currentIndex] ?? sourceTrack
        self.currentTrack = displaySong
        self.replaceCurrentQueueEntry(with: displaySong)
        self.saveQueueForPersistence()
        self.showMiniPlayer = false
        return true
    }

    func resolvePlaybackVersions(for track: Song) async throws -> SongPlaybackVersions {
        guard let client = self.ytMusicClient else {
            return SongPlaybackVersions(
                audio: self.fallbackAudioSong(from: track, versions: .init()),
                video: self.fallbackVideoSong(from: track)
            )
        }

        var audio = try await self.knownAudioSong(for: track, client: client)
        var video = try await self.knownVideoSong(for: track, client: client)

        if audio == nil || video == nil {
            let searchedVersions = try await client.getSongPlaybackVersions(for: track)
            audio = audio ?? searchedVersions.audio
            video = video ?? searchedVersions.video
        }

        return self.pairedVersions(audio: audio, video: video)
    }

    func knownAudioSong(for track: Song, client: any YTMusicClientProtocol) async throws -> Song? {
        if track.musicVideoType == .atv || track.musicVideoType == nil && track.videoVersionVideoId != track.videoId {
            return self.displaySongByPairing(track, audio: track, video: self.fallbackVideoSong(from: track))
        }

        guard let audioId = track.audioVersionVideoId else { return nil }
        if audioId == track.videoId {
            return self.displaySongByPairing(track, audio: track, video: self.fallbackVideoSong(from: track))
        }

        let song = try await client.getSong(videoId: audioId)
        return self.displaySongByPairing(song, audio: song, video: self.fallbackVideoSong(from: track))
    }

    func knownVideoSong(for track: Song, client: any YTMusicClientProtocol) async throws -> Song? {
        if track.musicVideoType == .omv {
            return self.displaySongByPairing(track, audio: nil, video: track)
        }

        guard let videoId = track.videoVersionVideoId else { return nil }
        if videoId == track.videoId {
            return self.displaySongByPairing(track, audio: nil, video: track)
        }

        let song = try await client.getSong(videoId: videoId)
        return self.displaySongByPairing(song, audio: self.fallbackAudioSong(from: track, versions: .init()), video: song)
    }

    func fallbackAudioSong(from track: Song, versions: SongPlaybackVersions) -> Song? {
        if track.musicVideoType == .omv, let audio = versions.audio {
            return audio
        }

        if track.musicVideoType == .omv, track.audioVersionVideoId == nil {
            return nil
        }

        return self.displaySongByPairing(track, audio: track, video: versions.video ?? self.fallbackVideoSong(from: track))
    }

    func fallbackVideoSong(from track: Song) -> Song? {
        guard track.musicVideoType == .omv || track.videoVersionVideoId == track.videoId else {
            return nil
        }
        return self.displaySongByPairing(track, audio: nil, video: track)
    }

    func pairedVersions(audio: Song?, video: Song?) -> SongPlaybackVersions {
        var pairedAudio = audio
        var pairedVideo = video
        let audioId = pairedAudio?.videoId
        let videoId = pairedVideo?.videoId

        pairedAudio = pairedAudio.map { self.displaySongByPairing($0, audio: $0, video: pairedVideo) }
        pairedVideo = pairedVideo.map { self.displaySongByPairing($0, audio: pairedAudio, video: $0) }

        pairedAudio?.audioVersionVideoId = audioId
        pairedAudio?.videoVersionVideoId = videoId
        pairedVideo?.audioVersionVideoId = audioId
        pairedVideo?.videoVersionVideoId = videoId

        return SongPlaybackVersions(audio: pairedAudio, video: pairedVideo)
    }

    func displaySongByPairing(_ song: Song, audio: Song?, video: Song?) -> Song {
        var pairedSong = song
        pairedSong.audioVersionVideoId = audio?.videoId ?? song.audioVersionVideoId
        pairedSong.videoVersionVideoId = video?.videoId ?? song.videoVersionVideoId
        pairedSong.hasVideo = pairedSong.videoVersionVideoId != nil || pairedSong.hasVideo == true
        return pairedSong
    }

    func applyPlaybackVersion(displaySong: Song, playbackVideoId: String) {
        self.logger.info("Switching playback version to \(playbackVideoId)")
        self.clearRestoredPlaybackSessionState()
        self.currentEpisode = nil
        self.state = .loading
        self.songNearingEnd = false
        self.shouldSuppressAutoplayAfterQueueEnd = false
        self.isKasetInitiatedPlayback = true
        self.currentTrack = displaySong
        self.currentTrackHasVideo = displaySong.videoVersionVideoId != nil
            || displaySong.musicVideoType?.hasVideoContent == true
            || displaySong.hasVideo == true
        self.pendingPlayVideoId = playbackVideoId
        self.showMiniPlayer = false

        self.replaceCurrentQueueEntry(with: displaySong)
        self.saveQueueForPersistence()

        if SingletonPlayerWebView.shared.webView != nil {
            SingletonPlayerWebView.shared.loadVideo(videoId: playbackVideoId)
        }
    }

    func replaceCurrentQueueEntry(with song: Song) {
        guard self.queueEntries.indices.contains(self.currentIndex) else { return }
        var updatedEntries = self.queueEntries
        updatedEntries[self.currentIndex] = QueueEntry(id: updatedEntries[self.currentIndex].id, song: song)
        self.setQueue(entries: updatedEntries)
    }
}
