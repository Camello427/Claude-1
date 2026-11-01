import SwiftUI
import AVKit

/// Choose which TV to cast to.
struct DevicePickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            List {
                if let item = app.pendingItem {
                    Section {
                        Label {
                            Text("Choose where to play “\(item.title)”").lineLimit(2)
                        } icon: {
                            Image(systemName: "play.tv")
                        }
                    }
                }

                ForEach(DeviceKind.allCases) { kind in
                    let list = app.devices.devices.filter { $0.kind == kind }
                    if !list.isEmpty {
                        Section(kind.label) {
                            ForEach(list) { device in
                                DeviceRow(device: device, selected: device.id == app.devices.selectedDeviceID) {
                                    app.choose(device)
                                }
                                .swipeActions {
                                    if device.isManual {
                                        Button(role: .destructive) { app.devices.removeManual(device) } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                if app.devices.devices.isEmpty {
                    Section {
                        if app.devices.isScanning {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Looking for TVs on your Wi-Fi…").foregroundStyle(.secondary)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("No TVs found yet").font(.headline)
                                Text("Make sure the TV is on and on the same Wi-Fi as this iPhone, then pull down to scan again. You can also add a device by its IP address below.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    HStack(spacing: 12) {
                        AirPlayButton()
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AirPlay")
                            Text("Apple TV and AirPlay TVs (many Samsung, LG, Sony, Vizio and Roku models). Tap the icon to pick one, then choose “Play on iPhone / AirPlay” for a video.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("AirPlay")
                }

                Section {
                    Button { showManual = true } label: {
                        Label("Add a device by IP address", systemImage: "plus.circle")
                    }
                    Button { Task { await app.devices.scan() } } label: {
                        Label(app.devices.isScanning ? "Scanning…" : "Scan again", systemImage: "arrow.clockwise")
                    }
                    .disabled(app.devices.isScanning)
                } footer: {
                    Text("Your iPhone and TV must be on the same Wi-Fi. If nothing shows up, check Settings › Privacy & Security › Local Network and make sure CastPilot is on.")
                }
            }
            .navigationTitle("Cast to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        app.pendingItem = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    if app.devices.isScanning { ProgressView() }
                }
            }
            .refreshable { await app.devices.scan() }
            .sheet(isPresented: $showManual) {
                ManualDeviceView().environment(app)
            }
        }
    }
}

struct DeviceRow: View {
    let device: CastDevice
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: device.kind.symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).foregroundStyle(.primary)
                    Text(device.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ManualDeviceView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var kind: DeviceKind = .dlna
    @State private var address = ""
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(DeviceKind.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("IP address, e.g. 192.168.1.50", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("You'll find the TV's IP address in its network settings. Your Wi-Fi router's app lists it too.")
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red) }
                }
                Section {
                    Button {
                        Task { await add() }
                    } label: {
                        HStack {
                            Text("Connect")
                            if working { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(address.isEmpty || working)
                }
            }
            .navigationTitle("Add device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func add() async {
        working = true
        errorText = nil
        defer { working = false }
        do {
            let device = try await app.devices.addManual(kind: kind, address: address)
            dismiss()
            app.choose(device)
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? "Couldn't reach a \(kind.label) at \(address)."
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.tintColor = .label
        view.activeTintColor = .tintColor
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
