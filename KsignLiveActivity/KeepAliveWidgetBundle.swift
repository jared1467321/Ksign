//
//  KeepAliveWidgetBundle.swift
//  KsignLiveActivity
//

import SwiftUI
import WidgetKit

// The extension's entry point. Only the Live Activity lives in here — there is
// no Home Screen widget, and adding one later means adding it to this bundle.
@main
struct KeepAliveWidgetBundle: WidgetBundle {
	var body: some Widget {
		KeepAliveLiveActivity()
	}
}
