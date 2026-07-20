//
//  VariedTabbarView.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import SwiftUI

struct VariedTabbarView: View {
	init() {}
	
	var body: some View {
		// The install drawer lives here, above both tab bar variants, so it
		// survives switching tabs. It was a sheet on `LibraryView`, which meant
		// it only existed on that screen and died the moment it was dismissed.
		ZStack(alignment: .bottom) {
			if #available(iOS 18, *) {
				ExtendedTabbarView()
			} else {
				TabbarView()
			}

			InstallDrawerView()
		}
	}
}
