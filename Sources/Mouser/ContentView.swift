import SwiftUI

struct ContentView: View {
    @EnvironmentObject var mouse: MouseController

    var body: some View {
        Form {
            deviceSection
            Section("macOS Tracking Speed") {
                Slider(value: $mouse.systemSpeed, in: SystemPointer.range,
                       label: { Text("Speed") },
                       minimumValueLabel: { Text("Slow") },
                       maximumValueLabel: { Text("Fast") },
                       onEditingChanged: { if !$0 { mouse.applySystemSpeed() } })
            }
            if let spec = mouse.spec {
                if spec.dpi != nil || spec.poll != nil { sensitivitySection(spec) }
                ForEach(spec.zones, id: \.zone) { lightingSection($0) }
            }
            buttonsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 560)
    }

    private var deviceSection: some View {
        Section {
            if let spec = mouse.spec {
                LabeledContent(spec.name, value: mouse.firmware.map { "Firmware \($0)" } ?? "")
                if let b = mouse.battery {
                    LabeledContent("Battery", value: "\(b.percent)%" + (b.charging ? " (charging)" : ""))
                }
            } else {
                Text(mouse.unsupportedRazer ? "Razer device found, but this model isn't supported yet."
                                            : "No supported Razer mouse connected.")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            if let spec = mouse.spec, !spec.tested {
                Text("This model hasn't been tested with Mouser yet. Settings are based on openrazer's data.")
            }
        }
    }

    private func sensitivitySection(_ spec: DeviceSpec) -> some View {
        Section {
            if spec.stagesTID != nil, !mouse.stages.isEmpty {
                LabeledContent("Current DPI", value: mouse.currentDPI.map(String.init) ?? "–")
                Picker("Active stage", selection: Binding(get: { mouse.activeStage },
                                                          set: { mouse.activeStage = $0; mouse.applyStages() })) {
                    ForEach(mouse.stages.indices, id: \.self) { Text("\($0 + 1)").tag($0) }
                }
                .pickerStyle(.segmented)
                ForEach(mouse.stages.indices, id: \.self) { i in
                    HStack {
                        Text("Stage \(i + 1)")
                        dpiSlider(Binding(get: { mouse.stages[i] }, set: { mouse.stages[i] = $0 })) { mouse.applyStages() }
                        Button(role: .destructive) { mouse.removeStage(at: i) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .disabled(mouse.stages.count <= 1)
                    }
                }
                Button("Add Stage", action: mouse.addStage).disabled(mouse.stages.count >= 5)
            } else if spec.dpi != nil {
                HStack {
                    Text("DPI")
                    dpiSlider(Binding(get: { mouse.currentDPI ?? 800 }, set: { mouse.currentDPI = $0 })) { mouse.applyDPI() }
                }
            }
            if let poll = spec.poll {
                Picker("Polling rate", selection: $mouse.pollingRate) {
                    ForEach(poll.rates, id: \.self) { Text("\($0) Hz").tag($0) }
                }
                .onChange(of: mouse.pollingRate) { mouse.applyPollingRate() }
            }
        } header: {
            Text("Mouse Sensitivity (DPI)")
        } footer: {
            if spec.stagesTID != nil { Text("The DPI button on the mouse cycles these stages. Saved on the mouse.") }
        }
    }

    private func dpiSlider(_ value: Binding<Int>, onCommit: @escaping () -> Void) -> some View {
        HStack {
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0) }),
                   in: Double(mouse.minDPI)...Double(mouse.maxDPI), step: 50,
                   onEditingChanged: { if !$0 { onCommit() } })
            Text("\(value.wrappedValue)").monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }

    private func lightingSection(_ z: ZoneSpec) -> some View {
        let state = Binding(get: { mouse.lights[z.zone] ?? LightState() }, set: { mouse.lights[z.zone] = $0 })
        let effects = LightingEffect.allCases.filter { z.effects[$0] != nil }
        return Section(z.zone.title) {
            if !effects.isEmpty {
                Picker("Effect", selection: state.effect) {
                    ForEach(effects) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: state.wrappedValue.effect) { mouse.applyLighting(z.zone) }
                if state.wrappedValue.effect.usesColor {
                    ColorPicker("Color", selection: state.color, supportsOpacity: false)
                        .onChange(of: state.wrappedValue.color) { mouse.applyLighting(z.zone) }
                }
            }
            if z.brightness != nil, state.wrappedValue.effect != .off || effects.isEmpty {
                Slider(value: state.brightness, in: 0...100,
                       onEditingChanged: { if !$0 { mouse.applyBrightness(z.zone) } }) { Text("Brightness") }
            }
        }
    }

    private var buttonsSection: some View {
        Section {
            ForEach(MouseButton.allCases) { button in
                Picker(button.title, selection: Binding(get: { mouse.mapping[button.rawValue] ?? .standard },
                                                        set: { mouse.setAction($0, for: button) })) {
                    ForEach(ButtonAction.allCases) { Text($0.title).tag($0) }
                }
            }
            if !mouse.accessibilityGranted {
                Button("Allow Accessibility Access…", action: mouse.requestAccessibility)
            }
        } header: {
            Text("Buttons")
        } footer: {
            Text("Custom actions need Accessibility access and work while Mouser is running.")
        }
    }
}
