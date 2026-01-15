import AppKit
import Foundation
import UniformTypeIdentifiers

final class PresetStore: ObservableObject {
  @Published var presets: [PresetDefinition] = []
  @Published var selection: Int = -1
  @Published var autoRandomize: Bool = true
  @Published var activePresetName: String?
  @Published private(set) var favorites: Set<String> = []
  @Published private(set) var blocked: Set<String> = []
  @Published private(set) var tags: [String: [String]] = [:]
  @Published private(set) var playlists: [ShaderPlaylist] = []
  @Published var activePlaylistName: String? {
    didSet {
      if activePlaylistName == oldValue {
        return
      }
      guard let activePlaylistName else {
        UserDefaults.standard.removeObject(forKey: activePlaylistKey)
        return
      }
      if isFavoritesPlaylistName(activePlaylistName) {
        if activePlaylistName != favoritesPlaylistName {
          self.activePlaylistName = favoritesPlaylistName
          return
        }
        UserDefaults.standard.set(favoritesPlaylistName, forKey: activePlaylistKey)
        return
      }
      if playlistIndex(named: activePlaylistName) == nil {
        self.activePlaylistName = nil
        return
      }
      UserDefaults.standard.set(activePlaylistName, forKey: activePlaylistKey)
    }
  }

  private let library = PresetLibrary()
  private let favoritesKey = "presetFavorites"
  private let blockedKey = "presetBlocked"
  private let tagsKey = "presetTags"
  private let favoritesPlaylistName = "Favorites"
  private let playlistsKey = "shaderPlaylists"
  private let activePlaylistKey = "activeShaderPlaylist"

  init() {
    presets = library.presets
    if let curated = library.loadCuratedNames() {
      let presetMap = Dictionary(uniqueKeysWithValues: presets.map { ($0.name, $0) })
      let curatedPresets = curated.compactMap { presetMap[$0] }
      if !curatedPresets.isEmpty {
        presets = curatedPresets
      }
    }
    loadFavorites()
    loadBlocked()
    loadTags()
    loadPlaylists()
    loadActivePlaylist()
  }

  var selectedPreset: PresetDefinition? {
    guard selection >= 0, selection < presets.count else { return nil }
    return presets[selection]
  }

  var isAutoSwitching: Bool {
    selection < 0
  }

  func isFavorite(_ name: String?) -> Bool {
    guard let name else { return false }
    return favorites.contains(name)
  }

  func toggleFavorite(_ name: String) {
    if favorites.contains(name) {
      favorites.remove(name)
    } else {
      favorites.insert(name)
    }
    persistFavorites()
  }

  func addFavorite(_ name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !favorites.contains(trimmed) else { return }
    favorites.insert(trimmed)
    persistFavorites()
  }

  func removeFavorite(_ name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard favorites.remove(trimmed) != nil else { return }
    persistFavorites()
  }

  var blockedNames: [String] {
    blocked.sorted()
  }

  func isBlocked(_ name: String?) -> Bool {
    guard let name else { return false }
    return blocked.contains(name)
  }

  func toggleBlocked(_ name: String) {
    if blocked.contains(name) {
      blocked.remove(name)
    } else {
      blocked.insert(name)
    }
    persistBlocked()
  }

  func addBlocked(_ name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !blocked.contains(trimmed) else { return }
    blocked.insert(trimmed)
    persistBlocked()
  }

  func removeBlocked(_ name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard blocked.remove(trimmed) != nil else { return }
    persistBlocked()
  }

  func tagsString(for name: String?) -> String {
    guard let name, let tagsForName = tags[name], !tagsForName.isEmpty else {
      return ""
    }
    return tagsForName.joined(separator: ", ")
  }

  var playlistsSorted: [ShaderPlaylist] {
    playlists
      .filter { !isFavoritesPlaylistName($0.name) }
      .sorted { lhs, rhs in
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
      }
  }

  var playlistNames: [String] {
    let names = playlistsSorted.map(\.name)
    return [favoritesPlaylistName] + names
  }

  var activePlaylistPresetNames: [String] {
    guard let activePlaylistName else { return [] }
    let available = Set(presets.map(\.name))
    if isFavoritesPlaylistName(activePlaylistName) {
      return favorites.sorted().filter { available.contains($0) }
    }
    guard let playlist = playlist(named: activePlaylistName) else { return [] }
    return playlist.presets.filter { available.contains($0) }
  }

  func isPreset(_ name: String, inPlaylist playlistName: String) -> Bool {
    guard let trimmed = normalizeShaderName(name) else { return false }
    if isFavoritesPlaylistName(playlistName) {
      return favorites.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
    }
    guard let playlist = playlist(named: playlistName) else {
      return false
    }
    return playlist.presets.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
  }

  @discardableResult
  func addPlaylist(named name: String) -> String? {
    let trimmed = normalizePlaylistName(name)
    guard !trimmed.isEmpty else { return nil }
    if isFavoritesPlaylistName(trimmed) {
      return favoritesPlaylistName
    }
    if let existing = playlist(named: trimmed)?.name {
      return existing
    }
    playlists.append(ShaderPlaylist(name: trimmed, presets: []))
    persistPlaylists()
    return trimmed
  }

  func addPreset(_ name: String, toPlaylist playlistName: String) {
    guard let presetName = normalizeShaderName(name),
          let resolvedName = addPlaylist(named: playlistName) else {
      return
    }
    if isFavoritesPlaylistName(resolvedName) {
      addFavorite(presetName)
      return
    }
    guard let index = playlistIndex(named: resolvedName) else {
      return
    }
    let existing = playlists[index].presets
    if existing.contains(where: { $0.caseInsensitiveCompare(presetName) == .orderedSame }) {
      return
    }
    playlists[index].presets.append(presetName)
    persistPlaylists()
  }

  @discardableResult
  func updateTags(from raw: String, for name: String) -> String {
    let normalized = normalizeTags(raw)
    if normalized.isEmpty {
      tags.removeValue(forKey: name)
    } else {
      tags[name] = normalized
    }
    persistTags()
    return tagsString(for: name)
  }

  func exportFavorites() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "butterchurn-favorites.json"
    panel.canCreateDirectories = true
    panel.begin { [weak self] result in
      guard result == .OK, let url = panel.url, let self else { return }
      let payload = ExportPayload(
        version: 1,
        favorites: self.favorites.sorted(),
        tags: self.tags
      )
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
      } catch {
        NSLog("Failed to export favorites: %@", error.localizedDescription)
      }
    }
  }


  func exportShaderLists() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "butterchurn-shader-lists.json"
    panel.canCreateDirectories = true
    panel.begin { [weak self] result in
      guard result == .OK, let url = panel.url, let self else { return }
      let payload = ShaderListPayload(
        version: 1,
        favorites: self.favorites.sorted(),
        blocked: self.blocked.sorted()
      )
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: url, options: .atomic)
      } catch {
        NSLog("Failed to export shader lists: %@", error.localizedDescription)
      }
    }
  }

  func importShaderLists() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.begin { [weak self] result in
      guard result == .OK, let url = panel.url, let self else { return }
      do {
        let data = try Data(contentsOf: url)
        if let payload = try? JSONDecoder().decode(ShaderListPayload.self, from: data) {
          self.favorites = self.normalizeShaderNames(payload.favorites)
          self.blocked = self.normalizeShaderNames(payload.blocked)
          self.persistFavorites()
          self.persistBlocked()
          return
        }
        if let legacy = try? JSONDecoder().decode(LegacyFavoritesPayload.self, from: data) {
          self.favorites = self.normalizeShaderNames(legacy.favorites)
          self.persistFavorites()
          return
        }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any] {
          let favorites = dict["favorites"] as? [String] ?? []
          let blocked = dict["blocked"] as? [String] ?? []
          if !favorites.isEmpty || !blocked.isEmpty {
            self.favorites = self.normalizeShaderNames(favorites)
            self.blocked = self.normalizeShaderNames(blocked)
            self.persistFavorites()
            self.persistBlocked()
            return
          }
        }
        NSLog("Failed to import shader lists: unsupported file format")
      } catch {
        NSLog("Failed to import shader lists: %@", error.localizedDescription)
      }
    }
  }

  func resetShaderLists() {
    favorites.removeAll()
    blocked.removeAll()
    persistFavorites()
    persistBlocked()
  }

  private func loadFavorites() {
    if let stored = UserDefaults.standard.array(forKey: favoritesKey) as? [String] {
      favorites = Set(stored)
    }
  }

  private func persistFavorites() {
    let sorted = favorites.sorted()
    UserDefaults.standard.set(sorted, forKey: favoritesKey)
  }

  private func loadBlocked() {
    if let stored = UserDefaults.standard.array(forKey: blockedKey) as? [String] {
      blocked = Set(stored)
    }
  }

  private func persistBlocked() {
    let sorted = blocked.sorted()
    UserDefaults.standard.set(sorted, forKey: blockedKey)
  }

  private func loadTags() {
    if let stored = UserDefaults.standard.dictionary(forKey: tagsKey) as? [String: [String]] {
      tags = stored
    }
  }

  private func persistTags() {
    UserDefaults.standard.set(tags, forKey: tagsKey)
  }

  private func loadPlaylists() {
    guard let data = UserDefaults.standard.data(forKey: playlistsKey) else {
      playlists = []
      return
    }
    if let decoded = try? JSONDecoder().decode([ShaderPlaylist].self, from: data) {
      let cleaned = decoded.map { playlist in
        ShaderPlaylist(
          name: playlist.name.trimmingCharacters(in: .whitespacesAndNewlines),
          presets: normalizeShaderListPreservingOrder(playlist.presets)
        )
      }
      playlists = cleaned.filter { !isFavoritesPlaylistName($0.name) }
      return
    }
    playlists = []
  }

  private func persistPlaylists() {
    let cleaned = playlists.map { playlist in
      ShaderPlaylist(
        name: playlist.name.trimmingCharacters(in: .whitespacesAndNewlines),
        presets: normalizeShaderListPreservingOrder(playlist.presets)
      )
    }
    if let data = try? JSONEncoder().encode(cleaned) {
      UserDefaults.standard.set(data, forKey: playlistsKey)
    }
  }

  private func loadActivePlaylist() {
    guard let stored = UserDefaults.standard.string(forKey: activePlaylistKey) else {
      activePlaylistName = nil
      return
    }
    if isFavoritesPlaylistName(stored) {
      activePlaylistName = favoritesPlaylistName
      return
    }
    if let index = playlistIndex(named: stored) {
      activePlaylistName = playlists[index].name
    } else {
      activePlaylistName = nil
    }
  }

  private func playlistIndex(named name: String) -> Int? {
    playlists.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
  }

  private func playlist(named name: String) -> ShaderPlaylist? {
    guard let index = playlistIndex(named: name) else { return nil }
    return playlists[index]
  }

  private func isFavoritesPlaylistName(_ name: String) -> Bool {
    name.caseInsensitiveCompare(favoritesPlaylistName) == .orderedSame
  }

  private func normalizeShaderNames(_ names: [String]) -> Set<String> {
    let cleaned = names
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return Set(cleaned)
  }

  private func normalizeShaderName(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func normalizeShaderListPreservingOrder(_ names: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for entry in names {
      let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      let key = trimmed.lowercased()
      if seen.insert(key).inserted {
        result.append(trimmed)
      }
    }
    return result
  }

  private func normalizePlaylistName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func normalizeTags(_ raw: String) -> [String] {
    let parts = raw
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    var seen = Set<String>()
    var result: [String] = []
    for tag in parts {
      let key = tag.lowercased()
      if seen.insert(key).inserted {
        result.append(tag)
      }
    }
    return result
  }

  private struct ExportPayload: Codable {
    let version: Int
    let favorites: [String]
    let tags: [String: [String]]
  }

  private struct ShaderListPayload: Codable {
    let version: Int
    let favorites: [String]
    let blocked: [String]
  }

  private struct LegacyFavoritesPayload: Codable {
    let favorites: [String]
  }

  struct ShaderPlaylist: Codable, Hashable, Identifiable {
    let name: String
    var presets: [String]

    var id: String { name }
  }
}
