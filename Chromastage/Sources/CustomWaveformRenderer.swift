import Foundation
import Metal

final class CustomWaveformRenderer {
  private struct WaveSettings {
    var enabled: Float = 0
    var samples: Float = 512
    var sep: Float = 0
    var scaling: Float = 1
    var smoothing: Float = 0.5
    var r: Float = 1
    var g: Float = 1
    var b: Float = 1
    var a: Float = 1
    var spectrum: Float = 0
    var usedots: Float = 0
    var thick: Float = 0
    var additive: Float = 0
  }

  private let maxSamples = 512
  private var pointsLeft: [Float]
  private var pointsRight: [Float]
  private var positions: [SIMD2<Float>]
  private var smoothedPositions: [SIMD2<Float>]
  private var colors: [SIMD4<Float>]
  private var smoothedColors: [SIMD4<Float>]

  init() {
    pointsLeft = [Float](repeating: 0, count: maxSamples)
    pointsRight = [Float](repeating: 0, count: maxSamples)
    positions = [SIMD2<Float>](repeating: .zero, count: maxSamples)
    smoothedPositions = [SIMD2<Float>](repeating: .zero, count: maxSamples * 2 - 1)
    colors = [SIMD4<Float>](repeating: .zero, count: maxSamples)
    smoothedColors = [SIMD4<Float>](repeating: .zero, count: maxSamples * 2 - 1)
  }

  func draw(
    wave: PresetWave,
    waveIndex: Int,
    frame: PresetFrame,
    timeArrayL: [Float],
    timeArrayR: [Float],
    spectrumL: [Float],
    spectrumR: [Float],
    size: CGSize,
    alpha: Float,
    waveformRenderer: BasicWaveformRenderer,
    equationRunner: JSEquationRunner?,
    global: GlobalFrameInfo,
    commandBuffer: MTLCommandBuffer,
    renderPass: MTLRenderPassDescriptor
  ) {
    let settings = applyDefaults(baseVals: wave.baseVals)
    guard settings.enabled != 0 else { return }

    let hasPointEqs = !(wave.point_eqs_str ?? "").isEmpty
    let eval = equationRunner?.evaluateWaveFrame(
      index: waveIndex,
      commitUserVars: !hasPointEqs,
      global: global
    )

    let maxSamples = self.maxSamples
    var samples = eval?.samples ?? Int(floor(settings.samples))
    if samples > maxSamples { samples = maxSamples }
    let sep = eval?.sep ?? Int(floor(settings.sep))
    samples -= sep
    let drawDotsSetting = eval?.usedots ?? (settings.usedots != 0)
    let needsAtLeast = drawDotsSetting ? 1 : 2
    guard samples >= needsAtLeast else { return }

    let useSpectrum = eval?.spectrum ?? (settings.spectrum != 0)
    let scaling = eval?.scaling ?? settings.scaling
    let smoothing = eval?.smoothing ?? settings.smoothing
    let scale = (useSpectrum ? 0.15 : 0.004) * scaling * frame.waveParams.x

    let pointsSrcL = useSpectrum ? spectrumL : timeArrayL
    let pointsSrcR = useSpectrum ? spectrumR : timeArrayR

    let j0: Int
    let j1: Int
    let t: Float
    if useSpectrum {
      j0 = 0
      j1 = 0
      t = Float(maxSamples - sep) / Float(samples)
    } else {
      j0 = max(0, (maxSamples - samples) / 2 - sep / 2)
      j1 = max(0, (maxSamples - samples) / 2 + sep / 2)
      t = 1
    }

    let smoothingClamped = max(0, min(1, smoothing))
    let mix1 = sqrt(smoothingClamped * 0.98)
    let mix2 = 1 - mix1

    pointsLeft[0] = sample(pointsSrcL, index: j0)
    pointsRight[0] = sample(pointsSrcR, index: j1)
    if samples > 1 {
      for j in 1..<samples {
        let idxL = Int(floor(Float(j) * t)) + j0
        let idxR = Int(floor(Float(j) * t)) + j1
        let left = sample(pointsSrcL, index: idxL)
        let right = sample(pointsSrcR, index: idxR)
        pointsLeft[j] = left * mix2 + pointsLeft[j - 1] * mix1
        pointsRight[j] = right * mix2 + pointsRight[j - 1] * mix1
      }
      if samples > 2 {
        for j in stride(from: samples - 2, through: 0, by: -1) {
          pointsLeft[j] = pointsLeft[j] * mix2 + pointsLeft[j + 1] * mix1
          pointsRight[j] = pointsRight[j] * mix2 + pointsRight[j + 1] * mix1
        }
      }
    }

    for j in 0..<samples {
      pointsLeft[j] *= scale
      pointsRight[j] *= scale
    }

    let texsizeX = Float(max(1, size.width))
    let texsizeY = Float(max(1, size.height))
    let aspectx: Float = texsizeY > texsizeX ? texsizeX / texsizeY : 1
    let aspecty: Float = texsizeX > texsizeY ? texsizeY / texsizeX : 1
    let invAspectx: Float = 1.0 / aspectx
    let invAspecty: Float = 1.0 / aspecty
    let usePointColors = hasPointEqs && equationRunner != nil

    for j in 0..<samples {
      var x = 0.5 + pointsLeft[j]
      var y = 0.5 + pointsRight[j]

      if let runner = equationRunner, hasPointEqs {
        let sample = samples > 1 ? Float(j) / Float(samples - 1) : 0
        let basePoint = WavePointResult(
          x: Float(x),
          y: Float(y),
          r: eval?.r ?? settings.r,
          g: eval?.g ?? settings.g,
          b: eval?.b ?? settings.b,
          a: eval?.a ?? settings.a
        )
        let evalPoint = runner.evaluateWavePoint(
          index: waveIndex,
          sample: sample,
          value1: pointsLeft[j],
          value2: pointsRight[j],
          base: basePoint
        )
        x = evalPoint.x
        y = evalPoint.y
        if usePointColors {
          colors[j] = SIMD4<Float>(evalPoint.r, evalPoint.g, evalPoint.b, evalPoint.a * alpha)
        }
      }

      let xClip = (x * 2 - 1) * invAspectx
      let yClip = (y * -2 + 1) * invAspecty
      positions[j] = SIMD2<Float>(xClip, yClip)
    }

    if hasPointEqs, equationRunner != nil {
      equationRunner?.finalizeWaveUserVars(index: waveIndex)
    }

    let color = SIMD4<Float>(
      eval?.r ?? settings.r,
      eval?.g ?? settings.g,
      eval?.b ?? settings.b,
      (eval?.a ?? settings.a) * alpha
    )
    let drawDots = drawDotsSetting
    let thick = eval?.thick ?? (settings.thick != 0)
    let additive = eval?.additive ?? (settings.additive != 0)

    if usePointColors {
      if drawDots {
        waveformRenderer.drawCustomWaveColored(
          commandBuffer: commandBuffer,
          renderPass: renderPass,
          vertices: positions,
          colors: colors,
          count: samples,
          additive: additive,
          drawDots: true,
          thick: thick,
          size: size
        )
        return
      }

      let smoothedCount = smoothPositionsAndColors(inputCount: samples)
      waveformRenderer.drawCustomWaveColored(
        commandBuffer: commandBuffer,
        renderPass: renderPass,
        vertices: smoothedPositions,
        colors: smoothedColors,
        count: smoothedCount,
        additive: additive,
        drawDots: false,
        thick: thick,
        size: size
      )
      return
    }

    if drawDots {
      waveformRenderer.drawCustomWave(
        commandBuffer: commandBuffer,
        renderPass: renderPass,
        vertices: positions,
        count: samples,
        color: color,
        additive: additive,
        drawDots: true,
        thick: thick,
        size: size
      )
      return
    }

    let smoothedCount = smoothPositions(inputCount: samples)
    waveformRenderer.drawCustomWave(
      commandBuffer: commandBuffer,
      renderPass: renderPass,
      vertices: smoothedPositions,
      count: smoothedCount,
      color: color,
      additive: additive,
      drawDots: false,
      thick: thick,
      size: size
    )
  }

  private func applyDefaults(baseVals: [String: Double]?) -> WaveSettings {
    var settings = WaveSettings()
    guard let baseVals else { return settings }
    settings.enabled = float(baseVals, key: "enabled", fallback: settings.enabled)
    settings.samples = float(baseVals, key: "samples", fallback: settings.samples)
    settings.sep = float(baseVals, key: "sep", fallback: settings.sep)
    settings.scaling = float(baseVals, key: "scaling", fallback: settings.scaling)
    settings.smoothing = float(baseVals, key: "smoothing", fallback: settings.smoothing)
    settings.r = float(baseVals, key: "r", fallback: settings.r)
    settings.g = float(baseVals, key: "g", fallback: settings.g)
    settings.b = float(baseVals, key: "b", fallback: settings.b)
    settings.a = float(baseVals, key: "a", fallback: settings.a)
    settings.spectrum = float(baseVals, key: "spectrum", fallback: settings.spectrum)
    settings.usedots = float(baseVals, key: "usedots", fallback: settings.usedots)
    settings.thick = float(baseVals, key: "thick", fallback: settings.thick)
    settings.additive = float(baseVals, key: "additive", fallback: settings.additive)
    return settings
  }

  private func float(_ baseVals: [String: Double], key: String, fallback: Float) -> Float {
    guard let value = baseVals[key] else { return fallback }
    return Float(value)
  }

  private func sample(_ array: [Float], index: Int) -> Float {
    if array.isEmpty { return 0 }
    let idx = max(0, min(array.count - 1, index))
    return array[idx]
  }

  private func smoothPositionsAndColors(inputCount: Int) -> Int {
    guard inputCount > 1 else {
      if inputCount == 1 {
        smoothedPositions[0] = positions[0]
        smoothedColors[0] = colors[0]
      }
      return inputCount
    }

    let c1: Float = -0.15
    let c2: Float = 1.15
    let c3: Float = 1.15
    let c4: Float = -0.15
    let invSum: Float = 1.0 / (c1 + c2 + c3 + c4)

    var j = 0
    var iBelow = 0
    var iAbove2 = 1
    for i in 0..<(inputCount - 1) {
      let iAbove = iAbove2
      iAbove2 = min(inputCount - 1, i + 2)

      smoothedPositions[j] = positions[i]
      let blend = (positions[iBelow] * c1 + positions[i] * c2 + positions[iAbove] * c3 + positions[iAbove2] * c4) * invSum
      smoothedPositions[j + 1] = blend

      smoothedColors[j] = colors[i]
      smoothedColors[j + 1] = colors[i]

      iBelow = i
      j += 2
    }

    smoothedPositions[j] = positions[inputCount - 1]
    smoothedColors[j] = colors[inputCount - 1]
    return inputCount * 2 - 1
  }

  private func smoothPositions(inputCount: Int) -> Int {
    guard inputCount > 1 else {
      if inputCount == 1 {
        smoothedPositions[0] = positions[0]
      }
      return inputCount
    }

    let c1: Float = -0.15
    let c2: Float = 1.15
    let c3: Float = 1.15
    let c4: Float = -0.15
    let invSum: Float = 1.0 / (c1 + c2 + c3 + c4)

    var j = 0
    var iBelow = 0
    var iAbove2 = 1
    for i in 0..<(inputCount - 1) {
      let iAbove = iAbove2
      iAbove2 = min(inputCount - 1, i + 2)

      smoothedPositions[j] = positions[i]
      let blend = (positions[iBelow] * c1 + positions[i] * c2 + positions[iAbove] * c3 + positions[iAbove2] * c4) * invSum
      smoothedPositions[j + 1] = blend

      iBelow = i
      j += 2
    }

    smoothedPositions[j] = positions[inputCount - 1]
    return inputCount * 2 - 1
  }
}
