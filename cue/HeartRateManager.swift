//
//  HeartRateManager.swift
//  cue
//
//  Continuous BLE + HealthKit Heart Rate Manager
//  nRF Connect–style live scanning
//

import Foundation
import CoreBluetooth
import HealthKit
import Combine

// MARK: - Models

enum HRDeviceType {
    case healthKit
    case bluetooth
}

struct HRDevice: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let type: HRDeviceType
    var peripheral: CBPeripheral?
    var rssi: Int
    var lastSeen: Date = Date()
}

enum ConnectionStatus {
    case disconnected
    case scanning
    case connecting
    case connected(HRDevice)
    case error(String)
}

// MARK: - HeartRateManager

final class HeartRateManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var discoveredDevices: [HRDevice] = []
    @Published var status: ConnectionStatus = .disconnected
    @Published var currentHeartRate: Int = 0
    @Published var heartRateHistory: [Int] = []
    @Published var sessionMaxHeartRate: Int = 0
    @Published var isSimulationMode: Bool = false
    let maxHeartRate: Int = 190

    private let maxHistoryPoints = 60

    // MARK: - Bluetooth

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?

    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementUUID = CBUUID(string: "2A37")

    // MARK: - HealthKit

    private let healthStore = HKHealthStore()
    private var heartRateQuery: HKAnchoredObjectQuery?

    // MARK: - Scanning State

    private var wantsScan = false
    private var isScanning = false
    private var scanHeartbeat: AnyCancellable?

    // MARK: - Init

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        print("CBCentralManager initialized")
    }

    // MARK: - Heart Rate History

    private func updateHistory(with bpm: Int) {
        guard !isSimulationMode else { return }
        processBPM(bpm)
    }

    func simulateHeartRate(_ bpm: Int) {
        guard isSimulationMode else { return }
        processBPM(bpm)
    }

    private func processBPM(_ bpm: Int) {
        currentHeartRate = bpm

        if bpm > 0 {
            if bpm > sessionMaxHeartRate {
                sessionMaxHeartRate = bpm
            }
            
            heartRateHistory.append(bpm)
            if heartRateHistory.count > maxHistoryPoints {
                heartRateHistory.removeFirst()
            }
        }
    }

    // MARK: - Scanning (nRF-style)

    func startScanning() {
        wantsScan = true
        status = .scanning

        print("Starting BLE scan")
        
        // Add Apple Watch if HealthKit is available
        if HKHealthStore.isHealthDataAvailable(),
           !discoveredDevices.contains(where: { $0.type == .healthKit }) {
            discoveredDevices.append(
                HRDevice(name: "Apple Watch", type: .healthKit, peripheral: nil, rssi: 100)
            )
            print("Added Apple Watch to device list")
        }
        
        // Traditional BLE scanning - works on all iOS versions
        startScanHeartbeat()
    }

    func stopScanning() {
        wantsScan = false
        isScanning = false
        scanHeartbeat?.cancel()
        scanHeartbeat = nil

        if centralManager.state == .poweredOn {
            centralManager.stopScan()
            print("🛑 Scan stopped by user")
        }

        status = .disconnected
    }

    private func startScanHeartbeat() {
        scanHeartbeat?.cancel()

        scanHeartbeat = Timer
            .publish(every: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                guard self.wantsScan,
                      self.centralManager.state == .poweredOn
                else { return }

                if !self.isScanning {
                    print("Restarting BLE scan (watchdog)")
                    self.scanBLE()
                }
            }
    }

    private func scanBLE() {
        guard !isScanning else { return }
        isScanning = true

        print("Starting continuous BLE scan")

        // Pick up already-connected HR devices
        let connected = centralManager.retrieveConnectedPeripherals(
            withServices: [heartRateServiceUUID]
        )

        for peripheral in connected {
            addOrUpdate(peripheral, rssi: -40)
        }

        // Only scan for Heart Rate monitors (service UUID 180D)
        centralManager.scanForPeripherals(
            withServices: [heartRateServiceUUID],  // Only HR monitors
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    // MARK: - Connect / Disconnect

    func connect(to device: HRDevice) {
        stopScanning()
        status = .connecting

        switch device.type {
        case .healthKit:
            connectHealthKit()

        case .bluetooth:
            guard let peripheral = device.peripheral else {
                status = .error("Invalid peripheral")
                return
            }

            connectedPeripheral = peripheral
            peripheral.delegate = self
            centralManager.connect(peripheral)

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self = self else { return }
                if case .connecting = self.status {
                    self.centralManager.cancelPeripheralConnection(peripheral)
                    self.status = .error("Connection timed out")
                }
            }
        }
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        if let query = heartRateQuery {
            healthStore.stop(query)
            heartRateQuery = nil
        }

        connectedPeripheral = nil
        currentHeartRate = 0
        status = .disconnected
    }

    // MARK: - HealthKit (Apple Watch)

    private func connectHealthKit() {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }

        healthStore.requestAuthorization(toShare: [], read: [hrType]) { [weak self] success, _ in
            DispatchQueue.main.async {
                if success {
                    self?.startHeartRateQuery()
                    // Set connected status immediately
                    self?.status = .connected(
                        HRDevice(name: "Apple Watch", type: .healthKit, peripheral: nil, rssi: 100)
                    )
                    
                    // Add Apple Watch to discovered devices if not already there
                    if let self = self, !self.discoveredDevices.contains(where: { $0.type == .healthKit }) {
                        self.discoveredDevices.append(
                            HRDevice(name: "Apple Watch", type: .healthKit, peripheral: nil, rssi: 100)
                        )
                    }
                } else {
                    self?.status = .error("HealthKit permission denied")
                }
            }
        }
    }

    private func startHeartRateQuery() {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }

        let predicate = HKQuery.predicateForSamples(
            withStart: Date(),
            end: nil,
            options: .strictStartDate
        )

        let query = HKAnchoredObjectQuery(
            type: hrType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, _ in
            self?.handle(samples)
        }

        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.handle(samples)
        }

        heartRateQuery = query
        healthStore.execute(query)
    }

    private func handle(_ samples: [HKSample]?) {
        guard let sample = (samples as? [HKQuantitySample])?.last else { return }
        let unit = HKUnit.count().unitDivided(by: .minute())
        let bpm = Int(sample.quantity.doubleValue(for: unit))
        updateHistory(with: bpm)
    }

    // MARK: - Device List Management

    private func addOrUpdate(_ peripheral: CBPeripheral, rssi: Int) {
        let name = peripheral.name ?? "Heart Rate Monitor"

        if let index = discoveredDevices.firstIndex(where: {
            $0.peripheral?.identifier == peripheral.identifier
        }) {
            discoveredDevices[index].rssi = rssi
            discoveredDevices[index].lastSeen = Date()
        } else {
            discoveredDevices.append(
                HRDevice(
                    name: name,
                    type: .bluetooth,
                    peripheral: peripheral,
                    rssi: rssi
                )
            )
        }

        discoveredDevices.sort { $0.rssi > $1.rssi }
    }
}

// MARK: - CBCentralManagerDelegate

extension HeartRateManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateNames = ["Unknown", "Resetting", "Unsupported", "Unauthorized", "PoweredOff", "PoweredOn"]
        let stateName = central.state.rawValue < stateNames.count ? stateNames[Int(central.state.rawValue)] : "Invalid"
        print("🔵 Bluetooth state changed: \(stateName) (raw: \(central.state.rawValue))")
        print("   wantsScan: \(wantsScan)")

        if central.state == .poweredOn && wantsScan {
            print("   Starting scan now...")
            scanBLE()
        } else if central.state != .poweredOn {
            print("   Cannot scan - Bluetooth not ready")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        // DEBUG LOG — this is what nRF Connect effectively does
        print("Discovered: \(peripheral.name ?? "Unknown") RSSI: \(RSSI) adv: \(advertisementData.keys)")

        let rawRSSI = RSSI.intValue

        // RSSI 127 = "not available" → normalize instead of dropping
        let normalizedRSSI = rawRSSI == 127 ? -100 : rawRSSI

        addOrUpdate(peripheral, rssi: normalizedRSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = .connected(
            HRDevice(
                name: peripheral.name ?? "Heart Rate Monitor",
                type: .bluetooth,
                peripheral: peripheral,
                rssi: -40
            )
        )

        peripheral.discoverServices([heartRateServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        status = .disconnected
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // Connection failed - reset to disconnected state
        status = .error("Connection failed")
        
        // Auto-retry after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.status = .disconnected
        }
    }
}

// MARK: - CBPeripheralDelegate

extension HeartRateManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        peripheral.services?
            .filter { $0.uuid == heartRateServiceUUID }
            .forEach {
                peripheral.discoverCharacteristics([heartRateMeasurementUUID], for: $0)
            }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        service.characteristics?
            .filter { $0.uuid == heartRateMeasurementUUID }
            .forEach {
                peripheral.setNotifyValue(true, for: $0)
            }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard
            characteristic.uuid == heartRateMeasurementUUID,
            let data = characteristic.value
        else { return }

        let bytes = [UInt8](data)
        let bpm: Int

        if bytes.count > 1 {
            bpm = (bytes[0] & 0x01) == 0
                ? Int(bytes[1])
                : Int(bytes[1]) | (Int(bytes[2]) << 8)
        } else {
            return
        }

        updateHistory(with: bpm)
    }
}
