import Foundation

@MainActor
final class WebLogStore: ObservableObject {
  @Published var lastMessage: String = ""
  private var lastUpdateAt: Date = .distantPast
  private let minimumUpdateInterval: TimeInterval = 1.0

  func update(message: String) {
    let now = Date()
    if now.timeIntervalSince(lastUpdateAt) < minimumUpdateInterval {
      return
    }
    lastUpdateAt = now
    lastMessage = message
  }
}
