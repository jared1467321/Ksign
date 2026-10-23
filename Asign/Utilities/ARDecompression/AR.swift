//
//  SwiftAR.swift
//  SwiftAR
//
//  Created by nekohaxx on 8/18/24.
//

import Foundation

class AR: NSObject {
	private var _data: Data
	
	init(with url: URL) throws {
		self._data = try Data(contentsOf: url, options: .mappedIfSafe)
		super.init()
	}
	
	func extract() async throws -> [ARFileModel] {
		if _data.prefix(8) != Data([0x21, 0x3c, 0x61, 0x72, 0x63, 0x68, 0x3e, 0x0a]) {
			throw ARError.badArchive("Invalid magic")
		}
		
		// Keep the mapped archive backing instead of copying the complete deb.
		var offset = 8
		var files: [ARFileModel] = []
		while offset < _data.count {
			let fileInfo = try _getFileInfo(_data, offset)
			files.append(fileInfo)
			offset += fileInfo.size + 60
			offset += offset % 2
		}
		return files
	}
	
	private func _getFileInfo(_ data: Data, _ offset: Int) throws -> ARFileModel {
		guard offset <= data.count, data.count - offset >= 60,
              data[offset + 58] == 0x60, data[offset + 59] == 0x0a else {
            throw ARError.badArchive("Invalid member header")
        }
        guard let size = Int(_removePadding(String(data: data.subdata(in: offset+48..<offset+48+10), encoding: .ascii) ?? "")),
              size >= 0, size <= data.count - offset - 60 else {
			throw ARError.badArchive("Invalid size")
		}
		
		let name = _removePadding(String(data: data.subdata(in: offset..<offset+16), encoding: .ascii) ?? "")
		guard name != "" else {
			throw ARError.badArchive("Invalid name")
		}
		
		return ARFileModel(
			name: name,
			modificationDate: Date(timeIntervalSince1970: Double(_removePadding(String(data: data.subdata(in: offset+16..<offset+16+12), encoding: .ascii) ?? "0")) ?? 0),
			ownerId: Int(_removePadding(String(data: data.subdata(in: offset+28..<offset+28+6), encoding: .ascii) ?? "0")) ?? 0,
			groupId: Int(_removePadding(String(data: data.subdata(in: offset+34..<offset+34+6), encoding: .ascii) ?? "0")) ?? 0,
			mode: Int(_removePadding(String(data: data.subdata(in: offset+40..<offset+40+8), encoding: .ascii) ?? "0")) ?? 0,
			size: size,
			content: data.subdata(in: offset+60..<offset+60+size)
		)
	}
	
	private func _removePadding(_ paddedString: String) -> String {
		let data = paddedString.data(using: .utf8)!
		
		guard let firstNonSpaceIndex = data.firstIndex(of: UInt8(ascii: " ")) else {
			return paddedString
		}
		
		let actualData = data[..<firstNonSpaceIndex]
		return String(data: actualData, encoding: .utf8)!
	}
}

enum ARError: Error {
	case badArchive(String)
}
