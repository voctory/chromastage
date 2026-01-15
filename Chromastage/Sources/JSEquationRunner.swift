import Foundation
import JavaScriptCore

struct GlobalFrameInfo {
  var frame: Int
  var time: Float
  var fps: Float
  var bass: Float
  var bassAtt: Float
  var mid: Float
  var midAtt: Float
  var treb: Float
  var trebAtt: Float
  var meshx: Float
  var meshy: Float
  var aspectx: Float
  var aspecty: Float
  var pixelsx: Float
  var pixelsy: Float
}

struct PixelWarpResult {
  var warp: Float
  var zoom: Float
  var zoomExp: Float
  var rot: Float
  var cx: Float
  var cy: Float
  var sx: Float
  var sy: Float
  var dx: Float
  var dy: Float
}

struct ShapeEvalResult {
  var sides: Int
  var x: Float
  var y: Float
  var rad: Float
  var ang: Float
  var r: Float
  var g: Float
  var b: Float
  var a: Float
  var r2: Float
  var g2: Float
  var b2: Float
  var a2: Float
  var borderR: Float
  var borderG: Float
  var borderB: Float
  var borderA: Float
  var thickOutline: Bool
  var textured: Bool
  var texZoom: Float
  var texAng: Float
  var additive: Bool
}

struct WaveEvalResult {
  var samples: Int
  var sep: Int
  var scaling: Float
  var smoothing: Float
  var spectrum: Bool
  var r: Float
  var g: Float
  var b: Float
  var a: Float
  var usedots: Bool
  var thick: Bool
  var additive: Bool
}

struct WavePointResult {
  var x: Float
  var y: Float
  var r: Float
  var g: Float
  var b: Float
  var a: Float
}

final class JSEquationRunner {
  private static let presetBaseScript = """
  var window = this;
  var EPSILON = 0.00001;
  window.sqr = function sqr(x) { return x * x; };
  window.sqrt = function sqrt(x) { return Math.sqrt(Math.abs(x)); };
  window.log10 = function log10(val) { return Math.log(val) * Math.LOG10E; };
  window.sign = function sign(x) { return x > 0 ? 1 : x < 0 ? -1 : 0; };
  window.rand = function rand(x) {
    var xf = Math.floor(x);
    if (xf < 1) { return Math.random(); }
    return Math.random() * xf;
  };
  window.randint = function randint(x) { return Math.floor(rand(x)); };
  window.bnot = function bnot(x) { return Math.abs(x) < EPSILON ? 1 : 0; };
  function isFiniteNumber(num) { return isFinite(num) && !isNaN(num); }
  window.pow = function pow(x, y) {
    var z = Math.pow(x, y);
    if (!isFiniteNumber(z)) { return 0; }
    return z;
  };
  window.div = function div(x, y) { if (y === 0) { return 0; } return x / y; };
  window.mod = function mod(x, y) {
    if (y === 0) { return 0; }
    var z = Math.floor(x) % Math.floor(y);
    return z;
  };
  window.bitor = function bitor(x, y) { return Math.floor(x) | Math.floor(y); };
  window.bitand = function bitand(x, y) { return Math.floor(x) & Math.floor(y); };
  window.sigmoid = function sigmoid(x, y) {
    var t = 1 + Math.exp(-x * y);
    return Math.abs(t) > EPSILON ? 1.0 / t : 0;
  };
  window.bor = function bor(x, y) { return Math.abs(x) > EPSILON || Math.abs(y) > EPSILON ? 1 : 0; };
  window.band = function band(x, y) { return Math.abs(x) > EPSILON && Math.abs(y) > EPSILON ? 1 : 0; };
  window.equal = function equal(x, y) { return Math.abs(x - y) < EPSILON ? 1 : 0; };
  window.above = function above(x, y) { return x > y ? 1 : 0; };
  window.below = function below(x, y) { return x < y ? 1 : 0; };
  window.ifcond = function ifcond(x, y, z) { return Math.abs(x) > EPSILON ? y : z; };
  window.memcpy = function memcpy(megabuf, dst, src, len) {
    let destOffset = dst;
    let srcOffset = src;
    let copyLen = len;
    if (srcOffset < 0) { copyLen += srcOffset; destOffset -= srcOffset; srcOffset = 0; }
    if (destOffset < 0) { copyLen += destOffset; srcOffset -= destOffset; destOffset = 0; }
    if (copyLen > 0) { megabuf.copyWithin(destOffset, srcOffset, copyLen); }
    return dst;
  };
  """

  private static let presetDefaults: [String: Double] = [
    "decay": 0.98,
    "warp": 1.0,
    "warpanimspeed": 1.0,
    "warpscale": 1.0,
    "zoom": 1.0,
    "zoomexp": 1.0,
    "rot": 0.0,
    "cx": 0.5,
    "cy": 0.5,
    "sx": 1.0,
    "sy": 1.0,
    "dx": 0.0,
    "dy": 0.0,
    "wrap": 1.0,
    "wave_r": 1.0,
    "wave_g": 1.0,
    "wave_b": 1.0,
    "wave_a": 0.8,
    "wave_scale": 1.0,
    "wave_thick": 0.0,
    "wave_brighten": 1.0,
    "wave_dots": 0.0,
    "wave_mode": 0.0,
    "wave_x": 0.5,
    "wave_y": 0.5,
    "wave_mystery": 0.0,
    "modwavealphabyvolume": 0.0,
    "modwavealphastart": 0.75,
    "modwavealphaend": 0.95,
    "additivewave": 0.0,
    "wave_smoothing": 0.75,
    "gammaadj": 2.0,
    "brighten": 0.0,
    "darken": 0.0,
    "invert": 0.0,
    "solarize": 0.0,
    "red_blue": 0.0,
    "darken_center": 0.0,
    "echo_alpha": 0.0,
    "echo_zoom": 2.0,
    "echo_orient": 0.0,
    "bmotionvectorson": 1.0,
    "mv_x": 12.0,
    "mv_y": 9.0,
    "mv_dx": 0.0,
    "mv_dy": 0.0,
    "mv_l": 0.9,
    "mv_r": 1.0,
    "mv_g": 1.0,
    "mv_b": 1.0,
    "mv_a": 1.0,
    "ob_size": 0.01,
    "ob_r": 0.0,
    "ob_g": 0.0,
    "ob_b": 0.0,
    "ob_a": 0.0,
    "ib_size": 0.01,
    "ib_r": 0.25,
    "ib_g": 0.25,
    "ib_b": 0.25,
    "ib_a": 0.0,
    "fshader": 0.0,
    "b1n": 0.0,
    "b2n": 0.0,
    "b3n": 0.0,
    "b1x": 1.0,
    "b2x": 1.0,
    "b3x": 1.0,
    "b1ed": 0.25,
  ]

  private static let shapeDefaults: [String: Double] = [
    "enabled": 0,
    "sides": 4,
    "additive": 0,
    "thickoutline": 0,
    "textured": 0,
    "num_inst": 1,
    "tex_zoom": 1,
    "tex_ang": 0,
    "x": 0.5,
    "y": 0.5,
    "rad": 0.1,
    "ang": 0,
    "r": 1,
    "g": 0,
    "b": 0,
    "a": 1,
    "r2": 0,
    "g2": 1,
    "b2": 0,
    "a2": 0,
    "border_r": 1,
    "border_g": 1,
    "border_b": 1,
    "border_a": 0.1,
  ]

  private static let waveDefaults: [String: Double] = [
    "enabled": 0,
    "samples": 512,
    "sep": 0,
    "scaling": 1,
    "smoothing": 0.5,
    "r": 1,
    "g": 1,
    "b": 1,
    "a": 1,
    "spectrum": 0,
    "usedots": 0,
    "thick": 0,
    "additive": 0,
  ]

  private static let globalKeys: [String] = [
    "frame",
    "time",
    "fps",
    "bass",
    "bass_att",
    "mid",
    "mid_att",
    "treb",
    "treb_att",
    "meshx",
    "meshy",
    "aspectx",
    "aspecty",
    "pixelsx",
    "pixelsy",
  ]

  private let context: JSContext
  private let presetState: JSValue
  private let presetInitFunc: JSValue?
  private let presetFrameFunc: JSValue?
  private let presetPixelFunc: JSValue?
  private let gmegabuf: JSValue?

  private var pixelState: JSValue?
  private var hasPixelEqs: Bool

  private let baseVals: [String: Double]
  private var qInit: [String: Double] = [:]
  private var qVars: [String: Double] = [:]
  private var regVars: [String: Double] = [:]

  private var shapeStates: [JSValue?] = []
  private var shapeFrameFuncs: [JSValue?] = []
  private var shapeBaseValsCache: [[String: Double]] = []
  private var shapeTInits: [[String: Double]] = []
  private var shapeUserKeys: [[String]] = []
  private var shapeUserVars: [[String: Double]] = []
  private var waveStates: [JSValue?] = []
  private var waveFrameFuncs: [JSValue?] = []
  private var wavePointFuncs: [JSValue?] = []
  private var waveBaseValsCache: [[String: Double]] = []
  private var waveTInits: [[String: Double]] = []
  private var waveUserKeys: [[String]] = []
  private var waveUserVars: [[String: Double]] = []

  private let qKeys: [String]
  private let tKeys: [String]
  private let regKeys: [String]

  init?(preset: PresetDefinition, global: GlobalFrameInfo, randStart: SIMD4<Float>, randPreset: SIMD4<Float>) {
    guard let context = JSContext() else { return nil }
    guard let presetState = JSValue(newObjectIn: context) else { return nil }

    context.exceptionHandler = { _, exception in
      if let message = exception?.toString() {
        NSLog("JS preset exception: %@", message)
      }
    }

    context.evaluateScript(Self.presetBaseScript)

    let qKeys = (1...32).map { "q\($0)" }
    let tKeys = (1...8).map { "t\($0)" }
    let regKeys = (0..<100).map { idx in
      if idx < 10 { return "reg0\(idx)" }
      return "reg\(idx)"
    }

    let baseVals = Self.mergeDefaults(Self.presetDefaults, preset.baseVals)
    for (key, value) in baseVals {
      presetState.setValue(value, forProperty: key)
    }
    for key in qKeys {
      presetState.setValue(0.0, forProperty: key)
    }
    for key in regKeys {
      presetState.setValue(0.0, forProperty: key)
    }

    let gmegabuf = Self.makeLargeArray(in: context)
    presetState.setValue(Self.randStartArray(randStart), forProperty: "rand_start")
    presetState.setValue(Self.randStartArray(randPreset), forProperty: "rand_preset")
    presetState.setValue(Self.makeLargeArray(in: context), forProperty: "megabuf")
    if let gmegabuf {
      presetState.setValue(gmegabuf, forProperty: "gmegabuf")
    }

    Self.updateGlobalVars(presetState, global)

    let presetInitFunc = Self.compileFunction(preset.init_eqs_str, in: context)
    let presetFrameFunc = Self.compileFunction(preset.frame_eqs_str, in: context)
    let presetPixelFunc = Self.compileFunction(preset.pixel_eqs_str, in: context)
    let hasPixelEqs = presetPixelFunc != nil

    self.context = context
    self.presetState = presetState
    self.presetInitFunc = presetInitFunc
    self.presetFrameFunc = presetFrameFunc
    self.presetPixelFunc = presetPixelFunc
    self.gmegabuf = gmegabuf
    self.pixelState = nil
    self.hasPixelEqs = hasPixelEqs
    self.qKeys = qKeys
    self.tKeys = tKeys
    self.regKeys = regKeys
    self.baseVals = baseVals

    if let presetInitFunc {
      _ = presetInitFunc.call(withArguments: [presetState])
    }
    qInit = captureValues(from: presetState, keys: qKeys)
    regVars = captureValues(from: presetState, keys: regKeys)

    resetBaseVals(on: presetState)
    applyQInit(to: presetState)
    applyRegVars(to: presetState)
    Self.updateGlobalVars(presetState, global)

    if let presetFrameFunc {
      _ = presetFrameFunc.call(withArguments: [presetState])
    }
    qVars = captureValues(from: presetState, keys: qKeys)
    regVars = captureValues(from: presetState, keys: regKeys)
    buildShapes(preset: preset, global: global)
    buildWaves(preset: preset, global: global)
  }

  func updateFrame(global: GlobalFrameInfo) -> PresetFrame {
    resetBaseVals(on: presetState)
    applyQInit(to: presetState)
    applyRegVars(to: presetState)
    Self.updateGlobalVars(presetState, global)
    if let presetFrameFunc {
      _ = presetFrameFunc.call(withArguments: [presetState])
    }
    qVars = captureValues(from: presetState, keys: qKeys)
    if !hasPixelEqs {
      regVars = captureValues(from: presetState, keys: regKeys)
    }
    return buildPresetFrame(from: presetState)
  }

  func preparePixelEqs(frame: PresetFrame) {
    guard hasPixelEqs else {
      pixelState = nil
      return
    }
    context.setObject(presetState, forKeyedSubscript: "__preset_state" as NSString)
    pixelState = context.evaluateScript("Object.assign({}, __preset_state)")
    guard let pixelState else { return }

    // Ensure base warp params are present before the first pixel eq
    pixelState.setValue(Double(frame.zoom), forProperty: "zoom")
    pixelState.setValue(Double(frame.zoomExp), forProperty: "zoomexp")
    pixelState.setValue(Double(frame.rot), forProperty: "rot")
    pixelState.setValue(Double(frame.warp), forProperty: "warp")
    pixelState.setValue(Double(frame.cx), forProperty: "cx")
    pixelState.setValue(Double(frame.cy), forProperty: "cy")
    pixelState.setValue(Double(frame.dx), forProperty: "dx")
    pixelState.setValue(Double(frame.dy), forProperty: "dy")
    pixelState.setValue(Double(frame.sx), forProperty: "sx")
    pixelState.setValue(Double(frame.sy), forProperty: "sy")
  }

  func applyPixelEqs(x: Float, y: Float, rad: Float, ang: Float, frame: PresetFrame) -> PixelWarpResult? {
    guard let pixelState, let presetPixelFunc else { return nil }

    pixelState.setValue(Double(x), forProperty: "x")
    pixelState.setValue(Double(y), forProperty: "y")
    pixelState.setValue(Double(rad), forProperty: "rad")
    pixelState.setValue(Double(ang), forProperty: "ang")
    pixelState.setValue(Double(frame.zoom), forProperty: "zoom")
    pixelState.setValue(Double(frame.zoomExp), forProperty: "zoomexp")
    pixelState.setValue(Double(frame.rot), forProperty: "rot")
    pixelState.setValue(Double(frame.warp), forProperty: "warp")
    pixelState.setValue(Double(frame.cx), forProperty: "cx")
    pixelState.setValue(Double(frame.cy), forProperty: "cy")
    pixelState.setValue(Double(frame.dx), forProperty: "dx")
    pixelState.setValue(Double(frame.dy), forProperty: "dy")
    pixelState.setValue(Double(frame.sx), forProperty: "sx")
    pixelState.setValue(Double(frame.sy), forProperty: "sy")

    _ = presetPixelFunc.call(withArguments: [pixelState])

    return PixelWarpResult(
      warp: float(pixelState, "warp", fallback: frame.warp),
      zoom: float(pixelState, "zoom", fallback: frame.zoom),
      zoomExp: float(pixelState, "zoomexp", fallback: frame.zoomExp),
      rot: float(pixelState, "rot", fallback: frame.rot),
      cx: float(pixelState, "cx", fallback: frame.cx),
      cy: float(pixelState, "cy", fallback: frame.cy),
      sx: float(pixelState, "sx", fallback: frame.sx),
      sy: float(pixelState, "sy", fallback: frame.sy),
      dx: float(pixelState, "dx", fallback: frame.dx),
      dy: float(pixelState, "dy", fallback: frame.dy)
    )
  }

  func finalizePixelEqs() {
    guard hasPixelEqs, let pixelState else { return }
    regVars = captureValues(from: pixelState, keys: regKeys)
  }

  func evaluateShape(index: Int, instance: Int, commitUserVars: Bool, global: GlobalFrameInfo) -> ShapeEvalResult? {
    guard index < shapeStates.count, let shapeState = shapeStates[index] else { return nil }
    Self.updateGlobalVars(shapeState, global)
    applyQRegs(to: shapeState)
    if index < shapeTInits.count {
      applyTInits(shapeTInits[index], to: shapeState)
    }

    let baseVals = shapeBaseVals(index: index)
    for (key, value) in baseVals {
      shapeState.setValue(value, forProperty: key)
    }
    applyShapeUserVars(index: index, to: shapeState)
    shapeState.setValue(Double(instance), forProperty: "instance")

    if let frameFunc = shapeFrameFuncs[index] {
      _ = frameFunc.call(withArguments: [shapeState])
    }

    if commitUserVars {
      commitShapeUserVars(index: index, from: shapeState)
    }

    let sides = Int(clamp(float(shapeState, "sides", fallback: 4), min: 3, max: 100))
    return ShapeEvalResult(
      sides: sides,
      x: float(shapeState, "x", fallback: 0.5),
      y: float(shapeState, "y", fallback: 0.5),
      rad: float(shapeState, "rad", fallback: 0.1),
      ang: float(shapeState, "ang", fallback: 0),
      r: float(shapeState, "r", fallback: 1),
      g: float(shapeState, "g", fallback: 0),
      b: float(shapeState, "b", fallback: 0),
      a: float(shapeState, "a", fallback: 1),
      r2: float(shapeState, "r2", fallback: 0),
      g2: float(shapeState, "g2", fallback: 1),
      b2: float(shapeState, "b2", fallback: 0),
      a2: float(shapeState, "a2", fallback: 0),
      borderR: float(shapeState, "border_r", fallback: 1),
      borderG: float(shapeState, "border_g", fallback: 1),
      borderB: float(shapeState, "border_b", fallback: 1),
      borderA: float(shapeState, "border_a", fallback: 0.1),
      thickOutline: boolFloat(shapeState, "thickoutline"),
      textured: boolFloat(shapeState, "textured"),
      texZoom: float(shapeState, "tex_zoom", fallback: 1),
      texAng: float(shapeState, "tex_ang", fallback: 0),
      additive: boolFloat(shapeState, "additive")
    )
  }

  func evaluateWaveFrame(index: Int, commitUserVars: Bool, global: GlobalFrameInfo) -> WaveEvalResult? {
    guard index < waveStates.count, let waveState = waveStates[index] else { return nil }
    Self.updateGlobalVars(waveState, global)
    applyQRegs(to: waveState)
    if index < waveTInits.count {
      applyTInits(waveTInits[index], to: waveState)
    }

    let baseVals = waveBaseVals(index: index)
    for (key, value) in baseVals {
      waveState.setValue(value, forProperty: key)
    }
    applyWaveUserVars(index: index, to: waveState)

    if let frameFunc = waveFrameFuncs[index] {
      _ = frameFunc.call(withArguments: [waveState])
    }
    if commitUserVars {
      commitWaveUserVars(index: index, from: waveState)
    }

    let samples = Int(clamp(float(waveState, "samples", fallback: 512), min: 1, max: 512))
    return WaveEvalResult(
      samples: samples,
      sep: Int(max(0, float(waveState, "sep", fallback: 0))),
      scaling: float(waveState, "scaling", fallback: 1),
      smoothing: float(waveState, "smoothing", fallback: 0.5),
      spectrum: boolFloat(waveState, "spectrum"),
      r: float(waveState, "r", fallback: 1),
      g: float(waveState, "g", fallback: 1),
      b: float(waveState, "b", fallback: 1),
      a: float(waveState, "a", fallback: 1),
      usedots: boolFloat(waveState, "usedots"),
      thick: boolFloat(waveState, "thick"),
      additive: boolFloat(waveState, "additive")
    )
  }

  func finalizeWaveUserVars(index: Int) {
    guard index < waveStates.count, let waveState = waveStates[index] else { return }
    commitWaveUserVars(index: index, from: waveState)
  }

  func evaluateWavePoint(index: Int, sample: Float, value1: Float, value2: Float, base: WavePointResult) -> WavePointResult {
    guard index < waveStates.count, let waveState = waveStates[index], let pointFunc = wavePointFuncs[index] else {
      return base
    }

    waveState.setValue(Double(sample), forProperty: "sample")
    waveState.setValue(Double(value1), forProperty: "value1")
    waveState.setValue(Double(value2), forProperty: "value2")
    waveState.setValue(Double(base.x), forProperty: "x")
    waveState.setValue(Double(base.y), forProperty: "y")
    waveState.setValue(Double(base.r), forProperty: "r")
    waveState.setValue(Double(base.g), forProperty: "g")
    waveState.setValue(Double(base.b), forProperty: "b")
    waveState.setValue(Double(base.a), forProperty: "a")

    _ = pointFunc.call(withArguments: [waveState])

    return WavePointResult(
      x: float(waveState, "x", fallback: base.x),
      y: float(waveState, "y", fallback: base.y),
      r: float(waveState, "r", fallback: base.r),
      g: float(waveState, "g", fallback: base.g),
      b: float(waveState, "b", fallback: base.b),
      a: float(waveState, "a", fallback: base.a)
    )
  }

  private func buildShapes(preset: PresetDefinition, global: GlobalFrameInfo) {
    shapeStates = []
    shapeFrameFuncs = []
    shapeBaseValsCache = []
    shapeTInits = []
    shapeUserKeys = []
    shapeUserVars = []

    let shapes = preset.shapes ?? []
    for shape in shapes {
      let merged = Self.mergeDefaults(Self.shapeDefaults, shape.baseVals)
      shapeBaseValsCache.append(merged)
      if merged["enabled"] == 0 {
        shapeStates.append(nil)
        shapeFrameFuncs.append(nil)
        shapeTInits.append([:])
        shapeUserKeys.append([])
        shapeUserVars.append([:])
        continue
      }

      let state = JSValue(newObjectIn: context)
      for (key, value) in merged {
        state?.setValue(value, forProperty: key)
      }
      for key in qKeys { state?.setValue(0.0, forProperty: key) }
      for key in tKeys { state?.setValue(0.0, forProperty: key) }
      for key in regKeys { state?.setValue(0.0, forProperty: key) }
      state?.setValue(Self.makeLargeArray(in: context), forProperty: "megabuf")
      if let gmegabuf {
        state?.setValue(gmegabuf, forProperty: "gmegabuf")
      }
      Self.updateGlobalVars(state, global)
      if let state {
        applyQRegs(to: state)
      }

      if let initFunc = Self.compileFunction(shape.init_eqs_str, in: context) {
        _ = initFunc.call(withArguments: [state as Any])
        for (key, value) in merged {
          state?.setValue(value, forProperty: key)
        }
      }

      shapeStates.append(state)
      shapeFrameFuncs.append(Self.compileFunction(shape.frame_eqs_str, in: context))
      shapeTInits.append(captureTValues(from: state))
      let nonUserKeys = Set(qKeys + tKeys + regKeys + merged.keys + Self.globalKeys + ["megabuf", "gmegabuf"])
      let userKeys = extractUserKeys(from: state, excluding: nonUserKeys)
      shapeUserKeys.append(userKeys)
      if let state {
        shapeUserVars.append(captureValues(from: state, keys: userKeys))
      } else {
        shapeUserVars.append([:])
      }
    }
  }

  private func buildWaves(preset: PresetDefinition, global: GlobalFrameInfo) {
    waveStates = []
    waveFrameFuncs = []
    wavePointFuncs = []
    waveBaseValsCache = []
    waveTInits = []
    waveUserKeys = []
    waveUserVars = []

    let waves = preset.waves ?? []
    for wave in waves {
      let merged = Self.mergeDefaults(Self.waveDefaults, wave.baseVals)
      waveBaseValsCache.append(merged)
      if merged["enabled"] == 0 {
        waveStates.append(nil)
        waveFrameFuncs.append(nil)
        wavePointFuncs.append(nil)
        waveTInits.append([:])
        waveUserKeys.append([])
        waveUserVars.append([:])
        continue
      }

      let state = JSValue(newObjectIn: context)
      for (key, value) in merged {
        state?.setValue(value, forProperty: key)
      }
      for key in qKeys { state?.setValue(0.0, forProperty: key) }
      for key in tKeys { state?.setValue(0.0, forProperty: key) }
      for key in regKeys { state?.setValue(0.0, forProperty: key) }
      state?.setValue(Self.makeLargeArray(in: context), forProperty: "megabuf")
      if let gmegabuf {
        state?.setValue(gmegabuf, forProperty: "gmegabuf")
      }
      Self.updateGlobalVars(state, global)
      if let state {
        applyQRegs(to: state)
      }

      if let initFunc = Self.compileFunction(wave.init_eqs_str, in: context) {
        _ = initFunc.call(withArguments: [state as Any])
        for (key, value) in merged {
          state?.setValue(value, forProperty: key)
        }
      }

      waveStates.append(state)
      waveFrameFuncs.append(Self.compileFunction(wave.frame_eqs_str, in: context))
      wavePointFuncs.append(Self.compileFunction(wave.point_eqs_str, in: context))
      waveTInits.append(captureTValues(from: state))
      let nonUserKeys = Set(qKeys + tKeys + regKeys + merged.keys + Self.globalKeys + ["megabuf", "gmegabuf"])
      let userKeys = extractUserKeys(from: state, excluding: nonUserKeys)
      waveUserKeys.append(userKeys)
      if let state {
        waveUserVars.append(captureValues(from: state, keys: userKeys))
      } else {
        waveUserVars.append([:])
      }
    }
  }

  private func shapeBaseVals(index: Int) -> [String: Double] {
    guard index < shapeBaseValsCache.count else { return [:] }
    return shapeBaseValsCache[index]
  }

  private func waveBaseVals(index: Int) -> [String: Double] {
    guard index < waveBaseValsCache.count else { return [:] }
    return waveBaseValsCache[index]
  }

  private func applyQRegs(to obj: JSValue) {
    for (key, value) in qVars {
      obj.setValue(value, forProperty: key)
    }
    for (key, value) in regVars {
      obj.setValue(value, forProperty: key)
    }
  }

  private func applyQInit(to obj: JSValue) {
    for (key, value) in qInit {
      obj.setValue(value, forProperty: key)
    }
  }

  private func applyRegVars(to obj: JSValue) {
    for (key, value) in regVars {
      obj.setValue(value, forProperty: key)
    }
  }

  private func applyShapeUserVars(index: Int, to obj: JSValue) {
    guard index < shapeUserVars.count else { return }
    for (key, value) in shapeUserVars[index] {
      obj.setValue(value, forProperty: key)
    }
  }

  private func commitShapeUserVars(index: Int, from obj: JSValue) {
    guard index < shapeUserKeys.count else { return }
    shapeUserVars[index] = captureValues(from: obj, keys: shapeUserKeys[index])
  }

  private func applyWaveUserVars(index: Int, to obj: JSValue) {
    guard index < waveUserVars.count else { return }
    for (key, value) in waveUserVars[index] {
      obj.setValue(value, forProperty: key)
    }
  }

  private func commitWaveUserVars(index: Int, from obj: JSValue) {
    guard index < waveUserKeys.count else { return }
    waveUserVars[index] = captureValues(from: obj, keys: waveUserKeys[index])
  }

  private func applyTInits(_ inits: [String: Double], to obj: JSValue) {
    for (key, value) in inits {
      obj.setValue(value, forProperty: key)
    }
  }

  private func resetBaseVals(on obj: JSValue) {
    for (key, value) in baseVals {
      obj.setValue(value, forProperty: key)
    }
  }

  private func captureValues(from obj: JSValue, keys: [String]) -> [String: Double] {
    var values: [String: Double] = [:]
    for key in keys {
      values[key] = double(obj, key, fallback: 0)
    }
    return values
  }

  private func extractUserKeys(from obj: JSValue?, excluding nonUserKeys: Set<String>) -> [String] {
    guard let obj, let raw = obj.toDictionary() else { return [] }
    var keys: [String] = []
    for (key, _) in raw {
      guard let name = key as? String else { continue }
      if !nonUserKeys.contains(name) {
        keys.append(name)
      }
    }
    return keys
  }

  private func captureTValues(from obj: JSValue?) -> [String: Double] {
    guard let obj else { return [:] }
    var values: [String: Double] = [:]
    for key in tKeys {
      values[key] = double(obj, key, fallback: 0)
    }
    return values
  }

  private func buildPresetFrame(from obj: JSValue) -> PresetFrame {
    let decay = float(obj, "decay", fallback: 0.98)
    let warp = float(obj, "warp", fallback: 1.0)
    let warpAnimSpeed = float(obj, "warpanimspeed", fallback: 1.0)
    let warpScale = float(obj, "warpscale", fallback: 1.0)
    let zoom = float(obj, "zoom", fallback: 1.0)
    let zoomExp = float(obj, "zoomexp", fallback: 1.0)
    let rot = float(obj, "rot", fallback: 0.0)
    let cx = float(obj, "cx", fallback: 0.5)
    let cy = float(obj, "cy", fallback: 0.5)
    let sx = float(obj, "sx", fallback: 1.0)
    let sy = float(obj, "sy", fallback: 1.0)
    let dx = float(obj, "dx", fallback: 0.0)
    let dy = float(obj, "dy", fallback: 0.0)
    let wrap = boolFloat(obj, "wrap")

    let waveR = float(obj, "wave_r", fallback: 1.0)
    let waveG = float(obj, "wave_g", fallback: 1.0)
    let waveB = float(obj, "wave_b", fallback: 1.0)
    let waveA = float(obj, "wave_a", fallback: 0.8)
    let waveScale = float(obj, "wave_scale", fallback: 1.0)
    let waveThick = float(obj, "wave_thick", fallback: 0.0)
    let waveBrighten = float(obj, "wave_brighten", fallback: 1.0)

    let gammaAdj = float(obj, "gammaadj", fallback: 2.0)
    let brighten = float(obj, "brighten", fallback: 0.0)
    let darken = float(obj, "darken", fallback: 0.0)
    let invert = float(obj, "invert", fallback: 0.0)
    let solarize = float(obj, "solarize", fallback: 0.0)
    let redBlue = float(obj, "red_blue", fallback: 0.0)
    let darkenCenter = float(obj, "darken_center", fallback: 0.0)

    let echoAlpha = float(obj, "echo_alpha", fallback: 0.0)
    let echoZoom = float(obj, "echo_zoom", fallback: 2.0)
    let echoOrient = float(obj, "echo_orient", fallback: 0.0)

    let motionVectorsOn = float(obj, "bmotionvectorson", fallback: 1.0)
    let mvX = float(obj, "mv_x", fallback: 12.0)
    let mvY = float(obj, "mv_y", fallback: 9.0)
    let mvDx = float(obj, "mv_dx", fallback: 0.0)
    let mvDy = float(obj, "mv_dy", fallback: 0.0)
    let mvL = float(obj, "mv_l", fallback: 0.9)
    let mvR = float(obj, "mv_r", fallback: 1.0)
    let mvG = float(obj, "mv_g", fallback: 1.0)
    let mvB = float(obj, "mv_b", fallback: 1.0)
    let mvA = float(obj, "mv_a", fallback: 1.0)

    let obSize = float(obj, "ob_size", fallback: 0.01)
    let obR = float(obj, "ob_r", fallback: 0.0)
    let obG = float(obj, "ob_g", fallback: 0.0)
    let obB = float(obj, "ob_b", fallback: 0.0)
    let obA = float(obj, "ob_a", fallback: 0.0)

    let ibSize = float(obj, "ib_size", fallback: 0.01)
    let ibR = float(obj, "ib_r", fallback: 0.25)
    let ibG = float(obj, "ib_g", fallback: 0.25)
    let ibB = float(obj, "ib_b", fallback: 0.25)
    let ibA = float(obj, "ib_a", fallback: 0.0)

    let fShader = float(obj, "fshader", fallback: 0.0)
    let b1n = float(obj, "b1n", fallback: 0.0)
    let b2n = float(obj, "b2n", fallback: 0.0)
    let b3n = float(obj, "b3n", fallback: 0.0)
    let b1x = float(obj, "b1x", fallback: 1.0)
    let b2x = float(obj, "b2x", fallback: 1.0)
    let b3x = float(obj, "b3x", fallback: 1.0)
    let b1ed = float(obj, "b1ed", fallback: 0.25)
    let nEchoWrapX = float(obj, "nechowrap_x", fallback: 0.0)
    let nEchoWrapY = float(obj, "nechowrap_y", fallback: 0.0)
    let nWrapModeX = float(obj, "nwrapmode_x", fallback: 0.0)
    let nWrapModeY = float(obj, "nwrapmode_y", fallback: 0.0)
    let rating = float(obj, "rating", fallback: 0.0)

    return PresetFrame(
      decay: decay,
      warp: warp,
      warpAnimSpeed: warpAnimSpeed,
      warpScale: warpScale,
      zoom: zoom,
      zoomExp: zoomExp,
      rot: rot,
      cx: cx,
      cy: cy,
      sx: sx,
      sy: sy,
      dx: dx,
      dy: dy,
      wrap: wrap,
      waveColorAlpha: SIMD4<Float>(waveR, waveG, waveB, waveA),
      waveParams: SIMD4<Float>(waveScale, waveThick, waveBrighten, 0.0),
      postParams0: SIMD4<Float>(gammaAdj, brighten, darken, invert),
      postParams1: SIMD4<Float>(solarize, redBlue, darkenCenter, 0.0),
      echoParams: SIMD4<Float>(echoAlpha, echoZoom, echoOrient, 0.0),
      waveMode: float(obj, "wave_mode", fallback: 0.0),
      waveX: float(obj, "wave_x", fallback: 0.5),
      waveY: float(obj, "wave_y", fallback: 0.5),
      waveMystery: float(obj, "wave_mystery", fallback: 0.0),
      modWaveAlphaByVolume: float(obj, "modwavealphabyvolume", fallback: 0.0),
      modWaveAlphaStart: float(obj, "modwavealphastart", fallback: 0.75),
      modWaveAlphaEnd: float(obj, "modwavealphaend", fallback: 0.95),
      additiveWave: float(obj, "additivewave", fallback: 0.0),
      waveDots: float(obj, "wave_dots", fallback: 0.0),
      waveThick: float(obj, "wave_thick", fallback: 0.0),
      waveBrighten: float(obj, "wave_brighten", fallback: 1.0),
      waveSmoothing: float(obj, "wave_smoothing", fallback: 0.75),
      motionVectorsOn: motionVectorsOn,
      mvX: mvX,
      mvY: mvY,
      mvDx: mvDx,
      mvDy: mvDy,
      mvL: mvL,
      mvR: mvR,
      mvG: mvG,
      mvB: mvB,
      mvA: mvA,
      outerBorderSize: obSize,
      outerBorderColor: SIMD4<Float>(obR, obG, obB, obA),
      innerBorderSize: ibSize,
      innerBorderColor: SIMD4<Float>(ibR, ibG, ibB, ibA),
      fShader: fShader,
      b1n: b1n,
      b2n: b2n,
      b3n: b3n,
      b1x: b1x,
      b2x: b2x,
      b3x: b3x,
      b1ed: b1ed,
      nEchoWrapX: nEchoWrapX,
      nEchoWrapY: nEchoWrapY,
      nWrapModeX: nWrapModeX,
      nWrapModeY: nWrapModeY,
      rating: rating
    )
  }

  private static func updateGlobalVars(_ obj: JSValue?, _ global: GlobalFrameInfo) {
    guard let obj else { return }
    obj.setValue(Double(global.frame), forProperty: "frame")
    obj.setValue(Double(global.time), forProperty: "time")
    obj.setValue(Double(global.fps), forProperty: "fps")
    obj.setValue(Double(global.bass), forProperty: "bass")
    obj.setValue(Double(global.bassAtt), forProperty: "bass_att")
    obj.setValue(Double(global.mid), forProperty: "mid")
    obj.setValue(Double(global.midAtt), forProperty: "mid_att")
    obj.setValue(Double(global.treb), forProperty: "treb")
    obj.setValue(Double(global.trebAtt), forProperty: "treb_att")
    obj.setValue(Double(global.meshx), forProperty: "meshx")
    obj.setValue(Double(global.meshy), forProperty: "meshy")
    obj.setValue(Double(global.aspectx), forProperty: "aspectx")
    obj.setValue(Double(global.aspecty), forProperty: "aspecty")
    obj.setValue(Double(global.pixelsx), forProperty: "pixelsx")
    obj.setValue(Double(global.pixelsy), forProperty: "pixelsy")
  }

  private static func makeLargeArray(in context: JSContext) -> JSValue? {
    return context.evaluateScript("new Array(1048576).fill(0)")
  }

  private static func randStartArray(_ value: SIMD4<Float>) -> [Double] {
    return [Double(value.x), Double(value.y), Double(value.z), Double(value.w)]
  }

  private static func compileFunction(_ code: String?, in context: JSContext) -> JSValue? {
    guard let code, !code.isEmpty else { return nil }
    let wrapped = "(function(a){ \(code) return a; })"
    return context.evaluateScript(wrapped)
  }

  private func float(_ obj: JSValue, _ key: String, fallback: Float) -> Float {
    let val = double(obj, key, fallback: Double(fallback))
    return Float(val)
  }

  private func double(_ obj: JSValue, _ key: String, fallback: Double) -> Double {
    guard let value = obj.forProperty(key), !value.isUndefined else { return fallback }
    let raw = value.toDouble()
    if raw.isNaN || !raw.isFinite { return fallback }
    return raw
  }

  private func boolFloat(_ obj: JSValue, _ key: String) -> Bool {
    return float(obj, key, fallback: 0) != 0
  }

  private func clamp(_ value: Float, min: Float, max: Float) -> Float {
    return Swift.max(min, Swift.min(max, value))
  }

  private static func mergeDefaults(_ defaults: [String: Double], _ base: [String: Double]?) -> [String: Double] {
    guard let base else { return defaults }
    var merged = defaults
    for (key, value) in base {
      merged[key] = value
    }
    return merged
  }
}
