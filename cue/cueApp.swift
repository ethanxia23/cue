//
//  cueApp.swift
//  cue
//
//  Created by Ethan Xia on 12/22/25.
//

import SwiftUI

@main
struct CueApp: App {
    @StateObject var heartRateManager = HeartRateManager()
    @StateObject var spotifyAuthManager = SpotifyAuthManager()
    @StateObject var userPreferences = UserPreferences.shared
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(heartRateManager)
                .environmentObject(spotifyAuthManager)
                .environmentObject(userPreferences)
                .onOpenURL { url in
                    // Handle callback from Spotify App Switch
                    if url.scheme == "cue-app" {
                        spotifyAuthManager.handleCallbackURL(url)
                    }
                }
        }
    }
}

