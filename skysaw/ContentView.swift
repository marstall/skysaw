//
//  ContentView.swift
//  skysaw
//
//  Created by Chris Marstall on 5/30/26.
//

import SwiftUI
import CoreMotion
import Combine

extension CMAcceleration: Equatable {
    public static func == (lhs: CMAcceleration, rhs: CMAcceleration) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z
    }
}

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

    private enum DetectMode: String, CaseIterable, Identifiable { case peak = "Peak", zero = "Zero-Cross", energy = "Energy"; var id: String { rawValue } }
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

    // MARK: - Subviews split out to help the type-checker
    @ViewBuilder private var titleSection: some View {
        Text("Mindful Motion")
            .font(.largeTitle.bold())
    }

    @ViewBuilder private var metricsSection: some View {
        VStack(spacing: 8) {
            Text("Acceleration magnitude: " + String(format: "%.3f", motion.magnitude) + " g")
                .font(.title3.monospacedDigit())
            HStack(spacing: 16) {
                MetricView(name: "x", value: motion.acceleration.x)
                MetricView(name: "y", value: motion.acceleration.y)
                MetricView(name: "z", value: motion.acceleration.z)
            }
        }
    }

    @ViewBuilder
    private var indicatorSection: some View {
        StepIndicatorView(isOn: motion.didStep)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var simulateSection: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stepFlash ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 16, height: 16)
                .overlay(
                    Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 1)
                )
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
    }

    @ViewBuilder
    private var modeButtonsSection: some View {
        HStack(spacing: 12) {
            ForEach(DetectMode.allCases) { m in
                let isSelected = (mode == m)
                Button(action: { selectMode(m) }) {
                    Text(m.rawValue)
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(isSelected ? .blue : .gray)
            }
            Button(action: { stopAll() }) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
            .tint(.red)
        }
    }

    var body: some View {
        mainContent
    }

    @ViewBuilder
    private var mainContent: some View {
        let stack = VStack(spacing: 24) {
            titleSection
            metricsSection
            indicatorSection
            simulateSection
            modeButtonsSection
        }
        stack
            .padding()
            .onAppear(perform: handleOnAppear)
            .onChange(of: motion.didStep, handleDidStepChange)
            .onChange(of: motion.acceleration, initial: false) { old, new in
                handleAccelerationChange(old, new)
            }
            .onChange(of: uiGain) { _, v in sound.gain = v }
            .onChange(of: uiStepInterval) { _, v in sound.stepInterval = v }
            .onChange(of: uiQuietInterval) { _, v in sound.quietInterval = v }
            .onChange(of: uiAttack) { _, v in sound.attack = v }
            .onChange(of: uiDecay) { _, v in sound.decay = v }
            .onChange(of: uiFrequency) { _, v in sound.blipFrequency = v }
            .onDisappear(perform: handleOnDisappear)
    }

    private func handleOnAppear() {
        motion.start()
        uiGain = sound.gain
        uiStepInterval = sound.stepInterval
        uiQuietInterval = sound.quietInterval
        uiAttack = sound.attack
        uiDecay = sound.decay
        uiFrequency = sound.blipFrequency
    }

    private func handleDidStepChange(_ old: Bool, _ newValue: Bool) {
        guard newValue else { return }
        withAnimation(.easeOut(duration: 0.2)) { stepFlash = true }
        if isActive { sound.playStepBlip() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.easeOut(duration: 0.2)) { stepFlash = false }
        }
    }

    private func handleAccelerationChange(_ old: CMAcceleration, _ acc: CMAcceleration) {
        guard let mode else { return }
        let ts = Date().timeIntervalSince1970
        switch mode {
        case .peak:
            let x = acc.x, y = acc.y, z = acc.z
            let magSquared = x*x + y*y + z*z
            let mag = max(0.0, sqrt(magSquared) - 1.0)
            if !aboveHigh && mag > peakHigh {
                aboveHigh = true
                trigger(at: ts)
            }
            if aboveHigh && mag < peakLow { aboveHigh = false }
        case .zero:
            let hpAlpha: Double = 0.05
            let lpAlpha: Double = 0.2
            let z = acc.z
            let newZHP = (1 - hpAlpha) * zHP + hpAlpha * z
            let hp = z - newZHP
            let newZBP = (1 - lpAlpha) * zBP + lpAlpha * hp
            let crossedUp = (prevZBP <= 0 && newZBP > 0)
            if crossedUp { trigger(at: ts) }
            zHP = newZHP
            prevZBP = newZBP
            zBP = newZBP
        case .energy:
            let x = acc.x, y = acc.y, z = acc.z
            let mag = sqrt(x*x + y*y + z*z)
            let newEnv = (1 - envAlpha) * env + envAlpha * abs(mag - 1.0)
            let newBaseline = (1 - baseAlpha) * baseline + baseAlpha * newEnv
            let thresh = envK * max(newBaseline, 1e-6)
            if newEnv > thresh { trigger(at: ts) }
            env = newEnv
            baseline = newBaseline
        }
    }

    private func handleOnDisappear() {
        motion.stop()
        sound.stop()
        isActive = false
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

private struct StepIndicatorView: View {
    let isOn: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Keep this simple to help the type-checker
            let opacity: Double = isOn ? 1.0 : 0.0
            Text("Step!")
                .font(.callout)
                .opacity(opacity)
        }
    }
}

#Preview {
    ContentView()
}

