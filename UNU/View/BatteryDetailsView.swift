//
//  BatteryDetailsView.swift
//  unu pro
//
//  Created by Lasse Blomenkemper on 24.01.25.
//

import SwiftUI

struct BatteryDetailsView: View {
    let primaryPercent: Int
    let secondaryPercent: Int
    let cbbPercent: Int
    let auxPercent: Int
    let isCharging: Bool
    
    var body: some View {
        NavigationStack {
            List {
                Section("Main Batteries") {
                    batteryRow(title: "Primary Battery", percent: primaryPercent)
                    batteryRow(title: "Secondary Battery", percent: secondaryPercent)
                }
                
                Section("System Batteries") {
                    HStack {
                        batteryRow(title: "CBB Battery", percent: cbbPercent)
                        if isCharging {
                            Image(systemName: "bolt.fill")
                                .foregroundStyle(.yellow)
                        }
                    }
                    batteryRow(title: "Auxiliary Battery", percent: auxPercent)
                }
            }
            .navigationTitle("Battery Status")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    
    private func batteryRow(title: String, percent: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(percent)%")
                .fontWeight(.semibold)
        }
    }
}
