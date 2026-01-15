import Foundation
import Metal

struct ShapeVertex {
  var position: SIMD2<Float>
  var color: SIMD4<Float>
  var uv: SIMD2<Float>
}

struct ShapeUniforms {
  var textured: Float
  var padding: SIMD3<Float>
}

final class CustomShapeRenderer {
  private struct ShapeSettings {
    var enabled: Float = 0
    var sides: Float = 4
    var additive: Float = 0
    var thickoutline: Float = 0
    var textured: Float = 0
    var numInst: Float = 1
    var texZoom: Float = 1
    var texAng: Float = 0
    var x: Float = 0.5
    var y: Float = 0.5
    var rad: Float = 0.1
    var ang: Float = 0
    var r: Float = 1
    var g: Float = 0
    var b: Float = 0
    var a: Float = 1
    var r2: Float = 0
    var g2: Float = 1
    var b2: Float = 0
    var a2: Float = 0
    var borderR: Float = 1
    var borderG: Float = 1
    var borderB: Float = 1
    var borderA: Float = 0.1
  }

  private let device: MTLDevice
  private let pipelineNormal: MTLRenderPipelineState
  private let pipelineAdditive: MTLRenderPipelineState
  private let vertexBuffer: MTLBuffer
  private let indexBuffer: MTLBuffer
  private let uniformBuffer: MTLBuffer

  private let maxSides = 100
  private var vertices: [ShapeVertex]
  private var borderPositions: [SIMD2<Float>]
  private var indices: [UInt16]

  init?(device: MTLDevice, pixelFormat: MTLPixelFormat) {
    self.device = device
    self.vertices = Array(repeating: ShapeVertex(position: .zero, color: .zero, uv: .zero), count: maxSides + 2)
    self.borderPositions = Array(repeating: .zero, count: maxSides + 1)
    self.indices = Array(repeating: 0, count: maxSides * 3)

    guard let library = device.makeDefaultLibrary(),
          let vertexFunc = library.makeFunction(name: "shape_vertex"),
          let fragmentFunc = library.makeFunction(name: "shape_fragment") else {
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

    do {
      pipelineNormal = try device.makeRenderPipelineState(descriptor: descriptor)
      pipelineAdditive = try device.makeRenderPipelineState(descriptor: additiveDescriptor)
    } catch {
      return nil
    }

    let vertexLength = MemoryLayout<ShapeVertex>.stride * (maxSides + 2)
    let indexLength = MemoryLayout<UInt16>.stride * maxSides * 3
    guard let vertexBuffer = device.makeBuffer(length: vertexLength, options: .storageModeShared),
          let indexBuffer = device.makeBuffer(length: indexLength, options: .storageModeShared),
          let uniformBuffer = device.makeBuffer(length: MemoryLayout<ShapeUniforms>.stride, options: .storageModeShared) else {
      return nil
    }

    self.vertexBuffer = vertexBuffer
    self.indexBuffer = indexBuffer
    self.uniformBuffer = uniformBuffer
  }

  func draw(
    shape: PresetShape,
    shapeIndex: Int,
    frame: PresetFrame,
    size: CGSize,
    alpha: Float,
    prevTexture: MTLTexture,
    samplerRepeat: MTLSamplerState,
    samplerClamp: MTLSamplerState,
    waveformRenderer: BasicWaveformRenderer,
    equationRunner: JSEquationRunner?,
    global: GlobalFrameInfo,
    commandBuffer: MTLCommandBuffer,
    renderPass: MTLRenderPassDescriptor
  ) {
    let settings = applyDefaults(baseVals: shape.baseVals)
    guard settings.enabled != 0 else { return }

    let numInst = Int(clamp(settings.numInst, min: 1, max: 1024))
    let aspect = aspectValues(size: size)

    for inst in 0..<numInst {
      let commitUserVars = inst == numInst - 1
      let eval = equationRunner?.evaluateShape(index: shapeIndex, instance: inst, commitUserVars: commitUserVars, global: global)

      let sidesValue = eval?.sides ?? Int(clamp(settings.sides, min: 3, max: Float(maxSides)))
      let sides = Int(clamp(Float(sidesValue), min: 3, max: Float(maxSides)))
      let isTextured = eval?.textured ?? (abs(settings.textured) >= 1)
      let isAdditive = eval?.additive ?? (abs(settings.additive) >= 1)
      let isBorderThick = eval?.thickOutline ?? (abs(settings.thickoutline) >= 1)
      let borderAlpha = (eval?.borderA ?? settings.borderA) * alpha
      let hasBorder = borderAlpha > 0.0001

      let centerX = (eval?.x ?? settings.x) * 2 - 1
      let centerY = (eval?.y ?? settings.y) * -2 + 1

      let centerColor = SIMD4<Float>(
        eval?.r ?? settings.r,
        eval?.g ?? settings.g,
        eval?.b ?? settings.b,
        (eval?.a ?? settings.a) * alpha
      )
      let edgeColor = SIMD4<Float>(
        eval?.r2 ?? settings.r2,
        eval?.g2 ?? settings.g2,
        eval?.b2 ?? settings.b2,
        (eval?.a2 ?? settings.a2) * alpha
      )

      vertices[0] = ShapeVertex(position: SIMD2<Float>(centerX, centerY), color: centerColor, uv: SIMD2<Float>(0.5, 0.5))

      let quarterPi = Float.pi * 0.25
      for k in 1...sides + 1 {
        let p = Float(k - 1) / Float(sides)
        let pTwoPi = p * 2 * Float.pi
        let angSum = pTwoPi + (eval?.ang ?? settings.ang) + quarterPi
        let radius = eval?.rad ?? settings.rad
        let x = centerX + radius * cos(angSum) * aspect.aspecty
        let y = centerY + radius * sin(angSum)

        var uv = SIMD2<Float>(0.5, 0.5)
        if isTextured {
          let texAng = eval?.texAng ?? settings.texAng
          let texZoom = eval?.texZoom ?? settings.texZoom
          let texAngSum = pTwoPi + texAng + quarterPi
          uv.x = 0.5 + ((0.5 * cos(texAngSum)) / max(texZoom, 0.0001)) * aspect.aspecty
          uv.y = 0.5 + (0.5 * sin(texAngSum)) / max(texZoom, 0.0001)
        }

        vertices[k] = ShapeVertex(position: SIMD2<Float>(x, y), color: edgeColor, uv: uv)
        if hasBorder {
          borderPositions[k - 1] = SIMD2<Float>(x, y)
        }
      }

      drawFill(
        sides: sides,
        textured: isTextured,
        additive: isAdditive,
        prevTexture: prevTexture,
        samplerRepeat: samplerRepeat,
        samplerClamp: samplerClamp,
        wrap: frame.wrap,
        commandBuffer: commandBuffer,
        renderPass: renderPass
      )

      if hasBorder {
        let borderColor = SIMD4<Float>(
          eval?.borderR ?? settings.borderR,
          eval?.borderG ?? settings.borderG,
          eval?.borderB ?? settings.borderB,
          borderAlpha
        )
        waveformRenderer.drawCustomWave(
          commandBuffer: commandBuffer,
          renderPass: renderPass,
          vertices: borderPositions,
          count: sides + 1,
          color: borderColor,
          additive: isAdditive,
          drawDots: false,
          thick: isBorderThick,
          size: size
        )
      }
    }
  }

  private func drawFill(
    sides: Int,
    textured: Bool,
    additive: Bool,
    prevTexture: MTLTexture,
    samplerRepeat: MTLSamplerState,
    samplerClamp: MTLSamplerState,
    wrap: Bool,
    commandBuffer: MTLCommandBuffer,
    renderPass: MTLRenderPassDescriptor
  ) {
    let count = sides + 2
    let byteCount = MemoryLayout<ShapeVertex>.stride * count
    vertices.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      memcpy(vertexBuffer.contents(), base, byteCount)
    }

    let indexCount = sides * 3
    for i in 0..<sides {
      indices[i * 3] = 0
      indices[i * 3 + 1] = UInt16(i + 1)
      indices[i * 3 + 2] = UInt16(i + 2)
    }
    let indexByteCount = MemoryLayout<UInt16>.stride * indexCount
    indices.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      memcpy(indexBuffer.contents(), base, indexByteCount)
    }

    var uniforms = ShapeUniforms(textured: textured ? 1 : 0, padding: .zero)
    memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<ShapeUniforms>.stride)

    let pipeline = additive ? pipelineAdditive : pipelineNormal
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    encoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)
    encoder.setFragmentTexture(prevTexture, index: 0)
    let sampler = wrap ? samplerRepeat : samplerClamp
    encoder.setFragmentSamplerState(sampler, index: 0)
    encoder.drawIndexedPrimitives(type: .triangle,
                                  indexCount: indexCount,
                                  indexType: .uint16,
                                  indexBuffer: indexBuffer,
                                  indexBufferOffset: 0)
    encoder.endEncoding()
  }

  private func applyDefaults(baseVals: [String: Double]?) -> ShapeSettings {
    var settings = ShapeSettings()
    guard let baseVals else { return settings }
    settings.enabled = float(baseVals, key: "enabled", fallback: settings.enabled)
    settings.sides = float(baseVals, key: "sides", fallback: settings.sides)
    settings.additive = float(baseVals, key: "additive", fallback: settings.additive)
    settings.thickoutline = float(baseVals, key: "thickoutline", fallback: settings.thickoutline)
    settings.textured = float(baseVals, key: "textured", fallback: settings.textured)
    settings.numInst = float(baseVals, key: "num_inst", fallback: settings.numInst)
    settings.texZoom = float(baseVals, key: "tex_zoom", fallback: settings.texZoom)
    settings.texAng = float(baseVals, key: "tex_ang", fallback: settings.texAng)
    settings.x = float(baseVals, key: "x", fallback: settings.x)
    settings.y = float(baseVals, key: "y", fallback: settings.y)
    settings.rad = float(baseVals, key: "rad", fallback: settings.rad)
    settings.ang = float(baseVals, key: "ang", fallback: settings.ang)
    settings.r = float(baseVals, key: "r", fallback: settings.r)
    settings.g = float(baseVals, key: "g", fallback: settings.g)
    settings.b = float(baseVals, key: "b", fallback: settings.b)
    settings.a = float(baseVals, key: "a", fallback: settings.a)
    settings.r2 = float(baseVals, key: "r2", fallback: settings.r2)
    settings.g2 = float(baseVals, key: "g2", fallback: settings.g2)
    settings.b2 = float(baseVals, key: "b2", fallback: settings.b2)
    settings.a2 = float(baseVals, key: "a2", fallback: settings.a2)
    settings.borderR = float(baseVals, key: "border_r", fallback: settings.borderR)
    settings.borderG = float(baseVals, key: "border_g", fallback: settings.borderG)
    settings.borderB = float(baseVals, key: "border_b", fallback: settings.borderB)
    settings.borderA = float(baseVals, key: "border_a", fallback: settings.borderA)
    return settings
  }

  private func float(_ baseVals: [String: Double], key: String, fallback: Float) -> Float {
    guard let value = baseVals[key] else { return fallback }
    return Float(value)
  }

  private func clamp(_ value: Float, min: Float, max: Float) -> Float {
    return Swift.max(min, Swift.min(max, value))
  }

  private struct AspectValues {
    var aspectx: Float
    var aspecty: Float
  }

  private func aspectValues(size: CGSize) -> AspectValues {
    let texsizeX = Float(max(1, size.width))
    let texsizeY = Float(max(1, size.height))
    let aspectx: Float = texsizeY > texsizeX ? texsizeX / texsizeY : 1
    let aspecty: Float = texsizeX > texsizeY ? texsizeY / texsizeX : 1
    return AspectValues(aspectx: aspectx, aspecty: aspecty)
  }
}
