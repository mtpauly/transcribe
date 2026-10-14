@preconcurrency import AVFoundation
import Foundation

/// Captures the default input device into memory as 16 kHz mono 16-bit PCM.
final class AudioCapture: @unchecked Sendable {
  static let sampleRate = 16_000

  private let engine = AVAudioEngine()
  private let outputFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: Double(AudioCapture.sampleRate),
    channels: 1,
    interleaved: true
  )!
  private let lock = NSLock()
  private var converter: AVAudioConverter?
  private var samples = Data()

  func start() throws {
    let input = engine.inputNode
    let inputFormat = input.outputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
      throw AudioCaptureError.noInputDevice
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
      throw AudioCaptureError.unsupportedInputFormat
    }
    self.converter = converter

    input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
      self?.append(buffer)
    }
    engine.prepare()
    do {
      try engine.start()
    } catch {
      input.removeTap(onBus: 0)
      throw error
    }
  }

  /// Stops capture and returns the recorded PCM samples.
  func stop() -> Data {
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()

    // The tap no longer fires, so drain the samples the resampler is still holding.
    if let converter, let tail = convert(nil, with: converter) {
      append(samples: tail)
    }

    lock.lock()
    defer { lock.unlock() }
    return samples
  }

  private func append(_ buffer: AVAudioPCMBuffer) {
    guard let converter, let converted = convert(buffer, with: converter) else {
      return
    }
    append(samples: converted)
  }

  private func append(samples converted: Data) {
    lock.lock()
    defer { lock.unlock() }
    samples.append(converted)
  }

  /// Converts one input buffer, or flushes the converter when `buffer` is nil.
  private func convert(_ buffer: AVAudioPCMBuffer?, with converter: AVAudioConverter) -> Data? {
    let inputFrames = buffer.map { Double($0.frameLength) } ?? 0
    let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
    let capacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
      return nil
    }

    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, inputStatus in
      guard let buffer else {
        inputStatus.pointee = .endOfStream
        return nil
      }
      if supplied {
        inputStatus.pointee = .noDataNow
        return nil
      }
      supplied = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, output.frameLength > 0, let channel = output.int16ChannelData else {
      return nil
    }
    return Data(
      bytes: channel[0],
      count: Int(output.frameLength) * MemoryLayout<Int16>.size
    )
  }
}

enum WAV {
  /// Wraps little-endian 16-bit mono PCM samples in a WAV container.
  static func encode(pcm16Mono samples: Data, sampleRate: Int) -> Data {
    let channels = 1
    let bitsPerSample = 16
    let blockAlign = channels * bitsPerSample / 8
    let byteRate = sampleRate * blockAlign

    var data = Data(capacity: 44 + samples.count)
    data.append(contentsOf: Array("RIFF".utf8))
    data.appendLittleEndian(UInt32(36 + samples.count))
    data.append(contentsOf: Array("WAVE".utf8))
    data.append(contentsOf: Array("fmt ".utf8))
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))  // PCM
    data.appendLittleEndian(UInt16(channels))
    data.appendLittleEndian(UInt32(sampleRate))
    data.appendLittleEndian(UInt32(byteRate))
    data.appendLittleEndian(UInt16(blockAlign))
    data.appendLittleEndian(UInt16(bitsPerSample))
    data.append(contentsOf: Array("data".utf8))
    data.appendLittleEndian(UInt32(samples.count))
    data.append(samples)
    return data
  }
}

extension Data {
  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
  }
}

private enum AudioCaptureError: LocalizedError {
  case noInputDevice
  case unsupportedInputFormat

  var errorDescription: String? {
    switch self {
    case .noInputDevice:
      return "No audio input device is available"
    case .unsupportedInputFormat:
      return "The input device format cannot be converted to 16 kHz mono PCM"
    }
  }
}
