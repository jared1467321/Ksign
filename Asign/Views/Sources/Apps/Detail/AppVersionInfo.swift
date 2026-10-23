//
//  AppVersionInfo.swift
//  Feather
//
//  Created by Nagata Asami on 27/7/25.
//

import SwiftUI
import NimbleExtensions

struct AppVersionInfo: View {
    let version: String
    let date: Date?
    let description: String
    
    init(
        version: String,
        date: Date? = nil,
        description: String
    ) {
        self.version = version
        self.date = date
        self.description = description
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: "Version \(version)")
                    .font(.subheadline)
                    .nbThemeForeground(.textSecondary)
                
                Spacer()
                
                if let date {
                    Text(date.formatted(.relative(presentation: .named)))
                        .font(.subheadline)
                        .nbThemeForeground(.textSecondary)
                }
            }
            .padding(.vertical, 4)
            
            ExpandableText(text: description, lineLimit: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
} 
