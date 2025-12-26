//
//  SettingsView.swift
//  cue
//
//  Created by Antigravity on 12/25/25.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var spotifyAuthManager: SpotifyAuthManager
    @EnvironmentObject var heartRateManager: HeartRateManager
    @EnvironmentObject var userPreferences: UserPreferences
    
    @State private var maxHR: String = ""
    @State private var showFullOnboarding = false
    @State private var showSimulator = false
    
    var isHeartRateConnected: Bool {
        if case .connected(_) = heartRateManager.status {
            return true
        }
        return false
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                List {
                    Section(header: Text("Toning & Zones").foregroundColor(.green)) {
                        HStack {
                            Text("Max Heart Rate")
                            Spacer()
                            TextField("190", text: $maxHR)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .foregroundColor(.green)
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                    
                    Section(header: Text("Music Recommendations").foregroundColor(.green)) {
                        Toggle("Automatic Recommendation", isOn: $userPreferences.isAutoRecommendationEnabled)
                            .tint(.green)
                        
                        NavigationLink(destination: GenreSelectionListView(title: "Steady State", selection: Binding(
                            get: { Set(userPreferences.steadyStateGenres) },
                            set: { userPreferences.steadyStateGenres = Array($0) }
                        ))) {
                            HStack {
                                Text("Steady State")
                                Spacer()
                                Text("\(userPreferences.steadyStateGenres.count) Genres")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                        
                        NavigationLink(destination: GenreSelectionListView(title: "Threshold", selection: Binding(
                            get: { Set(userPreferences.thresholdGenres) },
                            set: { userPreferences.thresholdGenres = Array($0) }
                        ))) {
                            HStack {
                                Text("Threshold")
                                Spacer()
                                Text("\(userPreferences.thresholdGenres.count) Genres")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                    
                    // Debugging & Tools section hidden
                    // Section(header: Text("Debugging & Tools").foregroundColor(.yellow)) {
                    //     Button(action: { showSimulator = true }) {
                    //         HStack {
                    //             Image(systemName: "cpu")
                    //                 .foregroundColor(.yellow)
                    //             Text("Open Log Simulator")
                    //             Spacer()
                    //             Image(systemName: "chevron.right")
                    //                 .font(.caption)
                    //                 .foregroundColor(.gray)
                    //         }
                    //     }
                    // }
                    // .listRowBackground(Color.white.opacity(0.05))
                    
                    Section {
                        if isHeartRateConnected {
                            Button(role: .destructive, action: {
                                heartRateManager.disconnect()
                                dismiss()
                            }) {
                                HStack {
                                    Spacer()
                                    Text("Disconnect Heart Rate Monitor")
                                        .foregroundColor(.red)
                                    Spacer()
                                }
                            }
                        }
                        
                        Button(role: .destructive, action: {
                            spotifyAuthManager.logout()
                            dismiss()
                        }) {
                            HStack {
                                Spacer()
                                Text("Log Out from Spotify")
                                    .foregroundColor(.red)
                                Spacer()
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                }
                .scrollContentBackground(.hidden)
                .background(Color.black)
                .foregroundColor(.white)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        if let hr = Int(maxHR) {
                            userPreferences.maxHeartRate = hr
                        }
                        dismiss()
                    }
                }
            }
            .onAppear {
                maxHR = "\(userPreferences.maxHeartRate)"
            }
            .sheet(isPresented: $showSimulator) {
                SimulatorView()
                    .environmentObject(heartRateManager)
                    .environmentObject(spotifyAuthManager)
                    .environmentObject(userPreferences)
            }
        }
    }
}

struct GenreSelectionListView: View {
    let title: String
    @Binding var selection: Set<String>
    @State private var searchText = ""
    @State private var displayedCount = 100
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // 1. Search Bar
                TextField("Search 1,300+ genres...", text: $searchText)
                    .padding()
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(12)
                    .padding()
                    .onChange(of: searchText) { _ in
                        displayedCount = 100
                    }
                
                // 2. Multipill Display (if any selection)
                if !selection.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Current Selection (\(selection.count)/10)")
                                .font(.caption.bold())
                                .foregroundColor(.gray)
                            Spacer()
                            Button("Clear All") {
                                selection.removeAll()
                            }
                            .font(.caption)
                            .foregroundColor(.red)
                        }
                        .padding(.horizontal)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(selection).sorted(), id: \.self) { genre in
                                    HStack {
                                        Text(genre)
                                            .font(.system(size: 14, weight: .medium))
                                        Button(action: { selection.remove(genre) }) {
                                            Image(systemName: "xmark.circle.fill")
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.green.opacity(0.8))
                                    .foregroundColor(.white)
                                    .cornerRadius(20)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.bottom, 12)
                }
                
                // 3. Genre List
                List {
                    ForEach(Array(filteredGenres.enumerated()), id: \.element) { index, genre in
                        Button(action: {
                            if selection.contains(genre) {
                                selection.remove(genre)
                            } else if selection.count < 10 {
                                selection.insert(genre)
                            }
                        }) {
                            HStack {
                                Text(genre)
                                    .foregroundColor(.white)
                                Spacer()
                                if selection.contains(genre) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundColor(.white.opacity(0.2))
                                }
                            }
                        }
                        .listRowBackground(selection.contains(genre) ? Color.green.opacity(0.1) : Color.white.opacity(0.05))
                        .onAppear {
                            if searchText.isEmpty && index == displayedCount - 10 {
                                loadMoreGenres()
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Color.black)
            }
        }
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if selection.count >= 10 {
                    Text("Max Reached")
                        .font(.caption)
                        .foregroundColor(.yellow)
                }
            }
        }
    }
    
    var filteredGenres: [String] {
        if searchText.isEmpty {
            let allGenres = Genres.all
            return Array(allGenres.prefix(min(displayedCount, allGenres.count)))
        } else {
            return Genres.all.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    private func loadMoreGenres() {
        let totalGenres = Genres.all.count
        if displayedCount < totalGenres {
            displayedCount = min(displayedCount + 100, totalGenres)
        }
    }
}
