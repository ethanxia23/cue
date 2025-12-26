//
//  ConnectionCard.swift
//  cue
//
//  Created by Ethan Xia on 12/23/25.
//

import Foundation
import SwiftUI

struct ConnectionCard: View {
    let title: String
    let icon: String
    let color: Color
    let isConnected: Bool
    let isLoading: Bool
    var connectedText: String = "Connected"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.2))
                        .frame(width: 50, height: 50)

                    if isLoading {
                        ProgressView()
                            .progressViewStyle(
                                CircularProgressViewStyle(tint: color)
                            )
                    } else {
                        Image(systemName: isConnected ? "checkmark" : icon)
                            .font(.system(size: 24))
                            .foregroundColor(color)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(
                        isConnected
                        ? connectedText
                        : (isLoading ? "Connecting..." : "Tap to Connect")
                    )
                    .font(.caption)
                    .foregroundColor(.gray)
                }

                Spacer()

                if !isConnected && !isLoading {
                    Image(systemName: "chevron.right")
                        .foregroundColor(.gray)
                }
            }
            .padding()
            .background(Color.white.opacity(0.05))
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        isConnected ? color.opacity(0.5) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .disabled(isLoading)
    }
}

#Preview {
    ConnectionCard(
        title: "Heart Rate Monitor",
        icon: "heart.fill",
        color: .red,
        isConnected: false,
        isLoading: false,
        action: {}
    )
}
