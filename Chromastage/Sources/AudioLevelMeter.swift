import Foundation

struct AudioLevelState {
  let bass: Float
  let mid: Float
  let treb: Float
  let bassAtt: Float
  let midAtt: Float
  let trebAtt: Float
}

final class AudioLevelMeter {
  private var avg = [Float](repeating: 1, count: 3)
  private var longAvg = [Float](repeating: 1, count: 3)
  private var imm = [Float](repeating: 0, count: 3)
  private var frameCount = 0

  func update(spectrum: [Float], fps: Float) -> AudioLevelState {
    frameCount += 1
    guard !spectrum.isEmpty else {
      return AudioLevelState(bass: 1, mid: 1, treb: 1, bassAtt: 1, midAtt: 1, trebAtt: 1)
    }

    let ranges = bandRanges(count: spectrum.count)
    imm[0] = average(spectrum, start: ranges.bass.start, end: ranges.bass.end)
    imm[1] = average(spectrum, start: ranges.mid.start, end: ranges.mid.end)
    imm[2] = average(spectrum, start: ranges.treb.start, end: ranges.treb.end)

    let effectiveFPS = max(15, min(144, fps))
    for i in 0..<3 {
      let rising = imm[i] > avg[i]
      let rateFast: Float = rising ? 0.2 : 0.5
      let rate = adjustRate(rateFast, baseFPS: 30, fps: effectiveFPS)
      avg[i] = avg[i] * rate + imm[i] * (1 - rate)

      let baseLong: Float = frameCount < 50 ? 0.9 : 0.992
      let longRate = adjustRate(baseLong, baseFPS: 30, fps: effectiveFPS)
      longAvg[i] = longAvg[i] * longRate + imm[i] * (1 - longRate)
    }

    let bass = value(index: 0)
    let mid = value(index: 1)
    let treb = value(index: 2)
    let bassAtt = att(index: 0)
    let midAtt = att(index: 1)
    let trebAtt = att(index: 2)

    return AudioLevelState(
      bass: bass,
      mid: mid,
      treb: treb,
      bassAtt: bassAtt,
      midAtt: midAtt,
      trebAtt: trebAtt
    )
  }

  private func value(index: Int) -> Float {
    guard longAvg[index] > 0.001 else { return 1 }
    return imm[index] / longAvg[index]
  }

  private func att(index: Int) -> Float {
    guard longAvg[index] > 0.001 else { return 1 }
    return avg[index] / longAvg[index]
  }

  private func average(_ data: [Float], start: Int, end: Int) -> Float {
    guard start <= end, start >= 0, end < data.count else { return 0 }
    var sum: Float = 0
    for i in start...end {
      sum += data[i]
    }
    return sum / Float(end - start + 1)
  }

  private func adjustRate(_ rate: Float, baseFPS: Float, fps: Float) -> Float {
    return pow(rate, baseFPS / fps)
  }

  private func bandRanges(count: Int) -> (bass: (start: Int, end: Int), mid: (start: Int, end: Int), treb: (start: Int, end: Int)) {
    let bassEnd = max(2, count / 6)
    let midEnd = max(bassEnd + 1, count / 2)
    let trebEnd = count - 1
    return (
      bass: (start: 0, end: bassEnd),
      mid: (start: bassEnd + 1, end: midEnd),
      treb: (start: midEnd + 1, end: trebEnd)
    )
  }
}
