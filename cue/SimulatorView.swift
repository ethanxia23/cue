//
//  SimulatorView.swift
//  cue
//

import SwiftUI

struct SimulatorView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var heartRateManager: HeartRateManager
    @EnvironmentObject var spotifyAuthManager: SpotifyAuthManager
    @EnvironmentObject var userPreferences: UserPreferences
    
    @State private var simulatedBPM: Double = 120
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // 1. Simulator Controls
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Text("HR SIMULATION")
                                .font(.caption.bold())
                                .foregroundColor(.green)
                            Spacer()
                            Toggle("", isOn: $heartRateManager.isSimulationMode)
                                .labelsHidden()
                                .tint(.green)
                        }
                        
                        if heartRateManager.isSimulationMode {
                            VStack(spacing: 5) {
                                HStack {
                                    Text("\(Int(simulatedBPM)) BPM")
                                        .font(.system(size: 32, weight: .bold, design: .rounded))
                                        .foregroundColor(heartRateColor)
                                    Spacer()
                                    Text("Zone \(userPreferences.zoneFor(bpm: Int(simulatedBPM)))")
                                        .font(.headline)
                                        .foregroundColor(heartRateColor)
                                }
                                
                                Slider(value: $simulatedBPM, in: 60...200, step: 1)
                                    .tint(heartRateColor)
                                    .onChange(of: simulatedBPM) { _, newValue in
                                        heartRateManager.simulateHeartRate(Int(newValue))
                                    }
                            }
                            .padding()
                            .background(Color.white.opacity(0.05))
                            .cornerRadius(12)
                        } else {
                            Text("Enable simulation mode to manually override heart rate and test recommendation triggers.")
                                .font(.caption)
                                .foregroundColor(.gray)
                                .padding()
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(12)
                        }
                    }
                    .padding()
                    
                    Divider().background(Color.white.opacity(0.1))
                    
                    // 2. Logs
                    VStack(alignment: .leading, spacing: 10) {
                        Text("REC ENGINE LOGS")
                            .font(.caption.bold())
                            .foregroundColor(.yellow)
                            .padding(.horizontal)
                            .padding(.top, 20)
                        
                        if spotifyAuthManager.recommendationLogs.isEmpty {
                            Spacer()
                            VStack(spacing: 12) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 40))
                                    .foregroundColor(.gray.opacity(0.3))
                                Text("No recommendations triggered yet.")
                                    .foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity)
                            Spacer()
                        } else {
                            List {
                                ForEach(spotifyAuthManager.recommendationLogs.reversed()) { event in
                                    LogEntryView(event: event)
                                        .listRowBackground(Color.clear)
                                        .listRowSeparator(.visible, edges: .bottom)
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                        }
                    }
                }
            }
            .navigationTitle("CUE Simulator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { spotifyAuthManager.recommendationLogs.removeAll() }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
        }
    }
    
    var heartRateColor: Color {
        let percent = simulatedBPM / Double(userPreferences.maxHeartRate)
        switch percent {
        case ..<0.60: return .blue
        case 0.60..<0.70: return .blue
        case 0.70..<0.80: return .green
        case 0.80..<0.90: return .orange
        case 0.90...: return .red
        default: return .white
        }
    }
}

struct LogEntryView: View {
    let event: RecommendationEvent
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(event.timestamp, style: .time)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.gray)
                
                Spacer()
                
                Text("Z\(event.zone)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(4)
                
                Text("\(event.bpm) BPM")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            
            HStack(alignment: .top) {
                if event.status == "fetching" {
                    ProgressView()
                        .scaleEffect(0.7)
                        .padding(.trailing, 5)
                } else if event.status == "waiting: analysis in progress" {
                    Image(systemName: "hourglass")
                        .foregroundColor(.blue)
                        .rotationEffect(.degrees(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 2) * 180)) // Simple animation
                } else if event.status.contains("success") {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    if let track = event.foundTrack {
                        Text("Queued: \(track)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.green)
                    } else {
                        Text(event.status.capitalized)
                            .font(.system(size: 14))
                            .foregroundColor(event.status.contains("error") ? .red : (event.status.contains("waiting") ? .blue : .gray))
                    }
                    
                    if !event.genres.isEmpty {
                        Text("Seeds: \(event.genres.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundColor(.gray)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
}
