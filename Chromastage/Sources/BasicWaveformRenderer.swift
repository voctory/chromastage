import Foundation
import Metal

struct WaveVertex {
  var position: SIMD2<Float>
}

struct WaveColorVertex {
  var position: SIMD2<Float>
  var color: SIMD4<Float>
}

struct WaveUniforms {
  var thickOffset: SIMD2<Float>
  var color: SIMD4<Float>
}

final class BasicWaveformRenderer {
  private let device: MTLDevice
  private let pipelineNormal: MTLRenderPipelineState
  private let pipelineAdditive: MTLRenderPipelineState
  private let pipelineColored: MTLRenderPipelineState
  private let pipelineColoredAdditive: MTLRenderPipelineState
  private let vertexBuffer: MTLBuffer
  private let colorVertexBuffer: MTLBuffer
  private let uniformBuffer: MTLBuffer

  private var positions: [SIMD2<Float>]
  private var positions2: [SIMD2<Float>]
  private var smoothedPositions: [SIMD2<Float>]
  private var smoothedPositions2: [SIMD2<Float>]
  private var colorVertices: [WaveColorVertex]

  private let maxVerts: Int = 1024

  init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
    self.device = device
    self.positions = Array(repeating: .zero, count: maxVerts)
    self.positions2 = Array(repeating: .zero, count: maxVerts)
    self.smoothedPositions = Array(repeating: .zero, count: maxVerts)
    self.smoothedPositions2 = Array(repeating: .zero, count: maxVerts)
    self.colorVertices = Array(repeating: WaveColorVertex(position: .zero, color: .zero), count: maxVerts)

    guard let library = device.makeDefaultLibrary(),
          let vertexFunc = library.makeFunction(name: "wave_vertex"),
          let fragmentFunc = library.makeFunction(name: "wave_fragment"),
          let colorVertexFunc = library.makeFunction(name: "wave_color_vertex"),
          let colorFragmentFunc = library.makeFunction(name: "wave_color_fragment") else {
      return nil
    }

    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertexFunc
    descriptor.fragmentFunction = fragmentFunc
    descriptor.colorAttachments[0].pixelFormat = pixelFormat
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].rgbBlendOperation = .add
    descriptor.colorAttachments[0].alphaBlendOperation = .add
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

    let additiveDescriptor = descriptor.copy() as! MTLRenderPipelineDescriptor
    additiveDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
    additiveDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

    let colorDescriptor = descriptor.copy() as! MTLRenderPipelineDescriptor
    colorDescriptor.vertexFunction = colorVertexFunc
    colorDescriptor.fragmentFunction = colorFragmentFunc

    let colorAdditiveDescriptor = colorDescriptor.copy() as! MTLRenderPipelineDescriptor
    colorAdditiveDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
    colorAdditiveDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

    do {
      pipelineNormal = try device.makeRenderPipelineState(descriptor: descriptor)
      pipelineAdditive = try device.makeRenderPipelineState(descriptor: additiveDescriptor)
      pipelineColored = try device.makeRenderPipelineState(descriptor: colorDescriptor)
      pipelineColoredAdditive = try device.makeRenderPipelineState(descriptor: colorAdditiveDescriptor)
    } catch {
      return nil
    }

    let vertexLength = MemoryLayout<WaveVertex>.stride * maxVerts
    let colorVertexLength = MemoryLayout<WaveColorVertex>.stride * maxVerts
    guard let vertexBuffer = device.makeBuffer(length: vertexLength, options: .storageModeShared),
          let colorVertexBuffer = device.makeBuffer(length: colorVertexLength, options: .storageModeShared),
          let uniformBuffer = device.makeBuffer(length: MemoryLayout<WaveUniforms>.stride, options: .storageModeShared) else {
      return nil
    }

    self.vertexBuffer = vertexBuffer
    self.colorVertexBuffer = colorVertexBuffer
    self.uniformBuffer = uniformBuffer
  }

  func renderPassDescriptor(for texture: MTLTexture) -> MTLRenderPassDescriptor? {
    let renderPass = MTLRenderPassDescriptor()
    renderPass.colorAttachments[0].texture = texture
    renderPass.colorAttachments[0].loadAction = .load
    renderPass.colorAttachments[0].storeAction = .store
    return renderPass
  }

  func draw(
    commandBuffer: MTLCommandBuffer,
    renderPass: MTLRenderPassDescriptor,
    frame: PresetFrame,
    levels: AudioLevelState,
    timeArrayL: [Float],
    timeArrayR: [Float],
    size: CGSize,
    time: Float
  ) {
    guard frame.waveColorAlpha.w > 0.001 else { return }
    guard timeArrayL.count > 0, timeArrayR.count > 0 else { return }

    let texsizeX = Float(max(1, size.width))
    let texsizeY = Float(max(1, size.height))
    let aspectx: Float = texsizeY > texsizeX ? texsizeX / texsizeY : 1
    let aspecty: Float = texsizeX > texsizeY ? texsizeY / texsizeX : 1

    let waveL = processWaveform(timeArrayL, frame: frame)
    let waveR = processWaveform(timeArrayR, frame: frame)

    let vol = (levels.bass + levels.mid + levels.treb) / 3.0
    var alpha = frame.waveColorAlpha.w

    let waveMode = Int(floor(frame.waveMode)) % 8
    let wavePosX = frame.waveX * 2.0 - 1.0
    let wavePosY = frame.waveY * 2.0 - 1.0

    var fWaveParam2 = frame.waveMystery
    if (waveMode == 0 || waveMode == 1 || waveMode == 4) && (fWaveParam2 < -1 || fWaveParam2 > 1) {
      var temp = fWaveParam2 * 0.5 + 0.5
      temp -= floor(temp)
      temp = abs(temp)
      fWaveParam2 = temp * 2.0 - 1.0
    }

    var numVert = 0
    var drawSecond = false

    switch waveMode {
    case 0:
      if frame.modWaveAlphaByVolume > 0.0 {
        let alphaDiff = max(0.001, frame.modWaveAlphaEnd - frame.modWaveAlphaStart)
        alpha *= (vol - frame.modWaveAlphaStart) / alphaDiff
      }
      alpha = clamp(alpha, 0, 1)
      numVert = Int(floor(Double(waveL.count) / 2.0)) + 1
      let numVertInv = 1.0 / Float(max(1, numVert - 1))
      let sampleOffset = max(0, (waveL.count - numVert) / 2)
      for i in 0..<(numVert - 1) {
        var rad = 0.5 + 0.4 * waveR[i + sampleOffset] + fWaveParam2
        let ang = Float(i) * numVertInv * 2.0 * Float.pi + time * 0.2
        if i < numVert / 10 {
          var mix = Float(i) / Float(max(1, numVert)) / 0.1
          mix = 0.5 - 0.5 * cos(mix * Float.pi)
          let rad2 = 0.5 + 0.4 * waveR[min(i + numVert + sampleOffset, waveR.count - 1)] + fWaveParam2
          rad = (1.0 - mix) * rad2 + rad * mix
        }
        positions[i] = SIMD2<Float>(
          rad * cos(ang) * aspecty + wavePosX,
          rad * sin(ang) * aspectx + wavePosY
        )
      }
      positions[numVert - 1] = positions[0]

    case 1:
      alpha *= 1.25
      if frame.modWaveAlphaByVolume > 0.0 {
        let alphaDiff = max(0.001, frame.modWaveAlphaEnd - frame.modWaveAlphaStart)
        alpha *= (vol - frame.modWaveAlphaStart) / alphaDiff
      }
      alpha = clamp(alpha, 0, 1)
      numVert = max(1, waveL.count / 2)
      for i in 0..<numVert {
        let rad = 0.53 + 0.43 * waveR[i] + fWaveParam2
        let ang = waveL[(i + 32) % waveL.count] * 0.5 * Float.pi + time * 2.3
        positions[i] = SIMD2<Float>(
          rad * cos(ang) * aspecty + wavePosX,
          rad * sin(ang) * aspectx + wavePosY
        )
      }

    case 2:
      if texsizeX < 1024 { alpha *= 0.09 }
      else if texsizeX < 2048 { alpha *= 0.11 }
      else { alpha *= 0.13 }
      if frame.modWaveAlphaByVolume > 0.0 {
        let alphaDiff = max(0.001, frame.modWaveAlphaEnd - frame.modWaveAlphaStart)
        alpha *= (vol - frame.modWaveAlphaStart) / alphaDiff
      }
      alpha = clamp(alpha, 0, 1)
      numVert = waveL.count
      for i in 0..<waveL.count {
        positions[i] = SIMD2<Float>(
          waveR[i] * aspecty + wavePosX,
          waveL[(i + 32) % waveL.count] * aspectx + wavePosY
        )
      }

    case 3:
      if texsizeX < 1024 { alpha *= 0.15 }
      else if texsizeX < 2048 { alpha *= 0.22 }
      else { alpha *= 0.33 }
      alpha *= 1.3
      alpha *= levels.treb * levels.treb
      if frame.modWaveAlphaByVolume > 0.0 {
        let alphaDiff = max(0.001, frame.modWaveAlphaEnd - frame.modWaveAlphaStart)
        alpha *= (vol - frame.modWaveAlphaStart) / alphaDiff
      }
      alpha = clamp(alpha, 0, 1)
      numVert = waveL.count
      for i in 0..<waveL.count {
        positions[i] = SIMD2<Float>(
          waveR[i] * aspecty + wavePosX,
          waveL[(i + 32) % waveL.count] * aspectx + wavePosY
        )
      }

    case 4:
      if frame.modWaveAlphaByVolume > 0.0 {
        let alphaDiff = max(0.001, frame.modWaveAlphaEnd - frame.modWaveAlphaStart)
        alpha *= (vol - frame.modWaveAlphaStart) / alphaDiff
      }
      alpha = clamp(alpha, 0, 1)
      numVert = min(waveL.count, Int(texsizeX / 3))
      let numVertInv = 1.0 / Float(max(1, numVert))
      let sampleOffset = max(0, (waveL.count - numVert) / 2)
      let w1 = 0.45 + 0.5 * (fWaveParam2 * 0.5 + 0.5)
      let w2 = 1.0 - w1
      for i in 0..<numVert {
        var x = 2.0 * Float(i) * numVertInv + (wavePosX - 1.0) + waveR[(i + 25 + sampleOffset) % waveL.count] * 0.44
        var y = waveL[i + sampleOffset] * 0.47 + wavePosY
        if i > 1 {
          x = x * w2 + w1 * (positions[i - 1].x * 2.0 - positions[i - 2].x)
          y = y * w2 + w1 * (positions[i - 1].y * 2.0 - positions[i - 2].y)
        }
        positions[i] = SIMD2<Float>(x, y)
      }

    case 5:
      if texsizeX < 1024 { alpha *= 0.09 }
      else if texsizeX < 2048 { alpha *= 0.11 }
      else { alpha *= 0.13 }
      if frame.modWaveAlphaByVolume > 0.0 {
        let alphaDiff = max(0.001, frame.modWaveAlphaEnd - frame.modWaveAlphaStart)
        alpha *= (vol - frame.modWaveAlphaStart) / alphaDiff
      }
      alpha = clamp(alpha, 0, 1)
      let cosRot = cos(time * 0.3)
      let sinRot = sin(time * 0.3)
      numVert = waveL.count
      for i in 0..<waveL.count {
        let ioff = (i + 32) % waveL.count
        let x0 = waveR[i] * waveL[ioff] + waveL[i] * waveR[ioff]
        let y0 = waveR[i] * waveR[i] - waveL[ioff] * waveL[ioff]
        positions[i] = SIMD2<Float>(
          (x0 * cosRot - y0 * sinRot) * (aspecty + wavePosX),
          (x0 * sinRot + y0 * cosRot) * (aspectx + wavePosY)
        )
      }

    default:
      if frame.modWaveAlphaByVolume > 0.0 {
        let alphaDiff = max(0.001, frame.modWaveAlphaEnd - frame.modWaveAlphaStart)
        alpha *= (vol - frame.modWaveAlphaStart) / alphaDiff
      }
      alpha = clamp(alpha, 0, 1)
      numVert = min(waveL.count / 2, Int(texsizeX / 3))
      let sampleOffset = max(0, (waveL.count - numVert) / 2)

      let ang = Float.pi * 0.5 * fWaveParam2
      var dx = cos(ang)
      var dy = sin(ang)
      var edgex = [
        wavePosX * cos(ang + Float.pi * 0.5) - dx * 3.0,
        wavePosX * cos(ang + Float.pi * 0.5) + dx * 3.0,
      ]
      var edgey = [
        wavePosX * sin(ang + Float.pi * 0.5) - dy * 3.0,
        wavePosX * sin(ang + Float.pi * 0.5) + dy * 3.0,
      ]

      for i in 0..<2 {
        for j in 0..<4 {
          var t: Float = 0
          var clip = false
          switch j {
          case 0:
            if edgex[i] > 1.1 {
              t = (1.1 - edgex[1 - i]) / (edgex[i] - edgex[1 - i])
              clip = true
            }
          case 1:
            if edgex[i] < -1.1 {
              t = (-1.1 - edgex[1 - i]) / (edgex[i] - edgex[1 - i])
              clip = true
            }
          case 2:
            if edgey[i] > 1.1 {
              t = (1.1 - edgey[1 - i]) / (edgey[i] - edgey[1 - i])
              clip = true
            }
          case 3:
            if edgey[i] < -1.1 {
              t = (-1.1 - edgey[1 - i]) / (edgey[i] - edgey[1 - i])
              clip = true
            }
          default:
            break
          }

          if clip {
            let dxi = edgex[i] - edgex[1 - i]
            let dyi = edgey[i] - edgey[1 - i]
            edgex[i] = edgex[1 - i] + dxi * t
            edgey[i] = edgey[1 - i] + dyi * t
          }
        }
      }

      dx = (edgex[1] - edgex[0]) / Float(max(1, numVert))
      dy = (edgey[1] - edgey[0]) / Float(max(1, numVert))
      let ang2 = atan2(dy, dx)
      let perpDx = cos(ang2 + Float.pi * 0.5)
      let perpDy = sin(ang2 + Float.pi * 0.5)

      if waveMode == 6 {
        for i in 0..<numVert {
          let sample = waveL[i + sampleOffset]
          positions[i] = SIMD2<Float>(
            edgex[0] + dx * Float(i) + perpDx * 0.25 * sample,
            edgey[0] + dy * Float(i) + perpDy * 0.25 * sample
          )
        }
      } else {
        drawSecond = true
        let sep = pow(wavePosY * 0.5 + 0.5, 2)
        for i in 0..<numVert {
          let sample = waveL[i + sampleOffset]
          positions[i] = SIMD2<Float>(
            edgex[0] + dx * Float(i) + perpDx * (0.25 * sample + sep),
            edgey[0] + dy * Float(i) + perpDy * (0.25 * sample + sep)
          )
        }

        for i in 0..<numVert {
          let sample = waveR[i + sampleOffset]
          positions2[i] = SIMD2<Float>(
            edgex[0] + dx * Float(i) + perpDx * (0.25 * sample - sep),
            edgey[0] + dy * Float(i) + perpDy * (0.25 * sample - sep)
          )
        }
      }
    }

    if numVert <= 1 {
      return
    }

    for i in 0..<numVert {
      positions[i].y = -positions[i].y
    }

    let smoothedCount = smoothWave(input: positions, output: &smoothedPositions, count: numVert)

    var smoothedCount2 = 0
    if drawSecond {
      for i in 0..<numVert {
        positions2[i].y = -positions2[i].y
      }
      smoothedCount2 = smoothWave(input: positions2, output: &smoothedPositions2, count: numVert)
    }

    var r = clamp(frame.waveColorAlpha.x, 0, 1)
    var g = clamp(frame.waveColorAlpha.y, 0, 1)
    var b = clamp(frame.waveColorAlpha.z, 0, 1)
    if frame.waveBrighten > 0 {
      let maxc = max(r, max(g, b))
      if maxc > 0.01 {
        r /= maxc
        g /= maxc
        b /= maxc
      }
    }

    let color = SIMD4<Float>(r, g, b, alpha)
    let additive = frame.additiveWave > 0.5
    let drawDots = frame.waveDots > 0.5
    let thick = frame.waveThick > 0.5 || drawDots

    drawWave(
      commandBuffer: commandBuffer,
      renderPass: renderPass,
      positions: smoothedPositions,
      count: smoothedCount,
      color: color,
      texsizeX: texsizeX,
      texsizeY: texsizeY,
      additive: additive,
      drawDots: drawDots,
      thick: thick
    )

    if drawSecond && smoothedCount2 > 1 {
      drawWave(
        commandBuffer: commandBuffer,
        renderPass: renderPass,
        positions: smoothedPositions2,
        count: smoothedCount2,
        color: color,
        texsizeX: texsizeX,
        texsizeY: texsizeY,
        additive: additive,
        drawDots: drawDots,
        thick: thick
      )
    }
  }

  func drawCustomWave(
    commandBuffer: MTLCommandBuffer,
    renderPass: MTLRenderPassDescriptor,
    vertices: [SIMD2<Float>],
    count: Int,
    color: SIMD4<Float>,
    additive: Bool,
    drawDots: Bool,
    thick: Bool,
    size: CGSize
  ) {
    guard count > 0 else { return }
    let texsizeX = Float(max(1, size.width))
    let texsizeY = Float(max(1, size.height))
    drawWave(
      commandBuffer: commandBuffer,
      renderPass: renderPass,
      positions: vertices,
      count: count,
      color: color,
      texsizeX: texsizeX,
      texsizeY: texsizeY,
      additive: additive,
      drawDots: drawDots,
      thick: thick
    )
  }

  func drawCustomWaveColored(
    commandBuffer: MTLCommandBuffer,
    renderPass: MTLRenderPassDescriptor,
    vertices: [SIMD2<Float>],
    colors: [SIMD4<Float>],
    count: Int,
    additive: Bool,
    drawDots: Bool,
    thick: Bool,
    size: CGSize
  ) {
    guard count > 0 else { return }
    let texsizeX = Float(max(1, size.width))
    let texsizeY = Float(max(1, size.height))
    drawWaveColored(
      commandBuffer: commandBuffer,
      renderPass: renderPass,
      positions: vertices,
      colors: colors,
      count: count,
      texsizeX: texsizeX,
      texsizeY: texsizeY,
      additive: additive,
      drawDots: drawDots,
      thick: thick
    )
  }

  private func drawWave(
    commandBuffer: MTLCommandBuffer,
    renderPass: MTLRenderPassDescriptor,
    positions: [SIMD2<Float>],
    count: Int,
    color: SIMD4<Float>,
    texsizeX: Float,
    texsizeY: Float,
    additive: Bool,
    drawDots: Bool,
    thick: Bool
  ) {
    guard count > 0 else { return }
    let byteCount = MemoryLayout<WaveVertex>.stride * count
    positions.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      memcpy(vertexBuffer.contents(), base, byteCount)
    }

    let instances = thick ? 4 : 1
    let offsets: [SIMD2<Float>] = [
      SIMD2<Float>(0, 0),
      SIMD2<Float>(2.0 / texsizeX, 0),
      SIMD2<Float>(0, 2.0 / texsizeY),
      SIMD2<Float>(2.0 / texsizeX, 2.0 / texsizeY),
    ]

    let pipeline = additive ? pipelineAdditive : pipelineNormal

    for i in 0..<instances {
      var uniforms = WaveUniforms(thickOffset: offsets[i], color: color)
      memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<WaveUniforms>.stride)

      if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        let primitive: MTLPrimitiveType = drawDots ? .point : .lineStrip
        encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: count)
        encoder.endEncoding()
      }
    }
  }

  private func drawWaveColored(
    commandBuffer: MTLCommandBuffer,
    renderPass: MTLRenderPassDescriptor,
    positions: [SIMD2<Float>],
    colors: [SIMD4<Float>],
    count: Int,
    texsizeX: Float,
    texsizeY: Float,
    additive: Bool,
    drawDots: Bool,
    thick: Bool
  ) {
    guard count > 0 else { return }
    let clampedCount = min(count, maxVerts)
    for i in 0..<clampedCount {
      colorVertices[i] = WaveColorVertex(position: positions[i], color: colors[i])
    }

    let byteCount = MemoryLayout<WaveColorVertex>.stride * clampedCount
    colorVertices.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      memcpy(colorVertexBuffer.contents(), base, byteCount)
    }

    let instances = thick ? 4 : 1
    let offsets: [SIMD2<Float>] = [
      SIMD2<Float>(0, 0),
      SIMD2<Float>(2.0 / texsizeX, 0),
      SIMD2<Float>(0, 2.0 / texsizeY),
      SIMD2<Float>(2.0 / texsizeX, 2.0 / texsizeY),
    ]

    let pipeline = additive ? pipelineColoredAdditive : pipelineColored

    for i in 0..<instances {
      var uniforms = WaveUniforms(thickOffset: offsets[i], color: SIMD4<Float>(0, 0, 0, 0))
      memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<WaveUniforms>.stride)

      if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) {
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(colorVertexBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 1)
        let primitive: MTLPrimitiveType = drawDots ? .point : .lineStrip
        encoder.drawPrimitives(type: primitive, vertexStart: 0, vertexCount: clampedCount)
        encoder.endEncoding()
      }
    }
  }

  private func processWaveform(_ timeArray: [Float], frame: PresetFrame) -> [Float] {
    let scale = frame.waveParams.x / 128.0
    let smooth = frame.waveSmoothing
    let smooth2 = scale * (1.0 - smooth)
    var waveform = [Float](repeating: 0, count: timeArray.count)
    if timeArray.isEmpty { return waveform }
    waveform[0] = timeArray[0] * scale
    if timeArray.count > 1 {
      for i in 1..<timeArray.count {
        waveform[i] = timeArray[i] * smooth2 + waveform[i - 1] * smooth
      }
    }
    return waveform
  }

  private func smoothWave(input: [SIMD2<Float>], output: inout [SIMD2<Float>], count: Int) -> Int {
    let c1: Float = -0.15
    let c2: Float = 1.15
    let c3: Float = 1.15
    let c4: Float = -0.15
    let invSum = 1.0 / (c1 + c2 + c3 + c4)

    var j = 0
    var iBelow = 0
    var iAbove = 0
    var iAbove2 = 1

    for i in 0..<(count - 1) {
      iAbove = iAbove2
      iAbove2 = min(count - 1, i + 2)

      output[j] = input[i]

      let p0 = input[iBelow]
      let p1 = input[i]
      let p2 = input[iAbove]
      let p3 = input[iAbove2]
      let smoothed = (p0 * c1 + p1 * c2 + p2 * c3 + p3 * c4) * invSum
      output[j + 1] = smoothed

      iBelow = i
      j += 2
    }

    output[j] = input[count - 1]
    return j + 1
  }

  private func clamp(_ value: Float, _ minValue: Float, _ maxValue: Float) -> Float {
    return min(maxValue, max(minValue, value))
  }
}
