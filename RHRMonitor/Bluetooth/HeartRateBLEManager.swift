import Foundation
import CoreBluetooth
import Observation
import HeartRateKit

/// A device seen during scanning, or already connected to this iPhone.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    var name: String
    var rssi: Int?
    var advertisesHeartRate: Bool
    var looksLikeWhoop: Bool
    /// Already connected at the system level (e.g. held by the official WHOOP app). Such
    /// devices stop advertising, so they are found with `retrieveConnectedPeripherals`.
    var connectedToSystem: Bool
}

struct BLELogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let message: String
}

struct BLEDiagnostics: Equatable {
    var notifications = 0
    var parseErrors = 0
    var implausible = 0
    var withRR = 0
    var noContact = 0
    var droppedTrailingBytes = 0
    var connects = 0
    var disconnects = 0
    var lastNotificationAt: Date?
    var meanInterval: Double?
    var maxInterval: Double = 0
    var intervalCount = 0
    var lastPacketHex = ""

    mutating func noteNotification(at date: Date) {
        if let last = lastNotificationAt {
            let dt = date.timeIntervalSince(last)
            // Ignore spacing across reconnects so the mean reflects the streaming cadence.
            if dt < 30 {
                intervalCount += 1
                meanInterval = ((meanInterval ?? 0) * Double(intervalCount - 1) + dt) / Double(intervalCount)
                maxInterval = max(maxInterval, dt)
            }
        }
        lastNotificationAt = date
        notifications += 1
    }
}

/// Connects to a heart rate sensor over the standard Bluetooth Heart Rate Service.
///
/// Read-only by design: the app discovers service 0x180D, subscribes to the Heart Rate
/// Measurement characteristic 0x2A37 and never writes to the strap, never touches WHOOP's
/// proprietary services and never initiates pairing. That keeps the official WHOOP app's bond
/// and functionality intact. The WHOOP service UUIDs are used only to *recognize* a strap that
/// is already connected to the iPhone.
///
/// All CoreBluetooth callbacks are delivered on the main queue.
@Observable
final class HeartRateBLEManager: NSObject {
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateMeasurement = CBUUID(string: "2A37")
    /// WHOOP 5.0/MG and WHOOP 4.0 vendor services — recognition only (see docs/ATTRIBUTION.md).
    static let whoopServices = [CBUUID(string: "FD4B0001-CCE1-4033-93CE-002D5875F58A"),
                                CBUUID(string: "61080001-8D6D-82B8-614A-1C8CB0F8DCC6")]
    static let restoreIdentifier = "rhrmonitor.ble.central"
    static let scanDuration: TimeInterval = 30

    private(set) var machine = ConnectionMachine()
    private(set) var discovered: [DiscoveredDevice] = []
    private(set) var isScanning = false
    private(set) var deviceID: UUID?
    private(set) var deviceName: String?
    private(set) var lastError: String?
    private(set) var diagnostics = BLEDiagnostics()
    private(set) var log: [BLELogEntry] = []
    private(set) var isActivated = false

    var phase: ConnectionPhase { machine.phase }
    var autoReconnect = true

    /// Called on the main queue for every successfully parsed notification.
    @ObservationIgnored var onMeasurement: ((HeartRateMeasurement, Date) -> Void)?
    /// Connection lifecycle events (kind, detail) for the recording's event log.
    @ObservationIgnored var onConnectionEvent: ((String, String) -> Void)?
    /// The selected device changed (persist it).
    @ObservationIgnored var onDeviceSelected: ((UUID?, String?) -> Void)?

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var knownPeripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var pendingScan = false
    @ObservationIgnored private var restoredPending = false
    @ObservationIgnored private var scanTimeout: DispatchWorkItem?
    @ObservationIgnored private var reconnectWork: DispatchWorkItem?

    init(savedDeviceID: UUID?, savedDeviceName: String?, autoReconnect: Bool) {
        self.deviceID = savedDeviceID
        self.deviceName = savedDeviceName
        self.autoReconnect = autoReconnect
        super.init()
        // Only create the central (which triggers the permission prompt) if permission was
        // already granted. Otherwise wait until the user asks to connect.
        if CBManager.authorization == .allowedAlways {
            activate()
        }
    }

    var authorization: CBManagerAuthorization { CBManager.authorization }

    var permissionDenied: Bool {
        CBManager.authorization == .denied || CBManager.authorization == .restricted
    }

    /// Creates the central manager. On first use this shows the Bluetooth permission prompt.
    func activate() {
        guard central == nil else { return }
        isActivated = true
        central = CBCentralManager(delegate: self, queue: .main, options: [
            CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
        addLog("Bluetooth central created")
    }

    // MARK: - User actions

    func startScan() {
        lastError = nil
        guard let central else {
            pendingScan = true
            activate()
            return
        }
        guard central.state == .poweredOn else {
            pendingScan = true
            return
        }
        apply(machine.handle(.startScan))
    }

    func stopScan() {
        pendingScan = false
        guard isScanning else { return }
        apply(machine.handle(.stopScan))
    }

    func connect(to id: UUID) {
        lastError = nil
        guard let central else { activate(); return }
        guard let p = knownPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            lastError = "That device is no longer available. Scan again."
            return
        }
        if let old = peripheral, old.identifier != id {
            peripheral = nil
            central.cancelPeripheralConnection(old)
        }
        select(p, name: discovered.first(where: { $0.id == id })?.name ?? p.name)
        apply(machine.handle(.connect))
    }

    /// Reconnects to the remembered device (e.g. after a manual disconnect).
    func reconnectSaved() {
        guard let id = deviceID else { return }
        connect(to: id)
    }

    func disconnect() {
        reconnectWork?.cancel()
        addLog("Disconnect requested by user")
        onConnectionEvent?("user_disconnected", deviceName ?? "")
        apply(machine.handle(.userDisconnect))
    }

    func forget() {
        reconnectWork?.cancel()
        addLog("Forgetting device")
        apply(machine.handle(.forget))
        peripheral = nil
        deviceID = nil
        deviceName = nil
        onDeviceSelected?(nil, nil)
    }

    // MARK: - Internals

    private func select(_ p: CBPeripheral, name: String?) {
        peripheral = p
        p.delegate = self
        knownPeripherals[p.identifier] = p
        deviceID = p.identifier
        deviceName = (name?.isEmpty == false ? name : nil) ?? p.name ?? "Heart rate sensor"
        onDeviceSelected?(p.identifier, deviceName)
    }

    private func apply(_ effects: [ConnectionMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .startScan:
                beginScan()
            case .stopScan:
                scanTimeout?.cancel()
                if isScanning { central?.stopScan() }
                isScanning = false
            case .connectPeripheral:
                connectSelected()
            case .scheduleReconnect(let delay):
                addLog(String(format: "Retrying connection in %.0f s", delay))
                reconnectWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.machine.wantsConnection else { return }
                    self.connectSelected()
                }
                reconnectWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            case .cancelPeripheral:
                if let p = peripheral { central?.cancelPeripheralConnection(p) }
            case .discoverServices:
                peripheral?.discoverServices([Self.heartRateService])
            }
        }
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }
        discovered.removeAll()
        // A strap connected to this iPhone (e.g. by the WHOOP app) does not advertise; list it too.
        for p in central.retrieveConnectedPeripherals(withServices: [Self.heartRateService] + Self.whoopServices) {
            knownPeripherals[p.identifier] = p
            let name = p.name ?? "Connected device"
            upsert(DiscoveredDevice(id: p.identifier, name: name, rssi: nil, advertisesHeartRate: false,
                                    looksLikeWhoop: name.uppercased().contains("WHOOP"), connectedToSystem: true))
        }
        // No service filter in the foreground: some straps include the Heart Rate UUID only in
        // the scan response, so we also match on the advertised name.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        isScanning = true
        addLog("Scanning for heart rate devices")
        scanTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.stopScan() }
        scanTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanDuration, execute: work)
    }

    private func upsert(_ d: DiscoveredDevice) {
        if let i = discovered.firstIndex(where: { $0.id == d.id }) {
            var merged = d
            merged.connectedToSystem = discovered[i].connectedToSystem || d.connectedToSystem
            merged.advertisesHeartRate = discovered[i].advertisesHeartRate || d.advertisesHeartRate
            if d.rssi == nil { merged.rssi = discovered[i].rssi }
            discovered[i] = merged
        } else {
            discovered.append(d)
        }
        discovered.sort { ($0.looksLikeWhoop ? 0 : 1, -($0.rssi ?? -200)) < ($1.looksLikeWhoop ? 0 : 1, -($1.rssi ?? -200)) }
    }

    private func connectSelected() {
        guard let central, central.state == .poweredOn else { return }
        if peripheral == nil, let id = deviceID, let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            select(p, name: deviceName)
        }
        guard let p = peripheral else {
            lastError = "The saved device could not be found. Scan to select it again."
            apply(machine.handle(.forget))
            return
        }
        addLog("Connecting to \(deviceName ?? p.identifier.uuidString)")
        // An iOS connection request never times out: it completes whenever the strap is in range,
        // including while the app is in the background.
        central.connect(p, options: nil)
    }

    func addLog(_ message: String) {
        log.append(BLELogEntry(date: Date(), message: message))
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    private static func availability(_ state: CBManagerState) -> BluetoothAvailability {
        switch state {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .resetting: return .resetting
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension HeartRateBLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let availability = Self.availability(central.state)
        let wasOn = machine.bluetooth == .poweredOn
        addLog("Bluetooth state: \(availability.rawValue)")
        if wasOn && availability != .poweredOn {
            onConnectionEvent?("bluetooth_unavailable", availability.rawValue)
        }
        apply(machine.handle(.bluetooth(availability)))
        guard availability == .poweredOn else { return }

        if restoredPending, let p = peripheral {
            restoredPending = false
            _ = machine.handle(.connect) // mark the connection as wanted without issuing effects
            if p.state == .connected {
                addLog("Restored connection — re-subscribing")
                apply(machine.handle(.didConnect))
            } else {
                connectSelected()
            }
        } else if machine.phase == .disconnected, autoReconnect, let id = deviceID {
            addLog("Auto-reconnecting to saved device")
            connect(to: id)
        }

        if pendingScan {
            pendingScan = false
            apply(machine.handle(.startScan))
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first(where: { $0.identifier == deviceID }) ?? peripherals.first else { return }
        select(p, name: deviceName ?? p.name)
        restoredPending = true
        addLog("iOS restored the Bluetooth session")
        onConnectionEvent?("restored", deviceName ?? "")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let hr = services.contains(Self.heartRateService)
        let whoop = name.uppercased().contains("WHOOP") || services.contains(where: { Self.whoopServices.contains($0) })
        guard hr || whoop else { return }
        knownPeripherals[peripheral.identifier] = peripheral
        let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue
        upsert(DiscoveredDevice(id: peripheral.identifier, name: name.isEmpty ? "Heart rate sensor" : name, rssi: rssi,
                                advertisesHeartRate: hr, looksLikeWhoop: whoop, connectedToSystem: false))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        diagnostics.connects += 1
        addLog("Connected — discovering Heart Rate service")
        onConnectionEvent?("connected", deviceName ?? "")
        apply(machine.handle(.didConnect))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        let detail = error?.localizedDescription ?? "unknown error"
        addLog("Connection failed: \(detail)")
        onConnectionEvent?("connect_failed", detail)
        apply(machine.handle(.didFailToConnect))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == self.peripheral?.identifier else { return }
        diagnostics.disconnects += 1
        let detail = error?.localizedDescription ?? ""
        let unexpected = machine.wantsConnection
        addLog(unexpected ? "Connection lost\(detail.isEmpty ? "" : ": \(detail)") — will reconnect" : "Disconnected")
        if unexpected { onConnectionEvent?("connection_lost", detail) }
        apply(machine.handle(.didDisconnect))
    }
}

// MARK: - CBPeripheralDelegate

extension HeartRateBLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            addLog("Service discovery failed: \(error.localizedDescription)")
            lastError = "Service discovery failed: \(error.localizedDescription)"
            central?.cancelPeripheralConnection(peripheral) // triggers a reconnect if still wanted
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.heartRateService }) else {
            addLog("Device has no standard Heart Rate service")
            lastError = "This device isn't sharing heart rate. In the WHOOP app, turn on Heart Rate Broadcast, then connect again."
            onConnectionEvent?("service_missing", "")
            apply(machine.handle(.serviceMissing))
            return
        }
        peripheral.discoverCharacteristics([Self.heartRateMeasurement], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let c = service.characteristics?.first(where: { $0.uuid == Self.heartRateMeasurement }) else {
            addLog("Heart Rate Measurement characteristic missing\(error.map { ": \($0.localizedDescription)" } ?? "")")
            lastError = "The Heart Rate Measurement characteristic was not found."
            apply(machine.handle(.serviceMissing))
            return
        }
        peripheral.setNotifyValue(true, for: c)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.heartRateMeasurement else { return }
        if let error {
            addLog("Subscribe failed: \(error.localizedDescription)")
            lastError = "Couldn't subscribe to heart rate: \(error.localizedDescription)"
            return
        }
        if characteristic.isNotifying {
            addLog("Subscribed to heart rate notifications")
            onConnectionEvent?("subscribed", "")
            apply(machine.handle(.subscribed))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.heartRateMeasurement, error == nil, let data = characteristic.value else { return }
        // Timestamp at delivery; the standard characteristic carries no time of its own.
        let now = Date()
        diagnostics.noteNotification(at: now)
        diagnostics.lastPacketHex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        do {
            let m = try HeartRateMeasurementParser.parse(data)
            if !m.isPlausible { diagnostics.implausible += 1 }
            if !m.rrIntervalsMs.isEmpty { diagnostics.withRR += 1 }
            if m.sensorContact == .notDetected { diagnostics.noContact += 1 }
            if m.droppedTrailingByte { diagnostics.droppedTrailingBytes += 1 }
            onMeasurement?(m, now)
        } catch {
            diagnostics.parseErrors += 1
        }
    }
}
