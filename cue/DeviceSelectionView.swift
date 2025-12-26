//
//  DeviceSelectionView.swift
//  cue
//
//  Created by Ethan Xia on 12/22/25.
//

import SwiftUI

struct DeviceSelectionView: View {
    @EnvironmentObject var heartRateManager: HeartRateManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if heartRateManager.discoveredDevices.isEmpty {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .colorScheme(.dark)
                        Text("Searching for Devices...")
                            .font(.headline)
                            .foregroundColor(.gray)
                        Text("Make sure your device is on and in range.")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.5))
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(heartRateManager.discoveredDevices) { device in
                                Button {
                                    heartRateManager.connect(to: device)
                                    dismiss()
                                } label: {
                                    HStack {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(device.type == .healthKit ? Color.gray.opacity(0.3) : Color.orange.opacity(0.2))
                                                .frame(width: 50, height: 50)
                                            Image(systemName: device.type == .healthKit ? "applewatch" : "heart.fill")
                                                .foregroundColor(device.type == .healthKit ? .white : .orange)
                                                .font(.system(size: 24))
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(device.name)
                                                .font(.headline)
                                                .foregroundColor(.white)
                                            Text(device.type == .healthKit ? "Apple Watch" : "Bluetooth HR")
                                                .font(.caption)
                                                .foregroundColor(.gray)
                                        }
                                        
                                        Spacer()
                                        
                                        if device.type == .bluetooth {
                                            SignalStrengthView(rssi: device.rssi)
                                        }
                                        
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.gray.opacity(0.5))
                                    }
                                    .padding()
                                    .background(Color(white: 0.15))
                                    .cornerRadius(16)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Select Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                heartRateManager.startScanning()
            }
            .onDisappear {
                heartRateManager.stopScanning()
                heartRateManager.cancelConnection()
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct SignalStrengthView: View {
    let rssi: Int
    var bars: Int {
        if rssi > -60 { return 4 }
        if rssi > -70 { return 3 }
        if rssi > -80 { return 2 }
        if rssi > -90 { return 1 }
        return 0
    }
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < bars ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 3, height: CGFloat(6 + index * 4))
            }
        }
    }
}