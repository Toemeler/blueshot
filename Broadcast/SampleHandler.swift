import CoreBluetooth
import CoreImage
import ReplayKit

/// Runs as its own process while the broadcast is on, whatever app is in front.
/// Keeps the newest screen frame and hands it to the Bluetooth sender on request.
final class SampleHandler: RPBroadcastSampleHandler {
    private let sender = Sender()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        sender.start()
    }

    override func broadcastFinished() {
        sender.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var orientation = CGImagePropertyOrientation.up
        if let raw = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                     attachmentModeOut: nil) as? NSNumber,
           let value = CGImagePropertyOrientation(rawValue: raw.uint32Value) {
            orientation = value
        }
        sender.setFrame(pixels, orientation: orientation)
    }
}

/// BLE peripheral. Protocol (all little endian):
///   PC writes to `control`: [0x01][maxWidth u16][quality u8 1-100][knownSeq u32]
///   iPad notifies on `data`: header [0xB5][0x01][seq u32][length u32][width u16][height u16],
///   then `length` bytes of JPEG split over as many notifications as needed.
///   length 0 = the screen has not changed since knownSeq.
final class Sender: NSObject, CBPeripheralManagerDelegate {
    static let service = CBUUID(string: "B5C0A1E0-6F1D-4E7A-9C3B-2D4F5A6B7C80")
    static let control = CBUUID(string: "B5C0A1E0-6F1D-4E7A-9C3B-2D4F5A6B7C81")
    static let data = CBUUID(string: "B5C0A1E0-6F1D-4E7A-9C3B-2D4F5A6B7C82")

    private let queue = DispatchQueue(label: "blueshot.ble")
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var manager: CBPeripheralManager?
    private var dataCharacteristic: CBMutableCharacteristic?

    private let lock = NSLock()
    private var frame: CVPixelBuffer?
    private var orientation = CGImagePropertyOrientation.up
    private var frameSeq: UInt32 = 0

    private var packets: [Data] = []
    private var next = 0
    private var retryScheduled = false

    func start() {
        queue.async { self.manager = CBPeripheralManager(delegate: self, queue: self.queue) }
    }

    func stop() {
        queue.sync {
            manager?.stopAdvertising()
            manager?.removeAllServices()
            manager = nil
        }
    }

    func setFrame(_ pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        lock.lock()
        frame = pixels
        self.orientation = orientation
        frameSeq &+= 1
        lock.unlock()
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        let data = CBMutableCharacteristic(type: Self.data, properties: [.notify],
                                           value: nil, permissions: [])
        let control = CBMutableCharacteristic(type: Self.control,
                                              properties: [.write, .writeWithoutResponse],
                                              value: nil, permissions: [.writeable])
        let service = CBMutableService(type: Self.service, primary: true)
        service.characteristics = [control, data]
        peripheral.removeAllServices()
        peripheral.add(service)
        dataCharacteristic = data
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.service],
                                     CBAdvertisementDataLocalNameKey: "BlueShot"])
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == Self.control {
            if let value = request.value { handle(value, mtu: request.central.maximumUpdateValueLength) }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pump()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        // Shortest connection interval the PC allows: more packets per second.
        peripheral.setDesiredConnectionLatency(.low, for: central)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        packets = []
        next = 0
    }

    private func handle(_ request: Data, mtu: Int) {
        let bytes = [UInt8](request)
        guard bytes.count >= 8, bytes[0] == 0x01 else { return }
        let maxWidth = Int(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        let quality = Double(max(1, min(100, Int(bytes[3])))) / 100
        let knownSeq = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24

        lock.lock()
        let pixels = frame, orientation = self.orientation, seq = frameSeq
        lock.unlock()

        var jpeg = Data(), width = 0, height = 0
        if let pixels, seq != knownSeq {
            var image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
            if maxWidth > 0, image.extent.width > CGFloat(maxWidth) {
                let scale = CGFloat(maxWidth) / image.extent.width
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            width = Int(image.extent.width.rounded())
            height = Int(image.extent.height.rounded())
            let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
            jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(),
                                              options: options) ?? Data()
        }

        var header = Data([0xB5, 0x01])
        header.append(le(seq))
        header.append(le(UInt32(jpeg.count)))
        header.append(le(UInt16(clamping: width)))
        header.append(le(UInt16(clamping: height)))

        // A new request replaces whatever was still being sent.
        packets = [header]
        let chunk = max(20, mtu)
        var offset = 0
        while offset < jpeg.count {
            let end = min(offset + chunk, jpeg.count)
            packets.append(jpeg.subdata(in: offset..<end))
            offset = end
        }
        next = 0
        pump()
    }

    private func pump() {
        guard let manager, let dataCharacteristic else { return }
        while next < packets.count {
            guard manager.updateValue(packets[next], for: dataCharacteristic, onSubscribedCentrals: nil) else {
                // Queue full. peripheralManagerIsReady resumes, but it often comes late
                // (measured: 1 packet per 75-165 ms), so also retry soon ourselves.
                if !retryScheduled {
                    retryScheduled = true
                    queue.asyncAfter(deadline: .now() + .milliseconds(4)) { self.retryScheduled = false; self.pump() }
                }
                return
            }
            next += 1
        }
        packets = []
        next = 0
    }

    private func le<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
