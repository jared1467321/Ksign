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
	@ObservedObject private var themes = NBThemeManager.shared
	var new: ASRepository.News
	
	var body: some View {
		ZStack(alignment: .bottomLeading) {
			let placeholderView = {
				NBThemePaint(.controlFill)
			}()
			
			Group {
			if let iconURL = new.imageURL {
				LazyImage(url: iconURL) { state in
					if let image = state.image {
						image
							.resizable()
							.aspectRatio(contentMode: .fill)
							.frame(width: 250, height: 150)
							.clipped()
                            .nbThemeContentSurface()
					} else {
						placeholderView
					}
				}
			} else {
				placeholderView
			}
			
            }
            .nbThemePaintLayer(0)

			LinearGradient(
				gradient: Gradient(colors: [themes.activeColor(for: .imageScrim).color, .clear]),
				startPoint: .bottom,
				endPoint: .top
			)
			.nbThemeInspectorTarget(.imageScrim)
            .nbThemePaintLayer(1)
			.frame(height: 70)
			.frame(maxWidth: .infinity, alignment: .bottom)
			.nbThemeClipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
			
			Text(new.title)
				.font(.headline)
				.nbThemeForeground(.overlayText)
				.lineLimit(2)
				.padding()
                .nbThemePaintLayer(2)
		}
		.frame(width: 250, height: 150)
		.nbThemeBackground {
            Group {
            if let tint = new.tintColor {
                tint.nbThemeContentSurface() // Content color, never a theme role.
            } else {
                NBThemePaint(.textSecondary)
            }
            }
            .nbThemePaintLayer(-1)
        }
		.nbThemeClipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
		.nbThemeOverlay(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.nbThemeStrokeBorder(.imageBorder, lineWidth: 1)
                .nbThemePaintLayer(3)
		)
        .nbThemePaintGroup()
	}
}

