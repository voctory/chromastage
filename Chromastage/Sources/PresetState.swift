import Foundation

struct PresetFrame {
  var decay: Float
  var warp: Float
  var warpAnimSpeed: Float
  var warpScale: Float
  var zoom: Float
  var zoomExp: Float
  var rot: Float
  var cx: Float
  var cy: Float
  var sx: Float
  var sy: Float
  var dx: Float
  var dy: Float
  var wrap: Bool
  var waveColorAlpha: SIMD4<Float>
  var waveParams: SIMD4<Float>
  var postParams0: SIMD4<Float>
  var postParams1: SIMD4<Float>
  var echoParams: SIMD4<Float>
  var waveMode: Float
  var waveX: Float
  var waveY: Float
  var waveMystery: Float
  var modWaveAlphaByVolume: Float
  var modWaveAlphaStart: Float
  var modWaveAlphaEnd: Float
  var additiveWave: Float
  var waveDots: Float
  var waveThick: Float
  var waveBrighten: Float
  var waveSmoothing: Float
  var motionVectorsOn: Float
  var mvX: Float
  var mvY: Float
  var mvDx: Float
  var mvDy: Float
  var mvL: Float
  var mvR: Float
  var mvG: Float
  var mvB: Float
  var mvA: Float
  var outerBorderSize: Float
  var outerBorderColor: SIMD4<Float>
  var innerBorderSize: Float
  var innerBorderColor: SIMD4<Float>
  var fShader: Float
  var b1n: Float
  var b2n: Float
  var b3n: Float
  var b1x: Float
  var b2x: Float
  var b3x: Float
  var b1ed: Float
  var nEchoWrapX: Float
  var nEchoWrapY: Float
  var nWrapModeX: Float
  var nWrapModeY: Float
  var rating: Float
}

struct PresetState {
  var baseDecay: Float = 0.98
  var baseWarp: Float = 1.0
  var baseWarpAnimSpeed: Float = 1.0
  var baseWarpScale: Float = 1.0
  var baseZoom: Float = 1.0
  var baseZoomExp: Float = 1.0
  var baseRot: Float = 0.0
  var baseCx: Float = 0.5
  var baseCy: Float = 0.5
  var baseSx: Float = 1.0
  var baseSy: Float = 1.0
  var baseDx: Float = 0.0
  var baseDy: Float = 0.0
  var baseWrap: Bool = true
  var baseWaveColorAlpha: SIMD4<Float> = SIMD4<Float>(1.0, 1.0, 1.0, 0.8)
  var baseWaveParams: SIMD4<Float> = SIMD4<Float>(1.0, 0.0, 1.0, 0.0)
  var basePostParams0: SIMD4<Float> = SIMD4<Float>(2.0, 0.0, 0.0, 0.0)
  var basePostParams1: SIMD4<Float> = SIMD4<Float>(0.0, 0.0, 0.0, 0.0)
  var baseEchoParams: SIMD4<Float> = SIMD4<Float>(0.0, 2.0, 0.0, 0.0)
  var baseWaveMode: Float = 0.0
  var baseWaveX: Float = 0.5
  var baseWaveY: Float = 0.5
  var baseWaveMystery: Float = 0.0
  var baseModWaveAlphaByVolume: Float = 0.0
  var baseModWaveAlphaStart: Float = 0.75
  var baseModWaveAlphaEnd: Float = 0.95
  var baseAdditiveWave: Float = 0.0
  var baseWaveDots: Float = 0.0
  var baseWaveThick: Float = 0.0
  var baseWaveBrighten: Float = 1.0
  var baseWaveSmoothing: Float = 0.75
  var baseMotionVectorsOn: Float = 1.0
  var baseMvX: Float = 12.0
  var baseMvY: Float = 9.0
  var baseMvDx: Float = 0.0
  var baseMvDy: Float = 0.0
  var baseMvL: Float = 0.9
  var baseMvR: Float = 1.0
  var baseMvG: Float = 1.0
  var baseMvB: Float = 1.0
  var baseMvA: Float = 1.0
  var baseOuterBorderSize: Float = 0.01
  var baseOuterBorderColor: SIMD4<Float> = SIMD4<Float>(0.0, 0.0, 0.0, 0.0)
  var baseInnerBorderSize: Float = 0.01
  var baseInnerBorderColor: SIMD4<Float> = SIMD4<Float>(0.25, 0.25, 0.25, 0.0)
  var baseFShader: Float = 0.0
  var baseB1n: Float = 0.0
  var baseB2n: Float = 0.0
  var baseB3n: Float = 0.0
  var baseB1x: Float = 1.0
  var baseB2x: Float = 1.0
  var baseB3x: Float = 1.0
  var baseB1ed: Float = 0.25
  var baseNEchoWrapX: Float = 0.0
  var baseNEchoWrapY: Float = 0.0
  var baseNWrapModeX: Float = 0.0
  var baseNWrapModeY: Float = 0.0
  var baseRating: Float = 0.0

  func frameValues(levels _: AudioLevelState) -> PresetFrame {
    let frame = PresetFrame(
      decay: baseDecay,
      warp: baseWarp,
      warpAnimSpeed: baseWarpAnimSpeed,
      warpScale: baseWarpScale,
      zoom: baseZoom,
      zoomExp: baseZoomExp,
      rot: baseRot,
      cx: baseCx,
      cy: baseCy,
      sx: baseSx,
      sy: baseSy,
      dx: baseDx,
      dy: baseDy,
      wrap: baseWrap,
      waveColorAlpha: baseWaveColorAlpha,
      waveParams: baseWaveParams,
      postParams0: basePostParams0,
      postParams1: basePostParams1,
      echoParams: baseEchoParams,
      waveMode: baseWaveMode,
      waveX: baseWaveX,
      waveY: baseWaveY,
      waveMystery: baseWaveMystery,
      modWaveAlphaByVolume: baseModWaveAlphaByVolume,
      modWaveAlphaStart: baseModWaveAlphaStart,
      modWaveAlphaEnd: baseModWaveAlphaEnd,
      additiveWave: baseAdditiveWave,
      waveDots: baseWaveDots,
      waveThick: baseWaveThick,
      waveBrighten: baseWaveBrighten,
      waveSmoothing: baseWaveSmoothing,
      motionVectorsOn: baseMotionVectorsOn,
      mvX: baseMvX,
      mvY: baseMvY,
      mvDx: baseMvDx,
      mvDy: baseMvDy,
      mvL: baseMvL,
      mvR: baseMvR,
      mvG: baseMvG,
      mvB: baseMvB,
      mvA: baseMvA,
      outerBorderSize: baseOuterBorderSize,
      outerBorderColor: baseOuterBorderColor,
      innerBorderSize: baseInnerBorderSize,
      innerBorderColor: baseInnerBorderColor,
      fShader: baseFShader,
      b1n: baseB1n,
      b2n: baseB2n,
      b3n: baseB3n,
      b1x: baseB1x,
      b2x: baseB2x,
      b3x: baseB3x,
      b1ed: baseB1ed,
      nEchoWrapX: baseNEchoWrapX,
      nEchoWrapY: baseNEchoWrapY,
      nWrapModeX: baseNWrapModeX,
      nWrapModeY: baseNWrapModeY,
      rating: baseRating
    )
    return frame
  }

  mutating func apply(baseVals: [String: Double]) {
    baseDecay = float(baseVals, key: "decay", fallback: baseDecay)
    baseWarp = float(baseVals, key: "warp", fallback: baseWarp)
    baseWarpAnimSpeed = float(baseVals, key: "warpanimspeed", fallback: baseWarpAnimSpeed)
    baseWarpScale = float(baseVals, key: "warpscale", fallback: baseWarpScale)
    baseZoom = float(baseVals, key: "zoom", fallback: baseZoom)
    baseZoomExp = float(baseVals, key: "zoomexp", fallback: baseZoomExp)
    baseRot = float(baseVals, key: "rot", fallback: baseRot)
    baseCx = float(baseVals, key: "cx", fallback: baseCx)
    baseCy = float(baseVals, key: "cy", fallback: baseCy)
    baseSx = float(baseVals, key: "sx", fallback: baseSx)
    baseSy = float(baseVals, key: "sy", fallback: baseSy)
    baseDx = float(baseVals, key: "dx", fallback: baseDx)
    baseDy = float(baseVals, key: "dy", fallback: baseDy)
    baseWrap = (baseVals["wrap"] ?? (baseWrap ? 1 : 0)) != 0

    let waveR = float(baseVals, key: "wave_r", fallback: baseWaveColorAlpha.x)
    let waveG = float(baseVals, key: "wave_g", fallback: baseWaveColorAlpha.y)
    let waveB = float(baseVals, key: "wave_b", fallback: baseWaveColorAlpha.z)
    let waveA = float(baseVals, key: "wave_a", fallback: baseWaveColorAlpha.w)
    baseWaveColorAlpha = SIMD4<Float>(waveR, waveG, waveB, waveA)

    let waveScale = float(baseVals, key: "wave_scale", fallback: baseWaveParams.x)

    baseWaveMode = float(baseVals, key: "wave_mode", fallback: baseWaveMode)
    baseWaveX = float(baseVals, key: "wave_x", fallback: baseWaveX)
    baseWaveY = float(baseVals, key: "wave_y", fallback: baseWaveY)
    baseWaveMystery = float(baseVals, key: "wave_mystery", fallback: baseWaveMystery)
    baseModWaveAlphaByVolume = float(baseVals, key: "modwavealphabyvolume", fallback: baseModWaveAlphaByVolume)
    baseModWaveAlphaStart = float(baseVals, key: "modwavealphastart", fallback: baseModWaveAlphaStart)
    baseModWaveAlphaEnd = float(baseVals, key: "modwavealphaend", fallback: baseModWaveAlphaEnd)
    baseAdditiveWave = float(baseVals, key: "additivewave", fallback: baseAdditiveWave)
    baseWaveDots = float(baseVals, key: "wave_dots", fallback: baseWaveDots)
    baseWaveThick = float(baseVals, key: "wave_thick", fallback: baseWaveThick)
    baseWaveBrighten = float(baseVals, key: "wave_brighten", fallback: baseWaveBrighten)
    baseWaveSmoothing = float(baseVals, key: "wave_smoothing", fallback: baseWaveSmoothing)
    baseWaveParams = SIMD4<Float>(waveScale, baseWaveThick, baseWaveBrighten, 0.0)

    let gammaAdj = float(baseVals, key: "gammaadj", fallback: basePostParams0.x)
    let brighten = boolFloat(baseVals, key: "brighten", fallback: basePostParams0.y)
    let darken = boolFloat(baseVals, key: "darken", fallback: basePostParams0.z)
    let invert = boolFloat(baseVals, key: "invert", fallback: basePostParams0.w)
    basePostParams0 = SIMD4<Float>(gammaAdj, brighten, darken, invert)

    let solarize = boolFloat(baseVals, key: "solarize", fallback: basePostParams1.x)
    let redBlue = boolFloat(baseVals, key: "red_blue", fallback: basePostParams1.y)
    let darkenCenter = boolFloat(baseVals, key: "darken_center", fallback: basePostParams1.z)
    basePostParams1 = SIMD4<Float>(solarize, redBlue, darkenCenter, 0.0)

    let echoAlpha = float(baseVals, key: "echo_alpha", fallback: baseEchoParams.x)
    let echoZoom = float(baseVals, key: "echo_zoom", fallback: baseEchoParams.y)
    let echoOrient = float(baseVals, key: "echo_orient", fallback: baseEchoParams.z)
    baseEchoParams = SIMD4<Float>(echoAlpha, echoZoom, echoOrient, 0.0)

    baseMotionVectorsOn = boolFloat(baseVals, key: "bmotionvectorson", fallback: baseMotionVectorsOn)
    baseMvX = float(baseVals, key: "mv_x", fallback: baseMvX)
    baseMvY = float(baseVals, key: "mv_y", fallback: baseMvY)
    baseMvDx = float(baseVals, key: "mv_dx", fallback: baseMvDx)
    baseMvDy = float(baseVals, key: "mv_dy", fallback: baseMvDy)
    baseMvL = float(baseVals, key: "mv_l", fallback: baseMvL)
    baseMvR = float(baseVals, key: "mv_r", fallback: baseMvR)
    baseMvG = float(baseVals, key: "mv_g", fallback: baseMvG)
    baseMvB = float(baseVals, key: "mv_b", fallback: baseMvB)
    baseMvA = float(baseVals, key: "mv_a", fallback: baseMvA)

    let obSize = float(baseVals, key: "ob_size", fallback: baseOuterBorderSize)
    let obR = float(baseVals, key: "ob_r", fallback: baseOuterBorderColor.x)
    let obG = float(baseVals, key: "ob_g", fallback: baseOuterBorderColor.y)
    let obB = float(baseVals, key: "ob_b", fallback: baseOuterBorderColor.z)
    let obA = float(baseVals, key: "ob_a", fallback: baseOuterBorderColor.w)
    baseOuterBorderSize = obSize
    baseOuterBorderColor = SIMD4<Float>(obR, obG, obB, obA)

    let ibSize = float(baseVals, key: "ib_size", fallback: baseInnerBorderSize)
    let ibR = float(baseVals, key: "ib_r", fallback: baseInnerBorderColor.x)
    let ibG = float(baseVals, key: "ib_g", fallback: baseInnerBorderColor.y)
    let ibB = float(baseVals, key: "ib_b", fallback: baseInnerBorderColor.z)
    let ibA = float(baseVals, key: "ib_a", fallback: baseInnerBorderColor.w)
    baseInnerBorderSize = ibSize
    baseInnerBorderColor = SIMD4<Float>(ibR, ibG, ibB, ibA)

    baseFShader = float(baseVals, key: "fshader", fallback: baseFShader)
    baseB1n = float(baseVals, key: "b1n", fallback: baseB1n)
    baseB2n = float(baseVals, key: "b2n", fallback: baseB2n)
    baseB3n = float(baseVals, key: "b3n", fallback: baseB3n)
    baseB1x = float(baseVals, key: "b1x", fallback: baseB1x)
    baseB2x = float(baseVals, key: "b2x", fallback: baseB2x)
    baseB3x = float(baseVals, key: "b3x", fallback: baseB3x)
    baseB1ed = float(baseVals, key: "b1ed", fallback: baseB1ed)

    baseNEchoWrapX = float(baseVals, key: "nechowrap_x", fallback: baseNEchoWrapX)
    baseNEchoWrapY = float(baseVals, key: "nechowrap_y", fallback: baseNEchoWrapY)
    baseNWrapModeX = float(baseVals, key: "nwrapmode_x", fallback: baseNWrapModeX)
    baseNWrapModeY = float(baseVals, key: "nwrapmode_y", fallback: baseNWrapModeY)

    baseRating = float(baseVals, key: "rating", fallback: baseRating)
  }

  private func float(_ baseVals: [String: Double], key: String, fallback: Float) -> Float {
    guard let value = baseVals[key] else { return fallback }
    return Float(value)
  }

  private func boolFloat(_ baseVals: [String: Double], key: String, fallback: Float) -> Float {
    guard let value = baseVals[key] else { return fallback }
    return value == 0 ? 0 : 1
  }
}
