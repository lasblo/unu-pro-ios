//
//  UnuScooterManager.swift
//  unu pro
//
//  Created by Lasse on 24.01.25.
//

import SwiftUI
import CoreBluetooth
import Combine

@MainActor
class UnuScooterManager: NSObject, ObservableObject {
    
    // MARK: - Published & Public Properties
    
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isLocked = true
    @Published private(set) var statusMessage = ""
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var currentState: ScooterState = .disconnected
    @Published private(set) var pendingStartScan = false
    
    @Published var hazardLightsOn = false
    
    // Battery Percentages
    @Published private(set) var primaryBatteryPercent: Int = 0
    @Published private(set) var secondaryBatteryPercent: Int = 0
    @Published private(set) var cbbBatteryPercent: Int = 0
    @Published private(set) var auxBatteryPercent: Int = 0
    @Published private(set) var cbbIsCharging: Bool = false
    
    // Alert handling (for lock/wake issues)
    @Published var showLockAlert = false
    @Published var lockAlertMessage = ""
    
    // MARK: - Private Properties
    
    private var centralManager: CBCentralManager!
    private var scooter: CBPeripheral?
    
    // Characteristics
    private var commandCharacteristic: CBCharacteristic?
    private var stateCharacteristic: CBCharacteristic?
    private var powerStateCharacteristic: CBCharacteristic?
    private var handlebarCharacteristic: CBCharacteristic?
    private var hibernationCommandCharacteristic: CBCharacteristic?
    
    // Battery-specific characteristics
    private var auxSOCCharacteristic: CBCharacteristic?
    private var cbbSOCCharacteristic: CBCharacteristic?
    private var cbbChargingCharacteristic: CBCharacteristic?
    private var primarySOCCharacteristic: CBCharacteristic?
    private var secondarySOCCharacteristic: CBCharacteristic?
    
    // Timers & Combine
    private var stateUpdateTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Services
    
    private let commandServiceUUID = CBUUID(string: "9a590000-6e67-5d0d-aab9-ad9126b66f91")
    private let mainServiceUUID    = CBUUID(string: "9a590020-6e67-5d0d-aab9-ad9126b66f91")
    private let powerServiceUUID   = CBUUID(string: "9a5900a0-6e67-5d0d-aab9-ad9126b66f91")
    private let auxServiceUUID     = CBUUID(string: "9a590040-6e67-5d0d-aab9-ad9126b66f91")
    private let cbbServiceUUID     = CBUUID(string: "9a590060-6e67-5d0d-aab9-ad9126b66f91")
    private let primaryServiceUUID = CBUUID(string: "9a5900e0-6e67-5d0d-aab9-ad9126b66f91")
    
    // MARK: - Characteristics
    
    private let commandCharUUID            = CBUUID(string: "9a590001-6e67-5d0d-aab9-ad9126b66f91")
    private let hibernationCommandCharUUID = CBUUID(string: "9a590002-6e67-5d0d-aab9-ad9126b66f91")
    private let stateCharUUID              = CBUUID(string: "9a590021-6e67-5d0d-aab9-ad9126b66f91")
    private let powerStateCharUUID         = CBUUID(string: "9a5900a1-6e67-5d0d-aab9-ad9126b66f91")
    private let handlebarCharUUID          = CBUUID(string: "9a590023-6e67-5d0d-aab9-ad9126b66f91")
    
    private let auxSOCCharUUID       = CBUUID(string: "9a590044-6e67-5d0d-aab9-ad9126b66f91")
    private let cbbSOCCharUUID       = CBUUID(string: "9a590061-6e67-5d0d-aab9-ad9126b66f91")
    private let cbbChargingCharUUID  = CBUUID(string: "9a590072-6e67-5d0d-aab9-ad9126b66f91")
    private let primarySOCCharUUID   = CBUUID(string: "9a5900e9-6e67-5d0d-aab9-ad9126b66f91")
    private let secondarySOCCharUUID = CBUUID(string: "9a5900f5-6e67-5d0d-aab9-ad9126b66f91")
    
    // States that are considered "awake"
    private let awakeStates: Set<ScooterState> = [
        .standby, .parked, .unlocked, .riding, .charging, .linking
    ]
    
    // MARK: - Scooter State
    
    enum ScooterState: Equatable, Hashable {
        case standby
        case unlocked
        case riding
        case parked
        case charging
        case linking
        case disconnected
        case shuttingDown
        case unknown(String)
        
        init(fromString string: String) {
            switch string.lowercased() {
            case "standby", "stand-by":
                self = .standby
            case "unlocked":
                self = .unlocked
            case "riding":
                self = .riding
            case "parked":
                self = .parked
            case "charging":
                self = .charging
            case "linking":
                self = .linking
            case "disconnected":
                self = .disconnected
            case "shutting-down":
                self = .shuttingDown
            default:
                self = .unknown(string)
            }
        }
        
        func hash(into hasher: inout Hasher) {
            switch self {
            case .standby:      hasher.combine(0)
            case .unlocked:     hasher.combine(1)
            case .riding:       hasher.combine(2)
            case .parked:       hasher.combine(3)
            case .charging:     hasher.combine(4)
            case .linking:      hasher.combine(5)
            case .disconnected: hasher.combine(6)
            case .shuttingDown: hasher.combine(7)
            case .unknown(let s):
                hasher.combine(8)
                hasher.combine(s)
            }
        }
    }
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        setupAppLifecycleObservers()
    }
    
    deinit {
        stateUpdateTimer?.invalidate()
        stateUpdateTimer = nil
        cancellables.forEach { $0.cancel() }
    }
    
    // MARK: - Private Methods
    
    private func setupAppLifecycleObservers() {
        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                guard let self = self else { return }
                // If we’re disconnected and Bluetooth is on, start scanning again
                if !self.isConnected, self.centralManager.state == .poweredOn {
                    self.startScanning()
                }
            }
            .store(in: &cancellables)
        
        // Stop scanning when entering background
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.stopScanning()
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    
    func startScanning() {
        pendingStartScan = true
        if centralManager.state == .poweredOn {
            initiateScanning()
        }
    }
    
    func initiateScanning() {
        print("🔍 startScanning() - Scanning for Scooter...")
        statusMessage = "Searching..."
        isScanning = true
        
        // Unfiltered scan
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        
        // Timeout after 30 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, self.isScanning else { return }
            self.centralManager.stopScan()
            self.isScanning = false
            self.statusMessage = "No scooter found."
        }
    }
    
    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
    }
    
    func disconnect() {
        guard let scooter = scooter else { return }
        centralManager.cancelPeripheralConnection(scooter)
    }
    
    // Lock/Unlock commands
    func unlock() {
        Task {
            guard await ensureScooterAwakeIfPossible() else { return }
            
            guard let characteristic = commandCharacteristic,
                  let scooter = scooter else {
                return
            }
            
            let command = "scooter:state unlock"
            if let data = command.data(using: .ascii) {
                scooter.writeValue(data, for: characteristic, type: .withResponse)
                statusMessage = "Unlocking..."
                print("🔓 Sending unlock command...")
                
                // Check handlebar after 2s
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await verifyHandlebarState()
            }
        }
    }
    
    func lock() {
        Task {
            guard await ensureScooterAwakeIfPossible() else { return }
            
            guard let characteristic = commandCharacteristic,
                  let scooter = scooter else {
                return
            }
            
            let command = "scooter:state lock"
            if let data = command.data(using: .ascii) {
                scooter.writeValue(data, for: characteristic, type: .withResponse)
                statusMessage = "Locking..."
                print("🔒 Sending lock command...")
                
                // Check handlebar after 2s
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await verifyHandlebarState()
                
                // If still unlocked, show alert
                if !isLocked {
                    print("⚠️ Lock failed, handlebar is still unlocked.")
                    showLockFailedAlert(message: """
                    The handlebar wasn't in a lockable position.
                    The scooter is off but still unlocked.
                    """)
                }
            }
        }
    }
    
    func openSeat() {
        guard let characteristic = commandCharacteristic,
              let scooter = scooter else {
            return
        }
        
        let command = "scooter:seatbox open"
        if let data = command.data(using: .ascii) {
            scooter.writeValue(data, for: characteristic, type: .withResponse)
        }
    }
    
    func sendBlinkerCommand(state: String) {
        guard let characteristic = commandCharacteristic,
              let scooter = scooter else { return }
        
        let command = "scooter:blinker \(state)"
        if let data = command.data(using: .ascii) {
            scooter.writeValue(data, for: characteristic, type: .withResponse)
        }
    }
    
    // MARK: - Private Helpers
    
    /// Wakes the scooter from hibernation if the hibernation characteristic is available
    private func wakeUpScooter() async {
        guard let hibernationCharacteristic = hibernationCommandCharacteristic,
              let scooter = scooter else {
            print("No hibernation characteristic found; skipping wake-up attempt.")
            return
        }
        
        if let data = "wakeup".data(using: .ascii) {
            scooter.writeValue(data, for: hibernationCharacteristic, type: .withResponse)
            statusMessage = "Waking scooter..."
            print("🤖 Sent wakeup command")
        }
    }
    
    /// Ensures the scooter is awake if possible, returning false if it fails to wake.
    private func ensureScooterAwakeIfPossible() async -> Bool {
        let canWake = (hibernationCommandCharacteristic != nil)
        if !awakeStates.contains(currentState) && canWake {
            await wakeUpScooter()
            let awake = await waitForScooterState(.standby, timeout: 30)
            if !awake {
                statusMessage = "Could not wake scooter."
                print("⚠️ Could not wake scooter to standby.")
                showLockFailedAlert(message: "Could not wake scooter to standby.")
                return false
            }
        }
        return true
    }
    
    /// Waits for a certain scooter state or times out.
    private func waitForScooterState(_ targetState: ScooterState,
                                     timeout: TimeInterval = 20) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if currentState == targetState {
                return true
            }
            if let stateChar = stateCharacteristic,
               let scooter = scooter {
                scooter.readValue(for: stateChar)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return (currentState == targetState)
    }
    
    /// Reads the handlebar characteristic to verify lock state.
    private func verifyHandlebarState() async {
        guard let handlebarChar = handlebarCharacteristic,
              let scooter = scooter else {
            return
        }
        
        scooter.readValue(for: handlebarChar)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    
    /// Show an alert in SwiftUI by setting published properties
    private func showLockFailedAlert(message: String) {
        lockAlertMessage = message
        showLockAlert = true
    }
    
    /// Re-attempt waking & locking if user chooses "Retry" from the alert
    func restartAndLock() {
        Task {
            // Attempt to unlock (which wakes the scooter if possible)
            await unlock()
            let awake = await waitForScooterState(.standby, timeout: 30)
            if !awake {
                showLockFailedAlert(message: """
                The scooter did not acknowledge our wake-up request.
                """)
                return
            }
            // Now try to lock again
            await lock()
        }
    }
    
    /// Update the statusMessage based on currentState + lock state
    private func updateStatusMessage() {
        switch currentState {
        case .unlocked, .riding:
            statusMessage = isLocked ? "Warning: mismatch" : "Unlocked"
        case .standby:
            statusMessage = "Standby"
        case .parked:
            statusMessage = "Parked"
        case .charging:
            statusMessage = "Charging"
        case .linking:
            statusMessage = "Linking"
        case .disconnected:
            statusMessage = "Disconnected"
        case .shuttingDown:
            statusMessage = "Shutting Down"
        case .unknown(let unknown):
            statusMessage = unknown
        }
    }
    
    /// Parses a battery SoC value from Data to an Int percent.
    private func parseSoC(data: Data, isCbb: Bool) -> Int? {
        // For CBB, typically 1 byte. For main or aux batteries, 4 bytes (little-endian).
        if isCbb {
            guard data.count >= 1 else { return nil }
            return Int(data[0])
        } else {
            guard data.count == 4 else { return nil }
            let b0 = data[0]
            let b1 = data[1]
            let b2 = data[2]
            let b3 = data[3]
            let value = UInt32(b0)
                    + (UInt32(b1) << 8)
                    + (UInt32(b2) << 16)
                    + (UInt32(b3) << 24)
            return max(0, min(100, Int(value)))
        }
    }
    
    // MARK: - State Update Timer
    
    func startStateUpdateTimer() {
        stopStateUpdateTimer()
        stateUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.verifyConnectionState()
        }
    }
    
    func stopStateUpdateTimer() {
        stateUpdateTimer?.invalidate()
        stateUpdateTimer = nil
    }
    
    // MARK: - Connection Verification
    
    private func verifyConnectionState() {
        guard bluetoothState == .poweredOn else { return }
        
        if let scooter = scooter {
            switch scooter.state {
            case .connected:
                if !isConnected {
                    isConnected = true
                    resubscribeToCharacteristics()
                }
            case .disconnected:
                handleDisconnection()
            case .connecting:
                statusMessage = "Connecting..."
            case .disconnecting:
                statusMessage = "Disconnecting..."
            @unknown default:
                break
            }
        }
    }
    
    private func handleDisconnection() {
        isConnected = false
        clearCharacteristics()
        statusMessage = "Disconnected."
        
        // Always reconnect automatically if Bluetooth is still on
        if centralManager.state == .poweredOn, let scooter = scooter {
            statusMessage = "Reconnecting..."
            centralManager.connect(scooter, options: nil)
        }
    }
    
    private func resubscribeToCharacteristics() {
        guard let scooter = scooter else { return }
        [
            stateCharacteristic,
            handlebarCharacteristic,
            auxSOCCharacteristic,
            cbbSOCCharacteristic,
            cbbChargingCharacteristic,
            primarySOCCharacteristic,
            secondarySOCCharacteristic
        ]
        .compactMap { $0 }
        .forEach {
            scooter.setNotifyValue(true, for: $0)
        }
    }
    
    private func clearCharacteristics() {
        commandCharacteristic = nil
        stateCharacteristic = nil
        powerStateCharacteristic = nil
        handlebarCharacteristic = nil
        hibernationCommandCharacteristic = nil
        auxSOCCharacteristic = nil
        cbbSOCCharacteristic = nil
        cbbChargingCharacteristic = nil
        primarySOCCharacteristic = nil
        secondarySOCCharacteristic = nil
    }
}

// MARK: - CBCentralManagerDelegate

extension UnuScooterManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        print("centralManagerDidUpdateState: \(central.state.rawValue)")
        
        if central.state == .poweredOn && pendingStartScan {
            pendingStartScan = false
            initiateScanning()
        }
        
        switch central.state {
        case .poweredOn:
            if !isConnected && !isScanning {
                statusMessage = "Connecting..."
            }
        case .poweredOff:
            isConnected = false
            scooter = nil
            statusMessage = "Please turn on Bluetooth"
        case .unauthorized:
            isConnected = false
            scooter = nil
            statusMessage = "Bluetooth permission required"
        case .unsupported:
            statusMessage = "Bluetooth not supported"
        case .resetting:
            statusMessage = "Bluetooth is resetting"
        case .unknown:
            statusMessage = "Bluetooth state unknown"
        @unknown default:
            statusMessage = "Unknown Bluetooth state"
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                       didDiscover peripheral: CBPeripheral,
                       advertisementData: [String : Any],
                       rssi RSSI: NSNumber) {
        print("Found peripheral: \(peripheral.name ?? "Unnamed"), RSSI: \(RSSI)")
        
        // Check if this is "unu Scooter" by name
        if peripheral.name == "unu Scooter" {
            scooter = peripheral
            finishPeripheralDiscovery()
        }
    }
    
    private func finishPeripheralDiscovery() {
        centralManager.stopScan()
        isScanning = false
        statusMessage = "Connecting..."
        if let scooter = scooter {
            centralManager.connect(scooter, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                       didConnect peripheral: CBPeripheral) {
        print("🔌 Connected to scooter!")
        peripheral.delegate = self
        isConnected = true
        statusMessage = "Connected"
        
        // Discover relevant services
        peripheral.discoverServices([
            commandServiceUUID,
            mainServiceUUID,
            powerServiceUUID,
            auxServiceUUID,
            cbbServiceUUID,
            primaryServiceUUID
        ])
    }
    
    func centralManager(_ central: CBCentralManager,
                       didFailToConnect peripheral: CBPeripheral,
                       error: Error?) {
        print("❌ Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        statusMessage = "Connection failed."
        
        if peripheral == self.scooter {
            self.scooter = nil
            isConnected = false
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                       didDisconnectPeripheral peripheral: CBPeripheral,
                       error: Error?) {
        print("📵 Disconnected: \(error?.localizedDescription ?? "No error")")
        if peripheral == self.scooter {
            isConnected = false
            statusMessage = (error == nil) ? "Disconnected" : "Connection lost"
            self.scooter = nil
        }
    }
}

// MARK: - CBPeripheralDelegate

extension UnuScooterManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        if let error = error {
            print("❌ Error discovering services: \(error.localizedDescription)")
            statusMessage = "Service discovery error: \(error.localizedDescription)"
            return
        }
        
        guard let services = peripheral.services else { return }
        for service in services {
            switch service.uuid {
            case commandServiceUUID:
                peripheral.discoverCharacteristics([commandCharUUID, hibernationCommandCharUUID],
                                                   for: service)
            case mainServiceUUID:
                peripheral.discoverCharacteristics([stateCharUUID, handlebarCharUUID],
                                                   for: service)
            case powerServiceUUID:
                peripheral.discoverCharacteristics([powerStateCharUUID],
                                                   for: service)
            case auxServiceUUID:
                peripheral.discoverCharacteristics([auxSOCCharUUID],
                                                   for: service)
            case cbbServiceUUID:
                peripheral.discoverCharacteristics([cbbSOCCharUUID, cbbChargingCharUUID],
                                                   for: service)
            case primaryServiceUUID:
                peripheral.discoverCharacteristics([primarySOCCharUUID, secondarySOCCharUUID],
                                                   for: service)
            default:
                break
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            print("❌ Error discovering characteristics: \(error.localizedDescription)")
            statusMessage = "Characteristic discovery error: \(error.localizedDescription)"
            return
        }
        
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case commandCharUUID:
                commandCharacteristic = characteristic
            case hibernationCommandCharUUID:
                hibernationCommandCharacteristic = characteristic
            case stateCharUUID:
                stateCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            case powerStateCharUUID:
                powerStateCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            case handlebarCharUUID:
                handlebarCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            case auxSOCCharUUID:
                auxSOCCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            case cbbSOCCharUUID:
                cbbSOCCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            case cbbChargingCharUUID:
                cbbChargingCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            case primarySOCCharUUID:
                primarySOCCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            case secondarySOCCharUUID:
                secondarySOCCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            print("❌ Error changing notification state for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        if characteristic.isNotifying {
            print("👂 Listening for updates on \(characteristic.uuid)")
        } else {
            print("🔕 Stopped updates on \(characteristic.uuid)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            print("❌ Error reading characteristic value: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else {
            print("⚠️ No data for characteristic \(characteristic.uuid)")
            return
        }
        
        let rawString = String(data: data, encoding: .ascii) ?? ""
        let trimmed = rawString.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.controlCharacters)
        )
        
        print("📱 Received update for \(characteristic.uuid): \(trimmed)")
        
        switch characteristic.uuid {
        case handlebarCharUUID:
            isLocked = (trimmed != "unlocked")
        case stateCharUUID:
            currentState = ScooterState(fromString: trimmed)
            updateStatusMessage()
        case powerStateCharUUID:
            // e.g., "running", "charging", ...
            break
        case auxSOCCharUUID:
            if let soc = parseSoC(data: data, isCbb: false) {
                auxBatteryPercent = soc
            }
        case cbbSOCCharUUID:
            if let soc = parseSoC(data: data, isCbb: true) {
                cbbBatteryPercent = soc
            }
        case cbbChargingCharUUID:
            cbbIsCharging = (trimmed == "charging")
        case primarySOCCharUUID:
            if let soc = parseSoC(data: data, isCbb: false) {
                primaryBatteryPercent = soc
            }
        case secondarySOCCharUUID:
            if let soc = parseSoC(data: data, isCbb: false) {
                secondaryBatteryPercent = soc
            }
        default:
            break
        }
    }
}
