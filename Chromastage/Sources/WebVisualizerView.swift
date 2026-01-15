import SwiftUI
import Foundation
import WebKit
import os

struct WebVisualizerView: NSViewRepresentable {
  @ObservedObject var audioCapture: AudioCapture
  @ObservedObject var logStore: WebLogStore
  var selectedPresetName: String?
  var autoSwitchEnabled: Bool
  var autoSwitchRandomized: Bool
  var manualPresetRequest: ManualPresetRequest?
  var blockedPresetNames: [String]
  var playlistPresetNames: [String]?
  var palette: [String]
  @Binding var activePresetName: String?

  func makeCoordinator() -> Coordinator {
    Coordinator(audioCapture: audioCapture, logStore: logStore, activePresetName: $activePresetName)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    if #available(macOS 10.12, *) {
      configuration.mediaTypesRequiringUserActionForPlayback = []
    }
    let contentController = WKUserContentController()
    contentController.add(context.coordinator, name: "nativeReady")
    contentController.add(context.coordinator, name: "nativeLog")
    contentController.add(context.coordinator, name: "nativePresetChanged")
    configuration.userContentController = contentController
    configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.setValue(false, forKey: "drawsBackground")

    context.coordinator.webView = webView
    context.coordinator.loadVisualizer()

    return webView
  }

  func updateNSView(_ nsView: WKWebView, context: Context) {
    context.coordinator.audioCapture = audioCapture
    context.coordinator.logStore = logStore
    context.coordinator.updatePresetSelection(
      selectedPresetName: selectedPresetName,
      autoSwitchEnabled: autoSwitchEnabled,
      autoSwitchRandomized: autoSwitchRandomized
    )
    context.coordinator.applyManualPresetRequest(manualPresetRequest)
    context.coordinator.updateBlockedPresets(blockedPresetNames)
    context.coordinator.updatePlaylistPresets(playlistPresetNames)
    context.coordinator.updatePalette(palette)
  }

  final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    weak var webView: WKWebView?
    var audioCapture: AudioCapture
    var logStore: WebLogStore
    private var activePresetName: Binding<String?>
    private let logger = Logger(subsystem: "com.chromastage.app", category: "Web")
    private var isReady = false
    private var timer: Timer?
    private var currentPresetName: String?
    private var autoSwitchEnabled = true
    private var autoSwitchRandomized = false
    private var pendingPresetName: String?
    private var pendingAutoSwitchEnabled: Bool?
    private var pendingAutoSwitchRandomized: Bool?
    private var pendingManualPresetName: String?
    private var lastManualRequestId: UUID?
    private var blockedPresetNames: [String] = []
    private var pendingBlockedPresetNames: [String]?
    private var playlistPresetNames: [String]?
    private var pendingPlaylistPresetNames: [String]?
    private var hasPendingPlaylistPresetNames = false
    private var currentPalette: [String] = []
    private var pendingPalette: [String]?
    private let autoSwitchIntervalMs = 15_000
    private let audioWorkQueue = DispatchQueue(label: "Chromastage.WebAudioWork", qos: .userInitiated)
    private var isAudioPushInFlight = false

    init(audioCapture: AudioCapture, logStore: WebLogStore, activePresetName: Binding<String?>) {
      self.audioCapture = audioCapture
      self.logStore = logStore
      self.activePresetName = activePresetName
    }

    deinit {
      stopTimer()
    }

    func loadVisualizer() {
      guard let webView else { return }
      let resourceRoot = Bundle.main.resourceURL
      if let directIndex = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Visualizer"),
         let root = resourceRoot ?? Bundle.main.resourceURL?.appendingPathComponent("Visualizer") {
        log("Loading direct index: \(directIndex.path)")
        webView.loadFileURL(directIndex, allowingReadAccessTo: root)
        return
      }

      let nestedRoot = Bundle.main.resourceURL?.appendingPathComponent("Resources/Visualizer")
      let nestedIndex = nestedRoot?.appendingPathComponent("index.html")
      guard let indexURL = nestedIndex else {
        log("Failed to locate visualizer resources. resourceURL=\(Bundle.main.resourceURL?.path ?? "nil")")
        return
      }
      let root = resourceRoot ?? nestedRoot ?? Bundle.main.resourceURL
      guard let readRoot = root else {
        log("Failed to locate visualizer resources. resourceURL=\(Bundle.main.resourceURL?.path ?? "nil")")
        return
      }
      log("Loading nested index: \(indexURL.path)")
      webView.loadFileURL(indexURL, allowingReadAccessTo: readRoot)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      if message.name == "nativeReady" {
        isReady = true
        startTimer()
        syncPresetState()
        log("Visualizer ready")
        return
      }
      if message.name == "nativePresetChanged" {
        handlePresetChanged(message.body)
        return
      }
      if message.name == "nativeLog" {
        log("JS: \(message.body)")
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      let url = webView.url?.absoluteString ?? "nil"
      log("WebView didFinish loading: \(url)")
      webView.evaluateJavaScript("document.readyState") { [weak self] result, error in
        if let error {
          self?.log("JS readyState error: \(error.localizedDescription)")
        } else {
          self?.log("JS readyState: \(String(describing: result))")
        }
      }
      webView.evaluateJavaScript("window.webkit?.messageHandlers?.nativeLog?.postMessage({ level: 'info', message: 'native ping' });") { [weak self] _, error in
        if let error {
          self?.log("JS ping error: \(error.localizedDescription)")
        } else {
          self?.log("JS ping sent")
        }
      }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      log("WebView didFail: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      log("WebView didFailProvisional: \(error.localizedDescription)")
    }

    private func startTimer() {
      stopTimer()
      timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
        self?.queueAudioPush()
      }
      timer?.tolerance = 0.01
    }

    private func stopTimer() {
      timer?.invalidate()
      timer = nil
      isAudioPushInFlight = false
    }

    private func queueAudioPush() {
      guard isReady, let webView else { return }
      if isAudioPushInFlight {
        return
      }
      isAudioPushInFlight = true
      audioWorkQueue.async { [weak self, weak webView] in
        guard let self else { return }
        let audio = self.audioCapture.latestAudioBytes(count: 2048)
        let mono = audio.mono.base64EncodedString()
        let left = audio.left.base64EncodedString()
        let right = audio.right.base64EncodedString()
        let js = "window.butterchurnNative?.updateAudio('\(mono)','\(left)','\(right)');"
        DispatchQueue.main.async { [weak self, weak webView] in
          guard let self else { return }
          self.isAudioPushInFlight = false
          guard let webView else { return }
          webView.evaluateJavaScript(js, completionHandler: nil)
        }
      }
    }

    private func log(_ message: String) {
      DispatchQueue.main.async { [weak self] in
        self?.logStore.update(message: message)
      }
      logger.info("\(message, privacy: .public)")
    }

    func updatePresetSelection(selectedPresetName: String?, autoSwitchEnabled: Bool, autoSwitchRandomized: Bool) {
      var autoSwitchDirty = false
      if autoSwitchEnabled != self.autoSwitchEnabled {
        self.autoSwitchEnabled = autoSwitchEnabled
        autoSwitchDirty = true
        if autoSwitchEnabled {
          pendingPresetName = nil
        }
      }
      if autoSwitchRandomized != self.autoSwitchRandomized {
        self.autoSwitchRandomized = autoSwitchRandomized
        autoSwitchDirty = true
      }
      if autoSwitchDirty {
        if isReady {
          sendAutoSwitch(enabled: self.autoSwitchEnabled, randomized: self.autoSwitchRandomized)
        } else {
          pendingAutoSwitchEnabled = self.autoSwitchEnabled
          pendingAutoSwitchRandomized = self.autoSwitchRandomized
        }
      }

      if selectedPresetName != currentPresetName {
        currentPresetName = selectedPresetName
        guard !autoSwitchEnabled, let selectedPresetName else { return }
        if isReady {
          sendPreset(selectedPresetName)
        } else {
          pendingPresetName = selectedPresetName
        }
      }
    }

    func applyManualPresetRequest(_ request: ManualPresetRequest?) {
      guard let request, request.id != lastManualRequestId else { return }
      lastManualRequestId = request.id
      if isReady {
        sendPreset(request.name)
      } else {
        pendingManualPresetName = request.name
      }
    }

    func updateBlockedPresets(_ names: [String]) {
      if names == blockedPresetNames {
        return
      }
      blockedPresetNames = names
      if isReady {
        sendBlockedPresets(names)
      } else {
        pendingBlockedPresetNames = names
      }
    }

    func updatePlaylistPresets(_ names: [String]?) {
      if names == playlistPresetNames {
        return
      }
      playlistPresetNames = names
      if isReady {
        sendPlaylistPresets(names)
      } else {
        pendingPlaylistPresetNames = names
        hasPendingPlaylistPresetNames = true
      }
    }

    private func syncPresetState() {
      let autoSwitch = pendingAutoSwitchEnabled ?? autoSwitchEnabled
      let randomized = pendingAutoSwitchRandomized ?? autoSwitchRandomized
      sendAutoSwitch(enabled: autoSwitch, randomized: randomized)

      if !autoSwitch, let presetName = pendingPresetName ?? currentPresetName {
        sendPreset(presetName)
      }
      if let manualPresetName = pendingManualPresetName {
        sendPreset(manualPresetName)
      }
      if let pendingBlockedPresetNames {
        sendBlockedPresets(pendingBlockedPresetNames)
      }
      if hasPendingPlaylistPresetNames {
        sendPlaylistPresets(pendingPlaylistPresetNames)
      }

      pendingAutoSwitchEnabled = nil
      pendingAutoSwitchRandomized = nil
      pendingPresetName = nil
      pendingManualPresetName = nil
      pendingBlockedPresetNames = nil
      pendingPlaylistPresetNames = nil
      hasPendingPlaylistPresetNames = false
      if let palette = pendingPalette {
        sendPalette(palette)
        pendingPalette = nil
      }
    }

    func updatePalette(_ palette: [String]) {
      if palette == currentPalette {
        return
      }
      currentPalette = palette
      if isReady {
        sendPalette(palette)
      } else {
        pendingPalette = palette
      }
    }

    private func sendAutoSwitch(enabled: Bool, randomized: Bool) {
      guard let webView else { return }
      let js = "window.butterchurnNative?.setAutoSwitch(\(enabled ? "true" : "false"), \(autoSwitchIntervalMs), \(randomized ? "true" : "false"));"
      webView.evaluateJavaScript(js) { [weak self] _, error in
        if let error {
          self?.log("setAutoSwitch error: \(error.localizedDescription)")
        }
      }
    }

    private func sendPreset(_ name: String) {
      guard let webView else { return }
      let js = "window.butterchurnNative?.setPreset(\(jsStringLiteral(name)));"
      webView.evaluateJavaScript(js) { [weak self] _, error in
        if let error {
          self?.log("setPreset error: \(error.localizedDescription)")
        }
      }
    }

    private func sendBlockedPresets(_ names: [String]) {
      guard let webView else { return }
      let payload = jsonArrayLiteral(names)
      let js = "window.butterchurnNative?.setBlockedPresets(\(payload));"
      webView.evaluateJavaScript(js) { [weak self] _, error in
        if let error {
          self?.log("setBlockedPresets error: \(error.localizedDescription)")
        }
      }
    }

    private func sendPlaylistPresets(_ names: [String]?) {
      guard let webView else { return }
      let payload = names == nil ? "null" : jsonArrayLiteral(names ?? [])
      let js = "window.butterchurnNative?.setPlaylistPresets(\(payload));"
      webView.evaluateJavaScript(js) { [weak self] _, error in
        if let error {
          self?.log("setPlaylistPresets error: \(error.localizedDescription)")
        }
      }
    }

    private func sendPalette(_ palette: [String]) {
      guard let webView else { return }
      let payload = jsonArrayLiteral(palette)
      let js = "window.butterchurnNative?.setPalette(\(payload));"
      webView.evaluateJavaScript(js) { [weak self] _, error in
        if let error {
          self?.log("setPalette error: \(error.localizedDescription)")
        }
      }
    }

    private func jsStringLiteral(_ value: String) -> String {
      if let data = try? JSONEncoder().encode(value),
         let encoded = String(data: data, encoding: .utf8) {
        return encoded
      }
      return "\"\""
    }

    private func jsonArrayLiteral(_ value: [String]) -> String {
      if let data = try? JSONEncoder().encode(value),
         let encoded = String(data: data, encoding: .utf8) {
        return encoded
      }
      return "[]"
    }

    private func handlePresetChanged(_ body: Any) {
      var name: String?
      if let dict = body as? [String: Any] {
        name = dict["name"] as? String
      } else if let value = body as? String {
        name = value
      }
      guard let name else { return }
      DispatchQueue.main.async { [weak self] in
        self?.activePresetName.wrappedValue = name
      }
    }
  }
}
