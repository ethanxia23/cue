//
//  OnboardingView.swift
//  cue
//
//  Created by Antigravity on 12/25/25.
//

import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject var spotifyAuthManager: SpotifyAuthManager
    @EnvironmentObject var userPreferences: UserPreferences
    
    @State private var currentStep = 0
    @State private var maxHR: String = ""
    @State private var searchText: String = ""
    
    let commonGenres = ["pop", "rock", "hip-hop", "dance", "electronic", "indie", "workout", "energetic", "focus", "chill"]
    
    // For local selection before saving
    @State private var localSteadyGenres: Set<String> = []
    @State private var localThresholdGenres: Set<String> = []
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 30) {
                // Progress indicator
                HStack {
                    ForEach(0..<3) { index in
                        Capsule()
                            .fill(currentStep >= index ? Color.green : Color.gray.opacity(0.3))
                            .frame(height: 6)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)
                
                if currentStep == 0 {
                    heartRateStep
                } else if currentStep == 1 {
                    genreStep(title: "Steady State", subtitle: "What do you listen to during low intensity?", selection: $localSteadyGenres)
                } else if currentStep == 2 {
                    genreStep(title: "Threshold", subtitle: "What gets you moving during high intensity?", selection: $localThresholdGenres)
                }
                
                Spacer()
                
                Button(action: nextStep) {
                    Text(currentStep == 2 ? "Finish" : "Next")
                        .font(.headline)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(canProceed ? Color.green : Color.gray)
                        .cornerRadius(12)
                }
                .disabled(!canProceed)
                .padding(.horizontal, 40)
                .padding(.bottom, 20)
            }
        }
        .onAppear {
            maxHR = "\(userPreferences.maxHeartRate)"
            localSteadyGenres = Set(userPreferences.steadyStateGenres)
            localThresholdGenres = Set(userPreferences.thresholdGenres)
        }
    }
    
    var heartRateStep: some View {
        VStack(spacing: 20) {
            Text("Set Your Baseline")
                .font(.largeTitle.bold())
                .foregroundColor(.white)
            
            Text("CUE uses your Max Heart Rate to calculate your personalized training zones.")
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("MAX HEART RATE (BPM)")
                    .font(.caption.bold())
                    .foregroundColor(.green)
                
                TextField("190", text: $maxHR)
                    .keyboardType(.numberPad)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
            
            // Preview zones
            if let hr = Int(maxHR), hr > 0 {
                VStack(spacing: 12) {
                    zonePreview(label: "Zone 1 (Recovery)", range: "\(Int(Double(hr) * 0.5)) - \(Int(Double(hr) * 0.6))", color: .gray)
                    zonePreview(label: "Zone 2 (Light)", range: "\(Int(Double(hr) * 0.6)) - \(Int(Double(hr) * 0.7))", color: .blue)
                    zonePreview(label: "Zone 3 (Moderate)", range: "\(Int(Double(hr) * 0.7)) - \(Int(Double(hr) * 0.8))", color: .green)
                    zonePreview(label: "Zone 4 (Threshold)", range: "\(Int(Double(hr) * 0.8)) - \(Int(Double(hr) * 0.9))", color: .orange)
                    zonePreview(label: "Zone 5 (Max)", range: "\(Int(Double(hr) * 0.9))+", color: .red)
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(12)
                .padding(.horizontal, 20)
            }
        }
    }
    
    func zonePreview(label: String, range: String, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundColor(.white).font(.subheadline)
            Spacer()
            Text(range).foregroundColor(.gray).font(.caption.monospaced())
        }
    }
    
    func genreStep(title: String, subtitle: String, selection: Binding<Set<String>>) -> some View {
        VStack(spacing: 15) {
            VStack(spacing: 5) {
                Text(title)
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                
                Text(subtitle)
                    .font(.body)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
            }
            
            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("Search genres...", text: $searchText)
                    .foregroundColor(.white)
            }
            .padding()
            .background(Color.white.opacity(0.1))
            .cornerRadius(12)
            .padding(.horizontal, 20)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if searchText.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("COMMONLY USED")
                                .font(.caption.bold())
                                .foregroundColor(.gray)
                                .padding(.horizontal)
                            
                            FlowLayout(items: commonGenres) { genre in
                                genrePill(genre: genre, selection: selection)
                            }
                        }
                        
                        Divider().background(Color.white.opacity(0.1)).padding(.horizontal)
                        
                        VStack(alignment: .leading, spacing: 10) {
                            Text("ALL GENRES")
                                .font(.caption.bold())
                                .foregroundColor(.gray)
                                .padding(.horizontal)
                            
                            FlowLayout(items: Array(Genres.all.filter { !commonGenres.contains($0.lowercased()) }.prefix(50))) { genre in
                                genrePill(genre: genre, selection: selection)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SEARCH RESULTS")
                                .font(.caption.bold())
                                .foregroundColor(.gray)
                                .padding(.horizontal)
                            
                            FlowLayout(items: filteredGenres) { genre in
                                genrePill(genre: genre, selection: selection)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
        }
    }
    
    func genrePill(genre: String, selection: Binding<Set<String>>) -> some View {
        Button(action: {
            if selection.wrappedValue.contains(genre) {
                selection.wrappedValue.remove(genre)
            } else if selection.wrappedValue.count < 10 {
                selection.wrappedValue.insert(genre)
            }
        }) {
            HStack(spacing: 6) {
                if selection.wrappedValue.contains(genre) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                }
                Text(genre)
                    .font(.subheadline.bold())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(selection.wrappedValue.contains(genre) ? Color.green : Color.white.opacity(0.1))
            .foregroundColor(selection.wrappedValue.contains(genre) ? .black : .white)
            .cornerRadius(20)
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(selection.wrappedValue.contains(genre) ? Color.green : Color.white.opacity(0.2), lineWidth: 1)
            )
        }
    }
    
    var filteredGenres: [String] {
        if searchText.isEmpty {
            return []
        } else {
            return Genres.all.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var canProceed: Bool {
        if currentStep == 0 {
            return Int(maxHR) ?? 0 > 100
        } else if currentStep == 1 {
            return !localSteadyGenres.isEmpty
        } else {
            return !localThresholdGenres.isEmpty
        }
    }
    
    func nextStep() {
        if currentStep < 2 {
            withAnimation {
                currentStep += 1
                searchText = ""
            }
        } else {
            // Save all to preferences
            if let hr = Int(maxHR) { userPreferences.maxHeartRate = hr }
            userPreferences.steadyStateGenres = Array(localSteadyGenres)
            userPreferences.thresholdGenres = Array(localThresholdGenres)
            userPreferences.hasCompletedOnboarding = true
        }
    }
}

// Simple FlowLayout for the genres
struct FlowLayout<Content: View, T: Hashable>: View {
    let items: [T]
    let content: (T) -> Content
    
    @State private var totalHeight = CGFloat.zero
    
    var body: some View {
        VStack {
            GeometryReader { geometry in
                self.generateContent(in: geometry)
            }
        }
        .frame(height: totalHeight)
    }
    
    private func generateContent(in geometry: GeometryProxy) -> some View {
        var width = CGFloat.zero
        var height = CGFloat.zero
        
        return ZStack(alignment: .topLeading) {
            ForEach(self.items, id: \.self) { item in
                self.content(item)
                    .padding([.horizontal, .vertical], 4)
                    .alignmentGuide(.leading, computeValue: { d in
                        if (abs(width - d.width) > geometry.size.width) {
                            width = 0
                            height -= d.height
                        }
                        let result = width
                        if item == self.items.last! {
                            width = 0 // last item
                        } else {
                            width -= d.width
                        }
                        return result
                    })
                    .alignmentGuide(.top, computeValue: { d in
                        let result = height
                        if item == self.items.last! {
                            height = 0 // last item
                        }
                        return result
                    })
            }
        }.background(viewHeightReader($totalHeight))
    }
    
    private func viewHeightReader(_ binding: Binding<CGFloat>) -> some View {
        return GeometryReader { geometry -> Color in
            let rect = geometry.frame(in: .local)
            DispatchQueue.main.async {
                binding.wrappedValue = rect.size.height
            }
            return .clear
        }
    }
}
