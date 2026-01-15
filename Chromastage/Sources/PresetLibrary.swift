import Foundation
import os

struct PresetLibraryPayload: Codable {
  let version: Int
  let count: Int
  let presets: [PresetDefinition]
}

struct PresetDefinition: Codable {
  let name: String
  let baseVals: [String: Double]
  let init_eqs_str: String?
  let frame_eqs_str: String?
  let pixel_eqs_str: String?
  let init_eqs_eel: String?
  let frame_eqs_eel: String?
  let pixel_eqs_eel: String?
  let warp: String?
  let comp: String?
  let shapes: [PresetShape]?
  let waves: [PresetWave]?
  let version: Int?
}

struct PresetShape: Codable {
  let baseVals: [String: Double]?
  let init_eqs_str: String?
  let frame_eqs_str: String?
  let init_eqs_eel: String?
  let frame_eqs_eel: String?
}

struct PresetWave: Codable {
  let baseVals: [String: Double]?
  let init_eqs_str: String?
  let frame_eqs_str: String?
  let point_eqs_str: String?
  let init_eqs_eel: String?
  let frame_eqs_eel: String?
  let point_eqs_eel: String?
}

final class PresetLibrary {
  private(set) var presets: [PresetDefinition] = []
  private var index: Int = 0
  private let logger = Logger(subsystem: "com.chromastage.app", category: "Presets")

  init() {
    load()
  }

  var count: Int {
    presets.count
  }

  func current() -> PresetDefinition? {
    guard !presets.isEmpty else { return nil }
    return presets[index]
  }

  func next() -> PresetDefinition? {
    guard !presets.isEmpty else { return nil }
    index = (index + 1) % presets.count
    return presets[index]
  }

  private func load() {
    let directURL = Bundle.main.url(forResource: "presets", withExtension: "json", subdirectory: "Presets")
    let nestedURL = Bundle.main.resourceURL?
      .appendingPathComponent("Resources/Presets")
      .appendingPathComponent("presets.json")
    guard let url = directURL ?? nestedURL else {
      logger.error("Preset bundle not found. resourceURL=\(Bundle.main.resourceURL?.path ?? "nil", privacy: .public)")
      presets = []
      return
    }

    do {
      let data = try Data(contentsOf: url)
      let payload = try JSONDecoder().decode(PresetLibraryPayload.self, from: data)
      var loadedPresets = payload.presets
      if let curated = loadCuratedNames() {
        let presetMap = Dictionary(uniqueKeysWithValues: loadedPresets.map { ($0.name, $0) })
        let curatedPresets = curated.compactMap { presetMap[$0] }
        if !curatedPresets.isEmpty {
          let missing = curated.count - curatedPresets.count
          if missing > 0 {
            logger.info("Curated preset list missing \(missing, privacy: .public) entries")
          }
          loadedPresets = curatedPresets
        }
      }
      presets = loadedPresets
      index = 0
      logger.info("Loaded \(self.presets.count, privacy: .public) presets")
    } catch {
      logger.error("Failed to load presets: \(error.localizedDescription, privacy: .public)")
      presets = []
    }
  }

  func loadCuratedNames() -> [String]? {
    let directURL = Bundle.main.url(forResource: "curated", withExtension: "json", subdirectory: "Presets")
    let nestedURL = Bundle.main.resourceURL?
      .appendingPathComponent("Resources/Presets")
      .appendingPathComponent("curated.json")
    guard let url = directURL ?? nestedURL else {
      return nil
    }
    do {
      let data = try Data(contentsOf: url)
      return try JSONDecoder().decode([String].self, from: data)
    } catch {
      logger.error("Failed to load curated preset list: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }
}
