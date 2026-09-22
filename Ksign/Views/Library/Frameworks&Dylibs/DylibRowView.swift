//
//  DylibRowView.swift
//  Ksign
//
//  Created by Nagata Asami on 14/8/25.
//

import SwiftUI
import NimbleExtensions

struct DylibRowView: View {
    let fileURL: URL
    let isSelected: Bool
    let toggleSelection: () -> Void
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: fileURL.pathExtension.lowercased() == "framework" ? "shippingbox" : "doc.circle")
                .foregroundColor(NBHalloween.accent)
                .frame(width: 32, height: 32)
            
            VStack(alignment: .leading) {
                Text(fileURL.lastPathComponent)
                    .font(.body)
                
                Text(fileURL.pathExtension.uppercased())
                    .font(.caption)
                    .foregroundColor(NBHalloween.textSecondary)
            }
            
            Spacer()
            
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundColor(NBHalloween.accent)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            toggleSelection()
        }
    }
}
