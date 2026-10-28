//
//  LogsModel.swift
//  Asign
//
//  Created by Nagata Asami on 8/10/25.
//

import Foundation

struct LogEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let message: String
}
