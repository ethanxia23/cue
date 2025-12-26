//
//  AuthView.swift
//  cue
//
//  Created by Ethan Xia on 12/22/25.
//

import SwiftUI

struct AuthView: View {
    @EnvironmentObject var heartRateManager: HeartRateManager
    @EnvironmentObject var spotifyAuthManager: SpotifyAuthManager

    @State private var animateGradient = false
    @State private var showDeviceSelection = false

    var body: some View {
        ZStack {
            // Background
            LinearGradient(
                colors: [Color.black, Color(red: 0.1, green: 0.1, blue: 0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // Animated glow
            Circle()
                .fill(Color.blue.opacity(0.1))
                .frame(width: 300, height: 300)
                .offset(
                    x: animateGradient ? -50 : 50,
                    y: animateGradient ? -100 : 100
                )
                .blur(radius: 40)
                .animation(
                    .easeInOut(duration: 5).repeatForever(autoreverses: true),
                    value: animateGradient
                )
                .onAppear { animateGradient.toggle() }

            VStack(spacing: 40) {
                // Header
                VStack(spacing: 8) {
                    Text("CUE")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .tracking(4)

                    Text("by Ethan Xia")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.top, 60)

                Spacer()

                // Connection cards
                VStack(spacing: 20) {
                    ConnectionCard(
                        title: "Heart Rate Monitor",
                        icon: "heart.fill",
                        color: .red,
                        isConnected: isHeartRateConnected,
                        isLoading: isHeartRateScanning,
                        connectedText: connectedDeviceName.map { "Connected to: \($0)" } ?? "Connected",
                        action: {
                            heartRateManager.startScanning()
                            showDeviceSelection = true
                        }
                    )

                    ConnectionCard(
                        title: "Spotify",
                        icon: "music.note",
                        color: .green,
                        isConnected: spotifyAuthManager.isConnected,
                        isLoading: spotifyAuthManager.isLoading,
                        connectedText: spotifyAuthManager.displayName.map { "Signed in as: \($0)" } ?? "Connected",
                        action: { spotifyAuthManager.connect() }
                    )
                }
                .padding(.horizontal)

                Spacer()

                Button {
                    // Continue action
                } label: {
                    Text("Ready to Start")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(allConnected ? Color.blue : Color.gray.opacity(0.3))
                        .cornerRadius(12)
                }
                .disabled(!allConnected)
                .opacity(allConnected ? 1 : 0)
                .animation(.easeInOut, value: allConnected)
                .padding(.horizontal, 30)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showDeviceSelection) {
            DeviceSelectionView()
                .environmentObject(heartRateManager)
        }
    }

    // MARK: - Derived State

    var isHeartRateConnected: Bool {
        // Use _ to match associated value in enum
        if case .connected(_) = heartRateManager.status {
            return true
        }
        return false
    }

    var isHeartRateScanning: Bool {
        if case .scanning = heartRateManager.status { return true }
        if case .connecting = heartRateManager.status { return true }
        return false
    }
    
    var connectedDeviceName: String? {
        if case .connected(let device) = heartRateManager.status {
            return device.name
        }
        return nil
    }

    var allConnected: Bool {
        isHeartRateConnected && spotifyAuthManager.isConnected
    }
}

