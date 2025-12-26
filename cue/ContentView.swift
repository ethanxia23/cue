//
//  ContentView.swift
//  cue
//
//  Created by Ethan Xia on 12/22/25.
//

import SwiftUI
import Charts

struct ContentView: View {
    @EnvironmentObject var heartRateManager: HeartRateManager
    @EnvironmentObject var spotifyAuthManager: SpotifyAuthManager
    @EnvironmentObject var userPreferences: UserPreferences
    
    @Environment(\.scenePhase) var scenePhase
    @State private var showSettings = false

    var body: some View {
        Group {
            if needsAuth {
                AuthView()
            } else if !userPreferences.hasCompletedOnboarding {
                OnboardingView()
            } else {
                MainAppView(showSettings: $showSettings)
            }
        }
        .animation(.easeInOut, value: needsAuth || !userPreferences.hasCompletedOnboarding)
        .sheet(isPresented: $showSettings) {
             SettingsView()
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            switch newPhase {
            case .active:
                spotifyAuthManager.isInBackground = false
                spotifyAuthManager.fetchQueue()
                print("App active - syncing Spotify status")
            case .background:
                spotifyAuthManager.isInBackground = true
                print("App backgrounded - limiting tasks")
            @unknown default:
                break
            }
        }
    }

    var needsAuth: Bool {
        !spotifyAuthManager.isConnected || !isHeartRateConnected
    }

    var isHeartRateConnected: Bool {
        if case .connected(_) = heartRateManager.status {
            return true
        }
        return false
    }
}

// MARK: - Main Split UI

struct MainAppView: View {
    @EnvironmentObject var heartRateManager: HeartRateManager
    @EnvironmentObject var spotifyAuthManager: SpotifyAuthManager
    @Binding var showSettings: Bool
    
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // TOP: Music
                MusicPlayerView(showSettings: $showSettings)
                    .frame(height: geometry.size.height * 0.60)
                    .background(Color.black)
                
                // BOTTOM: Heart Rate
                HeartRateSectionView()
                    .frame(height: geometry.size.height * 0.40)
                    .background(Color(red: 0.05, green: 0.05, blue: 0.05))
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
}

// MARK: - Top: Music View

// MARK: - Top: Music View

struct MusicPlayerView: View {
    @EnvironmentObject var spotifyManager: SpotifyAuthManager
    @EnvironmentObject var heartRateManager: HeartRateManager
    @EnvironmentObject var userPreferences: UserPreferences
    @Binding var showSettings: Bool
    
    // Animation States
    @State private var dragOffset: CGFloat = 0
    @State private var isPressed: Bool = false
    
    // Scrubber States
    @State private var isDragging: Bool = false
    @State private var localDragProgress: Double = 0.0
    
    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 10) {
                
                // Header
                HStack {
                    Text("NOW PLAYING")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.gray)
                    Spacer()
                    
                    if case let .connected(device) = heartRateManager.status {
                        Text("Connected to: \(device.name)")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                }
                .padding(.top, geometry.safeAreaInsets.top + 50)
                .padding(.horizontal)
                .padding(.bottom, -5)
            
            // Current Track Section
            if let track = spotifyManager.currentTrack {
                ZStack {
                    // Background Layer (Swipe Reveal Icons)
                    HStack {
                        // Left: Previous / Restart
                        Image(systemName: "backward.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding(.leading, 30)
                            .opacity(dragOffset > 0 ? Double(min(dragOffset / 100, 1.0)) : 0)
                            .scaleEffect(dragOffset > 0 ? min(dragOffset / 50, 1.2) : 0.5)
                        
                        Spacer()
                        
                        // Right: Next
                        Image(systemName: "forward.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding(.trailing, 30)
                            .opacity(dragOffset < 0 ? Double(min(-dragOffset / 100, 1.0)) : 0)
                            .scaleEffect(dragOffset < 0 ? min(-dragOffset / 50, 1.2) : 0.5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 100)
                    .background(
                        // Dynamic background color based on swipe direction
                        RoundedRectangle(cornerRadius: 12)
                            .fill(dragOffset > 0 ? Color.orange.opacity(0.3) : (dragOffset < 0 ? Color.blue.opacity(0.3) : Color.clear))
                    )
                    .padding(.horizontal)
                    
                    // Foreground Layer (Track Info)
                    HStack(spacing: 20) {
                        if let url = URL(string: track.album.images.first?.url ?? "") {
                            AsyncImage(url: url) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Color.gray.opacity(0.3)
                            }
                            .frame(width: 100, height: 100)
                            .cornerRadius(8)
                            .shadow(radius: 10)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(width: 100, height: 100)
                                .cornerRadius(8)
                        }
                        
                        VStack(alignment: .leading, spacing: 5) {
                            Text(track.name)
                                .font(.title3)
                                .fontWeight(.bold)
                                .foregroundColor(spotifyManager.isPlaying ? .green : .red)
                                .lineLimit(1)
                            
                            Text(track.artistNames)
                                .font(.body)
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color.black) // Opaque background to hide icons behind
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.5), radius: 5, x: 0, y: 2)
                    .padding(.horizontal)
                    .offset(x: dragOffset)
                    .scaleEffect(isPressed ? 0.95 : 1.0)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // Resistance when swiping
                                self.dragOffset = value.translation.width
                            }
                            .onEnded { value in
                                withAnimation(.spring()) {
                                    if value.translation.width < -100 {
                                        // Swipe Left -> Next
                                        spotifyManager.skipNext()
                                    } else if value.translation.width > 100 {
                                        // Swipe Right -> Previous
                                        spotifyManager.skipPrevious()
                                    }
                                    // Reset offset
                                    self.dragOffset = 0
                                }
                            }
                    )
                    .gesture(
                        LongPressGesture(minimumDuration: 0)
                            .onEnded { _ in
                                // Press Animation
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    self.isPressed = true
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    withAnimation {
                                        self.isPressed = false
                                    }
                                    // Action
                                    if spotifyManager.isPlaying {
                                        spotifyManager.pause()
                                    } else {
                                        spotifyManager.play()
                                    }
                                }
                            }
                    )
                }
                .padding(.horizontal)
                .padding(.top, 2.5)
                
                // Interactive Scrubber
                VStack(spacing: 8) {
                    GeometryReader { scrubberGeo in
                        let totalWidth = scrubberGeo.size.width
                        let currentProgress = isDragging ? localDragProgress : (spotifyManager.durationMs > 0 ? Double(spotifyManager.progressMs) / Double(spotifyManager.durationMs) : 0)
                        
                        ZStack(alignment: .leading) {
                            // Background
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .frame(height: 4)
                                .cornerRadius(2)
                            
                            // Active Progress
                            Rectangle()
                                .fill(spotifyManager.isPlaying ? Color.green : Color.red)
                                .frame(width: totalWidth * currentProgress, height: 4)
                                .cornerRadius(2)
                            
                            // Thumb
                            Circle()
                                .fill(Color.white)
                                .frame(width: 12, height: 12)
                                .offset(x: (totalWidth * currentProgress) - 6)
                                .shadow(radius: 2)
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    isDragging = true
                                    let newProgress = max(0, min(1, value.location.x / totalWidth))
                                    localDragProgress = newProgress
                                }
                                .onEnded { value in
                                    let newProgress = max(0, min(1, value.location.x / totalWidth))
                                    let seekTarget = Int(newProgress * Double(spotifyManager.durationMs))
                                    spotifyManager.seek(to: seekTarget)
                                    
                                    // Brief delay to prevent UI jump before Spotify updates
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        isDragging = false
                                    }
                                }
                        )
                    }
                    .frame(height: 12)
                    
                    // Time Labels
                    HStack {
                        Text(formatTime(ms: isDragging ? Int(localDragProgress * Double(spotifyManager.durationMs)) : spotifyManager.progressMs))
                        Spacer()
                        Text(formatTime(ms: spotifyManager.durationMs, negative: true))
                    }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.gray)
                }
                .padding(.horizontal, 25)
                .padding(.top, 5)
            } else {
                // No track loaded - show "Open Spotify" button centered
                Spacer()
                VStack(spacing: 20) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    
                    Button(action: {
                        if let url = URL(string: "spotify://") {
                            UIApplication.shared.open(url)
                        }
                    }) {
                        HStack {
                            Image(systemName: "arrow.up.right.square")
                            Text("Open Spotify")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.green)
                        .cornerRadius(12)
                    }
                    
                }
                .frame(maxWidth: .infinity)
                Spacer()
            }
            // Queue Title and List remain same...
            
            // Queue Title
            Text("UP NEXT")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.gray)
                .padding(.leading)
                .padding(.top, 10)
            
            // Queue List
            List {
                ForEach(spotifyManager.queue.prefix(20)) { track in
                    HStack {
                        if let url = URL(string: track.album.images.first?.url ?? "") {
                            AsyncImage(url: url) { img in
                                img.resizable()
                            } placeholder: { Color.gray }
                            .frame(width: 40, height: 40)
                            .cornerRadius(4)
                        }
                        
                        VStack(alignment: .leading) {
                            HStack(spacing: 4) {
                                Text(track.name)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(spotifyManager.isAutoRecommended(track) ? .yellow : .white)
                                    .lineLimit(1)
                                
                                if spotifyManager.isAutoRecommended(track) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10))
                                        .foregroundColor(.yellow)
                                }
                            }
                            
                            Text(track.artistNames)
                                .font(.system(size: 12))
                                .foregroundColor(.gray)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle()) // Make full row tappable
                    .onTapGesture {
                        spotifyManager.jumpToTrack(track)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            spotifyManager.removeFromQueue(track)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            }
        }
        .onAppear {
            spotifyManager.userPreferences = userPreferences
            spotifyManager.heartRateManager = heartRateManager
            spotifyManager.fetchQueue()
        }
    }
    
    // Format milliseconds to mm:ss
    private func formatTime(ms: Int, negative: Bool = false) -> String {
        let totalSeconds = ms / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let sign = negative ? "-" : ""
        return String(format: "%@%d:%02d", sign, minutes, seconds)
    }
}

// MARK: - Bottom: Heart Rate View

struct HeartRateSectionView: View {
    @EnvironmentObject var heartRateManager: HeartRateManager
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Background Graph with Axes
            HeartRateGraphView(lineColor: heartRateColor)
                .padding(.top, 20)
                .padding(.bottom, 10)
                .padding(.leading, 40) // Space for Y-axis labels
                .padding(.trailing, 10)
            
            // Overlay Info - Top Right Corner (BPM + Zone)
            VStack(alignment: .trailing, spacing: 4) {
                Text("HEART RATE")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.gray)
                
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("\(heartRateManager.currentHeartRate)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundColor(heartRateColor)
                        .scaleEffect(heartRateManager.currentHeartRate > 0 ? 1.05 : 1.0)
                    
                    Text("BPM")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.gray)
                }
                
                let zone = userPreferences.zoneFor(bpm: heartRateManager.currentHeartRate)
                Text("ZONE \(zone)")
                    .font(.caption.bold())
                    .foregroundColor(heartRateColor)
                    .frame(maxWidth: .infinity) // Center within the VStack
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(heartRateColor.opacity(0.2))
                    .cornerRadius(4)
            }
            .padding(12)
            .frame(width: 120) // Give it a fixed width so centering is obvious
            .background(Color.black.opacity(0.8))
            .cornerRadius(12)
            .padding(.top, 20)
            .padding(.trailing, 20)
        }
    }
    
    @EnvironmentObject var userPreferences: UserPreferences
    
    var heartRateColor: Color {
        let hr = Double(heartRateManager.currentHeartRate)
        let maxHR = Double(userPreferences.maxHeartRate)
        let percent = hr / maxHR
        
        switch percent {
        case ..<0.50: return .gray.opacity(0.5) // Zone 0 - Recovery/Idle
        case 0.50..<0.60: return .gray           // Zone 1 - Very Light
        case 0.60..<0.70: return .blue           // Zone 2 - Light
        case 0.70..<0.80: return .green          // Zone 3 - Moderate
        case 0.80..<0.90: return .orange         // Zone 4 - Hard
        case 0.90...: return .red                // Zone 5 - Maximum
        default: return .white
        }
    }
}

// MARK: - Reused Graph

struct HeartRateGraphView: View {
    @EnvironmentObject var heartRateManager: HeartRateManager
    var lineColor: Color = .green
    
    var body: some View {
        Chart {
            ForEach(Array(heartRateManager.heartRateHistory.enumerated()), id: \.offset) { index, bpm in
                LineMark(
                    x: .value("Time", index),
                    y: .value("BPM", bpm)
                )
                .foregroundStyle(lineColor)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                
                AreaMark(
                    x: .value("Time", index),
                    y: .value("BPM", bpm)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [lineColor.opacity(0.2), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.gray.opacity(0.2))
                AxisValueLabel {
                    if let bpm = value.as(Int.self) {
                        Text("\(bpm)")
                            .font(.system(size: 10))
                            .foregroundColor(.gray)
                    }
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYScale(domain: 0...max(100, heartRateManager.sessionMaxHeartRate + 10))
        .animation(.default, value: heartRateManager.heartRateHistory)
    }
}
