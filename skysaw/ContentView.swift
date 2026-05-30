//
//  ContentView.swift
//  skysaw
//
//  Created by Chris Marstall on 5/30/26.
//

import SwiftUI
import CoreMotion
import Combine

struct ContentView: View {
    @StateObject private var motion: MotionService
    @StateObject private var sound: SoundEngine

    init() {
        _motion = StateObject(wrappedValue: MotionService())
        _sound = StateObject(wrappedValue: SoundEngine())
    }

    @State private var isActive = false
    // UI state for live controls
    @State private var uiGain: Double = 0.9
    @State private var uiStepInterval: Double = 0.20
    @State private var uiQuietInterval: Double = 0.05
    @State private var uiAttack: Double = 0.01
    @State private var uiDecay: Double = 0.12
    @State private var uiFrequency: Double = 40.0
    @State private var stepFlash: Bool = false

    private enum DetectMode: String, CaseIterable { case peak = "Peak", zero = "Zero-Cross", energy = "Energy" }
    @State private var mode: DetectMode? = nil // nil = stopped
    // Detector state
    @State private var lastTriggerTime: TimeInterval = 0
    @State private var refractory: TimeInterval = 0.25
    // Peak/hysteresis
    @State private var peakHigh: Double = 0.35
    @State private var peakLow: Double = 0.15
    @State private var aboveHigh: Bool = false
    // Zero-crossing band-pass (simple 1st-order HP+LP)
    @State private var zHP: Double = 0
    @State private var zBP: Double = 0
    @State private var prevZBP: Double = 0
    // Energy envelope
    @State private var env: Double = 0
    @State private var baseline: Double = 0
    @State private var envAlpha: Double = 0.1
    @State private var baseAlpha: Double = 0.01
    @State private var envK: Double = 2.0

    var body: some View {
        VStack(spacing: 24) {
            Text("Mindful Motion")
                .font(.largeTitle.bold())

            VStack(spacing: 8) {
                Text("Acceleration magnitude: \(motion.magnitude, specifier: "%.3f") g")
                    .font(.title3.monospacedDigit())
                HStack(spacing: 16) {
                    MetricView(name: "x", value: motion.acceleration.x)
                    MetricView(name: "y", value: motion.acceleration.y)
                    MetricView(name: "z", value: motion.acceleration.z)
                }
            }

            VStack(spacing: 8) {
                Text(motion.didStep ? "Step!" : "")
                    .font(.callout)
                    .animation(.easeOut(duration: 0.2), value: motion.didStep)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                Circle()
                    .fill(stepFlash ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 1)
                    )
                    .animation(.easeOut(duration: 0.15), value: stepFlash)
                Text(stepFlash ? "Step!" : "Waiting for step")
                    .font(.caption)
                    .foregroundStyle(stepFlash ? .green : .secondary)
                Spacer()
                Button {
                    // Simulate a step: flash indicator and play sound if active
                    stepFlash = true
                    if isActive { sound.playStepBlip() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        stepFlash = false
                    }
                } label: {
                    Label("Simulate Step", systemImage: "figure.walk")
                        .font(.caption)
                        .padding(8)
                }
                .buttonStyle(.bordered)
            }
            .accessibilityLabel("Step indicator and simulate step")

            HStack(spacing: 12) {
                ForEach(DetectMode.allCases, id: \.self) { m in
                    Button {
                        selectMode(m)
                    } label: {
                        Text(m.rawValue)
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(mode == m ? .blue : .gray)
                }
                Button {
                    stopAll()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding()
        .onAppear {
            motion.start()
            // Sync UI from engine
            uiGain = sound.gain
            uiStepInterval = sound.stepInterval
            uiQuietInterval = sound.quietInterval
            uiAttack = sound.attack
            uiDecay = sound.decay
            uiFrequency = sound.blipFrequency
        }
        .onChange(of: motion.didStep) { _, newValue in
            guard newValue else { return }
            // Flash the indicator
            stepFlash = true
            // Trigger the blip only if audio is active
            if isActive {
                sound.playStepBlip()
            }
            // Auto-reset the indicator after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                stepFlash = false
            }
        }
        .onChange(of: motion.acceleration) { _, acc in
            guard let mode else { return }
            let ts = Date().timeIntervalSince1970
            switch mode {
            case .peak:
                // magnitude relative to ~g
                let mag = max(0.0, sqrt(acc.x*acc.x + acc.y*acc.y + acc.z*acc.z) - 1.0)
                if !aboveHigh && mag > peakHigh { aboveHigh = true; trigger(at: ts) }
                if aboveHigh && mag < peakLow { aboveHigh = false }
            case .zero:
                // simple high-pass then low-pass to band-limit
                let hpAlpha = 0.05 // hp strength
                let lpAlpha = 0.2  // lp smoothing
                let z = acc.z
                zHP = (1 - hpAlpha) * zHP + hpAlpha * z
                let hp = z - zHP
                zBP = (1 - lpAlpha) * zBP + lpAlpha * hp
                let crossedUp = (prevZBP <= 0 && zBP > 0)
                if crossedUp { trigger(at: ts) }
                prevZBP = zBP
            case .energy:
                let mag = sqrt(acc.x*acc.x + acc.y*acc.y + acc.z*acc.z)
                env = (1 - envAlpha) * env + envAlpha * abs(mag - 1.0)
                baseline = (1 - baseAlpha) * baseline + baseAlpha * env
                let thresh = envK * max(baseline, 1e-6)
                if env > thresh { trigger(at: ts) }
            }
        }
        .onChange(of: uiGain) { _, v in sound.gain = v }
        .onChange(of: uiStepInterval) { _, v in sound.stepInterval = v }
        .onChange(of: uiQuietInterval) { _, v in sound.quietInterval = v }
        .onChange(of: uiAttack) { _, v in sound.attack = v }
        .onChange(of: uiDecay) { _, v in sound.decay = v }
        .onChange(of: uiFrequency) { _, v in sound.blipFrequency = v }
        .onDisappear {
            motion.stop()
            sound.stop()
            isActive = false
        }
    }

    // MARK: - Detection
    private func selectMode(_ newMode: DetectMode) {
        mode = newMode
        // Reset state
        lastTriggerTime = 0
        aboveHigh = false
        zHP = 0; zBP = 0; prevZBP = 0
        env = 0; baseline = 0
        // Start audio
        sound.start()
    }
    private func stopAll() {
        mode = nil
        sound.stop()
    }
    private func trigger(at ts: TimeInterval) {
        let now = ts
        if now - lastTriggerTime < refractory { return }
        lastTriggerTime = now
        // Flash UI
        stepFlash = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { stepFlash = false }
        // Play sound if audio running
        if sound.isRunning { sound.playStepBlip() }
    }
}

private struct MetricView: View {
    let name: String
    let value: Double

    var body: some View {
        VStack {
            Text(name)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.3f", value))
                .font(.body.monospacedDigit())
                .frame(minWidth: 64)
        }
        .padding(8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    ContentView()
}

