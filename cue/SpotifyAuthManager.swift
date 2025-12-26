//
//  SpotifyAuthManager.swift
//  cue
//
//  Created by Ethan Xia on 12/22/25.
//

import Foundation
import SwiftUI
import Combine
import AuthenticationServices
import CryptoKit
import UIKit

class SpotifyAuthManager: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    
    @Published var isConnected: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
    
    @Published var accessToken: String?
    @Published var refreshToken: String?
    @Published var tokenExpiry: Date?
    @Published var displayName: String?
    @Published var userMarket: String = "US" // Default fallback
    
    // Dependencies (set after init)
    weak var userPreferences: UserPreferences?
    weak var heartRateManager: HeartRateManager?
    
    // Track if we've already recommended for the current track to avoid duplicates
    private var lastRecommendedTrackURI: String?
    
    @Published var currentTrack: SpotifyTrack?
    @Published var queue: [SpotifyTrack] = []
    @Published var progressMs: Int = 0  // Current position in milliseconds
    @Published var durationMs: Int = 0  // Total duration in milliseconds
    
    // Playback State for Session Persistence (Web API + Option B Context)
    private var pausedTrackURI: String?
    private var pausedPositionMs: Int?
    
    // MARK: - Configuration
    private let clientID = "9e1940116400439d9108b086676d8098"
    private let redirectURI = "cue-app://spotify-login-callback"
    private let tokenEndpoint = "https://accounts.spotify.com/api/token"
    private let scope = "user-read-private user-read-email user-read-playback-state user-modify-playback-state user-read-currently-playing user-read-recently-played user-top-read"
    
    // MARK: - PKCE
    private var codeVerifier: String?
    private var authSession: ASWebAuthenticationSession?
    // Tracks that user "deleted" from queue locally. If Spotify plays them, we skip.
    private var bannedTrackURIs: Set<String> = []
    // Tracks added by the algorithm for visual styling
    private var autoRecommendedURIs: Set<String> = []
    // Raw queue from Spotify, unfiltered
    private var rawQueue: [SpotifyTrack] = []
    // Last known active device ID
    private var activeDeviceId: String?
    
    @Published var isPlaying: Bool = false
    @Published var isInBackground: Bool = false
    @Published var isJumping: Bool = false
    private var userVolume: Int = 50 
    
    @Published var recommendationLogs: [RecommendationEvent] = []
    private var isFetchingRecommendation: Bool = false
    private var isPollingCyanite: Bool = false
    private var lastRecommendationAttempt: Date?
    private var progressTimer: AnyCancellable?
    // Session-based history of recommended tracks (normalized name + artist) to prevent loops
    private var sessionRecommendedTracks: Set<String> = []
    // Track retry attempts per seed track to prevent infinite loops
    private var recommendationRetryCount: [String: Int] = [:]
    
    // Familiarity tracking for 90/10 ranking system
    private var familiarTrackIds: Set<String> = [] // Track IDs from recently played + top tracks
    private var familiarArtistIds: Set<String> = [] // Artist IDs from familiar tracks
    private var isFamiliarityLoaded: Bool = false

    override init() {
        super.init()
        loadTokens()
        startProgressTimer()
    }
    
    private func startProgressTimer() {
        progressTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self = self else { return }
                
                // 1. Local progress interpolation (UI only)
                if self.isPlaying && self.progressMs < (self.durationMs) {
                    // Only interpolate if we are in the foreground and NOT jumping
                    if !self.isInBackground && !self.isJumping {
                        self.progressMs += 1000
                    }
                    
                    // Always check recommendations
                    self.checkAutoRecommendation()
                }
                
                // 2. Adaptive Polling
                let currentTime = Int(Date().timeIntervalSince1970)
                
                // Foreground: every 3s if playing, 15s if paused
                // Background: every 30s if playing, skip if paused
                let interval: Int
                if self.isInBackground {
                    interval = self.isPlaying ? 30 : 3600 // Basically wait for foreground
                } else {
                    interval = self.isPlaying ? 3 : 15
                }
                
                if currentTime % interval == 0 {
                    self.fetchQueue()
                }
            }
    }

    private func loadTokens() {
        self.accessToken = KeychainManager.shared.load(for: "spotify_access_token")
        self.refreshToken = KeychainManager.shared.load(for: "spotify_refresh_token")
        if let expiryStr = KeychainManager.shared.load(for: "spotify_token_expiry"),
           let expiryTime = Double(expiryStr) {
            self.tokenExpiry = Date(timeIntervalSince1970: expiryTime)
        }
        
        if accessToken != nil {
            self.isConnected = true
            
            // Fetch profile and queue
            fetchUserProfile()
            
            // Load familiarity data in background
            loadFamiliarityData()
            
            // Check if we need to refresh immediately
            if let expiry = tokenExpiry, expiry < Date() {
                refreshAccessToken()
            } else {
                fetchQueue()
            }
        }
    }

    func isAutoRecommended(_ track: SpotifyTrack) -> Bool {
        autoRecommendedURIs.contains(track.uri)
    }

    func setVolume(percent: Int) {
        guard let token = accessToken else { return }
        var urlString = "https://api.spotify.com/v1/me/player/volume?volume_percent=\(percent)"
        if let deviceId = activeDeviceId {
            urlString += "&device_id=\(deviceId)"
        }
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        print("Setting Spotify Volume to \(percent)%")
        URLSession.shared.dataTask(with: request).resume()
    }
    
    func fetchQueue() {
        guard let token = accessToken else { return }
        
        // Fetch Queue
        var queueRequest = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/queue")!)
        queueRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: queueRequest) { [weak self] data, _, _ in
            guard let data = data, let self = self else { return }
            do {
                let response = try JSONDecoder().decode(SpotifyQueueResponse.self, from: data)
                DispatchQueue.main.async {
                    // ALWAYS update queue if we have data (even if currently_playing is nil)
                    if !response.queue.isEmpty {
                        self.rawQueue = response.queue
                        
                        // Suppress queue updates during jumps to maintain the "Illusion"
                        if !self.isJumping {
                            self.queue = response.queue.filter { !self.bannedTrackURIs.contains($0.uri) }
                        }
                    }
                    
                    // Suppress track metadata updates during jumps
                    if self.isJumping { return }
                    
                    if let current = response.currently_playing {
                        // Reset recommendation flag if track changed
                        if self.currentTrack?.uri != current.uri {
                            self.lastRecommendedTrackURI = nil
                            print("Track Changed: \(current.name)")
                            
                            // Trigger recommendation IMMEDIATELY on first load / track change
                            DispatchQueue.main.async {
                                self.checkAutoRecommendation(force: true)
                            }
                        }
                        
                        // Check if current track is banned
                        if self.bannedTrackURIs.contains(current.uri) {
                            print("🚫 Auto-Advanced into Banned Track (\(current.name)). Triggering Silent Skip Illusion...")
                            self.performSmartSkip(steps: 1)
                        }
                        self.currentTrack = current
                    }
                }
            } catch {
                // Decay of session often results in decode errors
            }
        }.resume()
        
        // Fetch Playback State (for isPlaying & Device ID)
        var stateRequest = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player")!)
        stateRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: stateRequest) { [weak self] data, response, _ in
            guard let self = self else { return }
            // Check for session death (204 = No active device, 404 = Not found)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 204 || httpResponse.statusCode == 404 {
                    if self.activeDeviceId != nil {
                        print("Playback State: 204/404 (Session Lost/Device Gone)")
                    }
                    // Session is dead - stop polling, preserve UI
                    DispatchQueue.main.async {
                        self.isPlaying = false
                        self.activeDeviceId = nil // Clear it so next Play triggers Option A
                    }
                    return
                }
            }
            
            guard let data = data else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let is_playing_spotify = json["is_playing"] as? Bool ?? false
                    let progress = json["progress_ms"] as? Int ?? 0
                    
                    // Get current item URI
                    var duration = 0
                    if let item = json["item"] as? [String: Any] {
                        duration = item["duration_ms"] as? Int ?? 0
                    }
                    
                    // Capture Device ID
                    if let device = json["device"] as? [String: Any],
                       let id = device["id"] as? String {
                        if self.activeDeviceId != id {
                            print("New Active Device Found: \(id)")
                        }
                        self.activeDeviceId = id
                    }
                    
                    DispatchQueue.main.async {
                        // Capture Volume if not jumping
                        if let device = json["device"] as? [String: Any],
                           let vol = device["volume_percent"] as? Int,
                           !self.isJumping {
                            self.userVolume = vol
                        }

                        if self.isJumping { return }

                        if self.isPlaying != is_playing_spotify {
                            print("isPlaying changed -> \(is_playing_spotify)")
                        }
                        self.isPlaying = is_playing_spotify
                        self.progressMs = progress
                        self.durationMs = duration
                    }
                }
            } catch {
                // print("Playback state error: \(error)")
            }
        }.resume()
    }

    
    func fetchUserProfile() {
        guard let token = accessToken else { return }
        
        var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data = data else { return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    DispatchQueue.main.async {
                        if let name = json["display_name"] as? String {
                            self?.displayName = name
                            print("Spotify User: \(name)")
                        }
                        // Extract country/market for recommendations API
                        if let country = json["country"] as? String {
                            self?.userMarket = country
                            print("User Market: \(country)")
                        } else {
                            print("No country in profile, using default: US")
                        }
                    }
                }
            } catch {
                print("Profile fetch error: \(error)")
            }
        }.resume()
    }
    

    
    func fetchCyaniteRecommendations(spotifyTrackId: String, addToQueue: Bool = false, bpmRange: (start: Int, end: Int)? = nil, targetGenres: [String]? = nil, completion: (([String]) -> Void)? = nil) {
        var urlString = "https://cue-ashy.vercel.app/api/cyanite-webhook?trackId=\(spotifyTrackId)"
        
        if let range = bpmRange {
            urlString += "&bpmStart=\(range.start)&bpmEnd=\(range.end)"
        }
        
        if let genres = targetGenres, !genres.isEmpty {
            let encodedGenres = genres.joined(separator: ",").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            urlString += "&genres=\(encodedGenres)"
        }
        
        guard let proxyUrl = URL(string: urlString) else { return }
        
        self.isFetchingRecommendation = true
        self.lastRecommendationAttempt = Date()
        
        print("Requesting Cyanite Recommendation via Vercel Proxy (Filtered) for: \(spotifyTrackId)")
        
        var request = URLRequest(url: proxyUrl)
        request.timeoutInterval = 10.0 // 10s timeout
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isFetchingRecommendation = false
            }
            
            if let error = error {
                print("Vercel Proxy Network Error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.updateLogStatus("error: \(error.localizedDescription)")
                }
                return
            }
            
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            
            if let data = data, let body = String(data: data, encoding: .utf8) {
                print("Vercel Proxy Response [\(statusCode)]: \(body)")
            }
            
            if statusCode == 200, let data = data {
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let status = json["status"] as? String {
                        
                        if status == "success" {
                            // Handle both old format (trackId) and new format (trackIds array)
                            if let foundId = json["trackId"] as? String {
                                // Old format - single track ID
                                DispatchQueue.main.async {
                                    print("Vercel Proxy: Found similar track \(foundId)")
                                    // Call completion handler if provided
                                    completion?([foundId])
                                    if addToQueue {
                                        self.processRecommendationTrack(trackId: foundId, spotifyTrackId: spotifyTrackId, bpmRange: bpmRange, targetGenres: targetGenres)
                                    }
                                }
                            } else if let trackIds = json["trackIds"] as? [String], !trackIds.isEmpty {
                                // New format - array of track IDs
                                DispatchQueue.main.async {
                                    print("Vercel Proxy: Found \(trackIds.count) similar tracks")
                                    
                                    // Fetch track details to print names
                                    self.enrichTracks(trackIds: trackIds) { enrichedTracks in
                                        print("ALL CYANITE TRACKS RETURNED:")
                                        for (index, enriched) in enrichedTracks.enumerated() {
                                            print("   \(index + 1). '\(enriched.name)' by \(enriched.artistNames) (ID: \(enriched.id))")
                                        }
                                    }
                                    
                                    // Call completion handler if provided
                                    completion?(trackIds)
                                    if addToQueue {
                                        self.processRecommendationTracks(trackIds: trackIds, spotifyTrackId: spotifyTrackId, bpmRange: bpmRange, targetGenres: targetGenres)
                                    }
                                }
                            } else {
                                print("Vercel Proxy: Success but no track IDs found")
                                DispatchQueue.main.async {
                                    self.updateLogStatus("error: no track IDs in response")
                                }
                            }
                        } else if status == "analyzing" {
                            print("Vercel Proxy: Track is being analyzed. Polling...")
                            DispatchQueue.main.async {
                                self.updateLogStatus("waiting: analysis in progress")
                                completion?([]) // Return empty for analyzing
                                self.startCyanitePolling(trackId: spotifyTrackId)
                            }
                        } else {
                            print("Vercel Proxy returned unexpected status: \(status)")
                            DispatchQueue.main.async {
                                self.updateLogStatus("error: unexpected response schema")
                                completion?([])
                            }
                        }
                    } else {
                        print("Vercel Proxy: JSON missing 'status' field. Response: \(String(data: data, encoding: .utf8) ?? "nil")")
                        DispatchQueue.main.async {
                            self.updateLogStatus("error: stale server version")
                            completion?([])
                        }
                    }
                } catch {
                    print("Vercel Proxy parsing error: \(error)")
                    DispatchQueue.main.async {
                        self.updateLogStatus("error: parse failure")
                        completion?([])
                    }
                }
            } else {
                print("Vercel Proxy failed with status \(statusCode)")
                DispatchQueue.main.async {
                    self.updateLogStatus("error: proxy failure (\(statusCode))")
                    completion?([])
                }
            }
        }.resume()
    }
    
    // Process a single recommendation track (check duplicates, then add if valid)
    private func processRecommendationTrack(trackId: String, spotifyTrackId: String, bpmRange: (start: Int, end: Int)?, targetGenres: [String]?) {
        // First fetch track details to get name and artist for comparison
        fetchTrackDetails(id: trackId) { [weak self] track in
            guard let self = self, let track = track else {
                // If we can't fetch details, skip this track
                return
            }
            
            // Check for duplicates
            self.checkIfTrackShouldBeSkipped(trackId: trackId, trackName: track.name, artistNames: track.artistNames) { shouldSkip in
                if shouldSkip {
                    // Check retry count for this seed track
                    let currentRetries = self.recommendationRetryCount[spotifyTrackId] ?? 0
                    if currentRetries >= 3 {
                        print("Exceeded retry limit for seed track. Could not find suitable track.")
                        DispatchQueue.main.async {
                            self.updateLogStatus("error: no suitable tracks found after retries")
                            self.recommendationRetryCount.removeValue(forKey: spotifyTrackId)
                        }
                        return
                    }
                    
                    // Increment retry count and retry
                    self.recommendationRetryCount[spotifyTrackId] = currentRetries + 1
                    print("Track '\(track.name)' is duplicate. Retrying search (attempt \(currentRetries + 1))...")
                    DispatchQueue.main.async {
                        self.updateLogStatus("retrying: track is duplicate (attempt \(currentRetries + 1))")
                        // Retry the search
                        self.fetchCyaniteRecommendations(spotifyTrackId: spotifyTrackId, addToQueue: true, bpmRange: bpmRange, targetGenres: targetGenres)
                    }
                } else {
                    // Track is valid, add to queue and session history, clear retry count
                    let key = self.trackKey(name: track.name, artistNames: track.artistNames)
                    self.sessionRecommendedTracks.insert(key)
                    self.recommendationRetryCount.removeValue(forKey: spotifyTrackId)
                    print("Track '\(track.name)' is valid. Adding to queue.")
                    self.autoRecommendedURIs.insert(track.uri)
                    self.addToQueue(track)
                    self.logRecommendationSuccess(track: track)
                }
            }
        }
    }
    
    // Process multiple recommendation tracks (check each until finding one that's valid)
    private func processRecommendationTracks(trackIds: [String], spotifyTrackId: String, bpmRange: (start: Int, end: Int)?, targetGenres: [String]?) {
        guard !trackIds.isEmpty else {
            print("No track IDs to process")
            DispatchQueue.main.async {
                self.updateLogStatus("error: empty track list")
            }
            return
        }
        
        // Fetch all track details first to print them
        var fetchedTracks: [SpotifyTrack] = []
        var fetchCount = 0
        let totalCount = trackIds.count
        
        for trackId in trackIds {
            fetchTrackDetails(id: trackId) { [weak self] track in
                guard let self = self else { return }
                fetchCount += 1
                
                if let track = track {
                    fetchedTracks.append(track)
                }
                
                // When all tracks are fetched, print them and then process
                if fetchCount == totalCount {
                    print("ALL CYANITE TRACKS (with details) RETURNED:")
                    for (index, track) in fetchedTracks.enumerated() {
                        print("   \(index + 1). '\(track.name)' by \(track.artistNames)")
                    }
                    
                    // Now process tracks one by one
                    self.processFetchedTracks(fetchedTracks: fetchedTracks, spotifyTrackId: spotifyTrackId, bpmRange: bpmRange, targetGenres: targetGenres)
                }
            }
        }
    }
    
    // Process fetched tracks (check each until finding one that's valid)
    private func processFetchedTracks(fetchedTracks: [SpotifyTrack], spotifyTrackId: String, bpmRange: (start: Int, end: Int)?, targetGenres: [String]?) {
        guard !fetchedTracks.isEmpty else {
            print("No tracks to process")
            DispatchQueue.main.async {
                self.updateLogStatus("error: no valid tracks")
            }
            return
        }
        
        // Check tracks one by one
        var index = 0
        func checkNextTrack() {
            guard index < fetchedTracks.count else {
                // All tracks were duplicates, check retry count
                let currentRetries = self.recommendationRetryCount[spotifyTrackId] ?? 0
                if currentRetries >= 3 {
                    print("Exceeded retry limit for seed track. Could not find suitable track.")
                    DispatchQueue.main.async {
                        self.updateLogStatus("error: no suitable tracks found after retries")
                        self.recommendationRetryCount.removeValue(forKey: spotifyTrackId)
                    }
                    return
                }
                
                // Increment retry count and retry
                self.recommendationRetryCount[spotifyTrackId] = currentRetries + 1
                print("All \(fetchedTracks.count) tracks were duplicates. Retrying search (attempt \(currentRetries + 1))...")
                DispatchQueue.main.async {
                    self.updateLogStatus("retrying: all tracks are duplicates (attempt \(currentRetries + 1))")
                    self.fetchCyaniteRecommendations(spotifyTrackId: spotifyTrackId, addToQueue: true, bpmRange: bpmRange, targetGenres: targetGenres)
                }
                return
            }
            
            let track = fetchedTracks[index]
            index += 1
            
            let trackId = track.uri.replacingOccurrences(of: "spotify:track:", with: "")
            
            // Check for duplicates
            self.checkIfTrackShouldBeSkipped(trackId: trackId, trackName: track.name, artistNames: track.artistNames) { shouldSkip in
                if shouldSkip {
                    // This track is duplicate, check next one
                    print("Track '\(track.name)' is duplicate. Checking next...")
                    checkNextTrack()
                } else {
                    // Found a valid track, add it to queue and session history, clear retry count
                    let key = self.trackKey(name: track.name, artistNames: track.artistNames)
                    self.sessionRecommendedTracks.insert(key)
                    self.recommendationRetryCount.removeValue(forKey: spotifyTrackId)
                    print("Track '\(track.name)' is valid. Adding to queue.")
                    self.autoRecommendedURIs.insert(track.uri)
                    self.addToQueue(track)
                    self.logRecommendationSuccess(track: track)
                }
            }
        }
        
        checkNextTrack()
    }
    
    private func logRecommendationSuccess(track: SpotifyTrack) {
        if var lastEvent = self.recommendationLogs.last, lastEvent.status == "fetching" {
            lastEvent.status = "success (Cyanite Proxy)"
            lastEvent.foundTrack = track.name
            lastEvent.timestamp = Date()
            self.recommendationLogs[self.recommendationLogs.count - 1] = lastEvent
        }
    }
    
    private func updateLogStatus(_ status: String) {
        if var lastEvent = self.recommendationLogs.last, lastEvent.status == "fetching" {
            lastEvent.status = status
            self.recommendationLogs[self.recommendationLogs.count - 1] = lastEvent
        }
    }
    
    private func startCyanitePolling(trackId: String) {
        guard !isPollingCyanite else { return }
        isPollingCyanite = true
        
        let pollUrl = URL(string: "https://cue-ashy.vercel.app/api/cyanite-webhook?trackId=\(trackId)")!
        
        func performPoll() {
            guard isPollingCyanite else { return }
            
            URLSession.shared.dataTask(with: pollUrl) { [weak self] data, _, _ in
                guard let self = self else { return }
                
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let status = json["status"] as? String,
                   status == "success" {
                    
                    print("🔔 Vercel Proxy: Analysis Complete for \(trackId)!")
                    DispatchQueue.main.async {
                        self.isPollingCyanite = false
                        self.fetchCyaniteRecommendations(spotifyTrackId: trackId, addToQueue: true)
                    }
                } else {
                    // Still analyzing or pending, poll again in 5 seconds
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5.0) {
                        performPoll()
                    }
                }
            }.resume()
        }
        
        performPoll()
    }
    
    // Fetch track details when we only have an ID from Cyanite
    private func fetchTrackDetails(id: String, completion: @escaping (SpotifyTrack?) -> Void) {
        guard let token = accessToken else { completion(nil); return }
        let url = URL(string: "https://api.spotify.com/v1/tracks/\(id)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data else { completion(nil); return }
            let track = try? JSONDecoder().decode(SpotifyTrack.self, from: data)
            DispatchQueue.main.async {
                completion(track)
            }
        }.resume()
    }
    
    // MARK: - Familiarity Tracking
    
    // Load familiarity data (recently played + top tracks)
    private func loadFamiliarityData(completion: @escaping () -> Void = {}) {
        guard !isFamiliarityLoaded else { completion(); return }
        guard let token = accessToken else { completion(); return }
        
        var loadedCount = 0
        let totalSources = 3 // recently played, top short, top medium
        
        func checkComplete() {
            loadedCount += 1
            if loadedCount == totalSources {
                isFamiliarityLoaded = true
                print("Familiarity loaded: \(familiarTrackIds.count) tracks, \(familiarArtistIds.count) artists")
                completion()
            }
        }
        
        // 1. Recently played (last 50 tracks)
        let recentlyPlayedUrl = URL(string: "https://api.spotify.com/v1/me/player/recently-played?limit=50")!
        var recentlyPlayedRequest = URLRequest(url: recentlyPlayedUrl)
        recentlyPlayedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: recentlyPlayedRequest) { [weak self] data, _, _ in
            guard let self = self, let data = data else { checkComplete(); return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["items"] as? [[String: Any]] {
                for item in items {
                    if let track = item["track"] as? [String: Any],
                       let trackId = track["id"] as? String {
                        self.familiarTrackIds.insert(trackId)
                        if let artists = track["artists"] as? [[String: Any]] {
                            for artist in artists {
                                if let artistId = artist["id"] as? String {
                                    self.familiarArtistIds.insert(artistId)
                                }
                            }
                        }
                    }
                }
            }
            checkComplete()
        }.resume()
        
        // 2. Top tracks (short term)
        let topShortUrl = URL(string: "https://api.spotify.com/v1/me/top/tracks?time_range=short_term&limit=50")!
        var topShortRequest = URLRequest(url: topShortUrl)
        topShortRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: topShortRequest) { [weak self] data, _, _ in
            guard let self = self, let data = data else { checkComplete(); return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["items"] as? [[String: Any]] {
                for item in items {
                    if let trackId = item["id"] as? String {
                        self.familiarTrackIds.insert(trackId)
                    }
                    if let artists = item["artists"] as? [[String: Any]] {
                        for artist in artists {
                            if let artistId = artist["id"] as? String {
                                self.familiarArtistIds.insert(artistId)
                            }
                        }
                    }
                }
            }
            checkComplete()
        }.resume()
        
        // 3. Top tracks (medium term)
        let topMediumUrl = URL(string: "https://api.spotify.com/v1/me/top/tracks?time_range=medium_term&limit=50")!
        var topMediumRequest = URLRequest(url: topMediumUrl)
        topMediumRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: topMediumRequest) { [weak self] data, _, _ in
            guard let self = self, let data = data else { checkComplete(); return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["items"] as? [[String: Any]] {
                for item in items {
                    if let trackId = item["id"] as? String {
                        self.familiarTrackIds.insert(trackId)
                    }
                    if let artists = item["artists"] as? [[String: Any]] {
                        for artist in artists {
                            if let artistId = artist["id"] as? String {
                                self.familiarArtistIds.insert(artistId)
                            }
                        }
                    }
                }
            }
            checkComplete()
        }.resume()
    }
    
    // Check if a track is familiar
    private func isFamiliar(track: EnrichedTrack) -> Bool {
        return familiarTrackIds.contains(track.id) || 
               track.artistIds.contains(where: { familiarArtistIds.contains($0) })
    }
    
    // Batch enrich tracks with popularity and artist IDs
    private func enrichTracks(trackIds: [String], completion: @escaping ([EnrichedTrack]) -> Void) {
        guard let token = accessToken, !trackIds.isEmpty else { completion([]); return }
        
        // Spotify batch API allows up to 50 tracks per request
        let batches = trackIds.chunked(into: 50)
        var allEnriched: [EnrichedTrack] = []
        var completedBatches = 0
        
        for batch in batches {
            let idsString = batch.joined(separator: ",")
            let url = URL(string: "https://api.spotify.com/v1/tracks?ids=\(idsString)")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            URLSession.shared.dataTask(with: request) { data, _, _ in
                guard let data = data else {
                    completedBatches += 1
                    if completedBatches == batches.count {
                        DispatchQueue.main.async {
                            completion(allEnriched)
                        }
                    }
                    return
                }
                
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let tracks = json["tracks"] as? [[String: Any]] {
                        for trackData in tracks {
                            // Skip null tracks (Spotify API can return null for invalid IDs)
                            guard let trackDict = trackData as? [String: Any], trackDict["id"] != nil else { continue }
                            
                            if let track = try? JSONDecoder().decode(SpotifyTrack.self, from: JSONSerialization.data(withJSONObject: trackData)),
                               let popularity = trackData["popularity"] as? Int {
                                // Extract artist IDs directly from JSON (more reliable)
                                var artistIds: [String] = []
                                if let artists = trackData["artists"] as? [[String: Any]] {
                                    artistIds = artists.compactMap { $0["id"] as? String }
                                }
                                
                                let enriched = EnrichedTrack(
                                    id: track.id,
                                    name: track.name,
                                    uri: track.uri,
                                    artistNames: track.artistNames,
                                    artistIds: artistIds,
                                    popularity: popularity,
                                    track: track
                                )
                                allEnriched.append(enriched)
                            }
                        }
                    }
                } catch {
                    print("Error enriching tracks: \(error)")
                }
                
                completedBatches += 1
                if completedBatches == batches.count {
                    DispatchQueue.main.async {
                        completion(allEnriched)
                    }
                }
            }.resume()
        }
    }
    
    // Score a track based on familiarity and popularity
    private func scoreTrack(_ track: EnrichedTrack) -> Double {
        var score: Double = 0
        
        // Familiarity bonuses
        if familiarTrackIds.contains(track.id) {
            score += 5.0 // Direct track familiarity
        }
        
        // Artist familiarity
        let familiarArtistCount = track.artistIds.filter { familiarArtistIds.contains($0) }.count
        if familiarArtistCount > 0 {
            score += 3.0 * Double(familiarArtistCount)
        }
        
        // Popularity boost (0-100 scale, normalize to 0-5)
        score += Double(track.popularity) / 20.0
        
        // Novelty penalty (if completely unknown)
        if !familiarTrackIds.contains(track.id) && familiarArtistCount == 0 {
            score -= 2.0
        }
        
        return score
    }
    
    // 90/10 ranking system: Generate candidates, score, and sample
    private func rankAndSampleCandidates(candidates: [EnrichedTrack]) -> SpotifyTrack? {
        guard !candidates.isEmpty else { return nil }
        
        // Score all candidates
        let scored = candidates.map { (track: $0, score: scoreTrack($0)) }
        
        // Split into familiar and novel
        let familiarTracks = scored.filter { isFamiliar(track: $0.track) }
        let novelTracks = scored.filter { !isFamiliar(track: $0.track) }
        
        print("Ranking: \(familiarTracks.count) familiar, \(novelTracks.count) novel candidates")
        
        // Sample: 90% familiar, 10% novel
        let useFamiliar = Int.random(in: 1...100) <= 90
        
        if useFamiliar && !familiarTracks.isEmpty {
            // Sort by score (highest first) and pick top
            let sorted = familiarTracks.sorted { $0.score > $1.score }
            if let selected = sorted.first {
                print("Selected familiar track: '\(selected.track.name)' (score: \(String(format: "%.2f", selected.score)))")
                return selected.track.track
            }
        } else if !novelTracks.isEmpty {
            // Sort by score and pick top novel track
            let sorted = novelTracks.sorted { $0.score > $1.score }
            if let selected = sorted.first {
                print("Selected novel track: '\(selected.track.name)' (score: \(String(format: "%.2f", selected.score)))")
                return selected.track.track
            }
        }
        
        // Fallback: just pick highest scored overall
        let allSorted = scored.sorted { $0.score > $1.score }
        return allSorted.first?.track.track
    }
    
    // Fetch recently played tracks
    private func fetchRecentlyPlayed(limit: Int = 50, completion: @escaping ([SpotifyTrack]) -> Void) {
        guard let token = accessToken else { completion([]); return }
        let url = URL(string: "https://api.spotify.com/v1/me/player/recently-played?limit=\(limit)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data else { completion([]); return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let items = json["items"] as? [[String: Any]] {
                    // Recently played API returns items with nested "track" object
                    let tracks = items.compactMap { item -> SpotifyTrack? in
                        guard let trackData = item["track"] as? [String: Any] else { return nil }
                        return try? JSONDecoder().decode(SpotifyTrack.self, from: JSONSerialization.data(withJSONObject: trackData))
                    }
                    DispatchQueue.main.async {
                        completion(tracks)
                    }
                } else {
                    DispatchQueue.main.async {
                        completion([])
                    }
                }
            } catch {
                print("Error fetching recently played tracks: \(error)")
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }.resume()
    }
    
    // Fetch user's top tracks (short-term: last 4 weeks)
    private func fetchUserTopTracks(limit: Int = 50, completion: @escaping ([SpotifyTrack]) -> Void) {
        guard let token = accessToken else { completion([]); return }
        let url = URL(string: "https://api.spotify.com/v1/me/top/tracks?time_range=short_term&limit=\(limit)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data else { completion([]); return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let items = json["items"] as? [[String: Any]] {
                    let tracks = items.compactMap { item -> SpotifyTrack? in
                        return try? JSONDecoder().decode(SpotifyTrack.self, from: JSONSerialization.data(withJSONObject: item))
                    }
                    DispatchQueue.main.async {
                        completion(tracks)
                    }
                } else {
                    DispatchQueue.main.async {
                        completion([])
                    }
                }
            } catch {
                print("Error fetching top tracks: \(error)")
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }.resume()
    }
    
    // Get popular tracks using Spotify recommendations with seed tracks from user's history
    private func getPopularTracksFromHistory(seedTrackIds: [String], targetGenres: [String], bpmRange: (start: Int, end: Int)?, limit: Int = 20, completion: @escaping ([SpotifyTrack]) -> Void) {
        guard let token = accessToken, !seedTrackIds.isEmpty else { completion([]); return }
        
        // Use up to 5 seed tracks (Spotify limit)
        let seeds = Array(seedTrackIds.prefix(5))
        let seedTracksString = seeds.joined(separator: ",")
        
        // Validate genres for Spotify
        let validatedGenres = targetGenres.compactMap { genre -> String? in
            let lower = genre.lowercased().replacingOccurrences(of: " ", with: "-")
            // Map to Spotify genre seeds
            let genreMap: [String: String] = [
                "electronic": "electronic",
                "electronicdance": "electronic",
                "rock": "rock",
                "pop": "pop",
                "hiphop": "hip-hop",
                "rap": "hip-hop",
                "rnb": "r-n-b",
                "r&b": "r-n-b",
                "jazz": "jazz",
                "blues": "blues",
                "classical": "classical",
                "reggae": "reggae",
                "metal": "metal",
                "folk": "folk",
                "country": "country"
            ]
            return genreMap[lower] ?? (Genres.recommendationSeeds.contains(lower) ? lower : nil)
        }
        
        var components = URLComponents(string: "https://api.spotify.com/v1/recommendations")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "seed_tracks", value: seedTracksString),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        
        // Add genre seeds if available (up to 5 total seeds)
        if !validatedGenres.isEmpty && seeds.count < 5 {
            let genreSeeds = Array(validatedGenres.prefix(5 - seeds.count))
            queryItems.append(URLQueryItem(name: "seed_genres", value: genreSeeds.joined(separator: ",")))
        }
        
        // Add target tempo based on BPM range if available (Spotify uses BPM directly)
        if let bpmRange = bpmRange {
            queryItems.append(URLQueryItem(name: "min_tempo", value: "\(bpmRange.start)"))
            queryItems.append(URLQueryItem(name: "max_tempo", value: "\(bpmRange.end)"))
        }
        
        components.queryItems = queryItems
        
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil else {
                print("Error fetching popular tracks: \(error?.localizedDescription ?? "unknown")")
                completion([])
                return
            }
            
            do {
                let response = try JSONDecoder().decode(SpotifyRecommendationResponse.self, from: data)
                DispatchQueue.main.async {
                    completion(response.tracks)
                }
            } catch {
                print("Error parsing popular tracks: \(error)")
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }.resume()
    }
    
    // Normalize track name by removing common suffixes
    private func normalizeTrackName(_ name: String) -> String {
        var normalized = name.trimmingCharacters(in: .whitespaces)
        // Remove common suffixes like "- Radio Edit", "- Remix", "- Extended Mix", etc.
        let suffixes = [
            " - Radio Edit", " - Remix", " - Extended Mix", " - Original Mix",
            " - Edit", " - Single Version", " - Album Version", " - Clean Version",
            " - Explicit", " - Instrumental", " - Acoustic", " - Live"
        ]
        for suffix in suffixes {
            if normalized.lowercased().hasSuffix(suffix.lowercased()) {
                normalized = String(normalized.dropLast(suffix.count))
                break
            }
        }
        return normalized.trimmingCharacters(in: .whitespaces).lowercased()
    }
    
    // Create a unique key for a track (normalized name + artist) for duplicate detection
    private func trackKey(name: String, artistNames: String) -> String {
        return "\(normalizeTrackName(name))|\(artistNames.lowercased())"
    }
    
    // Check if a track is already in queue, currently playing, or in session history
    private func isTrackDuplicate(trackName: String, artistNames: String) -> Bool {
        let key = trackKey(name: trackName, artistNames: artistNames)
        
        // Check session history
        if sessionRecommendedTracks.contains(key) {
            return true
        }
        
        // Check currently playing track
        if let current = currentTrack {
            let currentKey = trackKey(name: current.name, artistNames: current.artistNames)
            if currentKey == key {
                return true
            }
        }
        
        // Check queue
        for queuedTrack in queue {
            let queuedKey = trackKey(name: queuedTrack.name, artistNames: queuedTrack.artistNames)
            if queuedKey == key {
                return true
            }
        }
        
        return false
    }
    
    // Check if track should be skipped (recently played, queue, current track, session history)
    private func checkIfTrackShouldBeSkipped(trackId: String, trackName: String, artistNames: String, completion: @escaping (Bool) -> Void) {
        // First check local duplicates (queue, current track, session history)
        if isTrackDuplicate(trackName: trackName, artistNames: artistNames) {
            print("Track '\(trackName)' is duplicate (in queue/current/session). Skipping.")
            completion(true)
            return
        }
        
        // Then check recently played
        guard let token = accessToken else { completion(false); return }
        let url = URL(string: "https://api.spotify.com/v1/me/player/recently-played?limit=50")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        let normalizedTrackName = normalizeTrackName(trackName)
        let normalizedArtistNames = artistNames.lowercased()
        
        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data else { completion(false); return }
            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let items = json["items"] as? [[String: Any]] {
                    // Check if track appears in recently played (by ID or normalized name + artist)
                    let wasRecentlyPlayed = items.contains { item in
                        if let track = item["track"] as? [String: Any] {
                            // Check by ID first (exact match)
                            if let id = track["id"] as? String, id == trackId {
                                return true
                            }
                            
                            // Check by normalized name and artist
                            if let name = track["name"] as? String,
                               let artists = track["artists"] as? [[String: Any]] {
                                let normalizedName = self.normalizeTrackName(name)
                                let normalizedArtists = artists.compactMap { $0["name"] as? String }
                                    .joined(separator: ", ")
                                    .lowercased()
                                
                                // Match if normalized names are similar and artists match
                                if normalizedName == normalizedTrackName && normalizedArtists == normalizedArtistNames {
                                    return true
                                }
                            }
                        }
                        return false
                    }
                    DispatchQueue.main.async {
                        completion(wasRecentlyPlayed)
                    }
                } else {
                    DispatchQueue.main.async {
                        completion(false)
                    }
                }
            } catch {
                print("Error checking recently played: \(error)")
                DispatchQueue.main.async {
                    completion(false)
                }
            }
        }.resume()
    }
    
    func fetchRecommendations(genres: [String], limit: Int = 10, addToQueue: Bool = false) {
        guard let token = accessToken, !genres.isEmpty else { return }
        
        // 1. Validate & Normalize Genres for Spotify Seeds
        // Spotify only accepts specific hyphenated lowercase seeds.
        let validatedSeeds = genres.compactMap { genre -> String? in
            let lower = genre.lowercased()
            let hyphenated = lower.replacingOccurrences(of: " ", with: "-")
            
            // Handle common aliases
            let aliases: [String: String] = [
                "alternative-rock": "alt-rock",
                "r&b": "r-n-b",
                "hip-hop": "hip-hop"
            ]
            
            let seedCandidate = aliases[hyphenated] ?? hyphenated
            return Genres.recommendationSeeds.contains(seedCandidate) ? seedCandidate : nil
        }
        
        guard !validatedSeeds.isEmpty else {
            print("No valid recommendation seeds found in selection: \(genres)")
            DispatchQueue.main.async {
                if var lastEvent = self.recommendationLogs.last, lastEvent.status == "fetching" {
                    lastEvent.status = "skipped: no valid seeds"
                    self.recommendationLogs[self.recommendationLogs.count - 1] = lastEvent
                }
            }
            return
        }
        
        // Spotify only allows up to 5 seed genres
        let finalSeeds = Array(validatedSeeds.prefix(5))
        let genreSeedsString = finalSeeds.joined(separator: ",")
        
        var components = URLComponents(string: "https://api.spotify.com/v1/recommendations")!
        components.queryItems = [
            URLQueryItem(name: "seed_genres", value: genreSeedsString),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        self.isFetchingRecommendation = true
        self.lastRecommendationAttempt = Date()
        
        print("Fetching recommendations for seeds: \(genreSeedsString)")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.isFetchingRecommendation = false
            }
            
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            
            // Log raw response for debugging
            if let data = data, let rawResponse = String(data: data, encoding: .utf8) {
                print("Raw Rec Response [\(statusCode)]: \(rawResponse)")
            }
            
            guard let data = data, !data.isEmpty else {
                print("Spotify recommendations returned empty data [\(statusCode)]")
                DispatchQueue.main.async {
                    if var lastEvent = self.recommendationLogs.last, lastEvent.status == "fetching" {
                        lastEvent.status = "error: empty response (\(statusCode))"
                        self.recommendationLogs[self.recommendationLogs.count - 1] = lastEvent
                    }
                }
                return
            }
            
            do {
                let recResponse = try JSONDecoder().decode(SpotifyRecommendationResponse.self, from: data)
                DispatchQueue.main.async {
                    print("Received \(recResponse.tracks.count) recommendations")
                    if addToQueue, let firstTrack = recResponse.tracks.first {
                        self.autoRecommendedURIs.insert(firstTrack.uri)
                        self.addToQueue(firstTrack)
                        
                        // Log track received
                        if var lastEvent = self.recommendationLogs.last, lastEvent.status == "fetching" {
                            lastEvent.status = "success"
                            lastEvent.foundTrack = firstTrack.name
                            lastEvent.timestamp = Date()
                            self.recommendationLogs[self.recommendationLogs.count - 1] = lastEvent
                        }
                    } else if addToQueue {
                        // Success but no tracks found
                        if var lastEvent = self.recommendationLogs.last, lastEvent.status == "fetching" {
                            lastEvent.status = "success: no tracks matched (200)"
                            self.recommendationLogs[self.recommendationLogs.count - 1] = lastEvent
                        }
                    }
                }
            } catch {
                print("Recommendation fetch error [\(statusCode)]: \(error)")
                DispatchQueue.main.async {
                    if var lastEvent = self.recommendationLogs.last, lastEvent.status == "fetching" {
                        lastEvent.status = "error: \(error.localizedDescription) (\(statusCode))"
                        self.recommendationLogs[self.recommendationLogs.count - 1] = lastEvent
                    }
                }
            }
        }.resume()
    }
    
    private func checkAutoRecommendation(force: Bool = false) {
        guard let prefs = userPreferences, prefs.isAutoRecommendationEnabled else { return }
        guard let hrManager = heartRateManager, currentTrack != nil else { return }
        
        // 1. Singleton Queue Enforcement: Ensure only ONE CUE-recommended track is in the queue
        let recommendedInQueue = queue.contains { isAutoRecommended($0) }
        
        // If we already have a recommended track in queue, don't add another one
        if recommendedInQueue {
            return
        }
        
        // 2. Performance: Proactive Maintenance
        triggerRecommendation(prefs: prefs, hrManager: hrManager, force: force)
    }
    


    private func triggerRecommendation(prefs: UserPreferences, hrManager: HeartRateManager, force: Bool = false) {
        guard let currentTrack = currentTrack, !isFetchingRecommendation else { return }
        
        // Cooldown: Don't trigger more than once every 15 seconds UNLESS it's a forced track change
        if !force, let last = lastRecommendationAttempt, Date().timeIntervalSince(last) < 15 {
            return
        }

        let hr = hrManager.currentHeartRate
        let zone = prefs.zoneFor(bpm: hr)
        
        // Only trigger recommendations for Zones 2-5
        guard zone >= 2 else {
            print("Rec Engine: Skipping (Zone \(zone))")
            return
        }
        
        let targetGenres: [String]
        let strategy: String
        
        // Zone 4-5 (Threshold): Use threshold genres for high-intensity workouts
        // Zone 2-3 (Steady State): Use steady state genres for moderate workouts
        if zone >= 4 {
            // Threshold zones (4-5): High intensity
            targetGenres = prefs.thresholdGenres
            strategy = "Threshold (Zone \(zone))"
            print("Threshold Zone: Using threshold genres: \(prefs.thresholdGenres.joined(separator: ", "))")
        } else {
            // Steady state zones (2-3): Moderate intensity
            targetGenres = prefs.steadyStateGenres
            strategy = "Steady State (Zone \(zone))"
            print("Steady State Zone: Using steady state genres: \(prefs.steadyStateGenres.joined(separator: ", "))")
        }
        
        if !targetGenres.isEmpty {
            print("Rec Engine: Triggering track find (\(strategy))")
            lastRecommendedTrackURI = currentTrack.uri
            
            let event = RecommendationEvent(
                zone: zone,
                bpm: hr,
                genres: targetGenres,
                status: "fetching"
            )
            recommendationLogs.append(event)
            if recommendationLogs.count > 50 { recommendationLogs.removeFirst() }

            // Calculate BPM range based on Zone and current heart rate
            // Use heart rate as center point with a range
            let hrBPM = hr // Current heart rate in BPM
            
            let calculatedRange: (start: Int, end: Int)
            switch zone {
            case 5: 
                // Zone 5: High intensity - use fixed range for high-energy music
                // If heart rate is too low, use default high-energy range
                if hrBPM < 150 {
                    calculatedRange = (140, 210) // Default high-energy range
                } else {
                    calculatedRange = (max(140, hrBPM - 20), min(210, hrBPM + 20))
                }
            case 4: 
                // Zone 4: Threshold - use fixed range if heart rate is too low
                if hrBPM < 120 {
                    calculatedRange = (120, 180) // Default threshold range
                } else {
                    calculatedRange = (max(120, hrBPM - 15), min(180, hrBPM + 15))
                }
            case 3: 
                // Zone 3: Moderate - use fixed range if heart rate is too low
                if hrBPM < 100 {
                    calculatedRange = (100, 160) // Default moderate range
                } else {
                    calculatedRange = (max(100, hrBPM - 12), min(160, hrBPM + 12))
                }
            case 2: 
                // Zone 2: Light - use fixed range if heart rate is too low
                if hrBPM < 80 {
                    calculatedRange = (80, 140) // Default light range
                } else {
                    calculatedRange = (max(80, hrBPM - 10), min(140, hrBPM + 10))
                }
            default: 
                calculatedRange = (60, 200)
            }
            
            // Ensure start <= end (create new tuple if needed)
            let bpmRange: (start: Int, end: Int)
            if calculatedRange.start > calculatedRange.end {
                bpmRange = (calculatedRange.end, calculatedRange.start)
            } else {
                bpmRange = calculatedRange
            }
            
            print("Heart Rate: \(hr) BPM (Zone \(zone)) -> Music BPM Range: \(bpmRange.start)-\(bpmRange.end)")

            let trackId = currentTrack.uri.replacingOccurrences(of: "spotify:track:", with: "")
            print("SEED TRACK (recommending from): '\(currentTrack.name)' by \(currentTrack.artistNames)")
            
            print("SPOTIFY CATEGORY FLOW: Starting recommendation process")
            print("  Zone: \(zone) (\(strategy))")
            print("  Target genres from user selection: \(targetGenres.joined(separator: ", "))")
            
            fetchTracksFromCategory(targetGenres: targetGenres) { [weak self] selectedTrack in
                guard let self = self else { return }
                
                if let track = selectedTrack {
                    print("SPOTIFY CATEGORY FLOW: Successfully selected track from Spotify: '\(track.name)' by \(track.artistNames)")
                    self.selectAndQueueTrack(track, seedTrackId: trackId)
                } else {
                    print("SPOTIFY CATEGORY FLOW: No valid track found from Spotify after trying all playlists, falling back to Cyanite")
                    self.fetchCyaniteRecommendations(
                        spotifyTrackId: trackId,
                        addToQueue: true,
                        bpmRange: bpmRange,
                        targetGenres: targetGenres
                    )
                }
            }
        } else {
            // Log that we skipped because of missing genres for THIS specific strategy
            let event = RecommendationEvent(
                zone: zone,
                bpm: hr,
                genres: [],
                status: "skipped: no genres selected for \(strategy)"
            )
            recommendationLogs.append(event)
            lastRecommendationAttempt = Date() // Mark attempt even if skipped to maintain cooldown
        }
    }
    
    // Spotify generates candidates, Cyanite scores them
    private func fetchRankedRecommendations(currentTrack: SpotifyTrack, targetGenres: [String], bpmRange: (start: Int, end: Int), strategy: String) {
        print("Correct Architecture: Spotify (generates) + Cyanite (scores)")
        print("SEED TRACK (recommending from): '\(currentTrack.name)' by \(currentTrack.artistNames)")
        
        let trackId = currentTrack.uri.replacingOccurrences(of: "spotify:track:", with: "")
        self.recommendationRetryCount[trackId] = 0
        
        // Build trusted pool from Spotify (recently played + top tracks)
        loadFamiliarityData { [weak self] in
            guard let self = self else { return }
            
            // Build seed tracks from trusted pool
            var seedTrackIds: [String] = [trackId] // Current track as primary seed
            
            // Add familiar tracks as seeds (up to 4 more)
            let familiarIds = Array(self.familiarTrackIds).prefix(4)
            seedTrackIds.append(contentsOf: familiarIds)
            
            // Ensure we have at least 5 seeds (Spotify requirement)
            while seedTrackIds.count < 5 {
                seedTrackIds.append(trackId)
            }
            let seeds = Array(seedTrackIds.prefix(5))
            
            print("Using seed tracks: \(seeds.count) tracks from trusted pool")
            
            // Generate candidate pool from Spotify (100 tracks - this is the 90% pool)
            // Use genre seeds to ensure tracks match requested genres
            print("Requesting Spotify candidates with genres: \(targetGenres.joined(separator: ", "))")
            self.generateSpotifyCandidatePool(
                seedTrackIds: seeds,
                targetGenres: targetGenres,
                limit: 100
            ) { spotifyCandidates in
                guard !spotifyCandidates.isEmpty else {
                    print("No Spotify candidates generated")
                    self.updateLogStatus("error: no Spotify candidates")
                    return
                }
                
                print("Generated \(spotifyCandidates.count) candidates from Spotify (trusted pool)")
                print("SPOTIFY CANDIDATE POOL:")
                for (index, track) in spotifyCandidates.prefix(10).enumerated() {
                    print("   \(index + 1). '\(track.name)' by \(track.artistNames)")
                }
                if spotifyCandidates.count > 10 {
                    print("   ... and \(spotifyCandidates.count - 10) more")
                }
                
                // Use Cyanite to SCORE Spotify candidates (not generate new ones)
                let candidateIds = spotifyCandidates.map { $0.uri.replacingOccurrences(of: "spotify:track:", with: "") }
                self.scoreCandidatesWithCyanite(
                    candidateTrackIds: candidateIds,
                    seedTrackId: trackId,
                    bpmRange: bpmRange
                ) { scoredCandidates in
                    guard !scoredCandidates.isEmpty else {
                        // Fallback: use Spotify candidates without Cyanite scoring
                        print("Cyanite scoring failed, using Spotify ranking")
                        let filtered = spotifyCandidates.filter { track in
                            !self.isTrackDuplicate(trackName: track.name, artistNames: track.artistNames)
                        }
                        if let selected = filtered.first {
                            self.selectAndQueueTrack(selected, seedTrackId: trackId)
                        }
                        return
                    }
                    
                    // Split into 90% familiar and 10% discovery
                    let (familiarPool, discoveryPool) = self.splitCandidates(scoredCandidates)
                    
                    print("Split: \(familiarPool.count) familiar, \(discoveryPool.count) discovery candidates")
                    
                    // Select from appropriate pool (90% familiar, 10% discovery)
                    let useFamiliar = Int.random(in: 1...100) <= 90
                    let selectedPool = useFamiliar && !familiarPool.isEmpty ? familiarPool : discoveryPool
                    
                    guard !selectedPool.isEmpty else {
                        // Fallback to other pool if selected is empty
                        let fallbackPool = useFamiliar ? discoveryPool : familiarPool
                        if let selected = fallbackPool.first {
                            self.selectAndQueueTrack(selected.track, seedTrackId: trackId)
                        }
                        return
                    }
                    
                    // Filter duplicates and select top-scored track
                    let filtered = selectedPool.filter { candidate in
                        !self.isTrackDuplicate(trackName: candidate.track.name, artistNames: candidate.track.artistNames)
                    }
                    
                    guard !filtered.isEmpty else {
                        print("All candidates were duplicates, retrying...")
                        let currentRetries = self.recommendationRetryCount[trackId] ?? 0
                        if currentRetries < 3 {
                            self.recommendationRetryCount[trackId] = currentRetries + 1
                            self.fetchRankedRecommendations(
                                currentTrack: currentTrack,
                                targetGenres: targetGenres,
                                bpmRange: bpmRange,
                                strategy: strategy
                            )
                        } else {
                            self.updateLogStatus("error: all candidates duplicates after retries")
                        }
                        return
                    }
                    
                    // Select highest-scored track from filtered pool
                    let sorted = filtered.sorted { $0.cyaniteScore > $1.cyaniteScore }
                    if let selected = sorted.first {
                        print("Selected \(useFamiliar ? "familiar" : "discovery") track: '\(selected.track.name)' (Cyanite score: \(String(format: "%.2f", selected.cyaniteScore)))")
                        self.selectAndQueueTrack(selected.track, seedTrackId: trackId)
                    }
                }
            }
        }
    }
    
    // Generate candidate pool using Spotify Recommendations API (trusted pool)
    private func generateSpotifyCandidatePool(seedTrackIds: [String], targetGenres: [String], limit: Int, completion: @escaping ([SpotifyTrack]) -> Void) {
        guard let token = accessToken, !seedTrackIds.isEmpty else { completion([]); return }
        
        let seeds = Array(seedTrackIds.prefix(5))
        let seedTracksString = seeds.joined(separator: ",")
        
        // Validate and map genres to Spotify's genre seeds
        let validatedGenres = targetGenres.compactMap { genre -> String? in
            let lower = genre.lowercased().trimmingCharacters(in: .whitespaces)
            let normalized = lower.replacingOccurrences(of: " ", with: "-")
            
            // Genre mapping to Spotify's seed genres
            let genreMap: [String: String] = [
                // Electronic/Dance
                "electronic": "electronic",
                "electronicdance": "electronic",
                "edm": "edm",
                "house": "house",
                "techno": "techno",
                "trance": "trance",
                "dubstep": "dubstep",
                "drum-and-bass": "drum-and-bass",
                "deep-house": "deep-house",
                "progressive-house": "progressive-house",
                "tech-house": "house",
                "hardstyle": "hardstyle",
                
                // Rock/Metal
                "rock": "rock",
                "alt-rock": "alt-rock",
                "indie-rock": "indie-rock",
                "hard-rock": "hard-rock",
                "metal": "metal",
                "heavy-metal": "heavy-metal",
                "punk": "punk",
                "punk-rock": "punk-rock",
                "metalcore": "metalcore",
                "hardcore": "hardcore",
                
                // Pop
                "pop": "pop",
                "indie-pop": "indie-pop",
                "dance-pop": "pop",
                "synth-pop": "synth-pop",
                
                // Hip Hop/Rap
                "hiphop": "hip-hop",
                "hip-hop": "hip-hop",
                "rap": "hip-hop",
                "trap": "hip-hop",
                
                // R&B/Soul
                "rnb": "r-n-b",
                "r&b": "r-n-b",
                "r-n-b": "r-n-b",
                "soul": "soul",
                
                // Other
                "jazz": "jazz",
                "blues": "blues",
                "classical": "classical",
                "reggae": "reggae",
                "folk": "folk",
                "country": "country",
                "funk": "funk",
                "disco": "disco",
                "latin": "latin",
                "reggaeton": "reggaeton"
            ]
            
            // Check direct mapping first
            if let mapped = genreMap[normalized] {
                return Genres.recommendationSeeds.contains(mapped) ? mapped : nil
            }
            
            // Check if it's already a valid Spotify seed
            if Genres.recommendationSeeds.contains(normalized) {
                return normalized
            }
            
            // Try partial matching (e.g., "electronic dance" -> "electronic")
            for (key, value) in genreMap {
                if normalized.contains(key) || key.contains(normalized) {
                    return Genres.recommendationSeeds.contains(value) ? value : nil
                }
            }
            
            return nil
        }
        
        print("Target genres: \(targetGenres.joined(separator: ", "))")
        print("Validated Spotify genres: \(validatedGenres.joined(separator: ", "))")
        
        // Try with full parameters first, then fallback if needed
        self.makeSpotifyRecommendationsRequest(
            seedTrackIds: seeds,
            validatedGenres: validatedGenres,
            limit: limit,
            useGenres: true,
            targetPopularity: 50,
            retryAttempt: 0,
            completion: completion
        )
    }
    
    // Make Spotify recommendations request with retry fallbacks
    private func makeSpotifyRecommendationsRequest(
        seedTrackIds: [String],
        validatedGenres: [String],
        limit: Int,
        useGenres: Bool,
        targetPopularity: Int,
        retryAttempt: Int,
        completion: @escaping ([SpotifyTrack]) -> Void
    ) {
        guard let token = accessToken, !seedTrackIds.isEmpty else {
            completion([])
            return
        }
        
        var components = URLComponents(string: "https://api.spotify.com/v1/recommendations")!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "market", value: userMarket) // Always include market
        ]
        
        // Use target_popularity to bias toward popular songs (0-100 scale)
        queryItems.append(URLQueryItem(name: "target_popularity", value: "\(targetPopularity)"))
        
        // Spotify requires at least ONE seed (track, artist, or genre)
        let seedTracksString = seedTrackIds.joined(separator: ",")
        
        if useGenres && !validatedGenres.isEmpty {
            // Use genre seeds (up to 4 to leave room for at least 1 track seed)
            let genreSeeds = Array(validatedGenres.prefix(4))
            queryItems.append(URLQueryItem(name: "seed_genres", value: genreSeeds.joined(separator: ",")))
            print("Using genre seeds: \(genreSeeds.joined(separator: ", "))")
            
            // Always include at least one track seed (Spotify requirement + provides context)
            let trackSeeds = Array(seedTrackIds.prefix(5 - genreSeeds.count)).filter { !$0.isEmpty }
            if !trackSeeds.isEmpty {
                queryItems.append(URLQueryItem(name: "seed_tracks", value: trackSeeds.joined(separator: ",")))
                print("Also using \(trackSeeds.count) track seed(s) for context: \(trackSeeds.prefix(2).joined(separator: ", "))")
            } else if let firstSeed = seedTrackIds.first, !firstSeed.isEmpty {
                queryItems.append(URLQueryItem(name: "seed_tracks", value: firstSeed))
                print("Using primary track seed as fallback: \(firstSeed)")
            } else {
                print("No valid track seeds available - cannot make recommendations request")
                DispatchQueue.main.async { completion([]) }
                return
            }
        } else {
            // No genres: use track seeds only
            queryItems.append(URLQueryItem(name: "seed_tracks", value: seedTracksString))
            print("Using track seeds only (retry attempt \(retryAttempt))")
        }
        
        components.queryItems = queryItems
        
        guard let url = components.url else {
            print("Failed to construct Spotify API URL from components")
            completion([])
            return
        }
        
        print("Spotify Recommendations URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            
            // Check for HTTP errors first
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode != 200 {
                    print("Spotify API returned status \(httpResponse.statusCode)")
                    if let data = data, let body = String(data: data, encoding: .utf8) {
                        print("   Response body: \(body)")
                        // Try to parse error details
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let error = json["error"] as? [String: Any] {
                            print("   Error details: \(error)")
                            if let message = error["message"] as? String {
                                print("   Error message: \(message)")
                            }
                        }
                    } else {
                        print("   No response body")
                    }
                    print("   Full URL was: \(url.absoluteString)")
                    
                    // If 404, the endpoint might be deprecated - try alternative approach
                    if httpResponse.statusCode == 404 {
                        print("Recommendations endpoint returned 404 - endpoint may be deprecated")
                        print("   Attempting alternative: Using recently played and top tracks as candidates")
                        // Fallback: Use recently played + top tracks as candidates
                        self.generateCandidatesFromHistory(
                            limit: limit,
                            completion: completion
                        )
                        return
                    }
                    
                    // Retry with fallback strategies for other errors
                    if retryAttempt < 3 {
                        self.retrySpotifyRequest(
                            seedTrackIds: seedTrackIds,
                            validatedGenres: validatedGenres,
                            limit: limit,
                            useGenres: useGenres,
                            targetPopularity: targetPopularity,
                            retryAttempt: retryAttempt,
                            completion: completion
                        )
                    } else {
                        DispatchQueue.main.async { completion([]) }
                    }
                    return
                }
            }
            
            guard let data = data, error == nil else {
                print("Error fetching Spotify recommendations: \(error?.localizedDescription ?? "unknown")")
                // Retry with fallback strategies
                if retryAttempt < 3 {
                    self.retrySpotifyRequest(
                        seedTrackIds: seedTrackIds,
                        validatedGenres: validatedGenres,
                        limit: limit,
                        useGenres: useGenres,
                        targetPopularity: targetPopularity,
                        retryAttempt: retryAttempt,
                        completion: completion
                    )
                } else {
                    DispatchQueue.main.async { completion([]) }
                }
                return
            }
            
            // Check if data is empty
            if data.isEmpty {
                print("Spotify API returned empty response")
                // Retry with fallback strategies
                if retryAttempt < 3 {
                    self.retrySpotifyRequest(
                        seedTrackIds: seedTrackIds,
                        validatedGenres: validatedGenres,
                        limit: limit,
                        useGenres: useGenres,
                        targetPopularity: targetPopularity,
                        retryAttempt: retryAttempt,
                        completion: completion
                    )
                } else {
                    DispatchQueue.main.async { completion([]) }
                }
                return
            }
            
            // Check if response has tracks (before parsing)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tracks = json["tracks"] as? [[String: Any]],
               tracks.isEmpty {
                print("Spotify API returned empty tracks array")
                // Retry with fallback strategies
                if retryAttempt < 3 {
                    self.retrySpotifyRequest(
                        seedTrackIds: seedTrackIds,
                        validatedGenres: validatedGenres,
                        limit: limit,
                        useGenres: useGenres,
                        targetPopularity: targetPopularity,
                        retryAttempt: retryAttempt,
                        completion: completion
                    )
                } else {
                    DispatchQueue.main.async { completion([]) }
                }
                return
            }
            
            // Log raw response for debugging (first 500 chars)
            if let responseString = String(data: data, encoding: .utf8) {
                let preview = responseString.count > 500 ? String(responseString.prefix(500)) + "..." : responseString
                print("Spotify API raw response: \(preview)")
            }
            
            do {
                let response = try JSONDecoder().decode(SpotifyRecommendationResponse.self, from: data)
                DispatchQueue.main.async {
                    print("SPOTIFY CANDIDATES RETURNED (\(response.tracks.count) tracks):")
                    for (index, track) in response.tracks.prefix(10).enumerated() {
                        print("   \(index + 1). '\(track.name)' by \(track.artistNames)")
                    }
                    if response.tracks.count > 10 {
                        print("   ... and \(response.tracks.count - 10) more")
                    }
                    completion(response.tracks)
                }
            } catch {
                print("Error parsing Spotify recommendations: \(error)")
                // Try to parse as JSON to see what we got
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    print("   Response keys: \(json.keys.joined(separator: ", "))")
                    if let errorInfo = json["error"] as? [String: Any] {
                        print("   Spotify error: \(errorInfo)")
                    }
                } else {
                    print("   Response is not valid JSON or is empty")
                }
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }.resume()
    }
    
    // Retry logic with fallback strategies
    private func retrySpotifyRequest(
        seedTrackIds: [String],
        validatedGenres: [String],
        limit: Int,
        useGenres: Bool,
        targetPopularity: Int,
        retryAttempt: Int,
        completion: @escaping ([SpotifyTrack]) -> Void
    ) {
        let nextAttempt = retryAttempt + 1
        print("Retry attempt \(nextAttempt)/3 with fallback strategy")
        
        // Strategy 1: Try with fewer genres (if we have multiple)
        if useGenres && validatedGenres.count > 1 {
            let fewerGenres = Array(validatedGenres.prefix(1))
            print("   Strategy: Using fewer genres (\(fewerGenres.joined(separator: ", ")))")
            makeSpotifyRecommendationsRequest(
                seedTrackIds: seedTrackIds,
                validatedGenres: fewerGenres,
                limit: limit,
                useGenres: true,
                targetPopularity: targetPopularity,
                retryAttempt: nextAttempt,
                completion: completion
            )
            return
        }
        
        // Strategy 2: Try with only track seeds (no genres)
        if useGenres {
            print("   Strategy: Using only track seeds (no genres)")
            makeSpotifyRecommendationsRequest(
                seedTrackIds: seedTrackIds,
                validatedGenres: [],
                limit: limit,
                useGenres: false,
                targetPopularity: targetPopularity,
                retryAttempt: nextAttempt,
                completion: completion
            )
            return
        }
        
        // Strategy 3: Try with higher popularity target
        if targetPopularity < 70 {
            let higherPopularity = min(70, targetPopularity + 20)
            print("   Strategy: Using higher popularity target (\(higherPopularity))")
            makeSpotifyRecommendationsRequest(
                seedTrackIds: seedTrackIds,
                validatedGenres: validatedGenres,
                limit: limit,
                useGenres: false,
                targetPopularity: higherPopularity,
                retryAttempt: nextAttempt,
                completion: completion
            )
            return
        }
        
        // No more fallbacks
        print("All retry strategies exhausted")
        DispatchQueue.main.async { completion([]) }
    }
    
    // Fallback: Generate candidates from user's listening history when Recommendations API fails
    private func generateCandidatesFromHistory(
        limit: Int,
        completion: @escaping ([SpotifyTrack]) -> Void
    ) {
        print("Using listening history as candidate pool (Recommendations API unavailable)")
        
        var allCandidates: [SpotifyTrack] = []
        let group = DispatchGroup()
        
        // Fetch recently played tracks
        group.enter()
        fetchRecentlyPlayed(limit: 50) { tracks in
            allCandidates.append(contentsOf: tracks)
            group.leave()
        }
        
        // Fetch top tracks
        group.enter()
        fetchUserTopTracks(limit: 50) { tracks in
            allCandidates.append(contentsOf: tracks)
            group.leave()
        }
        
        group.notify(queue: .main) {
            // Remove duplicates and limit
            var uniqueTracks: [SpotifyTrack] = []
            var seenIds = Set<String>()
            
            for track in allCandidates {
                if !seenIds.contains(track.id) {
                    seenIds.insert(track.id)
                    uniqueTracks.append(track)
                }
            }
            
            let limited = Array(uniqueTracks.prefix(limit))
            print("Generated \(limited.count) candidates from listening history")
            completion(limited)
        }
    }
    
    // Merge candidates with explicit 90/10 ratio
    private func mergeCandidates(familiarTracks: [SpotifyTrack], discoveryTracks: [SpotifyTrack]) -> [SpotifyTrack] {
        var merged: [SpotifyTrack] = []
        
        // 90% familiar (from Spotify)
        let familiarCount = min(9, familiarTracks.count)
        merged.append(contentsOf: familiarTracks.prefix(familiarCount))
        
        // 10% discovery (from Cyanite)
        let discoveryCount = min(1, discoveryTracks.count)
        merged.append(contentsOf: discoveryTracks.prefix(discoveryCount))
        
        // Shuffle after merging
        return merged.shuffled()
    }
    
    // Scored candidate: track + Cyanite similarity score
    struct ScoredCandidate {
        let track: SpotifyTrack
        let cyaniteScore: Double
    }
    
    // Score Spotify candidates using Cyanite (Cyanite evaluates, doesn't generate)
    private func scoreCandidatesWithCyanite(candidateTrackIds: [String], seedTrackId: String, bpmRange: (start: Int, end: Int)?, completion: @escaping ([ScoredCandidate]) -> Void) {
        guard !candidateTrackIds.isEmpty else { completion([]); return }
        
        // Fetch Cyanite recommendations to see which Spotify candidates also appear there
        fetchCyaniteRecommendations(
            spotifyTrackId: seedTrackId,
            addToQueue: false,
            bpmRange: bpmRange,
            targetGenres: nil
        ) { [weak self] cyaniteIds in
            guard let self = self else { completion([]); return }
            
            // Enrich all candidates
            self.enrichTracks(trackIds: candidateTrackIds) { enrichedCandidates in
                // Score: if candidate appears in Cyanite results, give it a high score
                // Otherwise, give it a base score based on popularity
                let scored = enrichedCandidates.map { enriched -> ScoredCandidate in
                    let cyaniteScore: Double
                    if cyaniteIds.contains(enriched.id) {
                        // High score if Cyanite also recommends it (audio similarity confirmed)
                        cyaniteScore = 10.0 + (Double(enriched.popularity) / 10.0)
                    } else {
                        // Base score from popularity (Spotify's ranking)
                        cyaniteScore = Double(enriched.popularity) / 10.0
                    }
                    
                    return ScoredCandidate(track: enriched.track, cyaniteScore: cyaniteScore)
                }
                
                print("Scored \(scored.count) candidates with Cyanite")
                DispatchQueue.main.async {
                    completion(scored)
                }
            }
        }
    }
    
    // Split candidates into familiar (90%) and discovery (10%) pools
    private func splitCandidates(_ candidates: [ScoredCandidate]) -> (familiar: [ScoredCandidate], discovery: [ScoredCandidate]) {
        let familiar = candidates.filter { candidate in
            let trackId = candidate.track.uri.replacingOccurrences(of: "spotify:track:", with: "")
            let artistIds = candidate.track.artists.compactMap { $0.id ?? "" }
            return familiarTrackIds.contains(trackId) ||
                   artistIds.contains(where: { familiarArtistIds.contains($0) })
        }
        
        let discovery = candidates.filter { candidate in
            let trackId = candidate.track.uri.replacingOccurrences(of: "spotify:track:", with: "")
            let artistIds = candidate.track.artists.compactMap { $0.id ?? "" }
            return !familiarTrackIds.contains(trackId) &&
                   !artistIds.contains(where: { familiarArtistIds.contains($0) })
        }
        
        return (familiar, discovery)
    }
    
    // Select and queue a track
    private func selectAndQueueTrack(_ track: SpotifyTrack, seedTrackId: String) {
        let key = self.trackKey(name: track.name, artistNames: track.artistNames)
        self.sessionRecommendedTracks.insert(key)
        self.recommendationRetryCount.removeValue(forKey: seedTrackId)
        print("Selected track: '\(track.name)' by \(track.artistNames)")
        self.autoRecommendedURIs.insert(track.uri)
        self.addToQueue(track)
        self.logRecommendationSuccess(track: track)
    }
    
    func addToQueue(_ track: SpotifyTrack) {
        guard let token = accessToken else { return }
        var urlString = "https://api.spotify.com/v1/me/player/queue?uri=\(track.uri)"
        if let deviceId = activeDeviceId {
            urlString += "&device_id=\(deviceId)"
        }
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { _, _, _ in
            print("➕ Added to Spotify Queue: \(track.name)")
            // Refresh local queue after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.fetchQueue()
            }
        }.resume()
    }
    
    // MARK: - Playback Controls
    
    func jumpToTrack(_ track: SpotifyTrack) {
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return }
        print("⏭ Jump Illusion Initiated (\(index + 1) steps).")
        performSmartSkip(steps: index + 1)
    }

    private func performSmartSkip(steps: Int, direction: String = "next") {
        guard steps > 0 else { return }
        print("🪄 Jump Illusion Initiated (\(steps) steps, \(direction)).")
        
        self.isJumping = true
        
        // Rapid Skip Loop
        for i in 1...steps {
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(i-1) * 0.1) {
                self.performAction(endpoint: direction, method: "POST")
                
                if i == steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.isJumping = false
                        self.fetchQueue()
                    }
                }
            }
        }
    }
    

    
    func play(uri: String? = nil, positionMs: Int? = nil) {
        print("Play button pressed")
        
        // OPTION A: If session is dead, deep-link to Spotify app
        if activeDeviceId == nil {
            print("Opening Spotify app (Option A)")
            if let url = URL(string: "spotify://") {
                UIApplication.shared.open(url)
            }
            return
        }
        
        let targetURI = uri ?? pausedTrackURI ?? currentTrack?.uri
        let targetPosition = positionMs ?? pausedPositionMs
        
        guard let token = accessToken else {
            print("Play failed: No access token")
            return
        }
        
        var url = "https://api.spotify.com/v1/me/player/play"
        if let deviceId = activeDeviceId {
            url += "?device_id=\(deviceId)"
            print("Targeting device: \(deviceId)")
        }
        
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [:]
        
        if let uri = uri, uri != currentTrack?.uri {
            // Mode 2: REPLACES playback context (This clears the queue!)
            body["uris"] = [uri]
            print("New Context (Queue will be cleared): \(uri)")
            
            if let position = positionMs {
                body["position_ms"] = position
            }
        } else if let track = currentTrack, uri == track.uri || uri == nil {
            // Mode 1: RESUMES current track (Maintains queue!)
            print("⏯ Resuming current session (\(track.name))")
            if let position = targetPosition {
                body["position_ms"] = position
            }
        } else if let uri = targetURI {
            // Fallback for when currentTrack is nil but we have a URI
            body["uris"] = [uri]
            if let position = targetPosition {
                body["position_ms"] = position
            }
        }
        
        if !body.isEmpty {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            guard let self = self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            
            DispatchQueue.main.async {
                if statusCode == 204 || statusCode == 200 {
                    print("Play Successful (Status: \(statusCode))")
                    self.isPlaying = true
                    // Clear paused state
                    self.pausedTrackURI = nil
                    self.pausedPositionMs = nil
                } else {
                    print("Play Failed with status \(statusCode)")
                }
            }
        }.resume()
    }
    
    func pause() {
        print("⏸ Pause button pressed")
        // Store context before pausing for re-hydration
        pausedTrackURI = currentTrack?.uri
        pausedPositionMs = progressMs
        print("💾 Stored context: \(pausedTrackURI ?? "none") at \(pausedPositionMs ?? 0)ms")
        
        guard let token = accessToken else { 
            print("Pause failed: No access token")
            return 
        }
        var url = "https://api.spotify.com/v1/me/player/pause"
        if let deviceId = activeDeviceId {
            url += "?device_id=\(deviceId)"
            print("Targeting device: \(deviceId)")
        }
        
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        print("Sending Web API Pause Request to: \(url)")
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            if let error = error {
                print("Pause Request Error: \(error.localizedDescription)")
            }
            if let httpResponse = response as? HTTPURLResponse {
                print("Pause Response Code: \(httpResponse.statusCode)")
                if httpResponse.statusCode == 404 {
                    print("Pause failed with 404. Session likely dead.")
                    DispatchQueue.main.async {
                        self?.activeDeviceId = nil
                    }
                }
            }
            DispatchQueue.main.async {
                self?.isPlaying = false
            }
        }.resume()
        
        // Optimistic UI update
        self.isPlaying = false
    }
    func skipNext() {
        print("⏭ Skipping Next Track...")
        performAction(endpoint: "next", method: "POST")
    }
    
    func skipPrevious() {
        print("⏮ Skipping Previous Track...")
        performAction(endpoint: "previous", method: "POST")
    }
    
    func seek(to positionMs: Int) {
        guard let token = accessToken else { return }
        
        var urlString = "https://api.spotify.com/v1/me/player/seek?position_ms=\(positionMs)"
        if let deviceId = activeDeviceId {
            urlString += "&device_id=\(deviceId)"
        }
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            // Update progress immediately for responsive UI
            DispatchQueue.main.async {
                self?.progressMs = positionMs
            }
        }.resume()
    }
    
    private func performAction(endpoint: String, method: String, uri: String? = nil, positionMs: Int? = nil) {
        guard let token = accessToken else { return }
        
        // Construct URL with optional Device ID
        var urlString = "https://api.spotify.com/v1/me/player/\(endpoint)"
        if let deviceId = activeDeviceId {
            urlString += "?device_id=\(deviceId)"
        }
        
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        if uri != nil || positionMs != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = [:]
            
            if let uri = uri {
                body["uris"] = [uri]
            }
            if let positionMs = positionMs {
                body["position_ms"] = positionMs
            }
            
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.fetchQueue()
            }
        }.resume()
    }
    
    func connect() {
        guard !isConnected else { return }
        self.isLoading = true
        self.errorMessage = nil
        
        let verifier = generateCodeVerifier()
        self.codeVerifier = verifier
        
        // Force use of in-app web auth instead of redirecting to Spotify app
        startWebAuth(verifier: verifier)
    }

    func removeFromQueue(_ track: SpotifyTrack) {
        print("🚫 Blacklisting track: \(track.name)")
        // Add to blacklist so if it comes up naturally, we skip it
        bannedTrackURIs.insert(track.uri)
        
        // If the track is currently playing, trigger the Silent Skip Illusion
        if track.uri == currentTrack?.uri {
            print("🗑 Deleted current track. Triggering Silent Skip Illusion...")
            self.performSmartSkip(steps: 1)
        }
        
        // Remove locally immediately for UI responsiveness
        if let index = queue.firstIndex(where: { $0.id == track.id }) {
            self.queue.remove(at: index)
        }
    }

    private func startWebAuth(url: URL? = nil, verifier: String) {
        let finalVerifier = verifier
        let challenge = generateCodeChallenge(from: finalVerifier)
        
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: scope)
        ]
        
        guard let authURL = url ?? components.url else { return }
        
        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "cue-app") { [weak self] callbackURL, error in
            guard let self = self else { return }
            if let error = error {
                 print("Web Auth Error: \(error)")
                 DispatchQueue.main.async { self.isLoading = false }
                 return
            }
            self.handleCallbackURL(callbackURL, verifier: finalVerifier)
        }
        session.presentationContextProvider = self
        session.start()
        self.authSession = session
    }
    
    func handleCallbackURL(_ url: URL?, verifier: String? = nil) {
        guard let url = url,
              let queryItems = URLComponents(string: url.absoluteString)?.queryItems,
              let code = queryItems.first(where: { $0.name == "code" })?.value else {
            DispatchQueue.main.async {
                self.errorMessage = "No auth code found"
                self.isLoading = false
            }
            return
        }
        
        let v = verifier ?? self.codeVerifier ?? ""
        exchangeCodeForToken(code: code, verifier: v)
    }
    
    private func exchangeCodeForToken(code: String, verifier: String) {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyParameters = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ]
        
        request.httpBody = bodyParameters
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isLoading = false
                
                if let error = error {
                    self.errorMessage = "Token exchange failed: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data else {
                    self.errorMessage = "No data received from token exchange"
                    return
                }
                
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let token = json["access_token"] as? String {
                    self.accessToken = token
                    self.isConnected = true
                    
                    // Save to Keychain
                    KeychainManager.shared.save(token, for: "spotify_access_token")
                    
                    if let refresh = json["refresh_token"] as? String {
                        self.refreshToken = refresh
                        KeychainManager.shared.save(refresh, for: "spotify_refresh_token")
                    }
                    
                    if let expiresIn = json["expires_in"] as? Double {
                        let expiry = Date().addingTimeInterval(expiresIn)
                        self.tokenExpiry = expiry
                        KeychainManager.shared.save("\(expiry.timeIntervalSince1970)", for: "spotify_token_expiry")
                    }
                    
                    print("Spotify Connected Successfully")
                    self.fetchUserProfile()
                    self.fetchQueue()
                } else {
                    self.errorMessage = "Invalid response from Spotify"
                }
            }
        }.resume()
    }
    
    func refreshAccessToken() {
        guard let refresh = refreshToken else { return }
        print("Refreshing Spotify Token...")
        
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let bodyParameters = [
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID
        ]
        
        request.httpBody = bodyParameters
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)
            
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let newToken = json["access_token"] as? String {
                    
                    self.accessToken = newToken
                    KeychainManager.shared.save(newToken, for: "spotify_access_token")
                    
                    if let newRefresh = json["refresh_token"] as? String {
                        self.refreshToken = newRefresh
                        KeychainManager.shared.save(newRefresh, for: "spotify_refresh_token")
                    }
                    
                    if let expiresIn = json["expires_in"] as? Double {
                        let expiry = Date().addingTimeInterval(expiresIn)
                        self.tokenExpiry = expiry
                        KeychainManager.shared.save("\(expiry.timeIntervalSince1970)", for: "spotify_token_expiry")
                    }
                    
                    print("Spotify Token Refreshed")
                    self.fetchQueue()
                } else {
                    print("Token Refresh Failed")
                    // If refresh fails, we might need a full re-auth
                    // self.isConnected = false
                }
            }
        }.resume()
    }
    
    func logout() {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        isConnected = false
        KeychainManager.shared.delete(for: "spotify_access_token")
        KeychainManager.shared.delete(for: "spotify_refresh_token")
        KeychainManager.shared.delete(for: "spotify_token_expiry")
    }
    
    // MARK: - ASWebAuthenticationPresentationContextProviding
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared
            .connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
    
    // MARK: - Browse Categories API
    
    private var cachedCategories: [SpotifyCategory] = []
    private var categoriesCacheDate: Date?
    private let categoriesCacheTTL: TimeInterval = 3600 // 1 hour cache
    
    // Negative intent filter - banned keywords for playlist names/descriptions
    private let bannedPlaylistTokens: [String] = [
        "christmas", "holiday", "xmas", "noel", "santa",
        "🎄", "🎅", "snow", "winter",
        "halloween", "easter", "valentine",
        "love songs", "romance",
        "sleep", "chill", "ambient", "relax", "meditation", "study",
        "soundtrack", "ost",
        "kids", "family"
    ]
    
    private func isBannedPlaylist(_ playlist: SpotifySearchPlaylistItem) -> Bool {
        let name = playlist.name.lowercased()
        let description = (playlist.description ?? "").lowercased()
        let combinedText = "\(name) \(description)"
        
        return bannedPlaylistTokens.contains { token in
            combinedText.contains(token.lowercased())
        }
    }
    
    private func mapGenresToCategoryIds(_ genres: [String], availableCategories: [SpotifyCategory]) -> [String] {
        print("SPOTIFY CATEGORY FLOW: Mapping genres to category IDs using fuzzy matching")
        print("  Input genres: \(genres.joined(separator: ", "))")
        print("  Available categories: \(availableCategories.count) total")
        
        var categoryScores: [(id: String, name: String, score: Int)] = []
        
        // Known valid browse category IDs (these are the actual category identifiers Spotify uses)
        let validCategoryIds: Set<String> = [
            "dance_electronic", "edm_dance", "electronic", "house", "techno", "trance",
            "rock", "metal", "pop", "hiphop", "hip_hop", "r_n_b", "rnb",
            "jazz", "blues", "classical", "reggae", "folk", "country",
            "funk", "disco", "latin", "reggaeton", "party", "work-out", "work_out", "study"
        ]
        
        // Genre to category name/ID mapping
        let genreToCategoryMap: [String: [String]] = [
            "electronic": ["dance_electronic", "edm_dance", "electronic"],
            "edm": ["edm_dance", "dance_electronic"],
            "house": ["house"],
            "drum and bass": ["edm_dance", "dance_electronic"],
            "drum-and-bass": ["edm_dance", "dance_electronic"],
            "techno": ["edm_dance", "dance_electronic"],
            "trance": ["edm_dance", "dance_electronic"],
            "rock": ["rock"],
            "metal": ["metal"],
            "pop": ["pop"],
            "hip-hop": ["hiphop", "hip_hop"],
            "hiphop": ["hiphop", "hip_hop"],
            "r&b": ["r_n_b", "rnb"],
            "rnb": ["r_n_b", "rnb"],
            "jazz": ["jazz"],
            "blues": ["blues"],
            "classical": ["classical"],
            "reggae": ["reggae"],
            "folk": ["folk"],
            "country": ["country"],
            "funk": ["funk"],
            "disco": ["disco"],
            "latin": ["latin"],
            "reggaeton": ["reggaeton"],
            "party": ["party"],
            "workout": ["work-out", "work_out"],
            "work-out": ["work-out", "work_out"],
            "focus": ["study"],
            "study": ["study"]
        ]
        
        // First, try direct mapping from genre to known category IDs
        var directMatches: [String] = []
        for genre in genres {
            let normalized = genre.lowercased().trimmingCharacters(in: .whitespaces)
            if let categoryIds = genreToCategoryMap[normalized] {
                directMatches.append(contentsOf: categoryIds)
            }
        }
        
        // Also try matching category names and constructing IDs from them
        for genre in genres {
            let normalized = genre.lowercased().trimmingCharacters(in: .whitespaces)
            let genreWords = normalized.components(separatedBy: CharacterSet(charactersIn: " -_")).filter { !$0.isEmpty }
            
            for category in availableCategories {
                let categoryNameLower = category.name.lowercased()
                var score = 0
                
                // Exact match in category name
                if categoryNameLower == normalized {
                    score += 200
                } else if categoryNameLower.contains(normalized) || normalized.contains(categoryNameLower) {
                    score += 100
                }
                
                // Word-by-word matching
                for word in genreWords {
                    if categoryNameLower.contains(word) {
                        score += 50
                    }
                }
                
                if score > 0 {
                    // Construct category ID from name based on Spotify's actual category ID format
                    var constructedId: String
                    
                    // Map common category names to their actual Spotify browse category IDs
                    let nameToIdMap: [String: String] = [
                        "hip-hop": "hiphop",
                        "hip hop": "hiphop",
                        "r&b": "r_n_b",
                        "rnb": "r_n_b",
                        "r and b": "r_n_b",
                        "dance / electronic": "dance_electronic",
                        "dance/electronic": "dance_electronic",
                        "dance electronic": "dance_electronic",
                        "edm / dance": "edm_dance",
                        "edm/dance": "edm_dance",
                        "edm dance": "edm_dance",
                        "work-out": "work-out",
                        "work out": "work-out",
                        "workout": "work-out"
                    ]
                    
                    // Check direct name mapping first
                    if let mappedId = nameToIdMap[categoryNameLower] {
                        constructedId = mappedId
                    } else {
                        // Construct from name: lowercase, replace spaces/slashes with underscores or hyphens
                        constructedId = categoryNameLower
                            .replacingOccurrences(of: " / ", with: "_")
                            .replacingOccurrences(of: "/", with: "_")
                            .replacingOccurrences(of: " ", with: "_")
                            .replacingOccurrences(of: "-", with: "_")
                            .replacingOccurrences(of: "&", with: "_")
                            .replacingOccurrences(of: "__", with: "_")
                            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                    }
                    
                    // Only use if it matches a known valid category ID or looks like a valid format
                    if validCategoryIds.contains(constructedId) {
                        categoryScores.append((id: constructedId, name: category.name, score: score))
                    } else if constructedId.count < 30 && constructedId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
                        // Looks like a valid category ID format, try it
                        categoryScores.append((id: constructedId, name: category.name, score: score))
                    }
                }
            }
        }
        
        // Combine direct matches with fuzzy matches, prioritizing direct matches
        var finalMatches: [String] = []
        
        // Add direct matches first (highest priority)
        finalMatches.append(contentsOf: directMatches)
        
        // Add fuzzy matches sorted by score
        categoryScores.sort { $0.score > $1.score }
        for match in categoryScores {
            if !finalMatches.contains(match.id) {
                finalMatches.append(match.id)
            }
        }
        
        if !finalMatches.isEmpty {
            print("  Matched category IDs (in priority order):")
            for (index, categoryId) in finalMatches.prefix(5).enumerated() {
                if index < directMatches.count {
                    print("    \(index + 1). '\(categoryId)' (direct match)")
                } else if let match = categoryScores.first(where: { $0.id == categoryId }) {
                    print("    \(index + 1). '\(categoryId)' (from '\(match.name)', score: \(match.score))")
                }
            }
            return finalMatches
        }
        
        print("  No category matches found, using fallback")
        return ["work-out"]
    }
    
    private func fetchSpotifyCategories(forceRefresh: Bool = false, completion: @escaping ([SpotifyCategory]) -> Void) {
        // Check cache first
        if !forceRefresh,
           let cacheDate = categoriesCacheDate,
           Date().timeIntervalSince(cacheDate) < categoriesCacheTTL,
           !cachedCategories.isEmpty {
            print("SPOTIFY CATEGORY FLOW: Using cached categories (\(cachedCategories.count) categories)")
            completion(cachedCategories)
            return
        }
        
        guard let token = accessToken else {
            print("SPOTIFY CATEGORY FLOW: No access token available for fetching categories")
            completion([])
            return
        }
        
        print("SPOTIFY CATEGORY FLOW: Fetching live categories from Spotify API")
        
        var components = URLComponents(string: "https://api.spotify.com/v1/browse/categories")!
        components.queryItems = [
            URLQueryItem(name: "country", value: userMarket),
            URLQueryItem(name: "limit", value: "50")
        ]
        
        guard let url = components.url else {
            print("SPOTIFY CATEGORY FLOW: Failed to construct URL for categories")
            completion([])
            return
        }
        
        print("SPOTIFY CATEGORY FLOW: Request URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else {
                completion([])
                return
            }
            
            if let error = error {
                print("SPOTIFY CATEGORY FLOW: Error fetching categories: \(error.localizedDescription)")
                completion([])
                return
            }
            
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse else {
                print("SPOTIFY CATEGORY FLOW: No data or invalid response for categories")
                completion([])
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                print("SPOTIFY CATEGORY FLOW: HTTP error status \(httpResponse.statusCode) for categories")
                if let responseBody = String(data: data, encoding: .utf8) {
                    print("SPOTIFY CATEGORY FLOW: Response body: \(responseBody)")
                }
                completion([])
                return
            }
            
            do {
                let response = try JSONDecoder().decode(SpotifyCategoriesResponse.self, from: data)
                let categories = response.categories.items
                
                print("SPOTIFY CATEGORY FLOW: Received \(categories.count) categories from Spotify")
                print("  Sample categories:")
                for (index, category) in categories.prefix(10).enumerated() {
                    print("    \(index + 1). '\(category.name)' (ID: \(category.id))")
                }
                if categories.count > 10 {
                    print("    ... and \(categories.count - 10) more categories")
                }
                
                // Update cache
                self.cachedCategories = categories
                self.categoriesCacheDate = Date()
                
                DispatchQueue.main.async {
                    completion(categories)
                }
            } catch {
                print("SPOTIFY CATEGORY FLOW: Error parsing categories: \(error)")
                completion([])
            }
        }.resume()
    }
    
    private func fetchCategoryPlaylists(categoryId: String, completion: @escaping ([SpotifyPlaylistItem]) -> Void) {
        guard let token = accessToken else {
            print("SPOTIFY CATEGORY FLOW: No access token available")
            completion([])
            return
        }
        
        print("SPOTIFY CATEGORY FLOW: Fetching playlists for category '\(categoryId)'")
        
        var components = URLComponents(string: "https://api.spotify.com/v1/browse/categories/\(categoryId)/playlists")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "country", value: userMarket)
        ]
        
        guard let url = components.url else {
            print("SPOTIFY CATEGORY FLOW: Failed to construct URL for category playlists")
            completion([])
            return
        }
        
        print("SPOTIFY CATEGORY FLOW: Request URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("SPOTIFY CATEGORY FLOW: Error fetching playlists: \(error.localizedDescription)")
                completion([])
                return
            }
            
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse else {
                print("SPOTIFY CATEGORY FLOW: No data or invalid response")
                completion([])
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                print("SPOTIFY CATEGORY FLOW: HTTP error status \(httpResponse.statusCode) for category '\(categoryId)'")
                if let responseBody = String(data: data, encoding: .utf8) {
                    print("SPOTIFY CATEGORY FLOW: Response body: \(responseBody)")
                }
                completion([])
                return
            }
            
            do {
                let response = try JSONDecoder().decode(SpotifyCategoryPlaylistsResponse.self, from: data)
                let playlists = response.playlists.items
                print("SPOTIFY CATEGORY FLOW: Received \(playlists.count) playlists from category '\(categoryId)'")
                print("  Playlists returned:")
                for (index, playlist) in playlists.prefix(5).enumerated() {
                    print("    \(index + 1). '\(playlist.name)' (ID: \(playlist.id))")
                }
                if playlists.count > 5 {
                    print("    ... and \(playlists.count - 5) more playlists")
                }
                DispatchQueue.main.async {
                    completion(playlists)
                }
            } catch {
                print("SPOTIFY CATEGORY FLOW: Error parsing category playlists: \(error)")
                completion([])
            }
        }.resume()
    }
    
    private func fetchPlaylistTracks(playlistId: String, completion: @escaping ([SpotifyTrack]) -> Void) {
        guard let token = accessToken else {
            print("SPOTIFY CATEGORY FLOW: No access token available for playlist tracks")
            completion([])
            return
        }
        
        print("SPOTIFY CATEGORY FLOW: Fetching tracks from playlist ID '\(playlistId)'")
        
        var components = URLComponents(string: "https://api.spotify.com/v1/playlists/\(playlistId)/tracks")!
        components.queryItems = [
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "market", value: userMarket)
        ]
        
        guard let url = components.url else {
            print("SPOTIFY CATEGORY FLOW: Failed to construct URL for playlist tracks")
            completion([])
            return
        }
        
        print("SPOTIFY CATEGORY FLOW: Request URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("SPOTIFY CATEGORY FLOW: Error fetching playlist tracks: \(error.localizedDescription)")
                completion([])
                return
            }
            
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse else {
                print("SPOTIFY CATEGORY FLOW: No data or invalid response for playlist tracks")
                completion([])
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                print("SPOTIFY CATEGORY FLOW: HTTP error status \(httpResponse.statusCode) for playlist tracks")
                if let responseBody = String(data: data, encoding: .utf8) {
                    print("SPOTIFY CATEGORY FLOW: Response body: \(responseBody)")
                }
                completion([])
                return
            }
            
            do {
                let response = try JSONDecoder().decode(SpotifyPlaylistTracksResponse.self, from: data)
                let tracks = response.items.compactMap { $0.track }
                print("SPOTIFY CATEGORY FLOW: Received \(tracks.count) tracks from playlist '\(playlistId)'")
                DispatchQueue.main.async {
                    completion(tracks)
                }
            } catch {
                print("SPOTIFY CATEGORY FLOW: Error parsing playlist tracks: \(error)")
                completion([])
            }
        }.resume()
    }
    
    private func fetchTracksFromCategory(targetGenres: [String], completion: @escaping (SpotifyTrack?) -> Void) {
        print("SPOTIFY CATEGORY FLOW: Starting search-based track discovery")
        print("  Target genres: \(targetGenres.joined(separator: ", "))")
        
        // Use Search API to find playlists by genre
        searchPlaylistsByGenre(genres: targetGenres) { [weak self] playlists in
            guard let self = self, !playlists.isEmpty else {
                print("SPOTIFY CATEGORY FLOW: No playlists found via search")
                completion(nil)
                return
            }
            
            print("SPOTIFY CATEGORY FLOW: Found \(playlists.count) playlists, trying to find valid track")
            
            // Try playlists in random order until we find a valid track
            var shuffledPlaylists = playlists.shuffled()
            self.tryPlaylistsForValidTrack(playlists: shuffledPlaylists, attemptIndex: 0, completion: completion)
        }
    }
    
    private func tryPlaylistsForValidTrack(playlists: [SpotifySearchPlaylistItem], attemptIndex: Int, completion: @escaping (SpotifyTrack?) -> Void) {
        guard attemptIndex < playlists.count else {
            print("SPOTIFY CATEGORY FLOW: Exhausted all \(playlists.count) playlists, no valid track found")
            completion(nil)
            return
        }
        
        let playlist = playlists[attemptIndex]
        print("SPOTIFY CATEGORY FLOW: Attempt \(attemptIndex + 1)/\(playlists.count): Trying playlist '\(playlist.name)' (ID: \(playlist.id))")
        
        fetchPlaylistTracks(playlistId: playlist.id) { [weak self] tracks in
            guard let self = self else {
                completion(nil)
                return
            }
            
            guard !tracks.isEmpty else {
                print("SPOTIFY CATEGORY FLOW: Playlist '\(playlist.name)' returned no tracks, trying next playlist")
                self.tryPlaylistsForValidTrack(playlists: playlists, attemptIndex: attemptIndex + 1, completion: completion)
                return
            }
            
            print("SPOTIFY CATEGORY FLOW: Received \(tracks.count) tracks from playlist '\(playlist.name)'")
            print("  Sample tracks:")
            for (index, track) in tracks.prefix(3).enumerated() {
                print("    \(index + 1). '\(track.name)' by \(track.artistNames)")
            }
            
            // Filter out duplicates
            let filtered = tracks.filter { track in
                !self.isTrackDuplicate(trackName: track.name, artistNames: track.artistNames)
            }
            
            print("SPOTIFY CATEGORY FLOW: After duplicate filtering: \(filtered.count) tracks remaining")
            
            if let selected = filtered.randomElement() {
                print("SPOTIFY CATEGORY FLOW: Successfully found valid track: '\(selected.name)' by \(selected.artistNames)")
                completion(selected)
            } else {
                print("SPOTIFY CATEGORY FLOW: All tracks from playlist '\(playlist.name)' were duplicates, trying next playlist")
                self.tryPlaylistsForValidTrack(playlists: playlists, attemptIndex: attemptIndex + 1, completion: completion)
            }
        }
    }
    
    private func searchPlaylistsByGenre(genres: [String], completion: @escaping ([SpotifySearchPlaylistItem]) -> Void) {
        guard let token = accessToken else {
            print("SPOTIFY CATEGORY FLOW: No access token available for search")
            completion([])
            return
        }
        
        // Build combined keyword search query from all genres
        // Normalize genres and combine into a single search string
        let normalizedGenres = genres.map { genre in
            genre.lowercased().trimmingCharacters(in: .whitespaces)
        }
        
        // Combine all genres into a single search query
        let searchQuery = normalizedGenres.joined(separator: " ")
        
        print("SPOTIFY CATEGORY FLOW: Searching for playlists with combined genre query: '\(searchQuery)'")
        print("  Combined from genres: \(genres.joined(separator: ", "))")
        
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: searchQuery),
            URLQueryItem(name: "type", value: "playlist"),
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "market", value: userMarket)
        ]
        
        guard let url = components.url else {
            print("SPOTIFY CATEGORY FLOW: Failed to construct search URL")
            completion([])
            return
        }
        
        print("SPOTIFY CATEGORY FLOW: Search URL: \(url.absoluteString)")
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("SPOTIFY CATEGORY FLOW: Error searching playlists: \(error.localizedDescription)")
                completion([])
                return
            }
            
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse else {
                print("SPOTIFY CATEGORY FLOW: No data or invalid response from search")
                completion([])
                return
            }
            
            guard httpResponse.statusCode == 200 else {
                print("SPOTIFY CATEGORY FLOW: HTTP error status \(httpResponse.statusCode) for search")
                if let responseBody = String(data: data, encoding: .utf8) {
                    print("SPOTIFY CATEGORY FLOW: Response body: \(responseBody)")
                }
                completion([])
                return
            }
            
            do {
                let response = try JSONDecoder().decode(SpotifySearchResponse.self, from: data)
                
                // Filter out null items (Spotify returns null for deleted/restricted playlists)
                let allItems = response.playlists?.items ?? []
                let validPlaylists = allItems.compactMap { $0 }
                
                print("SPOTIFY CATEGORY FLOW: Received \(allItems.count) items from search (total: \(response.playlists?.total ?? 0))")
                print("  Valid playlists after filtering nulls: \(validPlaylists.count)")
                
                // Filter for quality: minimum 20 tracks, exclude podcasts, exclude banned content
                let qualityPlaylists = validPlaylists.filter { playlist in
                    let trackCount = playlist.tracks?.total ?? 0
                    let nameLower = playlist.name.lowercased()
                    let isPodcast = nameLower.contains("podcast") || nameLower.contains("episode")
                    let hasEnoughTracks = trackCount >= 20
                    let isBanned = self.isBannedPlaylist(playlist)
                    
                    if isBanned {
                        print("SPOTIFY CATEGORY FLOW: Filtered out banned playlist: '\(playlist.name)'")
                    }
                    
                    return hasEnoughTracks && !isPodcast && !isBanned
                }
                
                print("  Quality playlists (>=20 tracks, no podcasts, no banned content): \(qualityPlaylists.count)")
                
                if qualityPlaylists.isEmpty {
                    print("SPOTIFY CATEGORY FLOW: No quality playlists found after filtering")
                    // Fallback: try without track count requirement, but still filter banned content
                    let fallbackPlaylists = validPlaylists.filter { playlist in
                        let nameLower = playlist.name.lowercased()
                        let isPodcast = nameLower.contains("podcast") || nameLower.contains("episode")
                        let isBanned = self.isBannedPlaylist(playlist)
                        return !isPodcast && !isBanned
                    }
                    
                    if !fallbackPlaylists.isEmpty {
                        print("SPOTIFY CATEGORY FLOW: Using fallback playlists (no track count requirement, but filtered banned content): \(fallbackPlaylists.count)")
                        DispatchQueue.main.async {
                            completion(fallbackPlaylists)
                        }
                        return
                    }
                    completion([])
                    return
                }
                
                print("  Sample quality playlists:")
                for (index, playlist) in qualityPlaylists.prefix(5).enumerated() {
                    let trackCount = playlist.tracks?.total ?? 0
                    print("    \(index + 1). '\(playlist.name)' (ID: \(playlist.id), tracks: \(trackCount))")
                }
                if qualityPlaylists.count > 5 {
                    print("    ... and \(qualityPlaylists.count - 5) more playlists")
                }
                
                DispatchQueue.main.async {
                    completion(qualityPlaylists)
                }
            } catch {
                print("SPOTIFY CATEGORY FLOW: Error parsing search response: \(error)")
                if let jsonString = String(data: data, encoding: .utf8) {
                    let preview = jsonString.count > 500 ? String(jsonString.prefix(500)) + "..." : jsonString
                    print("SPOTIFY CATEGORY FLOW: Raw response preview: \(preview)")
                }
                completion([])
            }
        }.resume()
    }
    
    // MARK: - PKCE Helper Functions
    
    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
    
    private func generateCodeChallenge(from verifier: String) -> String {
        guard let data = verifier.data(using: .utf8) else { return "" }
        let hashed = SHA256.hash(data: data)
        return Data(hashed).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Models

struct RecommendationEvent: Identifiable {
    let id = UUID()
    var timestamp = Date()
    let zone: Int
    let bpm: Int
    let genres: [String]
    var status: String
    var foundTrack: String?
}

struct SpotifyQueueResponse: Codable {
    let currently_playing: SpotifyTrack?
    let queue: [SpotifyTrack]
}

struct SpotifyTrack: Codable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum
    
    var artistNames: String { artists.map { $0.name }.joined(separator: ", ") }
}

struct SpotifyArtist: Codable {
    let id: String?
    let name: String
}

struct SpotifyAlbum: Codable {
    let images: [SpotifyImage]
}

struct SpotifyImage: Codable {
    let url: String
}

struct SpotifyRecommendationResponse: Codable {
    let tracks: [SpotifyTrack]
}

struct SpotifyCategoriesResponse: Codable {
    let categories: SpotifyCategoriesList
}

struct SpotifyCategoriesList: Codable {
    let items: [SpotifyCategory]
}

struct SpotifyCategory: Codable {
    let id: String
    let name: String
}

struct SpotifyCategoryPlaylistsResponse: Codable {
    let playlists: SpotifyPlaylistsList
}

struct SpotifyPlaylistsList: Codable {
    let items: [SpotifyPlaylistItem]
}

struct SpotifyPlaylistItem: Codable {
    let id: String
    let name: String
}

struct SpotifyPlaylistTracksResponse: Codable {
    let items: [SpotifyPlaylistTrackItem]
}

struct SpotifyPlaylistTrackItem: Codable {
    let track: SpotifyTrack?
}

struct SpotifySearchResponse: Codable {
    let playlists: SpotifySearchPlaylists?
}

struct SpotifySearchPlaylists: Codable {
    let items: [SpotifySearchPlaylistItem?]
    let total: Int?
}

struct SpotifySearchPlaylistItem: Codable {
    let id: String
    let name: String
    let tracks: SpotifyPlaylistTracksInfo?
    let description: String?
}

struct SpotifyPlaylistTracksInfo: Codable {
    let total: Int?
}

// Enriched track with popularity and artist IDs for ranking
struct EnrichedTrack {
    let id: String
    let name: String
    let uri: String
    let artistNames: String
    let artistIds: [String]
    let popularity: Int
    let track: SpotifyTrack
}

// Extension for chunking arrays
extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
