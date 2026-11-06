//
//  Storage+Certificate.swift
//  Feather
//
//  Created by samara on 16.04.2025.
//

import CoreData
import UIKit.UIImpactFeedbackGenerator
import Zsign

// MARK: - Class extension: certificate
extension Storage {
	func addCertificate(
		uuid: String,
		password: String? = nil,
		nickname: String? = nil,
		ppq: Bool = false,
		expiration: Date,
		completion: @escaping (Error?) -> Void
	) {
		insertLibraryRecord({ worker in
			let new = CertificatePair(context: worker)
			new.uuid = uuid
			new.date = Date()
			new.password = password
			new.ppQCheck = ppq
			new.expiration = expiration
			new.nickname = nickname
			
			return new
		}, completion: completion)
	}
    
    func revokagedCertificate(for cert: CertificatePair) {
        guard !cert.revoked else { return }
		print("Checking revokage for \(cert.nickname ?? "Unknown")")
        Zsign.checkRevokage(
            provisionPath: Storage.shared.getFile(.provision, from: cert)?.path ?? "",
            p12Path: Storage.shared.getFile(.certificate, from: cert)?.path ?? "",
            p12Password: cert.password ?? ""
        ) { (status, _, _) in
            if status == 1 {
                DispatchQueue.main.async {
                    cert.revoked = true
                    Storage.shared.saveContext()
                }
            }
        }
    }
    
    @MainActor
    func getProvisionFileDecoded(for cert: CertificatePair) async -> Certificate? {
        // A profile may be stored as a Core Data blob. Fault and decode it on
        // a private context too; no managed objects cross between queues.
        let id = cert.objectID
        guard !id.isTemporaryID else { return nil }
        let worker = container.newBackgroundContext()
        return await worker.perform {
            guard let pair = try? worker.existingObject(with: id) as? CertificatePair else { return nil }
            let embedded = pair.provisionData
            if let embedded, !embedded.isEmpty { return CertificateReader.parseData(embedded) }
            guard let uuid = pair.uuid else { return nil }
            let directory = FileManager.default.certificates(uuid)
            let url = FileManager.default.getPath(in: directory, for: FileRequest.provision.rawValue)
            return CertificateReader(url).decoded
        }
    }
    
	func deleteCertificate(for cert: CertificatePair) {
		let uuid = cert.p12Data == nil && cert.provisionData == nil ? cert.uuid : nil
		Task { @MainActor in
			do {
				if let uuid {
					try await BackgroundFileWork.perform {
						try FileManager.default.removeItem(at: FileManager.default.certificates(uuid))
					}
				}
				context.delete(cert)
				saveContext()
			} catch { print(error) }
		}
	}
		
	enum FileRequest: String {
		case certificate = "p12"
		case provision = "mobileprovision"
	}
	
	func getFile(_ type: FileRequest, from cert: CertificatePair) -> URL? {
		guard let url = getUuidDirectory(for: cert) else {
			return nil
		}
		
		return FileManager.default.getPath(in: url, for: type.rawValue)
	}
	
	func getUuidDirectory(for cert: CertificatePair) -> URL? {
		guard let uuid = cert.uuid else {
			return nil
		}
		
		return FileManager.default.certificates(uuid)
	}
}
