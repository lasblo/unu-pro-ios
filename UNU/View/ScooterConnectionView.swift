//
//  ScooterConnectionView.swift
//  unu pro
//
//  Created by Lasse on 24.01.25.
//


import SwiftUI

struct ScooterConnectionView: View {
    @EnvironmentObject var scooterManager: UnuScooterManager
    @Environment(\.dismiss) private var dismiss
    @Binding var hasCompletedOnboarding: Bool
    @State private var showSuccessMessage = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Scanning animation
                ZStack {
                    Circle()
                        .stroke(Color.blue.opacity(0.3), lineWidth: 2)
                        .frame(width: 200, height: 200)
                    
                    Circle()
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: 200, height: 200)
                        .scaleEffect(scooterManager.isScanning ? 1.5 : 1.0)
                        .opacity(scooterManager.isScanning ? 0.0 : 1.0)
                        .animation(.easeInOut(duration: 2).repeatForever(autoreverses: false),
                                 value: scooterManager.isScanning)
                    
                    Image(systemName: "scooter")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue)
                }
                
                if showSuccessMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.green)
                        
                        Text("Successfully Connected!")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Your unu pro scooter is now ready to use")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        
                        Button("Get Started") {
                            scooterManager.handlePostOnboardingConnection()
                            dismiss()
                            hasCompletedOnboarding = true
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top)
                    }
                    .transition(.opacity)
                } else {
                    Text(scooterManager.statusMessage)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Text("Make sure your unu pro scooter is nearby, powered on and unlocked.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button(action: {
                        if scooterManager.isScanning {
                            scooterManager.stopScanning()
                            dismiss()
                        } else {
                            scooterManager.startScanning()
                        }
                    }) {
                        Text(scooterManager.isScanning ? "Cancel" : "Try Again")
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                    .padding()
                }
            }
            .padding()
            .onChange(of: scooterManager.isConnected) { newValue in
                if newValue {
                    withAnimation {
                        showSuccessMessage = true
                    }
                }
            }
        }.onAppear() {
            scooterManager.startScanning()
        }
        .onDisappear {
            if !scooterManager.isConnected {
                scooterManager.stopScanning()
            }
        }
    }
}
