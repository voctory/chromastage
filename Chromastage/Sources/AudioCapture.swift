import Foundation
import CoreAudio

enum SystemAudioPermissionStatus: String {
  case unknown
  case granted
  case denied
}

@MainActor
final class AudioCapture: NSObject, ObservableObject {
  @Published var isCapturing = false
  @Published var statusMessage: String = ""
  @Published var permissionStatus: SystemAudioPermissionStatus = .unknown
  @Published var needsAttention = false
  @Published var lastError: String?

  nonisolated(unsafe) private let ringBuffer = AudioRingBuffer(capacity: 16_384)

  private var tapID: AudioObjectID = kAudioObjectUnknown
  private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
  private var tapIOProcID: AudioDeviceIOProcID?
  private var tapUID: String?

  private var isStarting = false
  private var permissionProbeTask: Task<Void, Never>?
  private var pendingStartAfterPermission = false

  func start(requestPermission: Bool = false) async {
    if isCapturing || isStarting {
      if pendingStartAfterPermission {
        schedulePermissionProbe()
      }
      return
    }

    isStarting = true
    defer { isStarting = false }

    guard #available(macOS 14.2, *) else {
      markCaptureIssue("System audio capture requires macOS 14.2 or later.")
      permissionStatus = .denied
      return
    }

    let permission = refreshPermissionStatus(requestIfNeeded: false)
    if permission != .granted, !requestPermission {
      pendingStartAfterPermission = true
      schedulePermissionProbe()
      markCaptureIssue("Enable System Audio Recording in System Settings to react to music.")
      return
    }

    pendingStartAfterPermission = false
    stopPermissionProbe()

    statusMessage = requestPermission
      ? "Requesting System Audio Recording permission…"
      : "Starting system audio capture…"

    let status = startTap()
    if status == kAudioHardwareNoError {
      isCapturing = true
      needsAttention = false
      lastError = nil
      permissionStatus = .granted
      statusMessage = "Capturing system audio."
      return
    }

    let permissionStatus = refreshPermissionStatus(requestIfNeeded: false)
    if permissionStatus != .granted {
      pendingStartAfterPermission = true
      schedulePermissionProbe()
    }

    markCaptureIssue("Audio capture failed: \(Self.describeCoreAudioStatus(status))")
  }

  func stop() {
    pendingStartAfterPermission = false
    stopPermissionProbe()
    guard #available(macOS 14.2, *) else {
      isCapturing = false
      return
    }

    stopTap()
    isCapturing = false
    statusMessage = "Capture stopped."
  }

  func refreshPermissionStatus(requestIfNeeded: Bool = false) -> SystemAudioPermissionStatus {
    if isCapturing {
      permissionStatus = .granted
      return .granted
    }

    guard #available(macOS 14.2, *) else {
      permissionStatus = .denied
      return .denied
    }

    _ = createTapIfNeeded()
    let authorized = isAudioCaptureAuthorized()

    if !authorized, requestIfNeeded {
      _ = requestAudioCaptureAuthorization()
    }

    let status: SystemAudioPermissionStatus = isAudioCaptureAuthorized() ? .granted : .denied
    permissionStatus = status

    if status == .granted {
      if !pendingStartAfterPermission && !isStarting {
        stopPermissionProbe()
      }
    } else if pendingStartAfterPermission {
      schedulePermissionProbe()
    }

    return status
  }

  private func markCaptureIssue(_ message: String) {
    statusMessage = message
    lastError = message
    needsAttention = true
    isCapturing = false
  }

  private func schedulePermissionProbe() {
    guard permissionProbeTask == nil else { return }
    permissionProbeTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let status = self.refreshPermissionStatus(requestIfNeeded: false)
        if status == .granted {
          if self.isStarting {
            continue
          }
          self.permissionProbeTask = nil
          if self.pendingStartAfterPermission && !self.isCapturing {
            self.pendingStartAfterPermission = false
            await self.start()
          }
          return
        }
      }
    }
  }

  private func stopPermissionProbe() {
    permissionProbeTask?.cancel()
    permissionProbeTask = nil
  }

  @available(macOS 14.2, *)
  private func startTap() -> OSStatus {
    if tapID == kAudioObjectUnknown || aggregateDeviceID == kAudioObjectUnknown || tapIOProcID == nil {
      guard createTapIfNeeded() else {
        return kAudioHardwareUnspecifiedError
      }
    }

    guard let tapIOProcID else {
      return kAudioHardwareUnspecifiedError
    }

    return AudioDeviceStart(aggregateDeviceID, tapIOProcID)
  }

  @available(macOS 14.2, *)
  private func stopTap() {
    if let tapIOProcID {
      AudioDeviceStop(aggregateDeviceID, tapIOProcID)
      AudioDeviceDestroyIOProcID(aggregateDeviceID, tapIOProcID)
    }

    if aggregateDeviceID != kAudioObjectUnknown {
      AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    }

    if tapID != kAudioObjectUnknown {
      AudioHardwareDestroyProcessTap(tapID)
    }

    tapUID = nil
    tapID = kAudioObjectUnknown
    aggregateDeviceID = kAudioObjectUnknown
    tapIOProcID = nil
  }

  @available(macOS 14.2, *)
  private func createTapIfNeeded() -> Bool {
    if tapID != kAudioObjectUnknown && aggregateDeviceID != kAudioObjectUnknown && tapIOProcID != nil {
      return true
    }

    if tapID != kAudioObjectUnknown || aggregateDeviceID != kAudioObjectUnknown || tapIOProcID != nil {
      stopTap()
    }

    guard let currentProcessAudioObjectID = getCurrentProcessAudioObjectID() else {
      return false
    }

    let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [currentProcessAudioObjectID])
    tapDescription.name = "Chromastage System Audio Tap"
    tapDescription.isPrivate = true
    tapDescription.muteBehavior = .unmuted

    var tapID: AudioObjectID = kAudioObjectUnknown
    var status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
    guard status == kAudioHardwareNoError else {
      return false
    }

    let tapUID = tapDescription.uuid.uuidString
    guard let aggregateDeviceID = createAggregateDevice(withTapUID: tapUID) else {
      AudioHardwareDestroyProcessTap(tapID)
      return false
    }

    var tapIOProcID: AudioDeviceIOProcID?
    status = AudioDeviceCreateIOProcID(
      aggregateDeviceID,
      Self.tapIOProc,
      Unmanaged.passUnretained(self).toOpaque(),
      &tapIOProcID
    )

    guard status == kAudioHardwareNoError, tapIOProcID != nil else {
      AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
      AudioHardwareDestroyProcessTap(tapID)
      return false
    }

    self.tapID = tapID
    self.tapUID = tapUID
    self.aggregateDeviceID = aggregateDeviceID
    self.tapIOProcID = tapIOProcID
    return true
  }

  @available(macOS 14.2, *)
  private func createAggregateDevice(withTapUID tapUID: String) -> AudioObjectID? {
    let subTap: [String: Any] = [
      kAudioSubTapUIDKey: tapUID,
      kAudioSubTapDriftCompensationKey: 1,
    ]

    let uid = UUID().uuidString
    let properties: [String: Any] = [
      kAudioAggregateDeviceNameKey: "Chromastage Audio Capture",
      kAudioAggregateDeviceUIDKey: uid,
      kAudioAggregateDeviceTapListKey: [subTap],
      kAudioAggregateDeviceTapAutoStartKey: 0,
      kAudioAggregateDeviceIsPrivateKey: 1,
    ]

    var deviceID: AudioObjectID = kAudioObjectUnknown
    let status = AudioHardwareCreateAggregateDevice(properties as CFDictionary, &deviceID)
    guard status == kAudioHardwareNoError, deviceID != kAudioObjectUnknown else {
      return nil
    }
    return deviceID
  }

  @available(macOS 14.2, *)
  private func isAudioCaptureAuthorized() -> Bool {
    if tapID == kAudioObjectUnknown {
      guard createTapIfNeeded() else { return false }
    }

    var address = AudioObjectPropertyAddress(
      mSelector: kAudioTapPropertyFormat,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var format = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format)
    return status == kAudioHardwareNoError
  }

  @available(macOS 14.2, *)
  private func requestAudioCaptureAuthorization() -> Bool {
    if isCapturing {
      return true
    }

    let status = startTap()
    if status == kAudioHardwareNoError {
      stopTap()
      return true
    }
    stopTap()
    return false
  }

  @available(macOS 14.2, *)
  private func getCurrentProcessAudioObjectID() -> AudioObjectID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyProcessObjectList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )

    var dataSize: UInt32 = 0
    let systemObjectID = AudioObjectID(kAudioObjectSystemObject)
    var status = AudioObjectGetPropertyDataSize(systemObjectID, &address, 0, nil, &dataSize)
    guard status == kAudioHardwareNoError else {
      return nil
    }

    let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
    var processObjectIDs = [AudioObjectID](repeating: 0, count: count)
    status = AudioObjectGetPropertyData(systemObjectID, &address, 0, nil, &dataSize, &processObjectIDs)
    guard status == kAudioHardwareNoError else {
      return nil
    }

    let currentPID = ProcessInfo.processInfo.processIdentifier
    for processID in processObjectIDs {
      var pidAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyPID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
      )

      var pid: pid_t = 0
      var pidSize = UInt32(MemoryLayout<pid_t>.size)
      status = AudioObjectGetPropertyData(processID, &pidAddress, 0, nil, &pidSize, &pid)
      if status == kAudioHardwareNoError, pid == currentPID {
        return processID
      }
    }

    return nil
  }

  nonisolated func latestAudioBytes(count: Int) -> (mono: Data, left: Data, right: Data) {
    let (leftSamples, rightSamples) = ringBuffer.snapshot(count: count)
    var monoBytes = [UInt8](repeating: 128, count: count)
    var leftBytes = [UInt8](repeating: 128, count: count)
    var rightBytes = [UInt8](repeating: 128, count: count)

    for i in 0..<count {
      let left = leftSamples[i]
      let right = rightSamples[i]
      leftBytes[i] = Self.floatToByte(left)
      rightBytes[i] = Self.floatToByte(right)
      monoBytes[i] = Self.floatToByte((left + right) * 0.5)
    }

    return (Data(monoBytes), Data(leftBytes), Data(rightBytes))
  }

  nonisolated func latestSamples(count: Int) -> (left: [Float], right: [Float]) {
    ringBuffer.snapshot(count: count)
  }

  nonisolated private static func floatToByte(_ sample: Float) -> UInt8 {
    let clamped = max(-1.0, min(1.0, sample))
    let scaled = (clamped * 127.0) + 128.0
    let rounded = Int(scaled.rounded())
    return UInt8(max(0, min(255, rounded)))
  }

  nonisolated private func receiveTapAudio(_ inputData: UnsafePointer<AudioBufferList>) {
    let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
    guard !bufferList.isEmpty else { return }

    if bufferList.count >= 2,
       bufferList[0].mNumberChannels == 1,
       bufferList[1].mNumberChannels == 1,
       let leftData = bufferList[0].mData,
       let rightData = bufferList[1].mData {
      let leftSamples = leftData.assumingMemoryBound(to: Float.self)
      let rightSamples = rightData.assumingMemoryBound(to: Float.self)
      let leftCount = Int(bufferList[0].mDataByteSize) / MemoryLayout<Float>.size
      let rightCount = Int(bufferList[1].mDataByteSize) / MemoryLayout<Float>.size
      let frameCount = min(leftCount, rightCount)
      if frameCount > 0 {
        ringBuffer.appendInterleaved(leftPtr: leftSamples, rightPtr: rightSamples, frameCount: frameCount)
      }
      return
    }

    for buffer in bufferList {
      guard let data = buffer.mData else { continue }
      let channels = Int(buffer.mNumberChannels)
      guard channels > 0 else { continue }
      let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
      let frameCount = sampleCount / channels
      if frameCount <= 0 { continue }
      let samplePtr = data.assumingMemoryBound(to: Float.self)
      ringBuffer.appendInterleaved(samplePtr: samplePtr, frameCount: frameCount, channels: channels)
    }
  }

  private static func describeCoreAudioStatus(_ status: OSStatus) -> String {
    if status == kAudioDevicePermissionsError {
      return "Permission denied. Enable Chromastage under System Settings → Privacy & Security → System Audio Recording."
    }

    if status == kAudioHardwareNotReadyError {
      return "Audio system not ready."
    }

    if status == kAudioHardwareUnsupportedOperationError {
      return "Unsupported operation."
    }

    if status == kAudioHardwareBadDeviceError {
      return "Invalid audio device."
    }

    if status == kAudioHardwareIllegalOperationError {
      return "Illegal operation."
    }

    let statusString = String(format: "OSStatus %d", status)
    return statusString
  }

  @available(macOS 14.2, *)
  private static let tapIOProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
    guard let clientData else { return noErr }
    let audioCapture = Unmanaged<AudioCapture>.fromOpaque(clientData).takeUnretainedValue()
    audioCapture.receiveTapAudio(inputData)
    return noErr
  }
}

final class AudioRingBuffer {
  private let capacity: Int
  private var left: [Float]
  private var right: [Float]
  private var writeIndex = 0
  private let queue = DispatchQueue(label: "Chromastage.AudioRingBuffer")

  init(capacity: Int) {
    self.capacity = capacity
    self.left = Array(repeating: 0, count: capacity)
    self.right = Array(repeating: 0, count: capacity)
  }

  func appendInterleaved(samplePtr: UnsafePointer<Float>, frameCount: Int, channels: Int) {
    guard channels > 0 else { return }
    queue.sync {
      for i in 0..<frameCount {
        let base = i * channels
        let l = samplePtr[base]
        let r = channels > 1 ? samplePtr[base + 1] : l
        write(left: l, right: r)
      }
    }
  }

  func appendInterleavedInt16(samplePtr: UnsafePointer<Int16>, frameCount: Int, channels: Int) {
    guard channels > 0 else { return }
    let scale = Float(1.0 / 32768.0)
    queue.sync {
      for i in 0..<frameCount {
        let base = i * channels
        let l = Float(samplePtr[base]) * scale
        let r = channels > 1 ? Float(samplePtr[base + 1]) * scale : l
        write(left: l, right: r)
      }
    }
  }

  func appendInterleaved(leftPtr: UnsafePointer<Float>, rightPtr: UnsafePointer<Float>, frameCount: Int) {
    queue.sync {
      for i in 0..<frameCount {
        write(left: leftPtr[i], right: rightPtr[i])
      }
    }
  }

  func appendInterleavedInt16(leftPtr: UnsafePointer<Int16>, rightPtr: UnsafePointer<Int16>, frameCount: Int) {
    let scale = Float(1.0 / 32768.0)
    queue.sync {
      for i in 0..<frameCount {
        write(left: Float(leftPtr[i]) * scale, right: Float(rightPtr[i]) * scale)
      }
    }
  }

  private func write(left l: Float, right r: Float) {
    left[writeIndex] = l
    right[writeIndex] = r
    writeIndex = (writeIndex + 1) % capacity
  }

  func snapshot(count: Int) -> ([Float], [Float]) {
    let count = min(count, capacity)
    var leftCopy = [Float](repeating: 0, count: count)
    var rightCopy = [Float](repeating: 0, count: count)

    queue.sync {
      var idx = writeIndex - count
      if idx < 0 { idx += capacity }
      for i in 0..<count {
        leftCopy[i] = left[idx]
        rightCopy[i] = right[idx]
        idx = (idx + 1) % capacity
      }
    }

    return (leftCopy, rightCopy)
  }
}
