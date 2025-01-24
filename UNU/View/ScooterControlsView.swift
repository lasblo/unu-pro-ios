//
//  ScooterControlsView.swift
//  unu pro
//
//  Created by Lasse on 24.01.25.
//

import SwiftUI

struct ScooterControlsView: View {
    @EnvironmentObject var scooterManager: UnuScooterManager
    @State private var showBatteryDetails = false
    
    // For the custom drag gesture on the lock slider
    @GestureState private var dragState = DragState.inactive
    enum DragState {
        case inactive
        case dragging(translation: CGFloat)
        
        var translation: CGFloat {
            switch self {
            case .inactive:               return 0
            case .dragging(let distance): return distance
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 4) {
            // Header
            Text("unu scooter pro")
                .font(.title.bold())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack {
                Circle()
                    .fill(scooterManager.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(scooterManager.statusMessage)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                // Slide to Lock/Unlock
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
                                
                                Image(systemName: scooterManager.isLocked
                                      ? "lock.fill"
                                      : "lock.open.fill")
                                    .font(.title3)
                                    .foregroundColor(.black)
                            }
                            .frame(width: 50, height: 50)
                            .offset(x: dragState.translation)
                            .gesture(
                                DragGesture()
                                    .updating($dragState) { value, state, _ in
                                        // Limit how far the user can drag the circle
                                        let maxTranslation = geometry.size.width - 80
                                        let newTranslation = min(max(0, value.translation.width),
                                                                 maxTranslation)
                                        state = .dragging(translation: newTranslation)
                                    }
                                    .onEnded { value in
                                        // If user drags more than half the width, trigger lock/unlock
                                        let threshold = geometry.size.width * 0.5
                                        if value.translation.width > threshold {
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
                        Text(scooterManager.isLocked
                             ? "Slide to Unlock"
                             : "Slide to Lock")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 60)
                
                // Quick Actions
                HStack(spacing: 16) {
                    // Hazard Button
                    Button {
                        if scooterManager.hazardLightsOn {
                            scooterManager.sendBlinkerCommand(state: "off")
                        } else {
                            scooterManager.sendBlinkerCommand(state: "both")
                        }
                        scooterManager.hazardLightsOn.toggle()
                    } label: {
                        VStack(spacing: 8) {
                            BlinkingImage(systemName: "exclamationmark.triangle.fill",
                                          isBlinking: scooterManager.hazardLightsOn)
                                .padding(.bottom, 2)
                            Text(scooterManager.hazardLightsOn
                                 ? "Disable Hazards"
                                 : "Enable Hazards")
                                .font(.callout)
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    
                    // Seat Button
                    Button(action: {
                        scooterManager.openSeat()
                    }) {
                        VStack(spacing: 8) {
                            Image(systemName: "suitcase.fill")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .padding(.bottom, 2)
                            Text("Open Storage")
                                .font(.callout)
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
                
                // Battery Details
                Button {
                    showBatteryDetails = true
                } label: {
                    HStack {
                        Image(systemName: "battery.100.bolt")
                            .foregroundStyle(.white)
                        Text("Battery Details")
                            .foregroundStyle(.white)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.bold())
                            .foregroundStyle(.gray)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding(20)
        }
        // Battery details sheet
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
        // Alert for lock/wake failures
        .alert(scooterManager.lockAlertMessage, isPresented: $scooterManager.showLockAlert) {
            Button("Ignore", role: .destructive) {
                // do nothing
            }
            Button("Retry") {
                scooterManager.restartAndLock()
            }
        }
        .onAppear() {
            scooterManager.startScanning()
        }
    }
}

// MARK: - BlinkingImage

struct BlinkingImage: View {
    let systemName: String
    let isBlinking: Bool
    
    @State private var isVisible = true
    
    var body: some View {
        Image(systemName: systemName)
            .font(.title2)
            .foregroundStyle(.yellow)
            .opacity(isBlinking ? (isVisible ? 1 : 0.3) : 1)
            .onChange(of: isBlinking) { newValue in
                if newValue {
                    withAnimation(Animation.easeInOut(duration: 0.5).repeatForever()) {
                        isVisible.toggle()
                    }
                } else {
                    // Stop blinking
                    withAnimation(.none) {
                        isVisible = true
                    }
                }
            }
    }
}
