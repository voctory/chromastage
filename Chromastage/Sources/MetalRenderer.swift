import Foundation
import Metal
import MetalKit
import QuartzCore
import os

struct WarpUniforms {
  var resolution: SIMD2<Float>
  var time: Float
  var decay: Float
  var rms: Float
  var beat: Float
  var waveColorAlpha: SIMD4<Float>
  var waveParams: SIMD4<Float>
  var echoParams: SIMD4<Float>
}

struct OutputUniforms {
  var resolution: SIMD2<Float>
  var time: Float
  var fShader: Float
  var echoParams: SIMD4<Float>
  var postParams0: SIMD4<Float>
  var postParams1: SIMD4<Float>
  var hueBase0: SIMD4<Float>
  var hueBase1: SIMD4<Float>
  var hueBase2: SIMD4<Float>
  var hueBase3: SIMD4<Float>
}

struct WarpVertex {
  var position: SIMD2<Float>
  var uv: SIMD2<Float>
}

final class MetalRenderer: NSObject, MTKViewDelegate {
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let warpPipeline: MTLRenderPipelineState
  private let outputPipeline: MTLRenderPipelineState
  private let overlayPipeline: MTLRenderPipelineState
  private let warpUniformBuffer: MTLBuffer
  private let outputUniformBuffer: MTLBuffer
  private let overlayUniformBuffer: MTLBuffer
  private let spectrumBuffer: MTLBuffer
  private let borderVertexBuffer: MTLBuffer
  private let motionVertexBuffer: MTLBuffer
  private let samplerRepeat: MTLSamplerState
  private let samplerClamp: MTLSamplerState
  private let analyzer: AudioAnalyzer
  private let levelMeter = AudioLevelMeter()
  private var preset = PresetState()
  private let basicWaveform: BasicWaveformRenderer?
  private let customWaveforms: [CustomWaveformRenderer]
  private let customShapes: [CustomShapeRenderer]
  private var activeShapes: [PresetShape] = []
  private var activeWaves: [PresetWave] = []
  private let presetLibrary = PresetLibrary()
  private var lastPresetSwitchTime: CFTimeInterval = 0
  private let presetSwitchInterval: CFTimeInterval = 15
  private var autoSwitchEnabled: Bool = true
  private let logger = Logger(subsystem: "com.chromastage.app", category: "Metal")
  private var equationRunner: JSEquationRunner?

  private var meshWidth: Int = 64
  private var meshHeight: Int = 48
  private var vertices: [WarpVertex] = []
  private var vertexBuffer: MTLBuffer
  private var indexBuffer: MTLBuffer
  private var indexCount: Int = 0
  private var motionVertices: [WaveVertex] = []
  private var borderVertices: [WaveVertex] = []
  private let maxMotionGridX = 64
  private let maxMotionGridY = 48

  private var prevTexture: MTLTexture?
  private var targetTexture: MTLTexture?
  private var drawableSize: CGSize = .zero

  private var frameIndex: Int = 0
  private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
  private let startTime: CFTimeInterval
  private var randStart: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)
  private var randPreset: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0)

  var audioCapture: AudioCapture

  init?(view: MTKView, audioCapture: AudioCapture) {
    guard let device = view.device else { return nil }
    guard let commandQueue = device.makeCommandQueue() else { return nil }
    guard let analyzer = AudioAnalyzer(fftSize: 1024, sampleRate: 48_000, bands: 64) else { return nil }

    self.device = device
    self.commandQueue = commandQueue
    self.audioCapture = audioCapture
    self.analyzer = analyzer
    self.startTime = CACurrentMediaTime()

    guard let library = device.makeDefaultLibrary() else { return nil }
    guard let warpVertex = library.makeFunction(name: "warp_vertex"),
          let warpFragment = library.makeFunction(name: "warp_fragment"),
          let outputVertex = library.makeFunction(name: "output_vertex"),
          let outputFragment = library.makeFunction(name: "output_fragment"),
          let overlayVertex = library.makeFunction(name: "wave_vertex"),
          let overlayFragment = library.makeFunction(name: "wave_fragment") else {
      return nil
    }

    let warpDescriptor = MTLRenderPipelineDescriptor()
    warpDescriptor.vertexFunction = warpVertex
    warpDescriptor.fragmentFunction = warpFragment
    warpDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

    let outputDescriptor = MTLRenderPipelineDescriptor()
    outputDescriptor.vertexFunction = outputVertex
    outputDescriptor.fragmentFunction = outputFragment
    outputDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat

    let overlayDescriptor = MTLRenderPipelineDescriptor()
    overlayDescriptor.vertexFunction = overlayVertex
    overlayDescriptor.fragmentFunction = overlayFragment
    overlayDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
    overlayDescriptor.colorAttachments[0].isBlendingEnabled = true
    overlayDescriptor.colorAttachments[0].rgbBlendOperation = .add
    overlayDescriptor.colorAttachments[0].alphaBlendOperation = .add
    overlayDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    overlayDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
    overlayDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    overlayDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

    do {
      warpPipeline = try device.makeRenderPipelineState(descriptor: warpDescriptor)
      outputPipeline = try device.makeRenderPipelineState(descriptor: outputDescriptor)
      overlayPipeline = try device.makeRenderPipelineState(descriptor: overlayDescriptor)
    } catch {
      return nil
    }

    let warpUniformLength = MemoryLayout<WarpUniforms>.stride
    let outputUniformLength = MemoryLayout<OutputUniforms>.stride
    let overlayUniformLength = MemoryLayout<WaveUniforms>.stride
    guard let warpUniformBuffer = device.makeBuffer(length: warpUniformLength, options: .storageModeShared),
          let outputUniformBuffer = device.makeBuffer(length: outputUniformLength, options: .storageModeShared),
          let overlayUniformBuffer = device.makeBuffer(length: overlayUniformLength, options: .storageModeShared),
          let spectrumBuffer = device.makeBuffer(length: 64 * MemoryLayout<Float>.stride, options: .storageModeShared) else {
      return nil
    }
    self.warpUniformBuffer = warpUniformBuffer
    self.outputUniformBuffer = outputUniformBuffer
    self.overlayUniformBuffer = overlayUniformBuffer
    self.spectrumBuffer = spectrumBuffer

    let samplerDesc = MTLSamplerDescriptor()
    samplerDesc.minFilter = .linear
    samplerDesc.magFilter = .linear
    samplerDesc.sAddressMode = .repeat
    samplerDesc.tAddressMode = .repeat
    guard let samplerRepeat = device.makeSamplerState(descriptor: samplerDesc) else { return nil }

    let samplerClampDesc = MTLSamplerDescriptor()
    samplerClampDesc.minFilter = .linear
    samplerClampDesc.magFilter = .linear
    samplerClampDesc.sAddressMode = .clampToEdge
    samplerClampDesc.tAddressMode = .clampToEdge
    guard let samplerClamp = device.makeSamplerState(descriptor: samplerClampDesc) else { return nil }

    self.samplerRepeat = samplerRepeat
    self.samplerClamp = samplerClamp

    self.vertices = []
    let mesh = MetalRenderer.buildMesh(width: meshWidth, height: meshHeight)
    self.vertices = mesh.vertices
    self.indexCount = mesh.indices.count
    guard let vertexBuffer = device.makeBuffer(bytes: mesh.vertices,
                                               length: MemoryLayout<WarpVertex>.stride * mesh.vertices.count,
                                               options: .storageModeShared),
          let indexBuffer = device.makeBuffer(bytes: mesh.indices,
                                              length: MemoryLayout<UInt16>.stride * mesh.indices.count,
                                              options: .storageModeShared) else {
      return nil
    }
    self.vertexBuffer = vertexBuffer
    self.indexBuffer = indexBuffer

    let maxMotionVertices = maxMotionGridX * maxMotionGridY * 2
    let motionBufferLength = MemoryLayout<WaveVertex>.stride * maxMotionVertices
    let borderBufferLength = MemoryLayout<WaveVertex>.stride * 24
    guard let motionVertexBuffer = device.makeBuffer(length: motionBufferLength, options: .storageModeShared),
          let borderVertexBuffer = device.makeBuffer(length: borderBufferLength, options: .storageModeShared) else {
      return nil
    }
    self.motionVertexBuffer = motionVertexBuffer
    self.borderVertexBuffer = borderVertexBuffer
    self.motionVertices = Array(repeating: WaveVertex(position: .zero), count: maxMotionVertices)
    self.borderVertices = Array(repeating: WaveVertex(position: .zero), count: 24)

    self.basicWaveform = BasicWaveformRenderer(device: device, pixelFormat: view.colorPixelFormat)
    self.customWaveforms = (0..<4).map { _ in CustomWaveformRenderer() }
    self.customShapes = (0..<4).compactMap { _ in CustomShapeRenderer(device: device, pixelFormat: view.colorPixelFormat) }

    super.init()
    drawableSize = view.drawableSize
    recreateTexturesIfNeeded(size: drawableSize)

    if let preset = presetLibrary.current() {
      applyPreset(preset)
      lastPresetSwitchTime = CACurrentMediaTime()
    }
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    drawableSize = size
    recreateTexturesIfNeeded(size: size)
  }

  func draw(in view: MTKView) {
    guard let drawable = view.currentDrawable else { return }
    let renderPass = view.currentRenderPassDescriptor
    let now = CACurrentMediaTime()
    let delta = max(0.001, now - lastFrameTime)
    lastFrameTime = now
    let fps = Float(1.0 / delta)
    frameIndex += 1

    let (leftSamples, rightSamples) = audioCapture.latestSamples(count: 1024)
    let analysis = computeAudioAnalysis(left: leftSamples, right: rightSamples)
    let levels = levelMeter.update(spectrum: analysis.spectrum, fps: fps)
    let globalInfo = buildGlobalInfo(time: Float(now - startTime), fps: fps, levels: levels)
    let presetFrame = equationRunner?.updateFrame(global: globalInfo) ?? preset.frameValues(levels: levels)
    let timeArrayL = buildTimeArray(samples: leftSamples)
    let timeArrayR = buildTimeArray(samples: rightSamples)
    let spectrumArray = buildSpectrumArray(from: analysis.spectrum, length: 512)

    if autoSwitchEnabled, presetLibrary.count > 1, now - lastPresetSwitchTime >= presetSwitchInterval {
      if let nextPreset = presetLibrary.next() {
        applyPreset(nextPreset)
        lastPresetSwitchTime = now
      }
    }

    updateWarpVertices(frame: presetFrame, time: Float(now - startTime), size: drawableSize, equationRunner: equationRunner)
    updateSpectrumBuffer(analysis.spectrum)

    let warpUniforms = WarpUniforms(
      resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
      time: Float(now - startTime),
      decay: presetFrame.decay,
      rms: analysis.rms,
      beat: analysis.beat,
      waveColorAlpha: presetFrame.waveColorAlpha,
      waveParams: presetFrame.waveParams,
      echoParams: presetFrame.echoParams
    )

    var warpUniformsCopy = warpUniforms
    memcpy(warpUniformBuffer.contents(), &warpUniformsCopy, MemoryLayout<WarpUniforms>.stride)

    let hueBase = computeHueBase(time: Float(now - startTime))
    let outputUniforms = OutputUniforms(
      resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
      time: Float(now - startTime),
      fShader: presetFrame.fShader,
      echoParams: presetFrame.echoParams,
      postParams0: presetFrame.postParams0,
      postParams1: presetFrame.postParams1,
      hueBase0: hueBase[0],
      hueBase1: hueBase[1],
      hueBase2: hueBase[2],
      hueBase3: hueBase[3]
    )
    var outputUniformsCopy = outputUniforms
    memcpy(outputUniformBuffer.contents(), &outputUniformsCopy, MemoryLayout<OutputUniforms>.stride)

    guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

    ensureTextures(size: drawableSize)
    guard let prevTexture = prevTexture, let targetTexture = targetTexture else { return }

    let warpPass = MTLRenderPassDescriptor()
    warpPass.colorAttachments[0].texture = targetTexture
    warpPass.colorAttachments[0].loadAction = .clear
    warpPass.colorAttachments[0].storeAction = .store
    warpPass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: warpPass) {
      encoder.setRenderPipelineState(warpPipeline)
      encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
      encoder.setFragmentBuffer(warpUniformBuffer, offset: 0, index: 0)
      encoder.setFragmentBuffer(spectrumBuffer, offset: 0, index: 1)
      encoder.setFragmentTexture(prevTexture, index: 0)
      encoder.setFragmentSamplerState(presetFrame.wrap ? samplerRepeat : samplerClamp, index: 0)
      encoder.drawIndexedPrimitives(type: .triangle,
                                    indexCount: indexCount,
                                    indexType: .uint16,
                                    indexBuffer: indexBuffer,
                                    indexBufferOffset: 0)
      encoder.endEncoding()
    }

    drawMotionVectors(commandBuffer: commandBuffer, targetTexture: targetTexture, frame: presetFrame, size: drawableSize)

    if let waveform = basicWaveform, let renderPass = waveform.renderPassDescriptor(for: targetTexture) {
      if !activeShapes.isEmpty, !customShapes.isEmpty {
        let shapeCount = min(activeShapes.count, customShapes.count)
        for i in 0..<shapeCount {
          customShapes[i].draw(
            shape: activeShapes[i],
            shapeIndex: i,
            frame: presetFrame,
            size: drawableSize,
            alpha: 1.0,
            prevTexture: prevTexture,
            samplerRepeat: samplerRepeat,
            samplerClamp: samplerClamp,
            waveformRenderer: waveform,
            equationRunner: equationRunner,
            global: globalInfo,
            commandBuffer: commandBuffer,
            renderPass: renderPass
          )
        }
      }
      if !activeWaves.isEmpty {
        let waveCount = min(activeWaves.count, customWaveforms.count)
        for i in 0..<waveCount {
          customWaveforms[i].draw(
            wave: activeWaves[i],
            waveIndex: i,
            frame: presetFrame,
            timeArrayL: timeArrayL,
            timeArrayR: timeArrayR,
            spectrumL: spectrumArray,
            spectrumR: spectrumArray,
            size: drawableSize,
            alpha: 1.0,
            waveformRenderer: waveform,
            equationRunner: equationRunner,
            global: globalInfo,
            commandBuffer: commandBuffer,
            renderPass: renderPass
          )
        }
      }
      waveform.draw(
        commandBuffer: commandBuffer,
        renderPass: renderPass,
        frame: presetFrame,
        levels: levels,
        timeArrayL: timeArrayL,
        timeArrayR: timeArrayR,
        size: drawableSize,
        time: Float(now - startTime)
      )
    }

    drawBorders(commandBuffer: commandBuffer, targetTexture: targetTexture, frame: presetFrame)

    if let renderPass = renderPass, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) {
      encoder.setRenderPipelineState(outputPipeline)
      encoder.setFragmentBuffer(outputUniformBuffer, offset: 0, index: 0)
      encoder.setFragmentTexture(targetTexture, index: 0)
      encoder.setFragmentSamplerState(presetFrame.wrap ? samplerRepeat : samplerClamp, index: 0)
      encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      encoder.endEncoding()
    }

    commandBuffer.present(drawable)
    commandBuffer.commit()

    swapTextures()
  }

  private func computeAudioAnalysis(left: [Float], right: [Float]) -> AudioAnalysis {
    if left.isEmpty || right.isEmpty {
      return AudioAnalysis(spectrum: Array(repeating: 0, count: 64), rms: 0, beat: 0)
    }
    var mono = [Float](repeating: 0, count: min(left.count, right.count))
    for i in 0..<mono.count {
      mono[i] = (left[i] + right[i]) * 0.5
    }
    return analyzer.analyze(samples: mono, bands: 64)
  }

  private func buildTimeArray(samples: [Float]) -> [Float] {
    let fftSize = 1024
    let numSamps = 512
    let clamped = samples.count >= fftSize ? Array(samples.suffix(fftSize)) : Array(repeating: 0, count: fftSize - samples.count) + samples
    var signed = [Float](repeating: 0, count: fftSize)
    for i in 0..<fftSize {
      let clampedSample = max(-1.0, min(1.0, clamped[i]))
      let byte = UInt8((clampedSample + 1.0) * 127.5)
      signed[i] = Float(Int(byte) - 128)
    }

    var output = [Float](repeating: 0, count: numSamps)
    var j = 0
    var lastIdx = 0
    for i in 0..<fftSize {
      let value = 0.5 * (signed[i] + signed[lastIdx])
      if i % 2 == 0 {
        output[j] = value
        j += 1
      }
      lastIdx = i
    }

    return output
  }

  private func buildSpectrumArray(from bands: [Float], length: Int) -> [Float] {
    guard length > 0 else { return [] }
    if bands.isEmpty {
      return [Float](repeating: 0, count: length)
    }
    if bands.count == length {
      return bands
    }

    let maxIndex = Float(bands.count - 1)
    let maxOut = Float(length - 1)
    var output = [Float](repeating: 0, count: length)
    for i in 0..<length {
      let t = maxOut > 0 ? Float(i) / maxOut : 0
      let pos = t * maxIndex
      let idx = Int(floor(pos))
      let frac = pos - Float(idx)
      let a = bands[max(0, min(bands.count - 1, idx))]
      let b = bands[max(0, min(bands.count - 1, idx + 1))]
      output[i] = a + (b - a) * frac
    }
    return output
  }

  private func updateSpectrumBuffer(_ spectrum: [Float]) {
    let ptr = spectrumBuffer.contents().bindMemory(to: Float.self, capacity: 64)
    for i in 0..<64 {
      ptr[i] = i < spectrum.count ? spectrum[i] : 0
    }
  }

  private func updateWarpVertices(frame: PresetFrame, time: Float, size: CGSize, equationRunner: JSEquationRunner?) {
    guard !vertices.isEmpty else { return }

    let texsizeX = Float(max(1, size.width))
    let texsizeY = Float(max(1, size.height))
    let aspectx: Float = texsizeY > texsizeX ? texsizeX / texsizeY : 1
    let aspecty: Float = texsizeX > texsizeY ? texsizeY / texsizeX : 1

    let warpTimeV = time * frame.warpAnimSpeed
    let warpScaleInv = 1.0 / max(frame.warpScale, 0.0001)
    let warpf0 = 11.68 + 4.0 * cos(warpTimeV * 1.413 + 10)
    let warpf1 = 8.77 + 3.0 * cos(warpTimeV * 1.113 + 7)
    let warpf2 = 10.54 + 3.0 * cos(warpTimeV * 1.233 + 3)
    let warpf3 = 11.49 + 4.0 * cos(warpTimeV * 0.933 + 5)

    equationRunner?.preparePixelEqs(frame: frame)

    let gridX = meshWidth
    let gridY = meshHeight
    let gridXf = Float(gridX)
    let gridYf = Float(gridY)

    var idx = 0
    for iy in 0...gridY {
      let y = (Float(iy) / gridYf) * 2.0 - 1.0
      for ix in 0...gridX {
        let x = (Float(ix) / gridXf) * 2.0 - 1.0
        let rad = sqrt(x * x * aspectx * aspectx + y * y * aspecty * aspecty)

        let ang = (ix == gridX / 2 && iy == gridY / 2) ? 0.0 : atan2Angle(y * aspecty, x * aspectx)

        var warp = frame.warp
        var zoom = frame.zoom
        var zoomExp = frame.zoomExp
        var cx = frame.cx
        var cy = frame.cy
        var sx = frame.sx
        var sy = frame.sy
        var dx = frame.dx
        var dy = frame.dy
        var rot = frame.rot

        if let runner = equationRunner, let pixel = runner.applyPixelEqs(
          x: x * 0.5 * aspectx + 0.5,
          y: -y * 0.5 * aspecty + 0.5,
          rad: rad,
          ang: ang,
          frame: frame
        ) {
          warp = pixel.warp
          zoom = pixel.zoom
          zoomExp = pixel.zoomExp
          cx = pixel.cx
          cy = pixel.cy
          sx = pixel.sx
          sy = pixel.sy
          dx = pixel.dx
          dy = pixel.dy
          rot = pixel.rot
        }

        let zoom2V = pow(zoom, pow(zoomExp, rad * 2.0 - 1.0))
        let zoom2Inv = 1.0 / max(0.0001, zoom2V)

        var u = x * 0.5 * aspectx * zoom2Inv + 0.5
        var v = -y * 0.5 * aspecty * zoom2Inv + 0.5

        u = (u - cx) / sx + cx
        v = (v - cy) / sy + cy

        if warp != 0 {
          u += warp * 0.0035 * sin(warpTimeV * 0.333 + warpScaleInv * (x * warpf0 - y * warpf3))
          v += warp * 0.0035 * cos(warpTimeV * 0.375 - warpScaleInv * (x * warpf2 + y * warpf1))
          u += warp * 0.0035 * cos(warpTimeV * 0.753 - warpScaleInv * (x * warpf1 - y * warpf2))
          v += warp * 0.0035 * sin(warpTimeV * 0.825 + warpScaleInv * (x * warpf0 + y * warpf3))
        }

        let u2 = u - cx
        let v2 = v - cy
        let cosRot = cos(rot)
        let sinRot = sin(rot)
        u = u2 * cosRot - v2 * sinRot + cx
        v = u2 * sinRot + v2 * cosRot + cy

        u -= dx
        v -= dy

        u = (u - 0.5) / aspectx + 0.5
        v = (v - 0.5) / aspecty + 0.5

        vertices[idx].uv = SIMD2<Float>(u, v)
        idx += 1
      }
    }

    equationRunner?.finalizePixelEqs()

    let byteCount = MemoryLayout<WarpVertex>.stride * vertices.count
    vertices.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      memcpy(vertexBuffer.contents(), baseAddress, byteCount)
    }
  }

  private static func buildMesh(width: Int, height: Int) -> (vertices: [WarpVertex], indices: [UInt16]) {
    var vertices: [WarpVertex] = []
    vertices.reserveCapacity((width + 1) * (height + 1))

    for iy in 0...height {
      let y = (Float(iy) / Float(height)) * 2.0 - 1.0
      for ix in 0...width {
        let x = (Float(ix) / Float(width)) * 2.0 - 1.0
        let pos = SIMD2<Float>(x, -y)
        vertices.append(WarpVertex(position: pos, uv: SIMD2<Float>(0.5, 0.5)))
      }
    }

    var indices: [UInt16] = []
    indices.reserveCapacity(width * height * 6)
    let rowStride = width + 1
    for iy in 0..<height {
      for ix in 0..<width {
        let a = UInt16(ix + rowStride * iy)
        let b = UInt16(ix + rowStride * (iy + 1))
        let c = UInt16(ix + 1 + rowStride * (iy + 1))
        let d = UInt16(ix + 1 + rowStride * iy)
        indices.append(contentsOf: [a, b, d, b, c, d])
      }
    }
    return (vertices, indices)
  }

  private func ensureTextures(size: CGSize) {
    if prevTexture == nil || targetTexture == nil {
      recreateTexturesIfNeeded(size: size)
    }
  }

  private func recreateTexturesIfNeeded(size: CGSize) {
    guard size.width > 0, size.height > 0 else { return }
    let width = Int(size.width)
    let height = Int(size.height)
    if prevTexture != nil && targetTexture != nil, drawableSize == size {
      return
    }

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .private

    prevTexture = device.makeTexture(descriptor: descriptor)
    targetTexture = device.makeTexture(descriptor: descriptor)
    drawableSize = size
  }

  private func swapTextures() {
    let temp = prevTexture
    prevTexture = targetTexture
    targetTexture = temp
  }

  private func computeHueBase(time: Float) -> [SIMD4<Float>] {
    var output: [SIMD4<Float>] = Array(repeating: SIMD4<Float>(1, 1, 1, 1), count: 4)
    for i in 0..<4 {
      let fi = Float(i)
      let r = 0.6 + 0.3 * sin(time * 30.0 * 0.0143 + 3.0 + fi * 21.0 + randStart.w)
      let g = 0.6 + 0.3 * sin(time * 30.0 * 0.0107 + 1.0 + fi * 13.0 + randStart.y)
      let b = 0.6 + 0.3 * sin(time * 30.0 * 0.0129 + 6.0 + fi * 9.0 + randStart.z)
      let maxShade = max(0.0001, max(r, max(g, b)))
      let nr = 0.5 + 0.5 * (r / maxShade)
      let ng = 0.5 + 0.5 * (g / maxShade)
      let nb = 0.5 + 0.5 * (b / maxShade)
      output[i] = SIMD4<Float>(nr, ng, nb, 1.0)
    }
    return output
  }

  private func overlayRenderPassDescriptor(for texture: MTLTexture) -> MTLRenderPassDescriptor {
    let renderPass = MTLRenderPassDescriptor()
    renderPass.colorAttachments[0].texture = texture
    renderPass.colorAttachments[0].loadAction = .load
    renderPass.colorAttachments[0].storeAction = .store
    return renderPass
  }

  private func drawMotionVectors(commandBuffer: MTLCommandBuffer, targetTexture: MTLTexture, frame: PresetFrame, size: CGSize) {
    let mvA = frame.motionVectorsOn > 0.5 ? frame.mvA : 0.0
    guard mvA > 0.001 else { return }
    let count = updateMotionVertices(frame: frame, size: size)
    guard count > 1 else { return }

    let renderPass = overlayRenderPassDescriptor(for: targetTexture)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }

    encoder.setRenderPipelineState(overlayPipeline)
    let byteCount = MemoryLayout<WaveVertex>.stride * count
    motionVertices.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      memcpy(motionVertexBuffer.contents(), baseAddress, byteCount)
    }

    var uniforms = WaveUniforms(thickOffset: .zero, color: SIMD4<Float>(frame.mvR, frame.mvG, frame.mvB, mvA))
    memcpy(overlayUniformBuffer.contents(), &uniforms, MemoryLayout<WaveUniforms>.stride)

    encoder.setVertexBuffer(motionVertexBuffer, offset: 0, index: 0)
    encoder.setVertexBuffer(overlayUniformBuffer, offset: 0, index: 1)
    encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: count)
    encoder.endEncoding()
  }

  private func drawBorders(commandBuffer: MTLCommandBuffer, targetTexture: MTLTexture, frame: PresetFrame) {
    let outerAlpha = frame.outerBorderColor.w
    let innerAlpha = frame.innerBorderColor.w
    guard (frame.outerBorderSize > 0 && outerAlpha > 0.0001) || (frame.innerBorderSize > 0 && innerAlpha > 0.0001) else { return }

    let renderPass = overlayRenderPassDescriptor(for: targetTexture)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
    encoder.setRenderPipelineState(overlayPipeline)

    if frame.outerBorderSize > 0 && outerAlpha > 0.0001 {
      drawBorder(encoder: encoder, color: frame.outerBorderColor, size: frame.outerBorderSize, prevSize: 0.0)
    }
    if frame.innerBorderSize > 0 && innerAlpha > 0.0001 {
      drawBorder(encoder: encoder, color: frame.innerBorderColor, size: frame.innerBorderSize, prevSize: frame.outerBorderSize)
    }

    encoder.endEncoding()
  }

  private func drawBorder(encoder: MTLRenderCommandEncoder, color: SIMD4<Float>, size: Float, prevSize: Float) {
    let count = updateBorderVertices(borderSize: size, prevBorderSize: prevSize)
    guard count > 0 else { return }
    let byteCount = MemoryLayout<WaveVertex>.stride * count
    borderVertices.withUnsafeBytes { rawBuffer in
      guard let baseAddress = rawBuffer.baseAddress else { return }
      memcpy(borderVertexBuffer.contents(), baseAddress, byteCount)
    }

    var uniforms = WaveUniforms(thickOffset: .zero, color: color)
    memcpy(overlayUniformBuffer.contents(), &uniforms, MemoryLayout<WaveUniforms>.stride)

    encoder.setVertexBuffer(borderVertexBuffer, offset: 0, index: 0)
    encoder.setVertexBuffer(overlayUniformBuffer, offset: 0, index: 1)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count)
  }

  private func updateMotionVertices(frame: PresetFrame, size: CGSize) -> Int {
    let texsizeX = Float(max(1, size.width))
    let minLen = 1.0 / texsizeX

    var nX = Int(floor(frame.mvX))
    var nY = Int(floor(frame.mvY))
    if nX <= 0 || nY <= 0 { return 0 }

    var dx = frame.mvX - Float(nX)
    var dy = frame.mvY - Float(nY)
    if nX > maxMotionGridX {
      nX = maxMotionGridX
      dx = 0
    }
    if nY > maxMotionGridY {
      nY = maxMotionGridY
      dy = 0
    }

    let dx2 = frame.mvDx
    let dy2 = frame.mvDy
    let lenMult = frame.mvL

    var count = 0
    let fxDiv = Float(nX) + dx + 0.25 - 1.0
    let fyDiv = Float(nY) + dy + 0.25 - 1.0
    if fxDiv <= 0 || fyDiv <= 0 { return 0 }

    for j in 0..<nY {
      var fy = (Float(j) + 0.25) / fyDiv
      fy -= dy2
      if fy > 0.0001 && fy < 0.9999 {
        for i in 0..<nX {
          var fx = (Float(i) + 0.25) / fxDiv
          fx += dx2
          if fx > 0.0001 && fx < 0.9999 {
            let dir = motionDir(fx: fx, fy: fy)
            var dxi = (dir.x - fx) * lenMult
            var dyi = (dir.y - fy) * lenMult
            let fdist = sqrt(dxi * dxi + dyi * dyi)
            if fdist < minLen && fdist > 0.00000001 {
              let scale = minLen / fdist
              dxi *= scale
              dyi *= scale
            } else {
              dxi = minLen
              dxi = minLen
            }

            let vx1 = 2.0 * fx - 1.0
            let vy1 = 2.0 * fy - 1.0
            let vx2 = 2.0 * (fx + dxi) - 1.0
            let vy2 = 2.0 * (fy + dyi) - 1.0

            if count + 1 < motionVertices.count {
              motionVertices[count] = WaveVertex(position: SIMD2<Float>(vx1, vy1))
              motionVertices[count + 1] = WaveVertex(position: SIMD2<Float>(vx2, vy2))
              count += 2
            }
          }
        }
      }
    }

    return count
  }

  private func motionDir(fx: Float, fy: Float) -> SIMD2<Float> {
    let gridX = meshWidth
    let gridY = meshHeight
    let gridX1 = gridX + 1

    let fyScaled = fy * Float(gridY)
    let fxScaled = fx * Float(gridX)
    let y0 = Int(floor(fyScaled))
    let x0 = Int(floor(fxScaled))
    let dy = fyScaled - Float(y0)
    let dx = fxScaled - Float(x0)

    let x1 = x0 + 1
    let y1 = y0 + 1

    func uvAt(_ x: Int, _ y: Int) -> SIMD2<Float> {
      let idx = y * gridX1 + x
      return vertices[idx].uv
    }

    var fx2 = uvAt(x0, y0).x * (1 - dx) * (1 - dy)
    var fy2 = uvAt(x0, y0).y * (1 - dx) * (1 - dy)
    fx2 += uvAt(x1, y0).x * dx * (1 - dy)
    fy2 += uvAt(x1, y0).y * dx * (1 - dy)
    fx2 += uvAt(x0, y1).x * (1 - dx) * dy
    fy2 += uvAt(x0, y1).y * (1 - dx) * dy
    fx2 += uvAt(x1, y1).x * dx * dy
    fy2 += uvAt(x1, y1).y * dx * dy

    return SIMD2<Float>(fx2, 1.0 - fy2)
  }

  private func updateBorderVertices(borderSize: Float, prevBorderSize: Float) -> Int {
    if borderSize <= 0 { return 0 }

    let width: Float = 2.0
    let height: Float = 2.0
    let widthHalf: Float = width / 2.0
    let heightHalf: Float = height / 2.0

    let prevBorderWidth = prevBorderSize / 2.0
    let borderWidth = borderSize / 2.0 + prevBorderWidth

    let prevBorderWidthWidth = prevBorderWidth * width
    let prevBorderWidthHeight = prevBorderWidth * height
    let borderWidthWidth = borderWidth * width
    let borderWidthHeight = borderWidth * height

    var count = 0
    func addTriangle(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>) {
      guard count + 2 < borderVertices.count else { return }
      borderVertices[count] = WaveVertex(position: a)
      borderVertices[count + 1] = WaveVertex(position: b)
      borderVertices[count + 2] = WaveVertex(position: c)
      count += 3
    }

    // Left
    var p1 = SIMD2<Float>(-widthHalf + prevBorderWidthWidth, -heightHalf + borderWidthHeight)
    var p2 = SIMD2<Float>(-widthHalf + prevBorderWidthWidth, heightHalf - borderWidthHeight)
    var p3 = SIMD2<Float>(-widthHalf + borderWidthWidth, heightHalf - borderWidthHeight)
    var p4 = SIMD2<Float>(-widthHalf + borderWidthWidth, -heightHalf + borderWidthHeight)
    addTriangle(p4, p2, p1)
    addTriangle(p4, p3, p2)

    // Right
    p1 = SIMD2<Float>(widthHalf - prevBorderWidthWidth, -heightHalf + borderWidthHeight)
    p2 = SIMD2<Float>(widthHalf - prevBorderWidthWidth, heightHalf - borderWidthHeight)
    p3 = SIMD2<Float>(widthHalf - borderWidthWidth, heightHalf - borderWidthHeight)
    p4 = SIMD2<Float>(widthHalf - borderWidthWidth, -heightHalf + borderWidthHeight)
    addTriangle(p1, p2, p4)
    addTriangle(p2, p3, p4)

    // Top
    p1 = SIMD2<Float>(-widthHalf + prevBorderWidthWidth, -heightHalf + prevBorderWidthHeight)
    p2 = SIMD2<Float>(-widthHalf + prevBorderWidthWidth, borderWidthHeight - heightHalf)
    p3 = SIMD2<Float>(widthHalf - prevBorderWidthWidth, borderWidthHeight - heightHalf)
    p4 = SIMD2<Float>(widthHalf - prevBorderWidthWidth, -heightHalf + prevBorderWidthHeight)
    addTriangle(p4, p2, p1)
    addTriangle(p4, p3, p2)

    // Bottom
    p1 = SIMD2<Float>(-widthHalf + prevBorderWidthWidth, heightHalf - prevBorderWidthHeight)
    p2 = SIMD2<Float>(-widthHalf + prevBorderWidthWidth, heightHalf - borderWidthHeight)
    p3 = SIMD2<Float>(widthHalf - prevBorderWidthWidth, heightHalf - borderWidthHeight)
    p4 = SIMD2<Float>(widthHalf - prevBorderWidthWidth, heightHalf - prevBorderWidthHeight)
    addTriangle(p1, p2, p4)
    addTriangle(p2, p3, p4)

    return count
  }

  private func applyPreset(_ preset: PresetDefinition) {
    self.preset.apply(baseVals: preset.baseVals)
    self.activeShapes = preset.shapes ?? []
    self.activeWaves = preset.waves ?? []
    randStart = SIMD4<Float>(Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1))
    randPreset = SIMD4<Float>(Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1), Float.random(in: 0...1))
    let initialGlobal = buildGlobalInfo(time: 0, fps: 60, levels: AudioLevelState(bass: 1, mid: 1, treb: 1, bassAtt: 1, midAtt: 1, trebAtt: 1))
    equationRunner = JSEquationRunner(preset: preset, global: initialGlobal, randStart: randStart, randPreset: randPreset)
    logger.info("Loaded preset: \(preset.name, privacy: .public)")
  }

  func setPreset(_ preset: PresetDefinition) {
    applyPreset(preset)
    lastPresetSwitchTime = CACurrentMediaTime()
  }

  func setAutoSwitching(_ enabled: Bool) {
    guard autoSwitchEnabled != enabled else { return }
    autoSwitchEnabled = enabled
    lastPresetSwitchTime = CACurrentMediaTime()
  }

  private func buildGlobalInfo(time: Float, fps: Float, levels: AudioLevelState) -> GlobalFrameInfo {
    let texsizeX = Float(max(1, drawableSize.width))
    let texsizeY = Float(max(1, drawableSize.height))
    let aspectx: Float = texsizeY > texsizeX ? texsizeX / texsizeY : 1
    let aspecty: Float = texsizeX > texsizeY ? texsizeY / texsizeX : 1
    let invAspectx: Float = 1.0 / aspectx
    let invAspecty: Float = 1.0 / aspecty
    return GlobalFrameInfo(
      frame: frameIndex,
      time: time,
      fps: fps,
      bass: levels.bass,
      bassAtt: levels.bassAtt,
      mid: levels.mid,
      midAtt: levels.midAtt,
      treb: levels.treb,
      trebAtt: levels.trebAtt,
      meshx: Float(meshWidth),
      meshy: Float(meshHeight),
      aspectx: invAspectx,
      aspecty: invAspecty,
      pixelsx: texsizeX,
      pixelsy: texsizeY
    )
  }

  private func atan2Angle(_ y: Float, _ x: Float) -> Float {
    var angle = atan2(y, x)
    if angle < 0 {
      angle += 2 * Float.pi
    }
    return angle
  }
}
