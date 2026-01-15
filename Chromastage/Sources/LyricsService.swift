import Foundation

enum LyricsKind: Equatable {
  case none
  case loading
  case synced
  case plain
  case instrumental
  case notFound
}

struct LyricsCue: Identifiable, Equatable {
  let time: TimeInterval
  let text: String
  let id: String

  init(time: TimeInterval, text: String) {
    self.time = time
    self.text = text
    self.id = String(format: "%.3f", time) + "::" + text
  }
}

struct LyricsDisplayLine: Identifiable, Equatable {
  let id: String
  let text: String
  let isActive: Bool
}

struct LRCLibResponse: Decodable {
  let id: Int?
  let trackName: String?
  let artistName: String?
  let albumName: String?
  let duration: Double?
  let instrumental: Bool?
  let plainLyrics: String?
  let syncedLyrics: String?
}

final class LyricsService {
  private let baseURL = URL(string: "https://lrclib.net")!
  private let session: URLSession
  private let userAgent: String

  init(session: URLSession = .shared, userAgent: String? = nil) {
    self.session = session
    if let userAgent {
      self.userAgent = userAgent
    } else {
      self.userAgent = Self.defaultUserAgent()
    }
  }

  func fetchLyrics(trackName: String, artistName: String, albumName: String, duration: TimeInterval) async throws -> LRCLibResponse? {
    var components = URLComponents(url: baseURL.appendingPathComponent("api/get"), resolvingAgainstBaseURL: false)
    let roundedDuration = Int(duration.rounded())
    components?.queryItems = [
      URLQueryItem(name: "track_name", value: trackName),
      URLQueryItem(name: "artist_name", value: artistName),
      URLQueryItem(name: "album_name", value: albumName),
      URLQueryItem(name: "duration", value: String(roundedDuration))
    ]
    guard let url = components?.url else {
      return nil
    }

    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      return nil
    }
    if httpResponse.statusCode == 404 {
      return nil
    }
    guard (200...299).contains(httpResponse.statusCode) else {
      throw URLError(.badServerResponse)
    }

    return try JSONDecoder().decode(LRCLibResponse.self, from: data)
  }

  static func parseSyncedLyrics(_ text: String) -> [LyricsCue] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }

    let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return []
    }

    var cues: [LyricsCue] = []
    let lines = trimmed.split(whereSeparator: \.isNewline)

    for rawLine in lines {
      let line = String(rawLine)
      let range = NSRange(line.startIndex..<line.endIndex, in: line)
      let matches = regex.matches(in: line, range: range)
      guard !matches.isEmpty else { continue }

      let text = regex.stringByReplacingMatches(in: line, range: range, withTemplate: "").trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }

      for match in matches {
        guard match.numberOfRanges >= 3 else { continue }
        let minutesString = (line as NSString).substring(with: match.range(at: 1))
        let secondsString = (line as NSString).substring(with: match.range(at: 2))
        let millisRange = match.range(at: 3)
        let millisString = millisRange.location != NSNotFound ? (line as NSString).substring(with: millisRange) : ""

        let minutes = Double(minutesString) ?? 0
        let seconds = Double(secondsString) ?? 0
        let millis = Double(millisString) ?? 0
        let fraction: Double
        switch millisString.count {
        case 1:
          fraction = millis / 10.0
        case 2:
          fraction = millis / 100.0
        case 3:
          fraction = millis / 1000.0
        default:
          fraction = 0
        }
        let time = (minutes * 60.0) + seconds + fraction
        cues.append(LyricsCue(time: time, text: text))
      }
    }

    return cues.sorted { $0.time < $1.time }
  }

  static func parsePlainLyrics(_ text: String) -> [String] {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    return trimmed
      .split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private static func defaultUserAgent() -> String {
    let name = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? "Chromastage"
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
    return "\(name)/\(version)"
  }
}
