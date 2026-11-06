//
//  TextEditorView.swift
//  Asign
//
//  Created by Nagata Asami on 10/10/25.
//

import SwiftUI
import NimbleExtensions

struct TextEditorView: View {
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    @State private var _text: String = ""
    @State private var _savedText: String = ""
    @State private var _isChanged: Bool = false
    @State private var _isLoading = true
    @State private var _isSaving = false
    @State private var _error: String?
    var body: some View {
        NavigationStack {
            TextEditor(text: $_text)
                .nbThemeCanvas()
                .nbThemeForeground(.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .font(.system(size: 12, design: .monospaced))
                .disabled(_isLoading)
                .navigationTitle(fileURL.lastPathComponent).navigationBarTitleDisplayMode(.inline)
                .toolbar { 
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Save")) { _saveFile() }
                            .disabled(!_isChanged || _isLoading || _isSaving)
                    }
                }
        }
        .task(id: fileURL) { await _loadFile() }
        .onChange(of: _text) { _ in
            _isChanged = _text != _savedText
        }
        .alert("Error", isPresented: Binding(get: { _error != nil }, set: { if !$0 { _error = nil } })) {
            Button("OK", role: .cancel) { _error = nil }
        } message: { Text(_error ?? "") }
    }

    @MainActor private func _loadFile() async {
        _isLoading = true
        _isChanged = false
        defer { _isLoading = false }
        let url = fileURL
        do {
            let contents = try await BackgroundFileWork.perform { try String(contentsOf: url, encoding: .utf8) }
            guard !Task.isCancelled else { return }
            _text = contents
            _savedText = contents
        } catch {
            if !Task.isCancelled { _error = error.localizedDescription }
        }
    }

    private func _saveFile() {
        guard !_isSaving else { return }
        _isSaving = true
        let text = _text
        let url = fileURL
        Task { @MainActor in
            defer { _isSaving = false }
            do {
                try await BackgroundFileWork.perform { try text.write(to: url, atomically: true, encoding: .utf8) }
                _savedText = text
                _isChanged = _text != text
            } catch { _error = error.localizedDescription }
        }
    }
}

