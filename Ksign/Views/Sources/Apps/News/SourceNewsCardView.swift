//
//  SourceNewsCardView.swift
//  Feather
//
//  Created by samara on 3.05.2025.
//

import SwiftUI
import NimbleExtensions
import AltSourceKit
import NukeUI

struct SourceNewsCardView: View {
	var new: ASRepository.News
	
	var body: some View {
		ZStack(alignment: .bottomLeading) {
			let placeholderView = {
				NBHalloween.controlFill
			}()
			
			if let iconURL = new.imageURL {
				LazyImage(url: iconURL) { state in
					if let image = state.image {
						image
							.resizable()
							.aspectRatio(contentMode: .fill)
							.frame(width: 250, height: 150)
							.clipped()
					} else {
						placeholderView
					}
				}
			} else {
				placeholderView
			}
			
			LinearGradient(
				gradient: Gradient(colors: [NBHalloween.imageScrim, .clear]),
				startPoint: .bottom,
				endPoint: .top
			)
			.frame(height: 70)
			.frame(maxWidth: .infinity, alignment: .bottom)
			.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
			
			Text(new.title)
				.font(.headline)
				.foregroundColor(NBHalloween.overlayText)
				.lineLimit(2)
				.padding()
		}
		.frame(width: 250, height: 150)
		.background(new.tintColor ?? NBHalloween.textSecondary)
		.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.strokeBorder(NBHalloween.imageBorder, lineWidth: 1)
		)
	}
}

