import CoreBluetooth
import ReplayKit
import SwiftUI

@main
struct BlueShotApp: App {
    @StateObject private var bluetooth = BluetoothAccess()
    @State private var picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 160, height: 160))

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 28) {
                Text("BlueShot").font(.largeTitle.bold())
                Text("Tap the button, then Start Broadcast. The screen is then sent to your PC over Bluetooth while you use any app. Locking the iPad ends the broadcast.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                PickerButton(picker: picker)
                    .frame(width: 160, height: 160)
                    .background(Circle().fill(Color.blue.opacity(0.15)))
                Text("Bluetooth: \(bluetooth.status)").font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            // blueshot://start opens the system sheet directly; only "Start Broadcast" is left to tap.
            // Opening the app while not broadcasting shows the start sheet at once, so a blind
            // Bluetooth sequence only has to tap "Start Broadcast".
            .onAppear {
                if !UIScreen.main.isCaptured { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { tap(picker) } }
            }
            .onOpenURL { url in
                if url.host == "start" { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { tap(picker) } }
            }
        }
    }

    private func tap(_ picker: RPSystemBroadcastPickerView) {
        for case let button as UIButton in picker.subviews { button.sendActions(for: .touchUpInside) }
    }
}

struct PickerButton: UIViewRepresentable {
    let picker: RPSystemBroadcastPickerView

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        // Sideloaders rewrite bundle ids, so read the extension's id from the bundle itself.
        if let plugins = Bundle.main.builtInPlugInsURL,
           let appex = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
               .first(where: { $0.pathExtension == "appex" }) {
            picker.preferredExtension = Bundle(url: appex)?.bundleIdentifier
        }
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ view: RPSystemBroadcastPickerView, context: Context) {}
}

/// Asks for Bluetooth permission once; the extension cannot show the prompt itself.
final class BluetoothAccess: NSObject, ObservableObject, CBPeripheralManagerDelegate {
    @Published var status = "…"
    private var manager: CBPeripheralManager?

    override init() {
        super.init()
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn: status = "ready"
        case .poweredOff: status = "off"
        case .unauthorized: status = "not allowed (Settings > BlueShot)"
        default: status = "unavailable"
        }
    }
}
