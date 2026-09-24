//
//  ImageRow.swift
//  Ksign
//
//  Created by Nagata Asami on 25/7/25.
//

import SwiftUI
import NimbleExtensions

struct ImageRow: View {
    let file: FileItem
    
    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    
    var body: some View {
        Group {
            if let image = loadedImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
                    .nbThemeContentSurface()
            } else if isLoading {
                ProgressView()
                    .scaleEffect(0.6)
            } else {
                Image(systemName: "photo")
                    .nbThemeForeground(.accent)
                    .font(.title2)
            }
        }
        .frame(width: 32, height: 32)
        .nbThemeBackground(.controlFill)
        .nbThemeClipShape(RoundedRectangle(cornerRadius: 4))
        .onAppear {
            loadImage()
        }
    }
    
    private func loadImage() {
        guard file.isImageFile else {
            isLoading = false
            return
        }
        
        DispatchQueue.global(qos: .userInteractive).async {
            let image = UIImage.fromFile(file.url)
            
            DispatchQueue.main.async {
                self.loadedImage = image
                self.isLoading = false
            }
        }
    }
}
