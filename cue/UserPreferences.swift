//
//  UserPreferences.swift
//  cue
//
//  Created by Antigravity on 12/25/25.
//

import Foundation
import SwiftUI

class UserPreferences: ObservableObject {
    static let shared = UserPreferences()
    
    @Published var maxHeartRate: Int {
        didSet { UserDefaults.standard.set(maxHeartRate, forKey: "maxHeartRate") }
    }
    
    @Published var steadyStateGenres: [String] {
        didSet { UserDefaults.standard.set(steadyStateGenres, forKey: "steadyStateGenres") }
    }
    
    @Published var thresholdGenres: [String] {
        didSet { UserDefaults.standard.set(thresholdGenres, forKey: "thresholdGenres") }
    }
    
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    
    @Published var isAutoRecommendationEnabled: Bool {
        didSet { UserDefaults.standard.set(isAutoRecommendationEnabled, forKey: "isAutoRecommendationEnabled") }
    }
    
    private init() {
        self.maxHeartRate = UserDefaults.standard.integer(forKey: "maxHeartRate") == 0 ? 190 : UserDefaults.standard.integer(forKey: "maxHeartRate")
        self.steadyStateGenres = UserDefaults.standard.stringArray(forKey: "steadyStateGenres") ?? []
        self.thresholdGenres = UserDefaults.standard.stringArray(forKey: "thresholdGenres") ?? []
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        self.isAutoRecommendationEnabled = UserDefaults.standard.bool(forKey: "isAutoRecommendationEnabled")
    }
    
    // Zone calculations
    func zoneFor(bpm: Int) -> Int {
        let percent = Double(bpm) / Double(maxHeartRate)
        if percent < 0.5 { return 0 }
        if percent < 0.6 { return 1 }
        if percent < 0.7 { return 2 }
        if percent < 0.8 { return 3 }
        if percent < 0.9 { return 4 }
        return 5
    }
    
    func reset() {
        maxHeartRate = 190
        steadyStateGenres = []
        thresholdGenres = []
        hasCompletedOnboarding = false
    }
}
