//
//  VoiceRecorder.swift
//  ChatAll
//
//  录音（16kHz / 单声道 / PCM16 → WAV，与桌面端、安卓端、网页端互通）+ 语音播放。
//

import Foundation
import AVFoundation

@MainActor
final class VoiceRecorder: ObservableObject {

    /// 是否正在录音
    @Published var isRecording = false
    /// 已录时长（秒）
    @Published var seconds = 0
    /// 当前音量（0~1，用于波形动画）
    @Published var power: Float = 0
    /// 当前正在播放的 URL（nil 表示未播放）
    @Published var playingURL: URL? = nil

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var recordURL: URL?
    private var lastTickSecond = 0

    /// 采样率（与其它端互通的关键）
    static let sampleRate: Double = 16000

    // MARK: - 权限

    func requestPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - 录音

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord,
                                mode: .default,
                                options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice_\(UUID().uuidString).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: VoiceRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        rec.record()

        self.recorder = rec
        self.recordURL = url
        self.seconds = 0
        self.power = 0
        self.lastTickSecond = 0
        self.isRecording = true
        startTimer()
    }

    /// 停止录音并返回 WAV 文件地址
    func stop() -> URL? {
        guard let rec = recorder else { return nil }
        rec.stop()
        stopTimer()
        isRecording = false
        power = 0
        recorder = nil
        let url = recordURL
        recordURL = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return url
    }

    /// 取消录音（不保留文件）
    func cancel() {
        guard let rec = recorder else { return }
        let url = recordURL
        rec.stop()
        stopTimer()
        isRecording = false
        power = 0
        recorder = nil
        recordURL = nil
        if let url = url { try? FileManager.default.removeItem(at: url) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTimer() {
        stopTimer()
        // 0.1s 一次：读 metering 更新音量波形；每满整秒 seconds += 1
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tickMeter()
        }
    }

    private func tickMeter() {
        guard let rec = recorder else { return }
        rec.updateMeters()
        // averagePower(forChannel:) 返回 -160dB ~ 0dB，归一化到 0~1
        let avg = rec.averagePower(forChannel: 0)
        let peak = rec.peakPower(forChannel: 0)
        let db = max(avg, peak)
        let normalized = max(0, min(1, (db + 60) / 60))   // -60dB → 0, 0dB → 1
        // 波形更明显一点
        power = pow(normalized, 0.6)

        let elapsed = Int(Date().timeIntervalSince(rec.deviceCurrentTime > 0
            ? Date(timeIntervalSinceReferenceDate: 0) : Date()))
        // 简单用 seconds 自增：100ms 一次，每 10 次秒数 +1
        let _ = elapsed
        lastTickSecond += 1
        if lastTickSecond >= 10 {
            lastTickSecond = 0
            seconds += 1
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 播放

    /// 播放语音：点击同一个再次点击则停止
    func play(url: URL) async {
        if playingURL == url {
            stopPlay()
            return
        }
        stopPlay()

        var data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            if let result = try? await URLSession.shared.data(from: url) {
                data = result.0
            }
        }
        guard let audioData = data else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            let p = try AVAudioPlayer(data: audioData)
            p.prepareToPlay()
            p.play()
            player = p
            playingURL = url
        } catch {
            playingURL = nil
        }
    }

    func stopPlay() {
        player?.stop()
        player = nil
        playingURL = nil
    }
}
