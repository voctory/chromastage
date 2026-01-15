import Foundation
import Accelerate

struct AudioAnalysis {
  let spectrum: [Float]
  let rms: Float
  let beat: Float
}

final class AudioAnalyzer {
  private let fftSize: Int
  private let log2n: vDSP_Length
  private let fftSetup: FFTSetup
  private var window: [Float]
  private let sampleRate: Float
  private var smoothedBands: [Float]
  private var smoothedRms: Float = 0
  private var smoothedBeat: Float = 0

  init?(fftSize: Int = 1024, sampleRate: Float = 48_000, bands: Int = 64) {
    guard fftSize > 0, (fftSize & (fftSize - 1)) == 0 else {
      return nil
    }
    self.fftSize = fftSize
    self.sampleRate = sampleRate
    self.log2n = vDSP_Length(log2(Float(fftSize)))
    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
      return nil
    }
    self.fftSetup = setup
    self.window = [Float](repeating: 0, count: fftSize)
    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    self.smoothedBands = [Float](repeating: 0, count: bands)
  }

  deinit {
    vDSP_destroy_fftsetup(fftSetup)
  }

  func analyze(samples: [Float], bands: Int) -> AudioAnalysis {
    let padded = prepareWindowed(samples: samples)
    var real = [Float](repeating: 0, count: fftSize / 2)
    var imag = [Float](repeating: 0, count: fftSize / 2)

    for i in 0..<(fftSize / 2) {
      real[i] = padded[i * 2]
      imag[i] = padded[i * 2 + 1]
    }

    var magnitudes = [Float](repeating: 0, count: fftSize / 2)
    real.withUnsafeMutableBufferPointer { realBuf in
      imag.withUnsafeMutableBufferPointer { imagBuf in
        magnitudes.withUnsafeMutableBufferPointer { magBuf in
          var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
          vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
          vDSP_zvmags(&split, 1, magBuf.baseAddress!, 1, vDSP_Length(fftSize / 2))
        }
      }
    }

    var scale: Float = 1.0 / Float(fftSize)
    var scaledMagnitudes = [Float](repeating: 0, count: fftSize / 2)
    vDSP_vsmul(&magnitudes, 1, &scale, &scaledMagnitudes, 1, vDSP_Length(fftSize / 2))
    var sqrtMagnitudes = [Float](repeating: 0, count: fftSize / 2)
    var count = Int32(fftSize / 2)
    scaledMagnitudes.withUnsafeBufferPointer { inBuf in
      sqrtMagnitudes.withUnsafeMutableBufferPointer { outBuf in
        guard let inPtr = inBuf.baseAddress, let outPtr = outBuf.baseAddress else { return }
        vvsqrtf(outPtr, inPtr, &count)
      }
    }

    let spectrum = makeBands(from: sqrtMagnitudes, bands: bands)
    let rms = computeRms(samples: padded)
    let beat = computeBeat(from: spectrum)

    let smoothedSpectrum = smoothBands(spectrum)
    let smoothedRms = smoothValue(rms, previous: smoothedRms, factor: 0.85)
    let smoothedBeat = smoothValue(beat, previous: smoothedBeat, factor: 0.7)

    self.smoothedRms = smoothedRms
    self.smoothedBeat = smoothedBeat

    return AudioAnalysis(spectrum: smoothedSpectrum, rms: smoothedRms, beat: smoothedBeat)
  }

  private func prepareWindowed(samples: [Float]) -> [Float] {
    var buffer = [Float](repeating: 0, count: fftSize)
    if samples.count >= fftSize {
      buffer = Array(samples.suffix(fftSize))
    } else if !samples.isEmpty {
      let padding = fftSize - samples.count
      buffer = Array(repeating: 0, count: padding) + samples
    }

    vDSP_vmul(buffer, 1, window, 1, &buffer, 1, vDSP_Length(fftSize))
    return buffer
  }

  private func makeBands(from magnitudes: [Float], bands: Int) -> [Float] {
    let minHz: Float = 20
    let maxHz: Float = min(sampleRate * 0.45, 20_000)
    let hzPerBin = sampleRate / Float(fftSize)
    let maxBin = magnitudes.count - 1
    var output = [Float](repeating: 0, count: bands)

    for band in 0..<bands {
      let startFrac = Float(band) / Float(bands)
      let endFrac = Float(band + 1) / Float(bands)
      let startHz = minHz * pow(maxHz / minHz, startFrac)
      let endHz = minHz * pow(maxHz / minHz, endFrac)
      let startBin = max(1, Int(startHz / hzPerBin))
      let endBin = min(maxBin, max(startBin, Int(endHz / hzPerBin)))

      if startBin >= endBin {
        output[band] = 0
        continue
      }

      var sum: Float = 0
      for bin in startBin...endBin {
        sum += magnitudes[bin]
      }
      let avg = sum / Float(endBin - startBin + 1)
      let compressed = pow(min(avg * 12, 1.0), 0.6)
      output[band] = compressed
    }

    return output
  }

  private func computeRms(samples: [Float]) -> Float {
    var result: Float = 0
    vDSP_rmsqv(samples, 1, &result, vDSP_Length(samples.count))
    let scaled = min(result * 3, 1)
    return scaled
  }

  private func computeBeat(from spectrum: [Float]) -> Float {
    let lowCount = max(4, spectrum.count / 8)
    let slice = spectrum.prefix(lowCount)
    let avg = slice.reduce(0, +) / Float(lowCount)
    return min(avg * 1.8, 1)
  }

  private func smoothBands(_ bands: [Float]) -> [Float] {
    if smoothedBands.count != bands.count {
      smoothedBands = bands
      return bands
    }

    var output = smoothedBands
    for i in 0..<bands.count {
      let value = bands[i]
      let previous = smoothedBands[i]
      let blended = smoothValue(value, previous: previous, factor: 0.75)
      output[i] = blended
    }
    smoothedBands = output
    return output
  }

  private func smoothValue(_ value: Float, previous: Float, factor: Float) -> Float {
    return previous * factor + value * (1 - factor)
  }
}
