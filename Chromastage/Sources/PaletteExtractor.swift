import AppKit
import CoreGraphics

struct PaletteExtractor {
  static func extract(from image: NSImage, maxColors: Int) -> [NSColor] {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return []
    }

    let targetSize = 80
    let width = targetSize
    let height = targetSize
    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * width
    var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

    guard let context = CGContext(
      data: &data,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
      return []
    }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var vivid: [SIMD3<Double>] = []
    var muted: [SIMD3<Double>] = []
    vivid.reserveCapacity(width * height)

    for index in stride(from: 0, to: data.count, by: 4) {
      let r = Double(data[index]) / 255.0
      let g = Double(data[index + 1]) / 255.0
      let b = Double(data[index + 2]) / 255.0
      let a = Double(data[index + 3]) / 255.0
      if a < 0.5 {
        continue
      }
      let maxVal = max(r, g, b)
      let minVal = min(r, g, b)
      let sat = maxVal == 0 ? 0 : (maxVal - minVal) / maxVal
      let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
      if luma < 0.02 || luma > 0.98 {
        continue
      }
      let color = SIMD3<Double>(r, g, b)
      if sat >= 0.18 {
        vivid.append(color)
      } else {
        muted.append(color)
      }
    }

    var samples = vivid
    if samples.count < 200 {
      samples.append(contentsOf: muted)
    }
    if samples.isEmpty {
      return []
    }

    if samples.count > 4000 {
      let strideSize = max(1, samples.count / 4000)
      samples = stride(from: 0, to: samples.count, by: strideSize).map { samples[$0] }
    }

    let k = min(maxColors, samples.count)
    let clusters = kMeans(samples, k: k)
    let ordered = selectVaried(clusters)
    return ordered.map { NSColor(calibratedRed: $0.x, green: $0.y, blue: $0.z, alpha: 1.0) }
  }

  private static func kMeans(_ samples: [SIMD3<Double>], k: Int) -> [(center: SIMD3<Double>, count: Int)] {
    var centers: [SIMD3<Double>] = []
    centers.reserveCapacity(k)
    centers.append(samples[Int.random(in: 0..<samples.count)])

    while centers.count < k {
      let distances: [Double] = samples.map { sample in
        centers.map { distanceSquared($0, sample) }.min() ?? 0
      }
      let total = distances.reduce(0, +)
      let pick = Double.random(in: 0..<max(total, 0.0001))
      var cumulative = 0.0
      var chosen = samples[0]
      for (idx, dist) in distances.enumerated() {
        cumulative += dist
        if cumulative >= pick {
          chosen = samples[idx]
          break
        }
      }
      centers.append(chosen)
    }

    var assignments = Array(repeating: 0, count: samples.count)
    var counts = Array(repeating: 0, count: k)

    for _ in 0..<8 {
      counts = Array(repeating: 0, count: k)
      var sums = Array(repeating: SIMD3<Double>(0, 0, 0), count: k)

      for (idx, sample) in samples.enumerated() {
        var bestIndex = 0
        var bestDistance = distanceSquared(centers[0], sample)
        for i in 1..<k {
          let d = distanceSquared(centers[i], sample)
          if d < bestDistance {
            bestDistance = d
            bestIndex = i
          }
        }
        assignments[idx] = bestIndex
        counts[bestIndex] += 1
        sums[bestIndex] += sample
      }

      for i in 0..<k {
        if counts[i] > 0 {
          centers[i] = sums[i] / Double(counts[i])
        }
      }
    }

    return (0..<k).map { (centers[$0], counts[$0]) }.filter { $0.count > 0 }
  }

  private static func selectVaried(_ clusters: [(center: SIMD3<Double>, count: Int)]) -> [SIMD3<Double>] {
    guard !clusters.isEmpty else { return [] }
    let sorted = clusters.sorted { $0.count > $1.count }
    var remaining = sorted.map { $0.center }
    var selected: [SIMD3<Double>] = [remaining.removeFirst()]
    while !remaining.isEmpty {
      var bestIndex = 0
      var bestScore = -1.0
      for (idx, candidate) in remaining.enumerated() {
        let minDistance = selected
          .map { distanceSquared($0, candidate) }
          .min() ?? 0
        if minDistance > bestScore {
          bestScore = minDistance
          bestIndex = idx
        }
      }
      selected.append(remaining.remove(at: bestIndex))
    }
    return selected
  }

  private static func distanceSquared(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let dr = a.x - b.x
    let dg = a.y - b.y
    let db = a.z - b.z
    return (dr * dr * 0.3) + (dg * dg * 0.59) + (db * db * 0.11)
  }
}
