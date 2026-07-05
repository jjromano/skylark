import AVFoundation
import Foundation
import SkylarkCore

// SkylarkBench — headless latency harness for the local decode path.
//
//   swift run -c release SkylarkBench [--engine parakeet|whisper] [--repeat N]
//                                     [--models-dir DIR] file...
//
// For each audio file it prints the audio duration, the median decode time over
// N repeats, and the real-time factor (RTFx = audioSeconds / decodeSeconds).
// It also emits machine-readable `RESULT<TAB>...` lines that Scripts/bench.sh
// merges into a two-engine comparison table. Exits nonzero on any failure so CI
// / Scripts/bench.sh can gate on it. Never prints transcript content.

struct BenchError: Error, CustomStringConvertible {
    let description: String
}

/// Boxes the converter's input buffer + "already fed" flag for the `@Sendable`
/// input block, which the converter actually invokes synchronously on the
/// calling thread (same pattern as AudioCaptureService.ConverterFeed).
final class ConverterFeed: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    var fed = false
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

// MARK: - Argument parsing

enum EngineChoice: String {
    case parakeet
    case whisper
}

var repeats = 3
var modelsDir: URL = ModelPaths.models
var engineChoice: EngineChoice = .parakeet
var files: [String] = []

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
    case "--engine":
        guard i + 1 < args.count, let choice = EngineChoice(rawValue: args[i + 1]) else {
            FileHandle.standardError.write(Data("error: --engine needs parakeet|whisper\n".utf8))
            exit(2)
        }
        engineChoice = choice
        i += 2
    case "--repeat":
        guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else {
            FileHandle.standardError.write(Data("error: --repeat needs a positive integer\n".utf8))
            exit(2)
        }
        repeats = n
        i += 2
    case "--models-dir":
        guard i + 1 < args.count else {
            FileHandle.standardError.write(Data("error: --models-dir needs a path\n".utf8))
            exit(2)
        }
        modelsDir = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
        i += 2
    default:
        files.append(arg)
        i += 1
    }
}

guard !files.isEmpty else {
    FileHandle.standardError.write(Data("usage: SkylarkBench [--engine parakeet|whisper] [--repeat N] [--models-dir DIR] file...\n".utf8))
    exit(2)
}

// MARK: - Audio loading (resample to 16 kHz mono Float32)

func loadClip(_ path: String) throws -> AudioClip {
    let url = URL(fileURLWithPath: path)
    let file = try AVAudioFile(forReading: url)
    let inputFormat = file.processingFormat
    let frameCount = AVAudioFrameCount(file.length)
    guard frameCount > 0 else { throw BenchError(description: "empty audio: \(path)") }

    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
        throw BenchError(description: "cannot allocate input buffer: \(path)")
    }
    try file.read(into: inputBuffer)

    let targetRate = 16_000.0
    guard let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetRate,
        channels: 1,
        interleaved: false
    ) else {
        throw BenchError(description: "cannot build 16 kHz format")
    }

    // Already 16 kHz mono? Copy straight out.
    if inputFormat.sampleRate == targetRate, inputFormat.channelCount == 1,
       let channel = inputBuffer.floatChannelData?.pointee {
        let n = Int(inputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channel, count: n))
        return AudioClip(samples: samples, sampleRate: targetRate, duration: Double(n) / targetRate)
    }

    guard let converter = AVAudioConverter(from: inputFormat, to: outFormat) else {
        throw BenchError(description: "cannot build converter for \(path)")
    }
    let ratio = targetRate / inputFormat.sampleRate
    let outCapacity = AVAudioFrameCount((Double(frameCount) * ratio).rounded(.up)) + 1024
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
        throw BenchError(description: "cannot allocate output buffer: \(path)")
    }

    let feed = ConverterFeed(inputBuffer)
    var convError: NSError?
    let status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
        if feed.fed {
            outStatus.pointee = .noDataNow
            return nil
        }
        feed.fed = true
        outStatus.pointee = .haveData
        return feed.buffer
    }
    if let convError { throw BenchError(description: "conversion failed for \(path): \(convError.localizedDescription)") }
    guard status == .haveData || status == .inputRanDry, let channel = outputBuffer.floatChannelData?.pointee else {
        throw BenchError(description: "conversion produced no data: \(path)")
    }
    let n = Int(outputBuffer.frameLength)
    let samples = Array(UnsafeBufferPointer(start: channel, count: n))
    return AudioClip(samples: samples, sampleRate: targetRate, duration: Double(n) / targetRate)
}

func median(_ xs: [Double]) -> Double {
    let s = xs.sorted()
    let m = s.count / 2
    return s.count.isMultiple(of: 2) ? (s[m - 1] + s[m]) / 2 : s[m]
}

func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}
func lpad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
}

// MARK: - Run

func run(files: [String], repeats: Int, modelsDir: URL, engineChoice: EngineChoice) async -> Int32 {
    let engine: any Transcriber
    let engineLabel: String
    switch engineChoice {
    case .parakeet:
        engine = FluidAudioParakeet(modelsDirectory: modelsDir)
        engineLabel = "parakeet"
        print("Preparing Parakeet models (dir: \(modelsDir.path))…")
    case .whisper:
        // First run downloads ~626 MB (Whisper large-v3-turbo) — expected.
        engine = WhisperKitWhisper(downloadBase: modelsDir.appendingPathComponent("whisperkit"))
        engineLabel = "whisper"
        print("Preparing WhisperKit models (dir: \(modelsDir.appendingPathComponent("whisperkit").path))…")
    }

    do {
        try await engine.warmUp()
    } catch {
        FileHandle.standardError.write(Data("error: model warmUp failed: \(error.localizedDescription)\n".utf8))
        return 1
    }

    print("")
    print("engine: \(engineLabel)")
    print(pad("file", 28) + " " + lpad("dur (s)", 10) + " " + lpad("decode (ms)", 14) + " " + lpad("RTFx", 8))
    print(String(repeating: "-", count: 64))

    var failed = false
    var allDecodeMs: [Double] = []
    var totalAudio = 0.0

    for path in files {
        let name = (path as NSString).lastPathComponent
        let clip: AudioClip
        do {
            clip = try loadClip(path)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            failed = true
            continue
        }

        var decodeMs: [Double] = []
        var ok = true
        for _ in 0..<repeats {
            let start = ContinuousClock.now
            do {
                _ = try await engine.transcribe(clip, hint: .none)
            } catch {
                FileHandle.standardError.write(Data("error: decode failed for \(name): \(error.localizedDescription)\n".utf8))
                ok = false
                break
            }
            let elapsed = start.duration(to: .now)
            decodeMs.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        if !ok { failed = true; continue }

        let med = median(decodeMs)
        let rtfx = med > 0 ? (clip.duration * 1000) / med : 0
        allDecodeMs.append(med)
        totalAudio += clip.duration
        print(pad(String(name.prefix(28)), 28) + " "
              + lpad(String(format: "%.2f", clip.duration), 10) + " "
              + lpad(String(format: "%.1f", med), 14) + " "
              + lpad(String(format: "%.1f", rtfx), 8))
        // Machine-readable line for Scripts/bench.sh's comparison table.
        print("RESULT\t\(engineLabel)\t\(name)\t\(String(format: "%.2f", clip.duration))\t\(String(format: "%.1f", med))\t\(String(format: "%.1f", rtfx))")
    }

    print(String(repeating: "-", count: 64))
    if !allDecodeMs.isEmpty {
        let totalDecode = allDecodeMs.reduce(0, +)
        let aggRtfx = totalDecode > 0 ? (totalAudio * 1000) / totalDecode : 0
        print(String(format: "total: %d files, %.2f s audio, %.1f ms median-decode sum, %.1fx aggregate RTFx",
                     allDecodeMs.count, totalAudio, totalDecode, aggRtfx))
    }

    return failed ? 1 : 0
}

let code = await run(files: files, repeats: repeats, modelsDir: modelsDir, engineChoice: engineChoice)
exit(code)
