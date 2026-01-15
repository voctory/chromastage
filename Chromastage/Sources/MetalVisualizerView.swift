import SwiftUI
import MetalKit

struct MetalVisualizerView: NSViewRepresentable {
  @ObservedObject var audioCapture: AudioCapture
  var selectedPreset: PresetDefinition?
  var autoSwitchEnabled: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> MTKView {
    let view = MTKView()
    view.clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1)
    view.colorPixelFormat = .bgra8Unorm
    view.framebufferOnly = true
    view.isPaused = false
    view.enableSetNeedsDisplay = false
    view.preferredFramesPerSecond = 60

    guard let device = MTLCreateSystemDefaultDevice() else {
      return view
    }

    view.device = device
    if let renderer = MetalRenderer(view: view, audioCapture: audioCapture) {
      context.coordinator.renderer = renderer
      view.delegate = renderer
    }

    return view
  }

  func updateNSView(_ nsView: MTKView, context: Context) {
    context.coordinator.renderer?.audioCapture = audioCapture
    if context.coordinator.autoSwitchEnabled != autoSwitchEnabled {
      context.coordinator.renderer?.setAutoSwitching(autoSwitchEnabled)
      context.coordinator.autoSwitchEnabled = autoSwitchEnabled
    }
    let presetName = selectedPreset?.name
    if context.coordinator.currentPresetName != presetName {
      if let selectedPreset {
        context.coordinator.renderer?.setPreset(selectedPreset)
      }
      context.coordinator.currentPresetName = presetName
    }
  }

  final class Coordinator {
    var renderer: MetalRenderer?
    var currentPresetName: String?
    var autoSwitchEnabled: Bool

    init() {
      self.renderer = nil
      self.currentPresetName = nil
      self.autoSwitchEnabled = true
    }
  }
}
