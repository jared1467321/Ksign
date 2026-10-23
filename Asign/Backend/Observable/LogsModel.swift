//
//  LogsModel.swift
//  Asign
//
//  Created by Nagata Asami on 8/10/25.
//


struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let message: String
}
