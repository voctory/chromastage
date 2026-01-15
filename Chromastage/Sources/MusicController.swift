import AppKit
import Foundation

enum PreferenceKeys {
  static let useSpotify = "useSpotify"
  static let hasSetSpotifyPreference = "hasSetSpotifyPreference"
  static let lyricsSyncOffset = "lyricsSyncOffset"
}

enum SpotifyIntegration {
  static let bundleIdentifier = "com.spotify.client"

  static var isInstalled: Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
  }

  static var isEnabled: Bool {
    if let stored = UserDefaults.standard.object(forKey: PreferenceKeys.useSpotify) as? Bool {
      return stored
    }
    return false
  }
}

enum PlayerSource: String {
  case music
  case spotify
  case none
}

struct NowPlayingInfo {
  let source: PlayerSource
  let title: String
  let artist: String
  let album: String
  let state: String
  let duration: TimeInterval
  let position: TimeInterval
  let artworkURL: String?
}

@MainActor
final class MusicController: ObservableObject {
  @Published var trackTitle: String = ""
  @Published var artist: String = ""
  @Published var album: String = ""
  @Published var isPlaying: Bool = false
  @Published var artworkPalette: [String] = []
  @Published var artworkImage: NSImage?
  @Published var artworkStatus: String = ""
  @Published var trackDuration: TimeInterval = 0
  @Published var lyricsKind: LyricsKind = .none
  @Published var syncedLyrics: [LyricsCue] = []
  @Published var plainLyricsLines: [String] = []
  @Published var lyricsSequenceID: UUID = UUID()

  private var timer: Timer?
  private var lastTrackKey: String = ""
  private var activeSource: PlayerSource = .none
  private var lastActiveSource: PlayerSource = .none
  private var lastArtworkFetchAt: Date = .distantPast
  private let artworkRetryInterval: TimeInterval = 3.0
  private var lastAppleScriptError: String?
  private var lastPositionSampledAt: Date = .distantPast
  private var lastKnownPosition: TimeInterval = 0
  private var lyricsTask: Task<Void, Never>?
  private var lastLyricsFetchKey: String = ""
  private let lyricsService = LyricsService()
  private var lastSyncedIndex: Int?
  private let playbackBacktrackTolerance: TimeInterval = 0.4
  private let playbackSeekThreshold: TimeInterval = 1.5
  private let manualSeekGrace: TimeInterval = 1.2
  private let manualSeekTolerance: TimeInterval = 0.75
  private var lastManualSeekAt: Date?
  private var lastManualSeekPosition: TimeInterval = 0
  private var artworkTask: Task<Void, Never>?
  private var spotifyArtworkURL: String?
  private var lastArtworkURL: String?

  private var shouldQuerySpotify: Bool {
    SpotifyIntegration.isEnabled && SpotifyIntegration.isInstalled
  }

  var artistAlbumLine: String {
    let parts = [artist, album].filter { !$0.isEmpty }
    if parts.isEmpty {
      return activeSource == .spotify ? "Spotify" : "Apple Music"
    }
    return parts.joined(separator: " · ")
  }

  func isBeforeFirstSyncedLyric(at position: TimeInterval) -> Bool {
    guard lyricsKind == .synced, let first = syncedLyrics.first else { return false }
    return position + 0.02 < first.time
  }

  func startPolling() {
    stopPolling()
    refreshNowPlaying()
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.refreshNowPlaying()
      }
    }
  }

  func stopPolling() {
    timer?.invalidate()
    timer = nil
  }

  func playPause() {
    runSimpleCommand("playpause", source: activeSource)
    refreshNowPlaying()
  }

  func nextTrack() {
    runSimpleCommand("next track", source: activeSource)
    refreshNowPlaying()
  }

  func previousTrack() {
    runSimpleCommand("previous track", source: activeSource)
    refreshNowPlaying()
  }

  func seek(to position: TimeInterval) {
    guard trackDuration > 0 else { return }
    let clamped = max(0, min(position, trackDuration))
    lastManualSeekAt = Date()
    lastManualSeekPosition = clamped
    runSetPosition(clamped, source: activeSource)
    updatePlayback(position: clamped, duration: trackDuration)
  }

  private func runSimpleCommand(_ command: String, source: PlayerSource) {
    let target: String
    switch source {
    case .spotify:
      guard shouldQuerySpotify else { return }
      target = "Spotify"
    case .music, .none:
      target = "Music"
    }
    let script = "tell application \"\(target)\" to \(command)"
    _ = runAppleScript(script)
  }

  private func runSetPosition(_ position: TimeInterval, source: PlayerSource) {
    let target: String
    switch source {
    case .spotify:
      guard shouldQuerySpotify else { return }
      target = "Spotify"
    case .music, .none:
      target = "Music"
    }
    let value = String(format: "%.3f", position)
    let script = "tell application \"\(target)\" to set player position to \(value)"
    _ = runAppleScript(script)
  }

  private func refreshNowPlaying() {
    let musicInfo = fetchMusicInfo()
    let spotifyInfo = shouldQuerySpotify ? fetchSpotifyInfo() : nil
    guard let info = chooseActiveSource(music: musicInfo, spotify: spotifyInfo) else {
      return
    }

    trackTitle = info.title
    artist = info.artist
    album = info.album
    isPlaying = (info.state == "playing")
    activeSource = info.source
    if info.state == "playing" {
      lastActiveSource = info.source
    }
    updatePlayback(position: info.position, duration: info.duration)

    let key = "\(info.source.rawValue)||\(trackTitle)||\(artist)||\(album)"
    if key != lastTrackKey {
      lastTrackKey = key
      spotifyArtworkURL = info.artworkURL
      lastArtworkURL = nil
      artworkTask?.cancel()
      artworkPalette = []
      artworkImage = nil
      artworkStatus = ""
      resetLyricsState()
      updateArtworkPalette()
    } else if artworkImage == nil {
      let elapsed = Date().timeIntervalSince(lastArtworkFetchAt)
      if elapsed >= artworkRetryInterval {
        spotifyArtworkURL = info.artworkURL
        updateArtworkPalette()
      }
    }

    fetchLyricsIfNeeded(trackTitle: trackTitle, artist: artist, album: album, duration: info.duration)
  }

  private func updatePlayback(position: TimeInterval, duration: TimeInterval) {
    let clampedDuration = max(0, duration)
    var clampedPosition = max(0, min(position, clampedDuration))
    if let lastSeekAt = lastManualSeekAt {
      let elapsed = Date().timeIntervalSince(lastSeekAt)
      if elapsed < manualSeekGrace {
        let distance = abs(clampedPosition - lastManualSeekPosition)
        if distance > manualSeekTolerance {
          clampedPosition = lastManualSeekPosition
        } else {
          lastManualSeekAt = nil
        }
      } else {
        lastManualSeekAt = nil
      }
    }
    if isPlaying {
      let backtrack = lastKnownPosition - clampedPosition
      if backtrack > playbackBacktrackTolerance {
        if backtrack < playbackSeekThreshold {
          clampedPosition = lastKnownPosition
        }
      }
    }
    lastKnownPosition = clampedPosition
    lastPositionSampledAt = Date()
    trackDuration = clampedDuration
  }

  func playbackPosition(at date: Date = Date()) -> TimeInterval {
    guard trackDuration > 0 else { return 0 }
    if isPlaying {
      let elapsed = date.timeIntervalSince(lastPositionSampledAt)
      return min(trackDuration, max(0, lastKnownPosition + elapsed))
    }
    return min(trackDuration, max(0, lastKnownPosition))
  }

  private func parseNumber(_ text: String) -> Double {
    Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
  }

  private func fetchMusicInfo() -> NowPlayingInfo? {
    let script = """
    tell application "Music"
      if it is running then
        set tName to ""
        set tArtist to ""
        set tAlbum to ""
        set tDuration to 0
        set tPosition to 0
        set tState to (player state as string)
        try
          set tName to name of current track
          set tArtist to artist of current track
          set tAlbum to album of current track
          set tDuration to duration of current track
          set tPosition to player position
        end try
        return tName & "||" & tArtist & "||" & tAlbum & "||" & tState & "||" & tDuration & "||" & tPosition
      else
        set tName to ""
        set tArtist to ""
        set tAlbum to ""
        set tDuration to 0
        set tPosition to 0
        set tState to "stopped"
        return tName & "||" & tArtist & "||" & tAlbum & "||" & tState & "||" & tDuration & "||" & tPosition
      end if
    end tell
    """

    guard let result = runAppleScript(script) else {
      return nil
    }
    let parts = result.components(separatedBy: "||")
    guard parts.count >= 6 else { return nil }
    return NowPlayingInfo(
      source: .music,
      title: parts[0],
      artist: parts[1],
      album: parts[2],
      state: parts[3],
      duration: parseNumber(parts[4]),
      position: parseNumber(parts[5]),
      artworkURL: nil
    )
  }

  private func fetchSpotifyInfo() -> NowPlayingInfo? {
    let script = """
    tell application "Spotify"
      if it is running then
        set tName to ""
        set tArtist to ""
        set tAlbum to ""
        set tDuration to 0
        set tPosition to 0
        set tState to (player state as string)
        set tArtwork to ""
        try
          set tName to name of current track
          set tArtist to artist of current track
          set tAlbum to album of current track
          set tDuration to duration of current track
          set tPosition to player position
          set tArtwork to artwork url of current track
        end try
        return tName & "||" & tArtist & "||" & tAlbum & "||" & tState & "||" & tDuration & "||" & tPosition & "||" & tArtwork
      else
        set tName to ""
        set tArtist to ""
        set tAlbum to ""
        set tDuration to 0
        set tPosition to 0
        set tState to "stopped"
        set tArtwork to ""
        return tName & "||" & tArtist & "||" & tAlbum & "||" & tState & "||" & tDuration & "||" & tPosition & "||" & tArtwork
      end if
    end tell
    """

    guard let result = runAppleScript(script) else {
      return nil
    }
    let parts = result.components(separatedBy: "||")
    guard parts.count >= 7 else { return nil }
    let durationRaw = parseNumber(parts[4])
    let duration = durationRaw > 0 ? durationRaw / 1000.0 : 0
    return NowPlayingInfo(
      source: .spotify,
      title: parts[0],
      artist: parts[1],
      album: parts[2],
      state: parts[3],
      duration: duration,
      position: parseNumber(parts[5]),
      artworkURL: parts[6].isEmpty ? nil : parts[6]
    )
  }

  private func chooseActiveSource(music: NowPlayingInfo?, spotify: NowPlayingInfo?) -> NowPlayingInfo? {
    if let spotify, spotify.state == "playing" {
      return spotify
    }
    if let music, music.state == "playing" {
      return music
    }
    if lastActiveSource == .spotify, let spotify, !spotify.title.isEmpty {
      return spotify
    }
    if lastActiveSource == .music, let music, !music.title.isEmpty {
      return music
    }
    if let spotify, !spotify.title.isEmpty {
      return spotify
    }
    if let music, !music.title.isEmpty {
      return music
    }
    return nil
  }

  private func resetLyricsState() {
    lyricsTask?.cancel()
    lyricsTask = nil
    syncedLyrics = []
    plainLyricsLines = []
    lyricsKind = .none
    lastLyricsFetchKey = ""
    lastSyncedIndex = nil
    lyricsSequenceID = UUID()
  }

  private func fetchLyricsIfNeeded(trackTitle: String, artist: String, album: String, duration: TimeInterval) {
    let trimmedTitle = trackTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      resetLyricsState()
      return
    }
    guard duration > 0 else { return }
    let trimmedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)
    let fetchKey = "\(trimmedTitle)||\(trimmedArtist)||\(trimmedAlbum)||\(Int(duration.rounded()))"
    guard fetchKey != lastLyricsFetchKey else { return }
    lastLyricsFetchKey = fetchKey
    lyricsTask?.cancel()
    lyricsKind = .loading
    syncedLyrics = []
    plainLyricsLines = []

    lyricsTask = Task { [weak self] in
      guard let self else { return }
      do {
        let response = try await lyricsService.fetchLyrics(
          trackName: trimmedTitle,
          artistName: trimmedArtist,
          albumName: trimmedAlbum,
          duration: duration
        )
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self.applyLyricsResponse(response)
        }
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self.lyricsKind = .none
        }
      }
    }
  }

  private func applyLyricsResponse(_ response: LRCLibResponse?) {
    guard let response else {
      lyricsKind = .notFound
      lyricsSequenceID = UUID()
      return
    }
    if response.instrumental == true {
      lyricsKind = .instrumental
      lyricsSequenceID = UUID()
      return
    }

    if let synced = response.syncedLyrics, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let cues = LyricsService.parseSyncedLyrics(synced)
      if !cues.isEmpty {
        syncedLyrics = cues
        lyricsKind = .synced
        lyricsSequenceID = UUID()
        return
      }
    }

    if let plain = response.plainLyrics, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let lines = LyricsService.parsePlainLyrics(plain)
      if !lines.isEmpty {
        plainLyricsLines = lines
        lyricsKind = .plain
        lyricsSequenceID = UUID()
        return
      }
    }

    lyricsKind = .notFound
    lyricsSequenceID = UUID()
  }

  func lyricsDisplayLines(maxLines: Int = 3, position: TimeInterval) -> [LyricsDisplayLine] {
    guard maxLines > 0 else { return [] }
    switch lyricsKind {
    case .synced:
      guard !syncedLyrics.isEmpty else { return [] }
      let index = stableSyncedIndex(for: position)
      if let index {
        let end = min(index + maxLines, syncedLyrics.count)
        return syncedLyrics[index..<end].enumerated().map { offset, cue in
          LyricsDisplayLine(id: cue.id, text: cue.text, isActive: offset == 0)
        }
      }
      let end = min(maxLines, syncedLyrics.count)
      return syncedLyrics[0..<end].enumerated().map { offset, cue in
        LyricsDisplayLine(id: cue.id, text: cue.text, isActive: false)
      }
    case .plain:
      let end = min(maxLines, plainLyricsLines.count)
      return plainLyricsLines[0..<end].enumerated().map { offset, text in
        LyricsDisplayLine(id: "plain-\(offset)-\(text)", text: text, isActive: offset == 0)
      }
    default:
      return []
    }
  }

  private func syncedLyricIndex(for position: TimeInterval) -> Int? {
    guard !syncedLyrics.isEmpty else { return nil }
    var low = 0
    var high = syncedLyrics.count - 1
    var best: Int?
    while low <= high {
      let mid = (low + high) / 2
      let cue = syncedLyrics[mid]
      if cue.time <= position + 0.01 {
        best = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return best
  }

  private func stableSyncedIndex(for position: TimeInterval) -> Int? {
    guard let candidate = syncedLyricIndex(for: position) else {
      lastSyncedIndex = nil
      return nil
    }
    if let last = lastSyncedIndex, candidate < last {
      let lastTime = syncedLyrics[last].time
      if position + 0.05 < lastTime {
        lastSyncedIndex = candidate
        return candidate
      }
      return last
    }
    lastSyncedIndex = candidate
    return candidate
  }

  private func updateArtworkPalette() {
    switch activeSource {
    case .spotify:
      updateSpotifyArtwork()
    case .music, .none:
      updateMusicArtwork()
    }
  }

  private func updateMusicArtwork() {
    lastArtworkFetchAt = Date()
    guard let path = fetchArtworkPath() else {
      setArtworkFailure(lastAppleScriptError ?? "Artwork unavailable")
      return
    }
    guard let image = readArtworkImage(from: path) else {
      setArtworkFailure("Artwork decode failed")
      return
    }
    try? FileManager.default.removeItem(atPath: path)
    applyArtworkImage(image)
  }

  private func updateSpotifyArtwork() {
    lastArtworkFetchAt = Date()
    guard let urlString = spotifyArtworkURL, let url = URL(string: urlString) else {
      setArtworkFailure("Spotify artwork unavailable")
      return
    }
    if urlString == lastArtworkURL, artworkImage != nil {
      return
    }
    lastArtworkURL = urlString
    artworkTask?.cancel()
    artworkTask = Task { [weak self] in
      guard let self else { return }
      do {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard !Task.isCancelled else { return }
        guard let image = NSImage(data: data) else {
          await MainActor.run {
            self.setArtworkFailure("Spotify artwork decode failed")
          }
          return
        }
        await MainActor.run {
          self.applyArtworkImage(image)
        }
      } catch {
        guard !Task.isCancelled else { return }
        await MainActor.run {
          self.setArtworkFailure("Spotify artwork fetch failed")
        }
      }
    }
  }

  private func setArtworkFailure(_ message: String) {
    artworkPalette = []
    artworkImage = nil
    if artworkStatus.isEmpty || artworkStatus != message {
      artworkStatus = message
    }
  }

  private func applyArtworkImage(_ image: NSImage) {
    artworkImage = image
    let colors = PaletteExtractor.extract(from: image, maxColors: 5)
    let hex = colors.map { color -> String in
      let rgb = color.usingColorSpace(.deviceRGB) ?? color
      let r = Int((rgb.redComponent * 255.0).rounded())
      let g = Int((rgb.greenComponent * 255.0).rounded())
      let b = Int((rgb.blueComponent * 255.0).rounded())
      return String(format: "#%02X%02X%02X", r, g, b)
    }
    artworkPalette = hex
    if let rep = image.representations.first {
      artworkStatus = "Artwork loaded \(rep.pixelsWide)x\(rep.pixelsHigh)"
    } else {
      artworkStatus = "Artwork loaded"
    }
  }

  private func readArtworkImage(from path: String) -> NSImage? {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: path) else {
      artworkStatus = "Artwork file missing"
      return nil
    }
    let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
    if size == 0 {
      artworkStatus = "Artwork file empty"
      return nil
    }
    if let image = NSImage(contentsOfFile: path) {
      return image
    }
    let fileURL = URL(fileURLWithPath: path)
    if let data = try? Data(contentsOf: fileURL),
       let image = NSImage(data: data) {
      return image
    }
    artworkStatus = "Artwork decode failed (\(size) bytes)"
    return nil
  }

  private func fetchArtworkPath() -> String? {
    let fileStub = "butterchurn-cover-\(UUID().uuidString)"
    lastAppleScriptError = nil
    let script = """
    tell application "Music"
      if it is running then
        try
          if (count of artworks of current track) is 0 then return ""
          set art to artwork 1 of current track
          set artData to raw data of art
          if artData is missing value then return ""
          set ext to ".jpg"
          if (format of art) is «class PNG » then set ext to ".png"
          set p to (POSIX path of (path to temporary items)) & "\(fileStub)" & ext
          set f to open for access (POSIX file p) with write permission
          set eof f to 0
          write artData to f
          close access f
          return p
        end try
      end if
    end tell
    return ""
    """
    guard let result = runAppleScript(script) else {
      artworkStatus = lastAppleScriptError ?? "AppleScript failed"
      return nil
    }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      artworkStatus = "No artwork returned"
    }
    if !trimmed.isEmpty, !FileManager.default.fileExists(atPath: trimmed) {
      artworkStatus = "Artwork file missing"
      return nil
    }
    return trimmed.isEmpty ? nil : trimmed
  }

  private func runAppleScript(_ source: String) -> String? {
    guard let script = NSAppleScript(source: source) else {
      return nil
    }
    var errorInfo: NSDictionary?
    let output = script.executeAndReturnError(&errorInfo)
    if let errorInfo {
      let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "AppleScript error"
      lastAppleScriptError = message
      print("AppleScript error: \(message)")
      return nil
    }
    lastAppleScriptError = nil
    return output.stringValue
  }
}
