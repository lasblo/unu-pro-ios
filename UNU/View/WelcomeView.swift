import SwiftUI

struct WelcomeScreen: View {
    @EnvironmentObject var scooterManager: UnuScooterManager
    @Binding var hasCompletedOnboarding: Bool
    @State private var isAnimating = false
    @State private var showConnect = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.1, green: 0.1, blue: 0.2),
                        Color(red: 0.2, green: 0.2, blue: 0.3)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                
                VStack(spacing: 30) {
                    Spacer()
                    
                    // Logo and title
                    VStack(spacing: 20) {
                        Text("Welcome!")
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                    
                    // Welcome message
                    VStack(spacing: 16) {
                        Text("Connect to your unu scooter and control it with just your phone.")
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 40)
                    }
                    
                    Spacer()
                    
                    // Action buttons
                    VStack(spacing: 16) {
                        Button(action: {
                            showConnect = true
                        }) {
                            HStack {
                                Image(systemName: "bolt.horizontal.circle.fill")
                                Text("Connect Scooter")
                            }
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(.white)
                            .foregroundStyle(Color(red: 0.1, green: 0.1, blue: 0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .opacity(scooterManager.bluetoothState != .poweredOn ? 0.4 : 1)
                        }
                        .disabled(scooterManager.bluetoothState != .poweredOn)
                        
                        if scooterManager.bluetoothState != .poweredOn {
                            Text(scooterManager.statusMessage)
                                .foregroundStyle(.white.opacity(0.8))
                                .font(.subheadline)
                        }
                    }
                    .padding(.horizontal, 24)
                    .opacity(isAnimating ? 1 : 0)
                    .offset(y: isAnimating ? 0 : 20)
                }
                .padding(.bottom, 48)
            }
            .sheet(isPresented: $showConnect) {
                ScooterConnectionView(hasCompletedOnboarding: $hasCompletedOnboarding)
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 1.2)) {
                isAnimating = true
            }
        }
    }
}
