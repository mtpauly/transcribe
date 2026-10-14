import Foundation
import Testing

@testable import Transcribe

@Suite("Recording archive")
struct RecordingArchiveTests {
  @Test("writes the audio to a new file in the directory")
  func write() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
      .appendingPathComponent("recordings", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    let archive = DirectoryRecordingArchive(directory: directory)
    let recording = Recording(audio: Data("audio".utf8), format: "wav")
    let date = Date(timeIntervalSince1970: 1_760_434_262)

    let url = try archive.write(recording, at: date)

    #expect(url.deletingLastPathComponent().path == directory.path)
    #expect(url.lastPathComponent.hasPrefix("2025-10-14T09-31-02Z-"))
    #expect(url.pathExtension == "wav")
    #expect(try Data(contentsOf: url) == recording.audio)
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
  }
}

@Suite("WAV")
struct WAVTests {
  @Test("wraps PCM samples in a 44-byte header")
  func header() {
    let samples = Data([0x01, 0x00, 0xFF, 0x7F])
    let wav = WAV.encode(pcm16Mono: samples, sampleRate: 16_000)

    #expect(wav.count == 44 + samples.count)
    #expect(wav.prefix(4) == Data("RIFF".utf8))
    #expect(wav[8..<16] == Data("WAVEfmt ".utf8))
    #expect(wav[24..<28] == Data([0x80, 0x3E, 0x00, 0x00]))  // 16000 Hz
    #expect(wav[36..<40] == Data("data".utf8))
    #expect(wav[40..<44] == Data([0x04, 0x00, 0x00, 0x00]))
    #expect(wav.suffix(4) == samples)
  }
}
