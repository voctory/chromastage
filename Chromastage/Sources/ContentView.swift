import AppKit
import SwiftUI

struct ManualPresetRequest: Equatable {
  let id: UUID
  let name: String
}

struct ContentView: View {
  @StateObject private var audioCapture = AudioCapture()
  @StateObject private var musicController = MusicController()
  @StateObject private var presetStore = PresetStore()
  @StateObject private var webLogStore = WebLogStore()
  @State private var tagDraft = ""
  @State private var lastInteraction = Date()
  @State private var isIdle = false
  @State private var idlePulse = false
  @State private var idleTimer: Timer?
  @State private var permissionTimer: Timer?
  @State private var cursorHidden = false
  @State private var manualPresetRequest: ManualPresetRequest?
  @State private var showPlaylistPopover = false
  @State private var newPlaylistName = ""
  @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
  @AppStorage(PreferenceKeys.useSpotify) private var useSpotify = false
  @AppStorage(PreferenceKeys.hasSetSpotifyPreference) private var hasSetSpotifyPreference = false
  @AppStorage(PreferenceKeys.lyricsSyncOffset) private var lyricsSyncOffset: Double = 0
  @State private var onboardingStep: OnboardingStep = .welcome

  private let idleTimeout: TimeInterval = 5

  var body: some View {
    ZStack(alignment: .bottomLeading) {
      WebVisualizerView(
        audioCapture: audioCapture,
        logStore: webLogStore,
        selectedPresetName: presetStore.selectedPreset?.name,
        autoSwitchEnabled: presetStore.isAutoSwitching,
        autoSwitchRandomized: presetStore.autoRandomize,
        manualPresetRequest: manualPresetRequest,
        blockedPresetNames: presetStore.blockedNames,
        playlistPresetNames: presetStore.activePlaylistName == nil
          ? nil
          : presetStore.activePlaylistPresetNames,
        palette: musicController.artworkPalette,
        activePresetName: $presetStore.activePresetName
      )
      .ignoresSafeArea()

      // Bottom-left corner widget
      controlsWidget
        .padding(.leading, 16)
        .padding(.bottom, 16)

      lyricsOverlay
    }
    .background(WindowConfigurator())
    .background(
      InteractionMonitor(
        onInteraction: registerInteraction,
        onKeyDown: { key in
          if key == "z" {
            triggerNextPreset()
            return true
          }
          if key == " " {
            musicController.playPause()
            return true
          }
          return false
        }
      )
      .allowsHitTesting(false)
    )
    .frame(minWidth: 900, minHeight: 600)
    .overlay(onboardingOverlay)
    .onAppear {
      if UserDefaults.standard.object(forKey: PreferenceKeys.useSpotify) == nil {
        if hasSeenOnboarding {
          let defaultSpotify = SpotifyIntegration.isInstalled
          UserDefaults.standard.set(defaultSpotify, forKey: PreferenceKeys.useSpotify)
          useSpotify = defaultSpotify
          hasSetSpotifyPreference = true
        }
      } else {
        hasSetSpotifyPreference = true
      }
      musicController.startPolling()
      Task { await audioCapture.start() }
      startIdleTimer()
      startPermissionTimer()
      registerInteraction()
    }
    .onDisappear {
      musicController.stopPolling()
      audioCapture.stop()
      stopIdleTimer()
      stopPermissionTimer()
    }
    .onChange(of: isIdle) { value in
      idlePulse = value
    }
    .onChange(of: audioCapture.needsAttention) { needsAttention in
      if needsAttention && (hasSeenOnboarding || hasSetSpotifyPreference) {
        onboardingStep = .audio
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      let status = audioCapture.refreshPermissionStatus(requestIfNeeded: false)
      if status == .granted, !audioCapture.isCapturing {
        Task { await audioCapture.start() }
      }
    }
  }

  private var lyricsOverlay: some View {
    Group {
      switch musicController.lyricsKind {
      case .synced:
        SyncedLyricsOverlayView(musicController: musicController, syncOffset: lyricsSyncOffset)
          .padding(.trailing, 42)
          .padding(.bottom, 32)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          .allowsHitTesting(false)
      case .plain:
        EmptyView()
      default:
        EmptyView()
      }
    }
  }

  private var onboardingOverlay: some View {
    Group {
      if shouldShowOnboarding {
        OnboardingView(
          audioCapture: audioCapture,
          step: $onboardingStep,
          hasSeenOnboarding: $hasSeenOnboarding,
          useSpotify: $useSpotify,
          hasSetSpotifyPreference: $hasSetSpotifyPreference
        ) {
          registerInteraction()
        }
        .transition(.opacity)
      }
    }
  }

  private var shouldShowOnboarding: Bool {
    !hasSeenOnboarding || audioCapture.needsAttention
  }

  @State private var isExpanded = false

  @ViewBuilder
  private var controlsWidget: some View {
    if isIdle {
      idleWidget
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    } else {
      fullWidget
        .transition(.opacity)
    }
  }

  // Compact idle state - just album art and basic info
  private var idleWidget: some View {
    HStack(spacing: 12) {
      AlbumArtView(
        image: musicController.artworkImage,
        palette: musicController.artworkPalette,
        size: 48
      )

      VStack(alignment: .leading, spacing: 2) {
        Text(musicController.trackTitle.isEmpty ? "Not Playing" : musicController.trackTitle)
          .font(.system(size: 14, weight: .semibold, design: .rounded))
          .lineLimit(1)
        Text(musicController.artistAlbumLine)
          .font(.system(size: 11, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.6))
          .lineLimit(1)
      }
      .frame(maxWidth: 180, alignment: .leading)
    }
    .padding(12)
    .background(
      VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
    )
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.white.opacity(0.1), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.3), radius: 12, y: 6)
    .scaleEffect(idlePulse ? 1.01 : 1.0)
    .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: idlePulse)
  }

  // Full widget with all controls
  private var fullWidget: some View {
    VStack(alignment: .leading, spacing: 0) {
      // Main content: Album art + track info + transport
      HStack(spacing: 12) {
        AlbumArtView(
          image: musicController.artworkImage,
          palette: musicController.artworkPalette,
          size: 56
        )

        VStack(alignment: .leading, spacing: 3) {
          Text(musicController.trackTitle.isEmpty ? "Not Playing" : musicController.trackTitle)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .lineLimit(1)

          Text(musicController.artistAlbumLine)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(Color.white.opacity(0.6))
            .lineLimit(1)

          // Inline transport controls
          HStack(spacing: 16) {
            Button { musicController.previousTrack() } label: {
              Image(systemName: "backward.fill")
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.7))

            Button { musicController.playPause() } label: {
              Image(systemName: musicController.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.9))

            Button { musicController.nextTrack() } label: {
              Image(systemName: "forward.fill")
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.7))
          }
          .padding(.top, 4)
        }
        .frame(maxWidth: 160, alignment: .leading)
      }
      .padding(12)

      // Expandable controls section
      if isExpanded {
        VStack(alignment: .leading, spacing: 10) {
          Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)

          playlistControls

          // Preset picker
          HStack(spacing: 6) {
            Picker("", selection: $presetStore.selection) {
              Text("Auto (15s)").tag(-1)
              ForEach(presetStore.presets.indices, id: \.self) { index in
                Text(presetStore.presets[index].name).tag(index)
              }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 180)
            .disabled(presetStore.presets.isEmpty)

            Button { triggerNextPreset() } label: {
              Image(systemName: "forward.end.fill")
                .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.white.opacity(0.7))
            .help("Next Preset (Z)")
          }

          // Shuffle + Favorite row
          HStack(spacing: 10) {
            Toggle("Shuffle", isOn: $presetStore.autoRandomize)
              .toggleStyle(.switch)
              .controlSize(.mini)
              .disabled(!presetStore.isAutoSwitching)

            if let activeName = presetStore.activePresetName, !activeName.isEmpty {
              Button {
                presetStore.toggleFavorite(activeName)
              } label: {
                Image(systemName: presetStore.isFavorite(activeName) ? "heart.fill" : "heart")
                  .font(.system(size: 11))
                  .foregroundStyle(presetStore.isFavorite(activeName) ? Color.pink : Color.white.opacity(0.5))
              }
              .buttonStyle(.plain)
              .help(presetStore.isFavorite(activeName) ? "Unfavorite" : "Favorite")

              Button {
                presetStore.toggleBlocked(activeName)
              } label: {
                Image(systemName: presetStore.isBlocked(activeName) ? "eye.slash.fill" : "eye.slash")
                  .font(.system(size: 11))
                  .foregroundStyle(presetStore.isBlocked(activeName) ? Color.orange : Color.white.opacity(0.5))
              }
              .buttonStyle(.plain)
              .help(presetStore.isBlocked(activeName) ? "Unblock" : "Block")
            }
          }
          .font(.system(size: 10, weight: .medium, design: .rounded))

          // Capture button
          Button(audioCapture.isCapturing ? "Stop Capture" : "Start Capture") {
            if audioCapture.isCapturing {
              audioCapture.stop()
            } else {
              Task { await audioCapture.start(requestPermission: true) }
            }
          }
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .buttonStyle(.borderedProminent)
          .controlSize(.mini)
          .tint(audioCapture.isCapturing ? Color.red.opacity(0.6) : Color.white.opacity(0.12))

        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
      }

      // Expand/collapse button
      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          isExpanded.toggle()
        }
      } label: {
        HStack {
          Spacer()
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.4))
          Spacer()
        }
        .frame(height: 20)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .frame(width: 260)
    .background(
      VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
    )
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .stroke(Color.white.opacity(0.1), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.35), radius: 16, y: 8)
    .onChange(of: currentPresetName) { newValue in
      tagDraft = presetStore.tagsString(for: newValue)
    }
    .onAppear {
      tagDraft = presetStore.tagsString(for: currentPresetName)
    }
  }

  private var playlistControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Shader Playlists")
        .font(.system(size: 10, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.6))

      HStack(spacing: 6) {
        Picker("Playlist", selection: $presetStore.activePlaylistName) {
          Text("All Shaders").tag(String?.none)
          ForEach(presetStore.playlistNames, id: \.self) { name in
            Text(name).tag(Optional(name))
          }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 180)

        Button {
          showPlaylistPopover.toggle()
        } label: {
          Image(systemName: "plus.circle")
            .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white.opacity(0.7))
        .help("Add current shader to a playlist")
        .popover(isPresented: $showPlaylistPopover, arrowEdge: .bottom) {
          playlistPopover
        }
      }

      if presetStore.activePlaylistName != nil,
         presetStore.activePlaylistPresetNames.isEmpty {
        Text("Playlist is empty.")
          .font(.system(size: 9, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.45))
      }
    }
  }

  private var playlistPopover: some View {
    let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
    return VStack(alignment: .leading, spacing: 10) {
      Text("Add to playlist")
        .font(.system(size: 12, weight: .semibold, design: .rounded))

      if let currentName = currentPresetName {
        Text(currentName)
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(Color.secondary)
          .lineLimit(1)
      } else {
        Text("No shader active yet.")
          .font(.system(size: 10, weight: .medium, design: .rounded))
          .foregroundStyle(Color.secondary)
      }

      ForEach(presetStore.playlistNames, id: \.self) { playlistName in
        Button {
          addCurrentPreset(to: playlistName)
        } label: {
          if let currentName = currentPresetName,
             presetStore.isPreset(currentName, inPlaylist: playlistName) {
            Label(playlistName, systemImage: "checkmark")
          } else {
            Text(playlistName)
          }
        }
        .disabled(currentPresetName == nil)
      }

      Divider()

      TextField("New playlist name", text: $newPlaylistName)
        .textFieldStyle(.roundedBorder)
        .onSubmit {
          createPlaylistFromPopover()
        }

      HStack {
        Spacer()
        Button("Create") {
          createPlaylistFromPopover()
        }
        .disabled(trimmed.isEmpty)
      }
    }
    .padding(12)
    .frame(width: 240)
    .onDisappear {
      newPlaylistName = ""
    }
  }

  private func addCurrentPreset(to playlistName: String) {
    guard let currentName = currentPresetName else { return }
    presetStore.addPreset(currentName, toPlaylist: playlistName)
    showPlaylistPopover = false
  }

  private func createPlaylistFromPopover() {
    let trimmed = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let createdName = presetStore.addPlaylist(named: trimmed) else { return }
    if let currentName = currentPresetName {
      presetStore.addPreset(currentName, toPlaylist: createdName)
    }
    newPlaylistName = ""
    showPlaylistPopover = false
  }

  private func registerInteraction() {
    lastInteraction = Date()
    setIdle(false)
  }

  private func triggerNextPreset() {
    let presets = presetStore.presets
    guard !presets.isEmpty else { return }
    let blocked = presetStore.blocked
    let shouldRandomize = presetStore.isAutoSwitching && presetStore.autoRandomize
    let currentName = currentPresetName
    let playlistActive = presetStore.isAutoSwitching && presetStore.activePlaylistName != nil
    let playlistNames = playlistActive ? presetStore.activePlaylistPresetNames : []
    let playlistSet = Set(playlistNames)
    let basePresets = presets.filter { !blocked.contains($0.name) }
    let filteredPresets: [PresetDefinition]
    if playlistActive {
      filteredPresets = basePresets.filter { playlistSet.contains($0.name) }
      if filteredPresets.isEmpty {
        return
      }
    } else {
      filteredPresets = basePresets.isEmpty ? presets : basePresets
    }

    let nextPreset: PresetDefinition?
    if shouldRandomize {
      let candidates = filteredPresets.filter { $0.name != currentName }
      nextPreset = (candidates.isEmpty ? filteredPresets : candidates).randomElement()
    } else if let currentName,
              let index = filteredPresets.firstIndex(where: { $0.name == currentName }) {
      var chosen: PresetDefinition?
      for offset in 1...filteredPresets.count {
        let candidate = filteredPresets[(index + offset) % filteredPresets.count]
        if !blocked.contains(candidate.name) {
          chosen = candidate
          break
        }
      }
      nextPreset = chosen ?? filteredPresets[index]
    } else {
      nextPreset = filteredPresets.first
    }
    guard let chosen = nextPreset else { return }
    if presetStore.isAutoSwitching {
      manualPresetRequest = ManualPresetRequest(id: UUID(), name: chosen.name)
    } else if let index = presets.firstIndex(where: { $0.name == chosen.name }) {
      presetStore.selection = index
    }
  }

  private func startIdleTimer() {
    idleTimer?.invalidate()
    idleTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
      Task { @MainActor in
        let idle = hasSeenOnboarding
          && !audioCapture.needsAttention
          && Date().timeIntervalSince(lastInteraction) > idleTimeout
        setIdle(idle)
      }
    }
  }

  private func stopIdleTimer() {
    idleTimer?.invalidate()
    idleTimer = nil
    if cursorHidden {
      NSCursor.unhide()
      cursorHidden = false
    }
  }

  private func startPermissionTimer() {
    permissionTimer?.invalidate()
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
      Task { @MainActor in
        if audioCapture.isCapturing {
          return
        }
        let status = audioCapture.refreshPermissionStatus(requestIfNeeded: false)
        if status == .granted, audioCapture.needsAttention || !hasSeenOnboarding {
          await audioCapture.start()
        }
      }
    }
  }

  private func stopPermissionTimer() {
    permissionTimer?.invalidate()
    permissionTimer = nil
  }

  private func setIdle(_ idle: Bool) {
    if idle == isIdle {
      return
    }
    withAnimation(.easeInOut(duration: 0.35)) {
      isIdle = idle
    }
    if idle {
      if !cursorHidden {
        NSCursor.hide()
        cursorHidden = true
      }
    } else {
      if cursorHidden {
        NSCursor.unhide()
        cursorHidden = false
      }
    }
  }

  private var currentPresetName: String? {
    if presetStore.isAutoSwitching {
      return presetStore.activePresetName
    }
    return presetStore.selectedPreset?.name
  }

}

private struct PlaybackTransportView: View {
  @ObservedObject var musicController: MusicController
  @ObservedObject var audioCapture: AudioCapture
  @State private var isScrubbing = false
  @State private var scrubPosition: Double = 0

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.2)) { context in
      let duration = max(musicController.trackDuration, 1)
      let currentPosition = min(duration, max(0, musicController.playbackPosition(at: context.date)))
      let sliderValue = isScrubbing ? scrubPosition : currentPosition

      VStack(spacing: 6) {
        // Standard slider
        Slider(
          value: Binding(
            get: { sliderValue },
            set: { scrubPosition = $0 }
          ),
          in: 0...duration,
          onEditingChanged: { editing in
            if editing {
              isScrubbing = true
              scrubPosition = currentPosition
            } else {
              isScrubbing = false
              musicController.seek(to: scrubPosition)
            }
          }
        )
        .tint(Color.white.opacity(0.7))
        .disabled(musicController.trackDuration <= 0)
        .frame(width: 280)

        // Time labels
        HStack {
          Text(formatTime(sliderValue))
          Spacer()
          Text(formatTime(musicController.trackDuration))
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.5))
        .frame(width: 280)

        // Simple inline transport controls
        HStack(spacing: 24) {
          Button {
            musicController.previousTrack()
          } label: {
            Image(systemName: "backward.fill")
              .font(.system(size: 16, weight: .semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color.white.opacity(0.8))

          Button {
            musicController.playPause()
          } label: {
            Image(systemName: musicController.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 20, weight: .semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color.white.opacity(0.9))

          Button {
            musicController.nextTrack()
          } label: {
            Image(systemName: "forward.fill")
              .font(.system(size: 16, weight: .semibold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(Color.white.opacity(0.8))
        }
        .padding(.top, 4)

        // Simple capture button
        Button(audioCapture.isCapturing ? "Stop Capture" : "Start Capture") {
          if audioCapture.isCapturing {
            audioCapture.stop()
          } else {
            Task { await audioCapture.start(requestPermission: true) }
          }
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .tint(audioCapture.isCapturing ? Color.red.opacity(0.7) : Color.white.opacity(0.15))
        .padding(.top, 4)
      }
    }
  }

  private func formatTime(_ time: TimeInterval) -> String {
    guard time.isFinite else { return "00:00" }
    let clamped = max(0, Int(time.rounded()))
    let minutes = clamped / 60
    let seconds = clamped % 60
    return String(format: "%02d:%02d", minutes, seconds)
  }
}

private struct SyncedLyricsOverlayView: View {
  @ObservedObject var musicController: MusicController
  let syncOffset: TimeInterval

  var body: some View {
    TimelineView(.periodic(from: .now, by: 0.2)) { context in
      let position = musicController.playbackPosition(at: context.date) + syncOffset
      let lines = musicController.lyricsDisplayLines(maxLines: 3, position: position)
      if !lines.isEmpty {
        LyricsOverlayView(
          lines: lines,
          introAnimationID: musicController.lyricsSequenceID,
          animateIntro: musicController.isBeforeFirstSyncedLyric(at: position)
        )
      }
    }
  }
}

private struct AlbumArtView: View {
  let image: NSImage?
  let palette: [String]
  let size: CGFloat

  init(image: NSImage?, palette: [String], size: CGFloat = 60) {
    self.image = image
    self.palette = palette
    self.size = size
  }

  var body: some View {
    ZStack {
      if let image {
        Image(nsImage: image)
          .resizable()
          .aspectRatio(contentMode: .fill)
      } else {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(
            LinearGradient(
              colors: [.white.opacity(0.1), .black.opacity(0.2)],
              startPoint: .topLeading,
              endPoint: .bottomTrailing
            )
          )
        Image(systemName: "music.note")
          .font(.system(size: size * 0.35, weight: .semibold))
          .foregroundStyle(.white.opacity(0.5))
      }
    }
    .frame(width: size, height: size)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.white.opacity(0.15), lineWidth: 1)
    )
    .shadow(color: Color.black.opacity(0.35), radius: 8, y: 4)
  }
}

private struct PaletteRow: View {
  let colors: [String]

  var body: some View {
    HStack(spacing: 6) {
      ForEach(colors, id: \.self) { hex in
        Circle()
          .fill(Color(hex: hex))
          .frame(width: 10, height: 10)
          .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
      }
    }
  }
}

private struct LyricsOverlayView: View {
  let lines: [LyricsDisplayLine]
  let introAnimationID: UUID
  let animateIntro: Bool
  @State private var introVisible = false

  var body: some View {
    VStack(alignment: .trailing, spacing: 8) {
      ForEach(lines) { line in
        Text(line.text)
          .font(.system(size: line.isActive ? 24 : 18, weight: line.isActive ? .semibold : .medium, design: .rounded))
          .foregroundStyle(line.isActive ? Color.white : Color.white.opacity(0.45))
          .multilineTextAlignment(.trailing)
          .frame(maxWidth: 420, alignment: .trailing)
          .fixedSize(horizontal: false, vertical: true)
          .shadow(color: Color.black.opacity(line.isActive ? 0.5 : 0.35), radius: 10, y: 6)
          .transition(.move(edge: .bottom).combined(with: .opacity))
          .animation(.spring(response: 0.45, dampingFraction: 0.85), value: line.isActive)
      }
    }
    .opacity(animateIntro ? (introVisible ? 1 : 0) : 1)
    .offset(y: animateIntro ? (introVisible ? 0 : 16) : 0)
    .onAppear {
      triggerIntroAnimation()
    }
    .onChange(of: introAnimationID) { _ in
      triggerIntroAnimation()
    }
    .animation(.spring(response: 0.45, dampingFraction: 0.85), value: lines)
  }

  private func triggerIntroAnimation() {
    guard animateIntro else {
      introVisible = true
      return
    }
    introVisible = false
    DispatchQueue.main.async {
      withAnimation(.easeOut(duration: 0.9)) {
        introVisible = true
      }
    }
  }
}

private struct PlainLyricsOverlayView: View {
  let lines: [String]

  var body: some View {
    VStack(alignment: .center, spacing: 6) {
      ForEach(lines.indices, id: \.self) { index in
        Text(lines[index])
          .font(.system(size: 14, weight: .medium, design: .rounded))
          .foregroundStyle(Color.white.opacity(0.6))
          .multilineTextAlignment(.center)
          .frame(maxWidth: 360, alignment: .center)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: 360, alignment: .center)
    .shadow(color: Color.black.opacity(0.3), radius: 8, y: 4)
  }
}

private struct StatusBadge: View {
  let text: String

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(Color.green)
        .frame(width: 5, height: 5)
        .shadow(color: Color.green.opacity(0.5), radius: 3)

      Text(text)
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .lineLimit(1)
    }
    .padding(.vertical, 5)
    .padding(.horizontal, 10)
    .background(
      ZStack {
        Color.white.opacity(0.05)
        Capsule()
          .stroke(Color.white.opacity(0.08), lineWidth: 1)
      }
    )
    .clipShape(Capsule())
    .foregroundStyle(Color.white.opacity(0.7))
  }
}

// MARK: - Simple Button

private struct GlassButton: View {
  let title: String
  let icon: String?
  let action: () -> Void

  @State private var isHovered = false

  init(title: String, icon: String? = nil, action: @escaping () -> Void) {
    self.title = title
    self.icon = icon
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        if let icon {
          Image(systemName: icon)
            .font(.system(size: 9, weight: .semibold))
        }
        Text(title)
          .font(.system(size: 10, weight: .medium, design: .rounded))
      }
      .padding(.vertical, 5)
      .padding(.horizontal, 8)
      .foregroundStyle(isHovered ? Color.white : Color.white.opacity(0.7))
      .background(Color.white.opacity(isHovered ? 0.1 : 0.06))
      .clipShape(Capsule())
      .overlay(
        Capsule()
          .stroke(Color.white.opacity(0.1), lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .onHover { hovering in
      withAnimation(.easeInOut(duration: 0.12)) {
        isHovered = hovering
      }
    }
  }
}

private enum OnboardingStep: Int, CaseIterable {
  case welcome
  case spotify
  case audio
  case controls
  case personalize

  var title: String {
    switch self {
    case .welcome:
      return "Welcome to Chromastage"
    case .spotify:
      return "Spotify integration"
    case .audio:
      return "Enable System Audio Capture"
    case .controls:
      return "Control the visuals"
    case .personalize:
      return "Make it yours"
    }
  }

  var detail: String {
    switch self {
    case .welcome:
      return "Enjoy Milkdrop visuals synced to your system audio. Chromastage can also show track info from Apple Music."
    case .spotify:
      return "Do you use Spotify? Chromastage can read track info from Spotify if you want. You can change this later in Settings."
    case .audio:
      return "Chromastage needs Screen & System Audio Recording permission to react to music."
    case .controls:
      return "Use Auto for timed presets, or press Z anytime to jump to the next preset. You can favorite or block presets you don't like."
    case .personalize:
      return "Tag presets by mood or genre, and export favorites anytime. Lyrics and palette colors follow the currently playing track."
    }
  }
}

private struct OnboardingView: View {
  @ObservedObject var audioCapture: AudioCapture
  @Binding var step: OnboardingStep
  @Binding var hasSeenOnboarding: Bool
  @Binding var useSpotify: Bool
  @Binding var hasSetSpotifyPreference: Bool
  let onDismiss: () -> Void

  private var steps: [OnboardingStep] { OnboardingStep.allCases }

  var body: some View {
    ZStack {
      Color.black.opacity(0.35)
        .ignoresSafeArea()
      VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
        .ignoresSafeArea()

      VStack(spacing: 18) {
        Text(step.title)
          .font(.system(size: 24, weight: .semibold, design: .rounded))

        if step == .audio {
          audioStep
        } else if step == .spotify {
          spotifyStep
        } else {
          Text(step.detail)
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 420)
        }

        HStack(spacing: 6) {
          ForEach(steps, id: \.self) { item in
            Capsule()
              .fill(item == step ? Color.white.opacity(0.9) : Color.white.opacity(0.2))
              .frame(width: item == step ? 28 : 12, height: 6)
              .animation(.easeInOut(duration: 0.25), value: step)
          }
        }
        .padding(.top, 6)

        HStack(spacing: 12) {
          if let previous = previousStep {
            Button("Back") {
              withAnimation(.easeInOut(duration: 0.2)) {
                step = previous
              }
            }
            .buttonStyle(.bordered)
          }
          Spacer()
          Button(isLastStep ? "Get Started" : "Next") {
            if isLastStep {
              hasSeenOnboarding = true
              onDismiss()
            } else if let next = nextStep {
              withAnimation(.easeInOut(duration: 0.2)) {
                step = next
              }
            }
          }
          .buttonStyle(.borderedProminent)
          .disabled((step == .audio && !audioCapture.isCapturing) || (step == .spotify && !hasSetSpotifyPreference))
        }
      }
      .padding(24)
      .frame(maxWidth: 520)
      .background(
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .fill(Color.white.opacity(0.06))
          .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
              .stroke(Color.white.opacity(0.12), lineWidth: 1)
          )
      )
      .shadow(color: Color.black.opacity(0.35), radius: 20, y: 12)
    }
    .task(id: step) {
      if step == .audio {
        await checkAndStartCapture()
      }
    }
  }

  private var isLastStep: Bool {
    step == steps.last
  }

  private var currentIndex: Int {
    steps.firstIndex(of: step) ?? 0
  }

  private var previousStep: OnboardingStep? {
    let index = currentIndex - 1
    guard index >= 0 else { return nil }
    return steps[index]
  }

  private var nextStep: OnboardingStep? {
    let index = currentIndex + 1
    guard index < steps.count else { return nil }
    return steps[index]
  }

  private var spotifyInstalled: Bool {
    SpotifyIntegration.isInstalled
  }

  private var spotifyAvailabilityNote: String? {
    guard !spotifyInstalled else { return nil }
    if useSpotify {
      return "Spotify is not installed yet. Chromastage will connect once it is available."
    }
    return "Spotify is not installed. Install it later if you want Spotify track info."
  }

  private var spotifyStep: some View {
    VStack(spacing: 12) {
      Text(step.detail)
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)

      VStack(spacing: 10) {
        spotifyChoiceButton(
          title: "Yes, I use Spotify",
          selected: hasSetSpotifyPreference && useSpotify
        ) {
          useSpotify = true
          hasSetSpotifyPreference = true
        }

        spotifyChoiceButton(
          title: "No, not right now",
          selected: hasSetSpotifyPreference && !useSpotify
        ) {
          useSpotify = false
          hasSetSpotifyPreference = true
        }
      }
      .padding(12)
      .background(Color.white.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      if let note = spotifyAvailabilityNote {
        Text(note)
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
      }
    }
  }

  @ViewBuilder
  private func spotifyChoiceButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
    if selected {
      Button(action: action) {
        HStack(spacing: 6) {
          Image(systemName: "checkmark.circle.fill")
          Text(title)
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
    } else {
      Button(action: action) {
        HStack(spacing: 6) {
          Image(systemName: "circle")
          Text(title)
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
    }
  }

  private var audioStep: some View {
    VStack(spacing: 12) {
      Text(step.detail)
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      VStack(alignment: .leading, spacing: 8) {
        Text("How to enable:")
          .font(.system(size: 13, weight: .semibold, design: .rounded))
        Text("1. Open System Settings → Privacy & Security.")
        Text("2. Select Screen & System Audio Recording.")
        Text("3. Enable Chromastage, then relaunch if prompted.")
      }
      .font(.system(size: 12, weight: .medium, design: .rounded))
      .foregroundStyle(.secondary)
      .frame(maxWidth: 420, alignment: .leading)
      .padding(12)
      .background(Color.white.opacity(0.06))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      HStack(spacing: 10) {
        Button(audioCapture.isCapturing ? "Capturing…" : "Enable Capture") {
          Task { await requestAndStartCapture() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(audioCapture.isCapturing)
      }

      if audioCapture.permissionStatus != .unknown {
        Text("Permission: \(audioCapture.permissionStatus == .granted ? "Granted" : "Not granted")")
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .foregroundStyle(audioCapture.permissionStatus == .granted ? Color.green.opacity(0.9) : Color.white.opacity(0.6))
      }

      if !audioCapture.statusMessage.isEmpty {
        Text(audioCapture.statusMessage)
          .font(.system(size: 12, weight: .medium, design: .rounded))
          .foregroundStyle(audioCapture.isCapturing ? Color.green.opacity(0.9) : Color.white.opacity(0.6))
          .multilineTextAlignment(.center)
          .frame(maxWidth: 420)
      }
    }
  }

  private func checkAndStartCapture() async {
    let status = audioCapture.refreshPermissionStatus(requestIfNeeded: false)
    guard status == .granted else { return }
    if !audioCapture.isCapturing {
      await audioCapture.start()
    }
  }

  private func requestAndStartCapture() async {
    await audioCapture.start(requestPermission: true)
  }
}

private struct VisualEffectView: NSViewRepresentable {
  let material: NSVisualEffectView.Material
  let blendingMode: NSVisualEffectView.BlendingMode

  init(material: NSVisualEffectView.Material, blendingMode: NSVisualEffectView.BlendingMode) {
    self.material = material
    self.blendingMode = blendingMode
  }

  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = material
    view.blendingMode = blendingMode
    view.state = .active
    return view
  }

  func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
    nsView.material = material
    nsView.blendingMode = blendingMode
  }
}

private struct WindowConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    DispatchQueue.main.async {
      if let window = view.window {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.acceptsMouseMovedEvents = true
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct InteractionMonitor: NSViewRepresentable {
  let onInteraction: () -> Void
  var onKeyDown: ((String) -> Bool)?
  var ignoredCharacters: Set<String> = []

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onInteraction: onInteraction,
      onKeyDown: onKeyDown,
      ignoredCharacters: ignoredCharacters
    )
  }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.startMonitoring()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  final class Coordinator {
    private let onInteraction: () -> Void
    private let onKeyDown: ((String) -> Bool)?
    private let ignoredCharacters: Set<String>
    private var monitors: [Any] = []
    private var lastMouseMoveTimestamp: TimeInterval = 0
    private let mouseMoveThrottle: TimeInterval = 0.15

    init(
      onInteraction: @escaping () -> Void,
      onKeyDown: ((String) -> Bool)?,
      ignoredCharacters: Set<String>
    ) {
      self.onInteraction = onInteraction
      self.onKeyDown = onKeyDown
      self.ignoredCharacters = ignoredCharacters
    }

    func startMonitoring() {
      if !monitors.isEmpty {
        return
      }
      let masks: [NSEvent.EventTypeMask] = [
        .mouseMoved,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
        .scrollWheel,
        .keyDown
      ]
      for mask in masks {
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
          if mask == .mouseMoved {
            guard let self else { return event }
            let now = event.timestamp
            if now - self.lastMouseMoveTimestamp < self.mouseMoveThrottle {
              return event
            }
            self.lastMouseMoveTimestamp = now
          }
          if mask == .keyDown,
             let characters = event.charactersIgnoringModifiers?.lowercased() {
            if let responder = event.window?.firstResponder,
               responder is NSTextView || responder is NSTextField {
              self?.onInteraction()
              return event
            }
            if let handled = self?.onKeyDown?(characters), handled {
              return nil
            }
            if let ignored = self?.ignoredCharacters, ignored.contains(characters) {
              return event
            }
          }
          self?.onInteraction()
          return event
        }) {
          monitors.append(monitor)
        }
      }
    }

    deinit {
      for monitor in monitors {
        NSEvent.removeMonitor(monitor)
      }
      monitors.removeAll()
    }
  }
}

private extension Color {
  init(hex: String) {
    let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
    guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else {
      self = Color.white
      return
    }
    let r = Double((value >> 16) & 0xff) / 255.0
    let g = Double((value >> 8) & 0xff) / 255.0
    let b = Double(value & 0xff) / 255.0
    self = Color(red: r, green: g, blue: b)
  }
}
