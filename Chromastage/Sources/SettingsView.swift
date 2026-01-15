import Foundation
import SwiftUI

struct SettingsView: View {
  @AppStorage(PreferenceKeys.useSpotify) private var useSpotify = false
  @AppStorage(PreferenceKeys.hasSetSpotifyPreference) private var hasSetSpotifyPreference = false
  @AppStorage(PreferenceKeys.lyricsSyncOffset) private var lyricsSyncOffset: Double = 0
  @StateObject private var presetStore = PresetStore()
  @State private var shaderDraft = ""
  @State private var shaderSearch = ""
  @State private var shaderListMode: ShaderListMode = .favorites
  @State private var showResetShaderLists = false

  private enum ShaderListMode: String, CaseIterable, Identifiable {
    case favorites = "Favorites"
    case blocked = "Blocked"

    var id: String { rawValue }

    var addPlaceholder: String {
      switch self {
      case .favorites:
        return "Add favorite shader name"
      case .blocked:
        return "Add blocked shader name"
      }
    }

    var emptyLabel: String {
      switch self {
      case .favorites:
        return "No favorite shaders yet."
      case .blocked:
        return "No blocked shaders."
      }
    }
  }

  private var spotifyInstalled: Bool {
    SpotifyIntegration.isInstalled
  }

  private var spotifyAvailabilityNote: String? {
    guard !spotifyInstalled else { return nil }
    if useSpotify {
      return "Spotify isn't installed yet. Chromastage will connect once it is available."
    }
    return "Spotify isn't installed. You can enable it anytime after installing Spotify."
  }

  private var lyricsOffsetLabel: String {
    String(format: "%+.1fs", lyricsSyncOffset)
  }

  private var currentShaderNames: [String] {
    switch shaderListMode {
    case .favorites:
      return presetStore.favorites.sorted()
    case .blocked:
      return presetStore.blocked.sorted()
    }
  }

  private var filteredShaderNames: [String] {
    let query = shaderSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return currentShaderNames }
    return currentShaderNames.filter { $0.localizedCaseInsensitiveContains(query) }
  }

  private var shaderListsEmpty: Bool {
    presetStore.favorites.isEmpty && presetStore.blocked.isEmpty
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      GroupBox("Music Sources") {
        VStack(alignment: .leading, spacing: 10) {
          Toggle("Apple Music (enabled by default)", isOn: .constant(true))
            .disabled(true)

          Toggle("Enable Spotify integration", isOn: $useSpotify)
            .onChange(of: useSpotify) { _ in
              hasSetSpotifyPreference = true
            }

          if let note = spotifyAvailabilityNote {
            Text(note)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
      }

      Divider()

      GroupBox("Lyrics") {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Sync offset")
            Spacer()
            Text(lyricsOffsetLabel)
              .foregroundStyle(.secondary)
          }

          Slider(value: $lyricsSyncOffset, in: -5...5, step: 0.1)

          HStack {
            Spacer()
            Button("Reset") {
              lyricsSyncOffset = 0
            }
            .disabled(lyricsSyncOffset == 0)
          }

          Text("Negative values show lyrics earlier. Range: ±5 seconds.")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(10)
      }

      Divider()

      GroupBox("Shaders") {
        VStack(alignment: .leading, spacing: 12) {
          Picker("List", selection: $shaderListMode) {
            ForEach(ShaderListMode.allCases) { mode in
              Text(mode.rawValue).tag(mode)
            }
          }
          .pickerStyle(.segmented)

          TextField("Search shaders", text: $shaderSearch)
            .textFieldStyle(.roundedBorder)

          HStack {
            TextField(shaderListMode.addPlaceholder, text: $shaderDraft)
              .textFieldStyle(.roundedBorder)
              .onSubmit { addShader() }
            Button("Add") { addShader() }
              .disabled(shaderDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }

          HStack {
            Text("\(filteredShaderNames.count) of \(currentShaderNames.count) shown")
              .font(.footnote)
              .foregroundStyle(.secondary)
            Spacer()
          }

          HStack(spacing: 12) {
            Button("Import Lists") { presetStore.importShaderLists() }
            Button("Export Lists") { presetStore.exportShaderLists() }
            Spacer()
            Button("Reset Lists") { showResetShaderLists = true }
              .disabled(shaderListsEmpty)
              .tint(.red)
          }
          .buttonStyle(.bordered)

          if filteredShaderNames.isEmpty {
            Text(shaderListMode.emptyLabel)
              .font(.footnote)
              .foregroundStyle(.secondary)
          } else {
            List {
              ForEach(filteredShaderNames, id: \.self) { name in
                HStack {
                  Text(name)
                    .lineLimit(1)
                  Spacer()
                  Button {
                    removeShader(name)
                  } label: {
                    Image(systemName: "trash")
                  }
                  .buttonStyle(.borderless)
                }
              }
            }
            .listStyle(.inset)
            .frame(minHeight: 240, maxHeight: 340)
          }
        }
        .padding(10)
      }
    }
    .padding(20)
    .frame(width: 540)
    .alert("Reset shader lists?", isPresented: $showResetShaderLists) {
      Button("Reset", role: .destructive) {
        presetStore.resetShaderLists()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will clear both Favorites and Blocked lists.")
    }
  }

  private func addShader() {
    let trimmed = shaderDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    switch shaderListMode {
    case .favorites:
      presetStore.addFavorite(trimmed)
    case .blocked:
      presetStore.addBlocked(trimmed)
    }
    shaderDraft = ""
  }

  private func removeShader(_ name: String) {
    switch shaderListMode {
    case .favorites:
      presetStore.removeFavorite(name)
    case .blocked:
      presetStore.removeBlocked(name)
    }
  }
}
