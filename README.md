# Cue

Cue is an iOS application that automatically curates music recommendations based on your real-time heart rate during workouts. The app connects to heart rate monitors (Bluetooth LE devices or Apple Watch via HealthKit) and uses your current heart rate zone to intelligently queue songs from Spotify that match your workout intensity.

## Overview

The core concept is simple: different workout intensities require different types of music. When you're in a steady-state zone (zones 2-3), you might want more moderate tempo tracks. During threshold training (zones 4-5), you need high-energy music that matches your elevated heart rate. Cue automatically detects which zone you're in and queues appropriate tracks without any manual intervention.

## How It Works

### Heart Rate Monitoring

The app supports two methods of heart rate input:

1. **Bluetooth LE Devices**: Connects to standard heart rate monitors that broadcast the Heart Rate Service (UUID 180D). The app continuously scans for available devices and maintains a list of discovered monitors.

2. **Apple Watch via HealthKit**: If you have an Apple Watch, the app can read heart rate data directly from HealthKit, providing seamless integration with your existing fitness tracking.

Heart rate zones are calculated based on your maximum heart rate (configurable in settings):
- Zone 0: < 50% max HR
- Zone 1: 50-60% max HR
- Zone 2: 60-70% max HR (Steady State)
- Zone 3: 70-80% max HR (Steady State)
- Zone 4: 80-90% max HR (Threshold)
- Zone 5: 90-100% max HR (Threshold)

### Music Recommendation System

The recommendation engine uses a hybrid approach combining Spotify's APIs with Cyanite AI for audio similarity matching:

1. **Current Track Analysis**: When a track is playing, the app extracts its Spotify track ID and sends it to Cyanite AI via a Vercel proxy endpoint.

2. **Audio Similarity Matching**: Cyanite analyzes the audio characteristics of the current track and finds similar tracks based on:
   - BPM (beats per minute) matching your heart rate zone
   - Genre preferences you've configured for each zone type
   - Audio features like energy, tempo, and mood

3. **Duplicate Prevention**: The system maintains a session history to prevent recommending the same track (or variations like "Radio Edit" versions) that you've already heard in the current session.

4. **Queue Management**: Recommended tracks are automatically added to your Spotify queue, so they play seamlessly after your current track ends.

### User Preferences

During onboarding, users configure:
- Maximum heart rate (used for zone calculations)
- Genre preferences for steady-state zones (2-3)
- Genre preferences for threshold zones (4-5)

These preferences ensure that recommendations align with your musical taste while still matching your workout intensity.

## Technical Architecture

### iOS App (Swift/SwiftUI)

The app is built using SwiftUI and follows a clean architecture pattern:

- **SpotifyAuthManager**: Handles all Spotify authentication (PKCE flow), playback control, queue management, and the recommendation logic.
- **HeartRateManager**: Manages Bluetooth LE scanning, device connections, HealthKit integration, and heart rate data processing.
- **UserPreferences**: Stores user configuration (max HR, genre preferences) using UserDefaults.
- **ContentView**: Main UI split between music player (top 60%) and heart rate visualization (bottom 40%).

### Vercel Proxy (Node.js)

A serverless function deployed on Vercel acts as a secure bridge between the iOS app and Cyanite AI:

- **Security**: Keeps Cyanite API keys server-side, preventing exposure in the client app.
- **Webhook Handling**: Receives analysis completion events from Cyanite when tracks are processed.
- **GraphQL Proxy**: Forwards recommendation requests from the iOS app to Cyanite's GraphQL API with proper authentication.

### Spotify Integration

The app uses Spotify's Web API with the following scopes:
- `user-read-playback-state`: Read current track and playback status
- `user-modify-playback-state`: Control playback and manage queue
- `user-read-currently-playing`: Get currently playing track details
- `user-read-recently-played`: Access recently played tracks for familiarity tracking
- `user-top-read`: Access top tracks for building user taste profile

## Challenges and Limitations

### Spotify Recommendations API Deprecation

One of the major challenges encountered during development was Spotify's deprecation of their Recommendations API endpoint (`GET /v1/recommendations`). This endpoint was originally intended to be a core part of the recommendation system, as it could generate track suggestions based on seed tracks and genre preferences.

**Impact**: The endpoint began returning 404 errors, making it unusable for generating candidate tracks. This forced a pivot in the recommendation architecture.

**Solution**: The app now relies primarily on Cyanite AI for recommendations, using Spotify's APIs only for:
- Fetching track details
- Managing playback and queue
- Accessing recently played tracks for duplicate checking
- Building a familiarity profile from user's listening history

### Limited Access to Listening History

Another significant limitation is the inability to comprehensively scrape a user's listening history to build a more sophisticated recommendation algorithm. Spotify's API provides:
- Recently played tracks (last 50 tracks)
- Top tracks (short-term and medium-term, up to 50 each)

However, this doesn't provide:
- Full listening history
- Playlist analysis
- Long-term listening patterns
- Detailed listening frequency data

**Impact**: The recommendation system cannot build a complete picture of user preferences. It can only use a limited "familiarity pool" based on recently played and top tracks, which may not accurately represent the user's full musical taste.

**Workaround**: The app uses the available data (recently played + top tracks) to build a small familiarity set, but the recommendations are primarily driven by audio similarity via Cyanite rather than collaborative filtering based on listening patterns.

### Duplicate Detection Challenges

The app implements duplicate detection to prevent recommending the same track multiple times, but this is complicated by:

1. **Track Name Variations**: The same song may appear as "Song Name", "Song Name - Radio Edit", "Song Name (Remix)", etc. The app normalizes track names by removing common suffixes, but this isn't perfect.

2. **Session History Limitations**: The session history only tracks tracks recommended during the current app session. If the app is restarted, the history is lost, potentially allowing duplicate recommendations.

3. **Queue State**: The app checks the current Spotify queue for duplicates, but there can be a race condition where a track is added to the queue before the duplicate check completes.

## Future Improvements

Given the constraints above, potential improvements include:

1. **Enhanced Familiarity Tracking**: If Spotify ever provides more comprehensive listening history APIs, the app could build a much better user taste profile.

2. **Local History Persistence**: Store recommendation history locally (using Core Data or SQLite) to persist across app sessions and prevent duplicates even after restarts.

3. **Playlist Analysis**: If playlist read access is available, analyze user-created playlists to understand musical preferences better.

4. **Machine Learning**: Implement on-device ML models to learn from user interactions (skips, likes) and improve recommendations over time.

5. **Alternative Recommendation Sources**: Integrate with other music recommendation services or build a hybrid system that combines multiple sources.

## Development Notes

The codebase is written in Swift using SwiftUI for the UI layer. Key dependencies:
- CoreBluetooth for BLE device communication
- HealthKit for Apple Watch integration
- AuthenticationServices for Spotify OAuth
- Combine for reactive programming
- Charts (Swift Charts) for heart rate visualization

The Vercel proxy is a simple Node.js serverless function that handles the Cyanite API integration securely.

## Setup

1. Clone the repository
2. Open `cue.xcodeproj` in Xcode
3. Configure Spotify app credentials in `SpotifyAuthManager.swift`
4. Set up Vercel deployment for the `api/cyanite-webhook.js` endpoint
5. Configure Cyanite API credentials in Vercel environment variables
6. Build and run on a physical iOS device (Bluetooth requires real hardware)

## License

This project is a personal development project. All rights reserved.

