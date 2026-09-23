//
//  TabbarView.swift
//  feather
//
//  Created by samara on 23.03.2025.
//

import SwiftUI

struct TabbarView: View {
	var previewTab: TabEnum? = nil
	init(previewTab: TabEnum? = nil) {
		self.previewTab = previewTab
		self._selectedTab = State(initialValue: previewTab ?? .sources)
	}
	@State private var selectedTab: TabEnum = .sources

	var body: some View {
		TabView(selection: $selectedTab) {
			ForEach(TabEnum.defaultTabs, id: \.hashValue) { tab in
				TabEnum.view(for: tab)
					.tabItem {
						Label(tab.title, systemImage: tab.icon)
					}
					.tag(tab)
			}
		}
	}
}
