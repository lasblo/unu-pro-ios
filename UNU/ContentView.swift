//
//  ContentView.swift
//  UNU
//
//  Created by Lasse Blomenkemper on 23/01/25.
//

import SwiftUI
import CoreBluetooth
import Combine

@MainActor
class UnuScooterManager: NSObject, ObservableObject {
    // MARK: - Properties
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
    
    // MARK: - Published States
    @Published private(set) var isScanning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isLocked = true
    @Published private(set) var statusMessage = ""
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published private(set) var currentState: ScooterState = .disconnected
    @Published var hazardLightsOn = false
    
    // Battery percents for each battery
    @Published private(set) var primaryBatteryPercent: Int = 0
    @Published private(set) var secondaryBatteryPercent: Int = 0
    @Published private(set) var cbbBatteryPercent: Int = 0
    @Published private(set) var auxBatteryPercent: Int = 0
    
    // If you want to display just one battery in the UI, you can use primaryBatteryPercent
    // or combine them however you like
    @Published private(set) var cbbIsCharging: Bool = false
    
    // MARK: - Services
    private let commandServiceUUID = CBUUID(string: "9a590000-6e67-5d0d-aab9-ad9126b66f91")
    private let mainServiceUUID    = CBUUID(string: "9a590020-6e67-5d0d-aab9-ad9126b66f91")
    private let powerServiceUUID   = CBUUID(string: "9a5900a0-6e67-5d0d-aab9-ad9126b66f91")
    
    // Extra battery services
    private let auxServiceUUID     = CBUUID(string: "9a590040-6e67-5d0d-aab9-ad9126b66f91")
    private let cbbServiceUUID     = CBUUID(string: "9a590060-6e67-5d0d-aab9-ad9126b66f91")
    private let primaryServiceUUID = CBUUID(string: "9a5900e0-6e67-5d0d-aab9-ad9126b66f91")
    
    // MARK: - Characteristics
    private let commandCharUUID            = CBUUID(string: "9a590001-6e67-5d0d-aab9-ad9126b66f91")
    private let hibernationCommandCharUUID = CBUUID(string: "9a590002-6e67-5d0d-aab9-ad9126b66f91")
    private let stateCharUUID              = CBUUID(string: "9a590021-6e67-5d0d-aab9-ad9126b66f91")
    private let powerStateCharUUID         = CBUUID(string: "9a5900a1-6e67-5d0d-aab9-ad9126b66f91")
    private let handlebarCharUUID          = CBUUID(string: "9a590023-6e67-5d0d-aab9-ad9126b66f91")
    
    // Battery SoC / charging characteristic UUIDs
    private let auxSOCCharUUID       = CBUUID(string: "9a590044-6e67-5d0d-aab9-ad9126b66f91")
    private let cbbSOCCharUUID       = CBUUID(string: "9a590061-6e67-5d0d-aab9-ad9126b66f91")
    private let cbbChargingCharUUID  = CBUUID(string: "9a590072-6e67-5d0d-aab9-ad9126b66f91")
    private let primarySOCCharUUID   = CBUUID(string: "9a5900e9-6e67-5d0d-aab9-ad9126b66f91")
    private let secondarySOCCharUUID = CBUUID(string: "9a5900f5-6e67-5d0d-aab9-ad9126b66f91")
    
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
            switch string {
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
            case .standby:
                hasher.combine(0)
            case .unlocked:
                hasher.combine(1)
            case .riding:
                hasher.combine(2)
            case .parked:
                hasher.combine(3)
            case .charging:
                hasher.combine(4)
            case .linking:
                hasher.combine(5)
            case .disconnected:
                hasher.combine(6)
            case .shuttingDown:
                hasher.combine(7)
            case .unknown(let value):
                hasher.combine(8)
                hasher.combine(value)
            }
        }
    }
    
    // Which states count as "awake"
    private let awakeStates: Set<ScooterState> = [
        .standby, .parked, .unlocked, .riding, .charging, .linking
    ]
    
    // MARK: - Initialization
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        setupAppLifecycleObservers()
    }
    
    deinit {
        Task { @MainActor in
            stopStateUpdateTimer()
        }
        cancellables.forEach { $0.cancel() }
    }
    
    // MARK: - App Lifecycle Observers
    private func setupAppLifecycleObservers() {
        NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.handleAppDidBecomeActive()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default
            .publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.handleAppDidEnterBackground()
            }
            .store(in: &cancellables)
        
        NotificationCenter.default
            .publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.handleAppWillTerminate()
            }
            .store(in: &cancellables)
    }
    
    private func handleAppDidBecomeActive() {
        verifyBluetoothState()
        verifyConnectionState()
        startStateUpdateTimer()
    }
    
    private func handleAppDidEnterBackground() {
        stopStateUpdateTimer()
    }
    
    private func handleAppWillTerminate() {
        stopStateUpdateTimer()
        disconnect()
    }
    
    // MARK: - State Verification
    private func verifyBluetoothState() {
        let currentState = centralManager.state
        bluetoothState = currentState
        
        switch currentState {
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
    
    private func startStateUpdateTimer() {
        stopStateUpdateTimer()
        stateUpdateTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.verifyConnectionState()
        }
    }
    
    private func stopStateUpdateTimer() {
        stateUpdateTimer?.invalidate()
        stateUpdateTimer = nil
    }
    
    private func handleDisconnection() {
        isConnected = false
        commandCharacteristic = nil
        stateCharacteristic = nil
        handlebarCharacteristic = nil
        hibernationCommandCharacteristic = nil
        
        // also set battery characteristics to nil
        auxSOCCharacteristic = nil
        cbbSOCCharacteristic = nil
        cbbChargingCharacteristic = nil
        primarySOCCharacteristic = nil
        secondarySOCCharacteristic = nil
        
        statusMessage = "Disconnected from scooter"
        
        if centralManager.state == .poweredOn {
            if let scooter = scooter {
                statusMessage = "Attempting to reconnect..."
                centralManager.connect(scooter, options: nil)
            }
        }
    }
    
    private func resubscribeToCharacteristics() {
        guard let scooter = scooter else { return }
        
        if let stateChar = stateCharacteristic {
            scooter.setNotifyValue(true, for: stateChar)
        }
        if let handlebarChar = handlebarCharacteristic {
            scooter.setNotifyValue(true, for: handlebarChar)
        }
        // For SoC, we also set notify if desired
        if let auxChar = auxSOCCharacteristic {
            scooter.setNotifyValue(true, for: auxChar)
        }
        if let cbbChar = cbbSOCCharacteristic {
            scooter.setNotifyValue(true, for: cbbChar)
        }
        if let cbbChargingChar = cbbChargingCharacteristic {
            scooter.setNotifyValue(true, for: cbbChargingChar)
        }
        if let primChar = primarySOCCharacteristic {
            scooter.setNotifyValue(true, for: primChar)
        }
        if let secChar = secondarySOCCharacteristic {
            scooter.setNotifyValue(true, for: secChar)
        }
    }
    
    // MARK: - Public Methods
    func startScanning() {
        print("🔍 startScanning() - Now scanning for Scooter.")
        statusMessage = "Scanning for UNU scooter..."
        
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        isScanning = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.isScanning else { return }
            
            self.statusMessage = "Scanning for UNU scooter by service..."
            self.centralManager.stopScan()
            self.centralManager.scanForPeripherals(withServices: [self.commandServiceUUID])
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self = self, self.isScanning else { return }
            
            self.centralManager.stopScan()
            self.isScanning = false
            self.statusMessage = "No scooter found. Please try again."
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
    
    // Wake up via hibernation (if available)
    private func wakeUpScooter() async {
        guard let hibernationCharacteristic = hibernationCommandCharacteristic,
              let scooter = scooter else {
            print("No hibernation characteristic found. Skipping wake-up attempt.")
            return
        }
        let command = "wakeup"
        if let data = command.data(using: .ascii) {
            scooter.writeValue(data, for: hibernationCharacteristic, type: .withResponse)
            statusMessage = "Waking scooter..."
            print("🤖 Sent wakeup command")
        }
    }
    
    // Wait for a certain state or timeout
    private func waitForScooterState(_ targetState: ScooterState, timeout: TimeInterval = 20) async -> Bool {
        let start = Date()
        
        while Date().timeIntervalSince(start) < timeout {
            if currentState == targetState {
                return true
            }
            if let stateChar = stateCharacteristic, let scooter = scooter {
                scooter.readValue(for: stateChar)
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return (currentState == targetState)
    }
    
    // MARK: Lock/Unlock/Seat
    
    func unlock() {
        Task {
            let canWake = (hibernationCommandCharacteristic != nil)
            if !awakeStates.contains(currentState) && canWake {
                await wakeUpScooter()
                let awake = await waitForScooterState(.standby, timeout: 30)
                if !awake {
                    statusMessage = "Could not wake scooter"
                    print("⚠️ Could not wake scooter to standby.")
                    return
                }
            }
            
            guard let characteristic = commandCharacteristic,
                  let scooter = scooter else { return }
            
            let command = "scooter:state unlock"
            if let data = command.data(using: .ascii) {
                scooter.writeValue(data, for: characteristic, type: .withResponse)
                statusMessage = "Unlocking..."
                print("🔓 Sending unlock command...")
                
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let handlebarChar = handlebarCharacteristic {
                    scooter.readValue(for: handlebarChar)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                
                if isLocked {
                    print("⚠️ Unlock failed, handlebar is still locked.")
                }
            }
        }
    }
    
    func lock() {
        Task {
            let canWake = (hibernationCommandCharacteristic != nil)
            if !awakeStates.contains(currentState) && canWake {
                await wakeUpScooter()
                let awake = await waitForScooterState(.standby, timeout: 30)
                if !awake {
                    statusMessage = "Could not wake scooter"
                    print("⚠️ Could not wake scooter to standby.")
                    return
                }
            }
            
            guard let characteristic = commandCharacteristic,
                  let scooter = scooter else { return }
            
            let command = "scooter:state lock"
            if let data = command.data(using: .ascii) {
                scooter.writeValue(data, for: characteristic, type: .withResponse)
                statusMessage = "Locking..."
                print("🔒 Sending lock command...")
                
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if let handlebarChar = handlebarCharacteristic {
                    scooter.readValue(for: handlebarChar)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                
                if !isLocked {
                    print("⚠️ Lock failed, handlebar is still unlocked.")
                    self.showLockFailedAlert()
                }
            }
        }
    }
    
    func openSeat() {
        guard let characteristic = commandCharacteristic,
              let scooter = scooter else { return }
        
        let command = "scooter:seatbox open"
        if let data = command.data(using: .ascii) {
            scooter.writeValue(data, for: characteristic, type: .withResponse)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension UnuScooterManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("centralManagerDidUpdateState: \(central.state.rawValue)")
        verifyBluetoothState()
        
        // Start scanning if powered on and not connected
        if central.state == .poweredOn, !isConnected, !isScanning {
            print("Bluetooth is powered on, starting scan...")
            startScanning()
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                       didDiscover peripheral: CBPeripheral,
                       advertisementData: [String : Any],
                       rssi RSSI: NSNumber)
    {
        print("Found peripheral: \(peripheral.name ?? "Unnamed"), RSSI: \(RSSI)")
        
        if peripheral.name == "unu Scooter" {
            scooter = peripheral
            central.stopScan()
            isScanning = false
            statusMessage = "Connecting..."
            central.connect(peripheral, options: nil)
            
        } else if let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
                  uuids.contains(commandServiceUUID)
        {
            scooter = peripheral
            central.stopScan()
            isScanning = false
            statusMessage = "Connecting..."
            central.connect(peripheral, options: nil)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("🔌 Connected to scooter!")
        peripheral.delegate = self
        isConnected = true
        statusMessage = "Connected"
        
        // Discover all relevant services, including battery services
        peripheral.discoverServices([
            commandServiceUUID, mainServiceUUID, powerServiceUUID,
            auxServiceUUID, cbbServiceUUID, primaryServiceUUID
        ])
    }
    
    func centralManager(_ central: CBCentralManager,
                       didFailToConnect peripheral: CBPeripheral,
                       error: Error?)
    {
        print("❌ Failed to connect to peripheral: \(error?.localizedDescription ?? "Unknown error")")
        statusMessage = "Connection failed."
        
        if peripheral == self.scooter {
            self.scooter = nil
            isConnected = false
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                       didDisconnectPeripheral peripheral: CBPeripheral,
                       error: Error?)
    {
        print("📵 Disconnected from peripheral: \(error?.localizedDescription ?? "No error")")
        
        if peripheral == self.scooter {
            isConnected = false
            statusMessage = (error == nil) ? "Disconnected" : "Connection lost"
            self.scooter = nil
        }
    }
}

// MARK: - CBPeripheralDelegate
extension UnuScooterManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            print("❌ Error discovering services: \(error!.localizedDescription)")
            statusMessage = "Error discovering services: \(error!.localizedDescription)"
            return
        }
        
        print("🔍 Discovered services")
        guard let services = peripheral.services else { return }
        
        for service in services {
            print("Found service: \(service.uuid)")
            
            // Discover relevant characteristics for each service
            switch service.uuid {
            case commandServiceUUID:
                peripheral.discoverCharacteristics(
                    [commandCharUUID, hibernationCommandCharUUID],
                    for: service
                )
                
            case mainServiceUUID:
                peripheral.discoverCharacteristics(
                    [stateCharUUID, handlebarCharUUID],
                    for: service
                )
                
            case powerServiceUUID:
                peripheral.discoverCharacteristics(
                    [powerStateCharUUID],
                    for: service
                )
                
            case auxServiceUUID:
                peripheral.discoverCharacteristics(
                    [auxSOCCharUUID],
                    for: service
                )
                
            case cbbServiceUUID:
                peripheral.discoverCharacteristics(
                    [cbbSOCCharUUID, cbbChargingCharUUID],
                    for: service
                )
                
            case primaryServiceUUID:
                peripheral.discoverCharacteristics(
                    [primarySOCCharUUID, secondarySOCCharUUID],
                    for: service
                )
                
            default:
                break
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?)
    {
        guard error == nil else {
            print("❌ Error discovering characteristics: \(error!.localizedDescription)")
            statusMessage = "Error discovering characteristics: \(error!.localizedDescription)"
            return
        }
        
        print("🔍 Discovered characteristics for service: \(service.uuid)")
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            print("Found characteristic: \(characteristic.uuid)")
            
            switch characteristic.uuid {
            case commandCharUUID:
                print("✅ Found command characteristic")
                commandCharacteristic = characteristic
                
            case hibernationCommandCharUUID:
                print("✅ Found hibernation command characteristic")
                hibernationCommandCharacteristic = characteristic
                
            case stateCharUUID:
                print("✅ Found state characteristic")
                stateCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
                
            case powerStateCharUUID:
                print("✅ Found power state characteristic")
                powerStateCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
                
            case handlebarCharUUID:
                print("✅ Found handlebar characteristic")
                handlebarCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
                
            case auxSOCCharUUID:
                print("✅ Found aux SOC characteristic")
                auxSOCCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
                
            case cbbSOCCharUUID:
                print("✅ Found cbb SOC characteristic")
                cbbSOCCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
                
            case cbbChargingCharUUID:
                print("✅ Found cbb charging characteristic")
                cbbChargingCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
                
            case primarySOCCharUUID:
                print("✅ Found primary SOC characteristic")
                primarySOCCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
                
            case secondarySOCCharUUID:
                print("✅ Found secondary SOC characteristic")
                secondarySOCCharacteristic = characteristic
                peripheral.readValue(for: characteristic)
                peripheral.setNotifyValue(true, for: characteristic)
                
            default:
                print("⚠️ Unknown characteristic: \(characteristic.uuid)")
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        if let error = error {
            print("❌ Error changing notification state for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        print("✅ Successfully updated notification state for \(characteristic.uuid)")
        if characteristic.isNotifying {
            print("👂 Now listening for updates on \(characteristic.uuid)")
        } else {
            print("🔕 Stopped listening for updates on \(characteristic.uuid)")
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?)
    {
        if let error = error {
            print("❌ Error reading characteristic value: \(error.localizedDescription)")
            return
        }
        
        guard let data = characteristic.value else {
            print("⚠️ No data for characteristic \(characteristic.uuid)")
            return
        }
        let rawString = String(data: data, encoding: .ascii) ?? ""
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        
        print("📱 Received value for \(characteristic.uuid): \(rawString)")
        
        DispatchQueue.main.async {
            switch characteristic.uuid {
            case self.handlebarCharUUID:
                print("🔐 Handlebar state: '\(trimmed)'")
                self.isLocked = (trimmed != "unlocked")
                
            case self.stateCharUUID:
                print("📊 Scooter state: '\(trimmed)'")
                self.currentState = ScooterState(fromString: trimmed)
                self.updateStatusMessage()
                
            case self.powerStateCharUUID:
                print("⚡️ Power state: '\(trimmed)'")
                // e.g. "running", "charging", etc. (No SoC here)
                
            // MARK: - Battery SoC Parsing
            case self.auxSOCCharUUID:
                print("🔋 Aux SoC data: \(data as NSData)")
                if let soc = self.parseSoC(data: data, isCbb: false) {
                    self.auxBatteryPercent = soc
                    print("auxBatteryPercent => \(soc)")
                }
                
            case self.cbbSOCCharUUID:
                print("🔋 CBB SoC data: \(data as NSData)")
                // cbb is typically 1 byte, according to Flutter code
                if let soc = self.parseSoC(data: data, isCbb: true) {
                    self.cbbBatteryPercent = soc
                    print("cbbBatteryPercent => \(soc)")
                }
                
            case self.cbbChargingCharUUID:
                if let str = String(data: data, encoding: .ascii)?.trimmingCharacters(in: .controlCharacters) {
                    print("🔌 CBB charging data: \(str)")
                    self.cbbIsCharging = (str == "charging")
                }
                
            case self.primarySOCCharUUID:
                print("🔋 Primary SoC data: \(data as NSData)")
                if let soc = self.parseSoC(data: data, isCbb: false) {
                    self.primaryBatteryPercent = soc
                    print("primaryBatteryPercent => \(soc)")
                }
                
            case self.secondarySOCCharUUID:
                print("🔋 Secondary SoC data: \(data as NSData)")
                if let soc = self.parseSoC(data: data, isCbb: false) {
                    self.secondaryBatteryPercent = soc
                    print("secondaryBatteryPercent => \(soc)")
                }
                
            default:
                print("⚠️ Unhandled characteristic update: \(characteristic.uuid)")
            }
        }
    }
    
    /// Update the top-level status message based on currentState + isLocked
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
    
    func sendBlinkerCommand(state: String) {
        guard let characteristic = commandCharacteristic,
              let scooter = scooter else { return }
        
        let command = "scooter:blinker \(state)"
        if let data = command.data(using: .ascii) {
            scooter.writeValue(data, for: characteristic, type: .withResponse)
        }
    }
    
    /// Converts the raw SoC data to an integer percent, either 1 byte for cbb or 4 bytes little-endian for others
    private func parseSoC(data: Data, isCbb: Bool) -> Int? {
        // cbb is usually 1 byte, others are 4 bytes
        if isCbb {
            // If there's at least 1 byte
            guard data.count >= 1 else { return nil }
            return Int(data[0])
        } else {
            // Expect 4 bytes for the standard battery SoC
            guard data.count == 4 else { return nil }
            // Little-endian to UInt32
            let b0 = data[data.startIndex]
            let b1 = data[data.startIndex + 1]
            let b2 = data[data.startIndex + 2]
            let b3 = data[data.startIndex + 3]
            
            let value = UInt32(b0)
                     + (UInt32(b1) << 8)
                     + (UInt32(b2) << 16)
                     + (UInt32(b3) << 24)
            
            // constrain to 0-100
            let soc = Int(value)
            let clamped = max(0, min(100, soc))
            return clamped
        }
    }
    
    private func showLockFailedAlert() {
        // We must hop onto the main thread to present a UIKit alert
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.windows.first,
                  let rootVC = window.rootViewController else {
                return
            }

            let alert = UIAlertController(
                title: "Lock Failed",
                message: """
    The handlebar wasn't in a lockable position. 
    The scooter is off but still unlocked.
    """,
                preferredStyle: .alert
            )
            
            alert.addAction(
                UIAlertAction(title: "Ignore", style: .destructive, handler: nil)
            )
            
            alert.addAction(
                UIAlertAction(title: "Retry", style: .default, handler: { [weak self] _ in
                    self?.restartAndLock()
                })
            )

            rootVC.present(alert, animated: true, completion: nil)
        }
    }

    /// This method wakes the scooter (if needed) and then attempts to lock again.
    private func restartAndLock() {
        Task {
            await unlock()
            let awake = await waitForScooterState(.standby, timeout: 30)
            if !awake {
                statusMessage = "Could not wake scooter"
                print("⚠️ Could not wake scooter to standby.")
                return
            }
            // Now that the scooter is awake again, attempt lock one more time:
            await lock()
        }
    }
}


struct BlinkingImage: View {
    let systemName: String
    let isBlinking: Bool
    
    @State private var isVisible = true
    
    var body: some View {
        Image(systemName: systemName)
            .font(.title2)
            .foregroundStyle(.yellow)
            .opacity(isVisible ? 1 : 0.3)
            .onChange(of: isBlinking) { newValue in
                guard newValue else {
                    isVisible = true
                    return
                }
                // Start the repeating animation when blinking is enabled
                withAnimation(Animation.easeInOut(duration: 0.5).repeatForever()) {
                    isVisible.toggle()
                }
            }
    }
}

struct ScooterControlsView: View {
    @StateObject private var scooterManager = UnuScooterManager()
    @State private var showBatteryDetails = false
    @GestureState private var dragState = DragState.inactive
    
    enum DragState {
        case inactive
        case dragging(translation: CGFloat)
        
        var translation: CGFloat {
            switch self {
            case .inactive: return 0
            case .dragging(let t): return t
            }
        }
    }
    
    var body: some View {
        // Status Area
        VStack(spacing: 4) {
            Text("UNU Scooter Pro")
                .font(.title.bold())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack {
                Circle()
                    .fill(scooterManager.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(scooterManager.statusMessage)
                    .foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        
        VStack(spacing: 8) {
            // Scooter Visualization
            Image("scooter")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 300)
                .padding()
            .padding(.top, 20)
            
            // Main Controls
            VStack(spacing: 24) {
                // Slide to Unlock
                GeometryReader { geometry in
                    ZStack {
                        // Track
                        Capsule()
                            .fill(.ultraThinMaterial)
                        
                        // Slider
                        HStack {
                            ZStack {
                                Circle()
                                    .fill(.white)
                                    .shadow(radius: 2)
                                Image(systemName: scooterManager.isLocked ? "lock.fill" : "lock.open.fill")
                                    .font(.title3)
                                    .foregroundStyle(.black)
                            }
                            .frame(width: 50, height: 50)
                            .offset(x: dragState.translation)
                            .gesture(
                                DragGesture()
                                    .updating($dragState) { value, state, _ in
                                        state = .dragging(translation: min(max(0, value.translation.width), geometry.size.width - 80))
                                    }
                                    .onEnded { value in
                                        if value.translation.width > geometry.size.width * 0.5 {
                                            if scooterManager.isLocked {
                                                scooterManager.unlock()
                                            } else {
                                                scooterManager.lock()
                                            }
                                        }
                                    }
                            )
                            
                            Spacer()
                        }
                        .padding(4)
                        
                        // Label
                        Text(scooterManager.isLocked ? "Slide to Unlock" : "Slide to Lock")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 60)
                
                // Quick Actions
                
                HStack(spacing: 16) {
                    // Hazard Button
                    Button(action: {
                        if scooterManager.hazardLightsOn {
                            scooterManager.sendBlinkerCommand(state: "off")
                        } else {
                            scooterManager.sendBlinkerCommand(state: "both")
                        }
                        scooterManager.hazardLightsOn.toggle()
                    }) {
                        VStack(spacing: 8) {
                            BlinkingImage(systemName: "exclamationmark.triangle.fill",
                                         isBlinking: scooterManager.hazardLightsOn)
                                .padding(.bottom, 2)
                            Text(scooterManager.hazardLightsOn ? "Disable Hazards" : "Enable Hazards")
                                .font(.callout)
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Material.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    
                    // Seat Button
                    Button(action: { scooterManager.openSeat() }) {
                        VStack(spacing: 8) {
                            Image(systemName: "car.side.rear.open.crop.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .padding(.bottom, 2)
                            Text("Open Seat")
                                .font(.callout)
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                
                // Battery Details Button
                Button(action: { showBatteryDetails = true }) {
                    HStack {
                        Image(systemName: "battery.100.bolt")
                            .foregroundStyle(.white)
                        Text("Battery Details")
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.bold())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                
            }
            .padding(20)
        }
        .sheet(isPresented: $showBatteryDetails) {
            BatteryDetailsView(
                primaryPercent: scooterManager.primaryBatteryPercent,
                secondaryPercent: scooterManager.secondaryBatteryPercent,
                cbbPercent: scooterManager.cbbBatteryPercent,
                auxPercent: scooterManager.auxBatteryPercent,
                isCharging: scooterManager.cbbIsCharging
            )
            .presentationDetents([.medium])
        }
    }
}

struct BatteryDetailsView: View {
    let primaryPercent: Int
    let secondaryPercent: Int
    let cbbPercent: Int
    let auxPercent: Int
    let isCharging: Bool
    
    var body: some View {
        NavigationStack {
            List {
                Section("Main Batteries") {
                    batteryRow(title: "Primary Battery", percent: primaryPercent)
                    batteryRow(title: "Secondary Battery", percent: secondaryPercent)
                }
                
                Section("System Batteries") {
                    HStack {
                        batteryRow(title: "CBB Battery", percent: cbbPercent)
                        if isCharging {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    batteryRow(title: "Auxiliary Battery", percent: auxPercent)
                }
            }
            .navigationTitle("Battery Status")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func batteryRow(title: String, percent: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(percent)%")
                .fontWeight(.semibold)
        }
    }
}
