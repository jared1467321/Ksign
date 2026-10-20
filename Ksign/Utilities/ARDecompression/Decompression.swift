//
//  Decompression.swift
//  feather
//
//  Created by samara on 21.08.2024.
//  Copyright (c) 2024 Samara M (khcrysalis)
//

import Foundation
import SWCompression
import Compression

// Decode the payload directly into its private prepared tree. The compressed
// member and intermediate tar no longer need a write/read round trip on disk.
func extractDebPayload(_ data: Data, name: String, to directory: URL) throws {
    let tar: Data
    switch name {
    case "data.tar.xz": tar = try XZArchive.unarchive(data)
    case "data.tar.lzma": tar = try LZMA.decompress(data)
    case "data.tar.bz2": tar = try BZip2.decompress(data)
    case "data.tar.gz": tar = try GzipArchive.unarchive(data)
    case "data.tar": tar = data
    default: throw TweakHandlerError.unsupportedFileExtension(name)
    }
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    for entry in try TarContainer.open(container: tar) {
        let name = entry.info.name
        guard !name.hasPrefix("/"), !name.contains("\\"),
              !name.split(separator: "/").contains("..") else {
            throw TweakHandlerError.decompressionFailed("Unsafe package path: \(name)")
        }
        let destination = directory.appendingPathComponent(name)
        if entry.info.type == .directory {
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        } else if entry.info.type == .regular, let contents = entry.data {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: destination)
        }
    }
}

func extractFile(at fileURL: inout URL) throws {
	let fileExtension = fileURL.pathExtension.lowercased()
	let fileManager = FileManager.default
	
	let decompressors: [String: (Data) throws -> Data] = [
		"xz": XZArchive.unarchive,
		"lzma": LZMA.decompress,
		"bz2": BZip2.decompress,
		"gz": GzipArchive.unarchive
	]
	
	if let decompressor = decompressors[fileExtension] {
		let outputURL = fileURL.deletingPathExtension()
		try decompressor(Data(contentsOf: fileURL)).write(to: outputURL)
		fileURL = outputURL
		return
	}
	
	if fileExtension == "tar" {
		let tarData = try Data(contentsOf: fileURL)
		let tarContainer = try TarContainer.open(container: tarData)
		
		let extractionDirectory = fileURL.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
		try fileManager.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
		
		for entry in tarContainer {
			let entryPath = extractionDirectory.appendingPathComponent(entry.info.name)
			
			if entry.info.type == .directory {
				try fileManager.createDirectory(at: entryPath, withIntermediateDirectories: true)
			} else if entry.info.type == .regular, let entryData = entry.data {
				try entryData.write(to: entryPath)
			}
		}
		
		fileURL = extractionDirectory
		return
	}
	
	throw TweakHandlerError.unsupportedFileExtension(fileExtension)
}
