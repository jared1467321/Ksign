//
//  WebViewSheet.swift
//  Asign
//
//  Created by Nagata Asami on 5/24/25.
//

import SwiftUI
import NimbleExtensions
import WebKit

struct WebViewSheet: View {
    @ObservedObject var downloadManager: IPADownloadManager
    @Environment(\.dismiss) private var dismiss

    let url: URL
    
    var body: some View {
        NavigationView {
            ZStack {
                WebViewContainer(
                    downloadManager: downloadManager,
                    url: url,
                )
                
            }
            .navigationTitle("Web Browser")
            .nbNavigationAccessoryToolbar()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }
}
