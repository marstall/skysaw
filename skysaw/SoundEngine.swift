import Foundation
import AVFoundation
import Combine

final class SoundEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!

    @Published var isRunning: Bool = false

    // Parameters controlled by motion
    private let sampleRate: Double
    private var phase: Double = 0
    private var frequency: Double = 220 // Hz
    private var amplitude: Double = 0.0 // 0...1

    private var envValue: Double = 0.0
    private var envPhase: Double = 0.0
    private var envAttack: Double = 0.01 // seconds
    private var envDecay: Double = 0.12 // seconds
    private var envActive: Bool = false
    private var stepBaseFrequency: Double = 40.0

    // Blip tuning
    private var blipGain: Double = 0.9 // overall blip loudness 0...1
    private var minimumStepInterval: Double = 0.20 // seconds between accepted triggers
    // Sample counters for debouncing
    private var currentSample: Int64 = 0
    private var lastTriggerSample: Int64 = -1
    // Quiet period hysteresis
    private var quietSamples: Int64 = 0
    private var minimumQuietInterval: Double = 0.05 // seconds of silence required before next trigger

    // MARK: - Public controls (thread-safe-ish with clamping)
    var gain: Double {
        get { blipGain }
        set { blipGain = max(0.0, min(1.0, newValue)) }
    }
    var stepInterval: Double {
        get { minimumStepInterval }
        set { minimumStepInterval = max(0.05, min(1.0, newValue)) } // clamp 50ms..1s
    }
    var quietInterval: Double {
        get { minimumQuietInterval }
        set { minimumQuietInterval = max(0.0, min(0.5, newValue)) } // clamp 0..500ms
    }
    var attack: Double {
        get { envAttack }
        set { envAttack = max(0.001, min(0.2, newValue)) } // 1ms..200ms
    }
    var decay: Double {
        get { envDecay }
        set { envDecay = max(0.03, min(1.0, newValue)) } // 30ms..1s
    }
    var blipFrequency: Double {
        get { stepBaseFrequency }
        set { stepBaseFrequency = max(20.0, min(200.0, newValue)) } // 20..200 Hz
    }

    init() {
        let output = engine.outputNode
        let hwFormat = output.outputFormat(forBus: 0)
        sampleRate = hwFormat.sampleRate

        sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let attackSamples = max(1, Int(self.envAttack * self.sampleRate))
            let decaySamples = max(1, Int(self.envDecay * self.sampleRate))
            let thetaIncrement = (2.0 * Double.pi * self.stepBaseFrequency) / self.sampleRate
            
            // envActive and values are updated below; sample counters advance each frame
            for frame in 0..<Int(frameCount) {
                // envelope update
                if self.envActive {
                    if self.envPhase < Double(attackSamples) {
                        self.envValue = Double(self.envPhase) / Double(attackSamples)
                    } else {
                        let d = max(0.0, 1.0 - ((self.envPhase - Double(attackSamples)) / Double(decaySamples)))
                        self.envValue = d
                    }
                    self.envPhase += 1
                    self.quietSamples = 0
                    if self.envPhase >= (Double(attackSamples) + Double(decaySamples)) {
                        self.envActive = false
                        self.envPhase = 0
                        self.envValue = 0
                    }
                } else {
                    self.envValue = 0
                    self.quietSamples += 1
                }
                self.currentSample += 1
                // generate 40 Hz sine scaled by envelope
                let sample = Float(sin(self.phase) * (self.envValue * self.blipGain))
                self.phase += thetaIncrement
                if self.phase > 2.0 * Double.pi { self.phase -= 2.0 * Double.pi }
                for buffer in ablPointer {
                    let buf: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
                    buf[frame] = sample
                }
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: output, format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
    }

    func playStepBlip() {
        // Debounce extremely rapid successive triggers and require a quiet period
        let minSamplesBetweenTriggers = Int64(self.minimumStepInterval * self.sampleRate)
        let minQuietSamples = Int64(self.minimumQuietInterval * self.sampleRate)
        if lastTriggerSample >= 0 && (currentSample - lastTriggerSample) < minSamplesBetweenTriggers {
            return
        }
        if quietSamples < minQuietSamples {
            return
        }
        // force a new envelope by resetting state; start sine at a consistent phase
        envActive = true
        envPhase = 0
        envValue = 0
        phase = 0 // consistent transient
        lastTriggerSample = currentSample
    }

    func start() {
        guard !engine.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            DispatchQueue.main.async { self.isRunning = true }
        } catch {
            print("Audio engine start error: \(error)")
        }
    }

    func stop() {
        engine.stop()
        DispatchQueue.main.async { self.isRunning = false }
    }

    func update(frequency: Double, amplitude: Double) {
        // Clamp inputs to sane ranges
        let clampedAmp = max(0.0, min(1.0, amplitude))
        let clampedFreq = max(60.0, min(2000.0, frequency))
        self.frequency = clampedFreq
        self.amplitude = clampedAmp
    }
}

