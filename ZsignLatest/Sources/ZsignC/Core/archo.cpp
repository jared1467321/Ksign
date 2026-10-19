#include "common.h"
#include "json.h"
#include "archo.h"
#include "signing.h"
#include <openssl/evp.h>

ZArchO::ZArchO()
{
	m_pBase = NULL;
	m_uLength = 0;
	m_uCodeLength = 0;
	m_pSignBase = NULL;
	m_uSignLength = 0;
	m_pHeader = NULL;
	m_uHeaderSize = 0;
	m_uFileType = 0;
	m_bEncrypted = false;
	m_b64Bit = false;
	m_bBigEndian = false;
	m_bEnoughSpace = true;
	m_pCodeSignSegment = NULL;
	m_pLinkEditSegment = NULL;
	m_uLoadCommandsFreeSpace = 0;
	m_uExecSegLimit = 0;
}

bool ZArchO::Init(uint8_t* pBase, uint32_t uLength)
{
	if (NULL == pBase || uLength <= 0) {
		return false;
	}

	m_pBase = pBase;
	m_uLength = uLength;
	m_uCodeLength = (uLength % 16 == 0) ? uLength : uLength + 16 - (uLength % 16);
	m_pHeader = (mach_header*)m_pBase;
	if (MH_MAGIC != m_pHeader->magic && MH_CIGAM != m_pHeader->magic && MH_MAGIC_64 != m_pHeader->magic && MH_CIGAM_64 != m_pHeader->magic) {
		return false;
	}

	m_uFileType = BO(m_pHeader->filetype);
	m_b64Bit = (MH_MAGIC_64 == m_pHeader->magic || MH_CIGAM_64 == m_pHeader->magic) ? true : false;
	m_bBigEndian = (MH_CIGAM == m_pHeader->magic || MH_CIGAM_64 == m_pHeader->magic) ? true : false;
	m_uHeaderSize = m_b64Bit ? sizeof(mach_header_64) : sizeof(mach_header);

	uint8_t* pLoadCommand = m_pBase + m_uHeaderSize;
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
		load_command* plc = (load_command*)pLoadCommand;
		switch (BO(plc->cmd)) {
		case LC_SEGMENT:
		{
			segment_command* seglc = (segment_command*)pLoadCommand;
			if (0 == strcmp("__TEXT", seglc->segname)) {
				m_uExecSegLimit = seglc->vmsize;
				for (uint32_t j = 0; j < BO(seglc->nsects); j++) {
					section* sect = (section*)((pLoadCommand + sizeof(segment_command)) + sizeof(section) * j);
					if (0 == strcmp("__text", sect->sectname)) {
						if (BO(sect->offset) > (BO(m_pHeader->sizeofcmds) + m_uHeaderSize)) {
							m_uLoadCommandsFreeSpace = BO(sect->offset) - BO(m_pHeader->sizeofcmds) - m_uHeaderSize;
						}
					} else if (0 == strcmp("__info_plist", sect->sectname)) {
						m_strInfoPlist.append((const char*)m_pBase + BO(sect->offset), BO(sect->size));
					}
				}
			} else if (0 == strcmp("__LINKEDIT", seglc->segname)) {
				m_pLinkEditSegment = pLoadCommand;
			}
		}
		break;
		case LC_SEGMENT_64:
		{
			segment_command_64* seglc = (segment_command_64*)pLoadCommand;
			if (0 == strcmp("__TEXT", seglc->segname)) {
				m_uExecSegLimit = seglc->vmsize;
				for (uint32_t j = 0; j < BO(seglc->nsects); j++) {
					section_64* sect = (section_64*)((pLoadCommand + sizeof(segment_command_64)) + sizeof(section_64) * j);
					if (0 == strcmp("__text", sect->sectname)) {
						if (BO(sect->offset) > (BO(m_pHeader->sizeofcmds) + m_uHeaderSize)) {
							m_uLoadCommandsFreeSpace = BO(sect->offset) - BO(m_pHeader->sizeofcmds) - m_uHeaderSize;
						}
					} else if (0 == strcmp("__info_plist", sect->sectname)) {
						m_strInfoPlist.append((const char*)m_pBase + BO(sect->offset), BO((uint32_t)sect->size));
					}
				}
			} else if (0 == strcmp("__LINKEDIT", seglc->segname)) {
				m_pLinkEditSegment = pLoadCommand;
			}
		}
		break;
		case LC_ENCRYPTION_INFO:
		case LC_ENCRYPTION_INFO_64:
		{
			encryption_info_command* crypt_cmd = (encryption_info_command*)pLoadCommand;
			if (BO(crypt_cmd->cryptid) >= 1) {
				m_bEncrypted = true;
			}
		}
		break;
		case LC_CODE_SIGNATURE:
		{
			codesignature_command* pcslc = (codesignature_command*)pLoadCommand;
			m_pCodeSignSegment = pLoadCommand;
			m_uCodeLength = BO(pcslc->dataoff);
			m_pSignBase = m_pBase + m_uCodeLength;
			m_uSignLength = ZSign::GetCodeSignatureLength(m_pSignBase);
		}
		break;
		}

		pLoadCommand += BO(plc->cmdsize);
	}

	return true;
}

const char* ZArchO::GetArch(int cpuType, int cpuSubType)
{
	switch (cpuType) {
	case CPU_TYPE_ARM:
	{
		switch (cpuSubType) {
		case CPU_SUBTYPE_ARM_V6:
			return "armv6";
			break;
		case CPU_SUBTYPE_ARM_V7:
			return "armv7";
			break;
		case CPU_SUBTYPE_ARM_V7S:
			return "armv7s";
			break;
		case CPU_SUBTYPE_ARM_V7K:
			return "armv7k";
			break;
		case CPU_SUBTYPE_ARM_V8:
			return "armv8";
			break;
		}
	}
	break;
	case CPU_TYPE_ARM64:
	{
		switch (cpuSubType) {
		case CPU_SUBTYPE_ARM64_ALL:
			return "arm64";
			break;
		case CPU_SUBTYPE_ARM64_V8:
			return "arm64v8";
			break;
		case 2:
			return "arm64e";
			break;
		}
	}
	break;
	case CPU_TYPE_ARM64_32:
	{
		switch (cpuSubType) {
		case CPU_SUBTYPE_ARM64_ALL:
			return "arm64_32";
			break;
		case CPU_SUBTYPE_ARM64_32_V8:
			return "arm64e_32";
			break;
		}
	}
	break;
	case CPU_TYPE_X86:
	{
		return "x86_32";
	}
	break;
	case CPU_TYPE_X86_64:
	{
		return "x86_64";
	}
	break;
	}
	return "unknown";
}

const char* ZArchO::GetFileType(uint32_t uFileType)
{
	switch (uFileType) {
	case MH_OBJECT:
		return "MH_OBJECT";
		break;
	case MH_EXECUTE:
		return "MH_EXECUTE";
		break;
	case MH_FVMLIB:
		return "MH_FVMLIB";
		break;
	case MH_CORE:
		return "MH_CORE";
		break;
	case MH_PRELOAD:
		return "MH_PRELOAD";
		break;
	case MH_DYLIB:
		return "MH_DYLIB";
		break;
	case MH_DYLINKER:
		return "MH_DYLINKER";
		break;
	case MH_BUNDLE:
		return "MH_BUNDLE";
		break;
	case MH_DYLIB_STUB:
		return "MH_DYLIB_STUB";
		break;
	case MH_DSYM:
		return "MH_DSYM";
		break;
	case MH_KEXT_BUNDLE:
		return "MH_KEXT_BUNDLE";
		break;
	}
	return "MH_UNKNOWN";
}

uint32_t ZArchO::BO(uint32_t uValue)
{
	return m_bBigEndian ? LE(uValue) : uValue;
}

bool ZArchO::IsExecute()
{
	if (NULL != m_pHeader) {
		return (MH_EXECUTE == BO(m_pHeader->filetype));
	}
	return false;
}

bool ZArchO::IsSigned() const 
{
	if (NULL == m_pSignBase || m_uSignLength <= 0) {
		ZLog::PrintV("File is not signed.\n");
		return false;
	}
	
	ZLog::PrintV("File is signed.\n");
	return true;
}

void ZArchO::PrintInfo()
{
	if (NULL == m_pHeader) {
		return;
	}

	ZLog::Print("------------------------------------------------------------------\n");
	ZLog::Print(">>> MachO Info: \n");
	ZLog::PrintV("\tFileType: \t%s\n", GetFileType(BO(m_pHeader->filetype)));
	ZLog::PrintV("\tTotalSize: \t%u (%s)\n", m_uLength, ZUtil::FormatSize(m_uLength).c_str());
	ZLog::PrintV("\tPlatform: \t%u\n", m_b64Bit ? 64 : 32);
	ZLog::PrintV("\tCPUArch: \t%s\n", GetArch(BO(m_pHeader->cputype), BO(m_pHeader->cpusubtype)));
	ZLog::PrintV("\tCPUType: \t0x%x\n", BO(m_pHeader->cputype));
	ZLog::PrintV("\tCPUSubType: \t0x%x\n", BO(m_pHeader->cpusubtype));
	ZLog::PrintV("\tBigEndian: \t%d\n", m_bBigEndian);
	ZLog::PrintV("\tEncrypted: \t%d\n", m_bEncrypted);
	ZLog::PrintV("\tCommandCount: \t%d\n", BO(m_pHeader->ncmds));
	ZLog::PrintV("\tCodeLength: \t%d (%s)\n", m_uCodeLength, ZUtil::FormatSize(m_uCodeLength).c_str());
	ZLog::PrintV("\tSignLength: \t%d (%s)\n", m_uSignLength, ZUtil::FormatSize(m_uSignLength).c_str());
	ZLog::PrintV("\tSpareLength: \t%d (%s)\n", m_uLength - m_uCodeLength - m_uSignLength, ZUtil::FormatSize(m_uLength - m_uCodeLength - m_uSignLength).c_str());

	uint8_t* pLoadCommand = m_pBase + m_uHeaderSize;
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
		load_command* plc = (load_command*)pLoadCommand;
		if (LC_VERSION_MIN_IPHONEOS == BO(plc->cmd)) {
			ZLog::PrintV("\tMIN_IPHONEOS: \t0x%x\n", *((uint32_t*)(pLoadCommand + sizeof(load_command))));
		} else if (LC_RPATH == BO(plc->cmd)) {
			ZLog::PrintV("\tLC_RPATH: \t%s\n", (char*)(pLoadCommand + sizeof(load_command) + 4));
		}
		pLoadCommand += BO(plc->cmdsize);
	}

	bool bHasWeakDylib = false;
	ZLog::PrintV("\tLC_LOAD_DYLIB: \n");
	pLoadCommand = m_pBase + m_uHeaderSize;
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
		load_command* plc = (load_command*)pLoadCommand;
		if (LC_LOAD_DYLIB == BO(plc->cmd)) {
			dylib_command* dlc = (dylib_command*)pLoadCommand;
			const char* szDylib = (const char*)(pLoadCommand + BO(dlc->dylib.name.offset));
			ZLog::PrintV("\t\t\t%s\n", szDylib);
		} else if (LC_LOAD_WEAK_DYLIB == BO(plc->cmd)) {
			bHasWeakDylib = true;
		}
		pLoadCommand += BO(plc->cmdsize);
	}

	if (bHasWeakDylib) {
		ZLog::PrintV("\tLC_LOAD_WEAK_DYLIB: \n");
		pLoadCommand = m_pBase + m_uHeaderSize;
		for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
			load_command* plc = (load_command*)pLoadCommand;
			if (LC_LOAD_WEAK_DYLIB == BO(plc->cmd)) {
				dylib_command* dlc = (dylib_command*)pLoadCommand;
				const char* szDylib = (const char*)(pLoadCommand + BO(dlc->dylib.name.offset));
				ZLog::PrintV("\t\t\t%s (weak)\n", szDylib);
			}
			pLoadCommand += BO(plc->cmdsize);
		}
	}

	if (!m_strInfoPlist.empty()) {
		ZLog::Print("\n>>> Embedded Info.plist: \n");
		ZLog::PrintV("\tlength: \t%lu\n", m_strInfoPlist.size());

		string strInfoPlist = m_strInfoPlist;
		ZUtil::StringReplace(strInfoPlist, "\n", "\n\t\t\t");
		ZLog::PrintV("\tcontent: \t%s\n", strInfoPlist.c_str());

		ZSHA::PrintData1("\tSHA-1:  \t", m_strInfoPlist);
		ZSHA::PrintData256("\tSHA-256:\t", m_strInfoPlist);
	}

	if (NULL == m_pSignBase || m_uSignLength <= 0) {
		ZLog::Warn(">>> Can't find CodeSignature segment!\n");
	} else {
		ZSign::ParseCodeSignature(m_pSignBase);
	}

	ZLog::Print("------------------------------------------------------------------\n");
}

static bool BuildCodeSlotHashes(uint8_t* pCodeBase,
    uint32_t uCodeLength, bool bNeedSHA1, bool bNeedSHA256,
    string& strSHA1Slots, string& strSHA256Slots)
{
    const size_t pageSize = 4096;
    const size_t slots = ((size_t)uCodeLength + pageSize - 1) / pageSize;
    if (slots == 0 || (!bNeedSHA1 && !bNeedSHA256)) return true;
    if (bNeedSHA1) strSHA1Slots.resize(slots * 20);
    if (bNeedSHA256) strSHA256Slots.resize(slots * 32);
    const size_t workers = uCodeLength >= 512 * 1024 && slots >= 64 ? ZUtil::GetWorkerCount(slots) : 1;
    using Context = unique_ptr<EVP_MD_CTX, decltype(&EVP_MD_CTX_free)>;
    vector<Context> sha1, sha256;
    for (size_t lane = 0; lane < workers; lane++) {
        sha1.emplace_back(bNeedSHA1 ? EVP_MD_CTX_new() : NULL, EVP_MD_CTX_free);
        sha256.emplace_back(bNeedSHA256 ? EVP_MD_CTX_new() : NULL, EVP_MD_CTX_free);
        if ((bNeedSHA1 && (!sha1.back() || EVP_DigestInit_ex(sha1.back().get(), EVP_sha1(), NULL) != 1)) ||
            (bNeedSHA256 && (!sha256.back() || EVP_DigestInit_ex(sha256.back().get(), EVP_sha256(), NULL) != 1))) return false;
    }
    atomic<bool> ok(true);
    ZUtil::ParallelFor(slots, workers, [&](size_t slot, size_t lane) {
        if (!ok.load(std::memory_order_relaxed)) return;
        const size_t offset = slot * pageSize;
        const size_t length = std::min(pageSize, (size_t)uCodeLength - offset);
        auto hash = [&](EVP_MD_CTX* ctx, char* destination, unsigned int expected) {
            unsigned int written = 0;
            // A null digest reinitializes the existing implementation, retaining
            // its allocation/provider selection for every page in this lane.
            return EVP_DigestInit_ex(ctx, NULL, NULL) == 1 &&
                EVP_DigestUpdate(ctx, pCodeBase + offset, length) == 1 &&
                EVP_DigestFinal_ex(ctx, (unsigned char*)destination, &written) == 1 && written == expected;
        };
        if ((bNeedSHA1 && !hash(sha1[lane].get(), &strSHA1Slots[slot * 20], 20)) ||
            (bNeedSHA256 && !hash(sha256[lane].get(), &strSHA256Slots[slot * 32], 32))) ok.store(false, std::memory_order_relaxed);
    }, 16);
    return ok.load();
}

bool ZArchO::BuildCodeSignature(ZSignAsset* pSignAsset, 
	bool bForce, 
	const string& strBundleId, 
	const string& strInfoSHA1, 
	const string& strInfoSHA256, 
	const string& strCodeResourcesSHA1, 
	const string& strCodeResourcesSHA256, 
	string& strOutput)
{
	const auto& requirements = pSignAsset->PreparedRequirements(strBundleId);
	const auto& entitlements = pSignAsset->PreparedEntitlements(IsExecute());
	const string& strRequirementsSlot = requirements.data;
	const string& strEntitlementsSlot = entitlements.xml.data;
	const string& strDerEntitlementsSlot = entitlements.der.data;
	const string& strRequirementsSlotSHA1 = requirements.sha1;
	const string& strRequirementsSlotSHA256 = requirements.sha256;
	const string& strEntitlementsSlotSHA1 = entitlements.xml.sha1;
	const string& strEntitlementsSlotSHA256 = entitlements.xml.sha256;
	const string& strDerEntitlementsSlotSHA1 = entitlements.der.sha1;
	const string& strDerEntitlementsSlotSHA256 = entitlements.der.sha256;

	uint8_t* pCodeSlots1Data = NULL;
	uint8_t* pCodeSlots256Data = NULL;
	uint32_t uCodeSlots1DataLength = 0;
	uint32_t uCodeSlots256DataLength = 0;
	if (!bForce) {
		ZSign::GetCodeSignatureExistsCodeSlotsData(m_pSignBase, pCodeSlots1Data, uCodeSlots1DataLength, pCodeSlots256Data, uCodeSlots256DataLength);
	}

	// Build missing code-page hashes once. Dual-hash signatures now calculate
	// SHA-1 and SHA-256 in the same page pass instead of traversing the Mach-O
	// twice, and independent pages are processed by a bounded worker pool.
	const uint32_t uPageSize = 1u << 12;
	const uint32_t uCodeSlots = (m_uCodeLength + uPageSize - 1) / uPageSize;
	const uint32_t uExpectedSHA1Length = uCodeSlots * 20;
	const uint32_t uExpectedSHA256Length = uCodeSlots * 32;
	const bool bHaveSHA1Slots = !pSignAsset->m_bSHA256Only && NULL != pCodeSlots1Data && uCodeSlots1DataLength == uExpectedSHA1Length;
	const bool bHaveSHA256Slots = NULL != pCodeSlots256Data && uCodeSlots256DataLength == uExpectedSHA256Length;

	string strComputedSHA1Slots;
	string strComputedSHA256Slots;
	if (!BuildCodeSlotHashes(m_pBase,
		m_uCodeLength,
		!pSignAsset->m_bSHA256Only && !bHaveSHA1Slots,
		!bHaveSHA256Slots,
		strComputedSHA1Slots,
		strComputedSHA256Slots)) return false;

	if (!pSignAsset->m_bSHA256Only && !bHaveSHA1Slots) {
		pCodeSlots1Data = (uint8_t*)strComputedSHA1Slots.data();
		uCodeSlots1DataLength = (uint32_t)strComputedSHA1Slots.size();
	}
	if (!bHaveSHA256Slots) {
		pCodeSlots256Data = (uint8_t*)strComputedSHA256Slots.data();
		uCodeSlots256DataLength = (uint32_t)strComputedSHA256Slots.size();
	}

	uint64_t uExecSegFlags = 0;
	if (MH_EXECUTE == m_uFileType) {
		// MAIN_BINARY must be set on the main executable for any signature flavour
		// (ad-hoc, single-binary, or full CMS). Without it, codesign --verify on
		// macOS rejects the signature as "invalid".
		uExecSegFlags = CS_EXECSEG_MAIN_BINARY;
	}

	// ALLOW_UNSIGNED is a development-only flag. It must be set *only* when
	// get-task-allow is actually true (debug build), not merely present in
	// the entitlements plist. Distribution profiles include
	// <key>get-task-allow</key><false/> and must keep this flag cleared -- Apple
	// codesign never sets ALLOW_UNSIGNED for such signatures.
	if (!strEntitlementsSlot.empty()) {
		const char* pEnt = strEntitlementsSlot.data() + 8; // skip blob header
		const char* pKey = strstr(pEnt, "<key>get-task-allow</key>");
		if (NULL != pKey) {
			const char* pTrue  = strstr(pKey, "<true/>");
			const char* pFalse = strstr(pKey, "<false/>");
			if (NULL != pTrue && (NULL == pFalse || pTrue < pFalse)) {
				uExecSegFlags |= CS_EXECSEG_ALLOW_UNSIGNED;
			}
		}
	}

	string strCodeDirectorySlot;
	string strAltnateCodeDirectorySlot;
	if (!pSignAsset->m_bSHA256Only) {
		if (!ZSign::SlotBuildCodeDirectory(false,
			m_pBase,
			m_uCodeLength,
			pCodeSlots1Data,
			uCodeSlots1DataLength,
			m_uExecSegLimit,
			uExecSegFlags,
			strBundleId,
			pSignAsset->m_strTeamId,
			strInfoSHA1,
			strRequirementsSlotSHA1,
			strCodeResourcesSHA1,
			strEntitlementsSlotSHA1,
			strDerEntitlementsSlotSHA1,
			IsExecute(),
			pSignAsset->m_bAdhoc,
			strCodeDirectorySlot)) {
			ZLog::Error(">>> Build SHA1 CodeDirectory failed!\n");
			return false;
		}
	}

	if (!ZSign::SlotBuildCodeDirectory(true,
		m_pBase,
		m_uCodeLength,
		pCodeSlots256Data,
		uCodeSlots256DataLength,
		m_uExecSegLimit,
		uExecSegFlags,
		strBundleId,
		pSignAsset->m_strTeamId,
		strInfoSHA256,
		strRequirementsSlotSHA256,
		strCodeResourcesSHA256,
		strEntitlementsSlotSHA256,
		strDerEntitlementsSlotSHA256,
		IsExecute(),
		pSignAsset->m_bAdhoc,
		strAltnateCodeDirectorySlot)) {
		ZLog::Error(">>> Build SHA256 CodeDirectory failed!\n");
		return false;
	}
	if (pSignAsset->m_bSHA256Only) {
		// SHA256-based code directory is usually the alternate; however, make it the primary (and only)
		// code directory if `m_bUseSHA256Only == true`.
		strAltnateCodeDirectorySlot.swap(strCodeDirectorySlot);
	}

	string strCMSSignatureSlot;
	if (!pSignAsset->m_bAdhoc) { //adhoc remove cms signature slot
		if (!ZSign::SlotBuildCMSSignature(pSignAsset, strCodeDirectorySlot, strAltnateCodeDirectorySlot, strCMSSignatureSlot)) {
			ZLog::Error(">>> Build CMS signature failed!\n");
			return false;
		}
	}

	uint32_t uCodeDirectorySlotLength = (uint32_t)strCodeDirectorySlot.size();
	uint32_t uRequirementsSlotLength = (uint32_t)strRequirementsSlot.size();
	uint32_t uEntitlementsSlotLength = (uint32_t)strEntitlementsSlot.size();
	uint32_t uDerEntitlementsLength = (uint32_t)strDerEntitlementsSlot.size();
	uint32_t uAltnateCodeDirectorySlotLength = (uint32_t)strAltnateCodeDirectorySlot.size();
	uint32_t uCMSSignatureSlotLength = (uint32_t)strCMSSignatureSlot.size();

	uint32_t uCodeSignBlobCount = 0;
	uCodeSignBlobCount += (uCodeDirectorySlotLength > 0) ? 1 : 0;
	uCodeSignBlobCount += (uRequirementsSlotLength > 0) ? 1 : 0;
	uCodeSignBlobCount += (uEntitlementsSlotLength > 0) ? 1 : 0;
	uCodeSignBlobCount += (uDerEntitlementsLength > 0) ? 1 : 0;
	uCodeSignBlobCount += (uAltnateCodeDirectorySlotLength > 0) ? 1 : 0;
	uCodeSignBlobCount += (uCMSSignatureSlotLength > 0) ? 1 : 0;

	uint32_t uSuperBlobHeaderLength = sizeof(CS_SuperBlob) + uCodeSignBlobCount * sizeof(CS_BlobIndex);
	uint32_t uCodeSignLength = uSuperBlobHeaderLength +
		uCodeDirectorySlotLength +
		uRequirementsSlotLength +
		uEntitlementsSlotLength +
		uDerEntitlementsLength +
		uAltnateCodeDirectorySlotLength +
		uCMSSignatureSlotLength;

	vector<CS_BlobIndex> arrBlobIndexes;
	if (uCodeDirectorySlotLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_CODEDIRECTORY);
		blob.offset = BE(uSuperBlobHeaderLength);
		arrBlobIndexes.push_back(blob);
	}

	if (uRequirementsSlotLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_REQUIREMENTS);
		blob.offset = BE(uSuperBlobHeaderLength + uCodeDirectorySlotLength);
		arrBlobIndexes.push_back(blob);
	}

	if (uEntitlementsSlotLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_ENTITLEMENTS);
		blob.offset = BE(uSuperBlobHeaderLength + uCodeDirectorySlotLength + uRequirementsSlotLength);
		arrBlobIndexes.push_back(blob);
	}

	if (uDerEntitlementsLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_DER_ENTITLEMENTS);
		blob.offset = BE(uSuperBlobHeaderLength + uCodeDirectorySlotLength + uRequirementsSlotLength + uEntitlementsSlotLength);
		arrBlobIndexes.push_back(blob);
	}

	if (uAltnateCodeDirectorySlotLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_ALTERNATE_CODEDIRECTORIES);
		blob.offset = BE(uSuperBlobHeaderLength + uCodeDirectorySlotLength + uRequirementsSlotLength + uEntitlementsSlotLength + uDerEntitlementsLength);
		arrBlobIndexes.push_back(blob);
	}

	if (uCMSSignatureSlotLength > 0) {
		CS_BlobIndex blob;
		blob.type = BE((uint32_t)CSSLOT_SIGNATURESLOT);
		blob.offset = BE(uSuperBlobHeaderLength + uCodeDirectorySlotLength + uRequirementsSlotLength + uEntitlementsSlotLength + uDerEntitlementsLength + uAltnateCodeDirectorySlotLength);
		arrBlobIndexes.push_back(blob);
	}

	CS_SuperBlob superblob;
	superblob.magic = BE((uint32_t)CSMAGIC_EMBEDDED_SIGNATURE);
	superblob.length = BE(uCodeSignLength);
	superblob.count = BE(uCodeSignBlobCount);

	strOutput.clear();
	strOutput.reserve(uCodeSignLength);
	strOutput.append((const char*)&superblob, sizeof(superblob));
	for (size_t i = 0; i < arrBlobIndexes.size(); i++) {
		CS_BlobIndex& blob = arrBlobIndexes[i];
		strOutput.append((const char*)&blob, sizeof(blob));
	}
	strOutput += strCodeDirectorySlot;
	strOutput += strRequirementsSlot;
	strOutput += strEntitlementsSlot;
	strOutput += strDerEntitlementsSlot;
	strOutput += strAltnateCodeDirectorySlot;
	strOutput += strCMSSignatureSlot;

	if (ZLog::IsDebug()) {
		ZFile::WriteFile("./.zsign_debug/Requirements.slot.new", strRequirementsSlot);
		ZFile::WriteFile("./.zsign_debug/Entitlements.slot.new", strEntitlementsSlot);
		ZFile::WriteFile("./.zsign_debug/Entitlements.der.slot.new", strDerEntitlementsSlot);
		ZFile::WriteFile("./.zsign_debug/Entitlements.plist.new", strEntitlementsSlot.data() + 8, strEntitlementsSlot.size() - 8);
		ZFile::WriteFile("./.zsign_debug/CodeDirectory_SHA1.slot.new", strCodeDirectorySlot);
		ZFile::WriteFile("./.zsign_debug/CodeDirectory_SHA256.slot.new", strAltnateCodeDirectorySlot);
		ZFile::WriteFile("./.zsign_debug/CMSSignature.slot.new", strCMSSignatureSlot);
		ZFile::WriteFile("./.zsign_debug/CMSSignature.der.new", strCMSSignatureSlot.data() + 8, strCMSSignatureSlot.size() - 8);
		ZFile::WriteFile("./.zsign_debug/CodeSignature.blob.new", strOutput);
	}

	return true;
}

bool ZArchO::Sign(ZSignAsset* pSignAsset, 
					bool bForce, 
					const string& strBundleId, 
					const string& strInfoSHA1, 
					const string& strInfoSHA256, 
					const string& strCodeResourcesData)
{
	if (NULL == m_pSignBase) {
		m_bEnoughSpace = false;
		ZLog::Warn(">>> Can't find CodeSignature segment!\n");
		return false;
	}

	string strCodeResourcesSHA1;
	string strCodeResourcesSHA256;
	if (strCodeResourcesData.empty()) {
		if (!pSignAsset->m_bSHA256Only) {
			strCodeResourcesSHA1.append(20, 0);
		}
		strCodeResourcesSHA256.append(32, 0);
	} else if (pSignAsset->m_bSHA256Only) {
		ZSHA::SHA256(strCodeResourcesData, strCodeResourcesSHA256);
	} else {
		ZSHA::SHA(strCodeResourcesData, strCodeResourcesSHA1, strCodeResourcesSHA256);
	}

	string strCodeSignBlob;
	if (!BuildCodeSignature(pSignAsset, bForce, strBundleId, strInfoSHA1, strInfoSHA256, strCodeResourcesSHA1, strCodeResourcesSHA256, strCodeSignBlob)) {
		ZLog::Error(">>> Build CodeSignature failed!\n");
		return false;
	}

	int nSpaceLength = (int)m_uLength - (int)m_uCodeLength - (int)strCodeSignBlob.size();
	if (nSpaceLength < 0) {
		m_bEnoughSpace = false;
		ZLog::WarnV(">>> No enough CodeSignature space (now: %d, need: %d).\n", (int)m_uLength - (int)m_uCodeLength, (int)strCodeSignBlob.size());
		return false;
	}

	memcpy(m_pBase + m_uCodeLength, strCodeSignBlob.data(), strCodeSignBlob.size());
	//memset(m_pBase + m_uCodeLength + strCodeSignBlob.size(), 0, nSpaceLength);
	return true;
}

uint32_t ZArchO::RequiredCodeSignSpace(ZSignAsset* asset, const string& bundleId)
{
	const auto& requirements = asset->PreparedRequirements(bundleId);
	const auto& entitlements = asset->PreparedEntitlements(IsExecute());
	const uint64_t pages = ((uint64_t)m_uCodeLength + 4095) / 4096;
	// Upper bounds: seven special slots, all six blob indexes, and both CDs
	// unless SHA256-only. No page bytes are read and no CMS signature is made.
	const uint64_t cdHeader = sizeof(CS_CodeDirectory) + bundleId.size() + 1 + asset->m_strTeamId.size() + 1;
	uint64_t size = sizeof(CS_SuperBlob) + 6 * sizeof(CS_BlobIndex) +
		requirements.data.size() + entitlements.xml.data.size() + entitlements.der.data.size() + cdHeader + (pages + 7) * 32;
	if (!asset->m_bSHA256Only) size += cdHeader + (pages + 7) * 20;
	if (!asset->m_bAdhoc) {
		size_t cms = asset->CMSSignatureSizeBound();
		if (cms == 0 || cms > UINT32_MAX) return 0;
		size += cms;
	}
	return size <= UINT32_MAX - 15 ? (uint32_t)((size + 15) & ~uint64_t(15)) : 0;
}

bool ZArchO::SetCodeSignSpace(uint32_t uNewLength)
{
	if (NULL == m_pLinkEditSegment || uNewLength < m_uLength || uNewLength < m_uCodeLength) return false;
	if (NULL == m_pCodeSignSegment && m_uLoadCommandsFreeSpace < sizeof(codesignature_command)) {
		ZLog::Error(">>> Can't find free space of LoadCommands for CodeSignature!\n");
		return false;
	}
	load_command* pseglc = (load_command*)m_pLinkEditSegment;
	switch (BO(pseglc->cmd)) {
	case LC_SEGMENT:
	{
		segment_command* seglc = (segment_command*)m_pLinkEditSegment;
		seglc->vmsize = ZUtil::ByteAlign(BO(seglc->vmsize) + (uNewLength - m_uLength), 4096);
		seglc->vmsize = BO(seglc->vmsize);
		seglc->filesize = uNewLength - BO(seglc->fileoff);
		seglc->filesize = BO(seglc->filesize);
	}
	break;
	case LC_SEGMENT_64:
	{
		segment_command_64* seglc = (segment_command_64*)m_pLinkEditSegment;
		seglc->vmsize = ZUtil::ByteAlign(BO((uint32_t)seglc->vmsize) + (uNewLength - m_uLength), 4096);
		seglc->vmsize = BO((uint32_t)seglc->vmsize);
		seglc->filesize = uNewLength - BO((uint32_t)seglc->fileoff);
		seglc->filesize = BO((uint32_t)seglc->filesize);
	}
	break;
	}

	codesignature_command* pcslc = (codesignature_command*)m_pCodeSignSegment;
	if (NULL == pcslc) {
		if (m_uLoadCommandsFreeSpace < sizeof(codesignature_command)) {
			ZLog::Error(">>> Can't find free space of LoadCommands for CodeSignature!\n");
			return false;
		}

		pcslc = (codesignature_command*)(m_pBase + m_uHeaderSize + BO(m_pHeader->sizeofcmds));
		pcslc->cmd = BO(LC_CODE_SIGNATURE);
		pcslc->cmdsize = BO((uint32_t)sizeof(codesignature_command));
		pcslc->dataoff = BO(m_uCodeLength);
		m_pHeader->ncmds = BO(BO(m_pHeader->ncmds) + 1);
		m_pHeader->sizeofcmds = BO(BO(m_pHeader->sizeofcmds) + sizeof(codesignature_command));
	}
	pcslc->datasize = BO(uNewLength - m_uCodeLength);

	return true;
}

uint32_t ZArchO::ReallocCodeSignSpace(const string& strNewFile, uint32_t signatureSize)
{
	uint64_t required = (uint64_t)m_uCodeLength + signatureSize;
	if (required > UINT32_MAX) return 0;
	uint32_t uNewLength = std::max(m_uLength, (uint32_t)required);
	if (!SetCodeSignSpace(uNewLength)) return 0;
	ZFile::RemoveFile(strNewFile.c_str());

	if (!ZFile::AppendFile(strNewFile.c_str(), (const char*)m_pBase, m_uLength)) {
		return 0;
	}

	string strPadding;
	strPadding.append(uNewLength - m_uLength, 0);
	if (!ZFile::AppendFile(strNewFile.c_str(), strPadding)) {
		ZFile::RemoveFile(strNewFile.c_str());
		return 0;
	}

	return uNewLength;
}

bool ZArchO::InjectDylib(bool bWeakInject, const char* szDylibFile)
{
	if (NULL == m_pHeader) {
		return false;
	}

	uint8_t* pLoadCommand = m_pBase + m_uHeaderSize;
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
		load_command* plc = (load_command*)pLoadCommand;
		uint32_t uLoadType = BO(plc->cmd);
		if (LC_LOAD_DYLIB == uLoadType || LC_LOAD_WEAK_DYLIB == uLoadType) {
			dylib_command* dlc = (dylib_command*)pLoadCommand;
			const char* szDylib = (const char*)(pLoadCommand + BO(dlc->dylib.name.offset));
			if (0 == strcmp(szDylib, szDylibFile)) {
				if ((bWeakInject && (LC_LOAD_WEAK_DYLIB != uLoadType)) || (!bWeakInject && (LC_LOAD_DYLIB != uLoadType))) {
					dlc->cmd = BO((uint32_t)(bWeakInject ? LC_LOAD_WEAK_DYLIB : LC_LOAD_DYLIB));
					const char* oldLoadType = bWeakInject ? "LC_LOAD_DYLIB" : "LC_LOAD_WEAK_DYLIB";
					const char* newLoadType = bWeakInject ? "LC_LOAD_WEAK_DYLIB" : "LC_LOAD_DYLIB";
					ZLog::WarnV(">>>\t\t %s -> %s\n", oldLoadType, newLoadType);
				}
				return true;
			}
		}
		pLoadCommand += BO(plc->cmdsize);
	}

	uint32_t uDylibFileLength = (uint32_t)strlen(szDylibFile);
	uint32_t uDylibFilePadding = (8 - uDylibFileLength % 8);
	uint32_t uDylibCommandSize = sizeof(dylib_command) + uDylibFileLength + uDylibFilePadding;
	if (m_uLoadCommandsFreeSpace > 0 && m_uLoadCommandsFreeSpace < uDylibCommandSize) { // some bin doesn't have '__text'
		ZLog::Error(">>> Can't find free space of LoadCommands for LC_LOAD_DYLIB or LC_LOAD_WEAK_DYLIB!\n");
		return false;
	}

	//add
	dylib_command* dlc = (dylib_command*)(m_pBase + m_uHeaderSize + BO(m_pHeader->sizeofcmds));
	dlc->cmd = BO((uint32_t)(bWeakInject ? LC_LOAD_WEAK_DYLIB : LC_LOAD_DYLIB));
	dlc->cmdsize = BO(uDylibCommandSize);
	dlc->dylib.name.offset = BO((uint32_t)sizeof(dylib_command));
	dlc->dylib.timestamp = BO((uint32_t)2);
	dlc->dylib.current_version = 0;
	dlc->dylib.compatibility_version = 0;

	string strDylibFile = szDylibFile;
	strDylibFile.append(uDylibFilePadding, 0);

	uint8_t* pDylibFile = (uint8_t*)dlc + sizeof(dylib_command);
	memcpy(pDylibFile, strDylibFile.data(), strDylibFile.size());

	m_pHeader->ncmds = BO(BO(m_pHeader->ncmds) + 1);
	m_pHeader->sizeofcmds = BO(BO(m_pHeader->sizeofcmds) + uDylibCommandSize);

	return true;
}

void ZArchO::RemoveDylibs(const set<string>& setDylibs)
{
	uint8_t* pLoadCommand = m_pBase + m_uHeaderSize;
	uint32_t old_load_command_size = m_pHeader->sizeofcmds;
	uint8_t* new_load_command_data = (uint8_t*)malloc(old_load_command_size);
	if (NULL == new_load_command_data) {
		return;
	}

	memset(new_load_command_data, 0, old_load_command_size);
	uint32_t new_load_command_size = 0;
	uint32_t clear_num = 0;
	uint32_t clear_data_size = 0;
	for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
		load_command* plc = (load_command*)pLoadCommand;
		uint32_t load_command_size = BO(plc->cmdsize);
		if (LC_LOAD_DYLIB == BO(plc->cmd) || LC_LOAD_WEAK_DYLIB == BO(plc->cmd)) {
			dylib_command* dlc = (dylib_command*)pLoadCommand;
			const char* szDylib = (const char*)(pLoadCommand + BO(dlc->dylib.name.offset));
			string dylibName = szDylib;
			if (setDylibs.count(dylibName) > 0) {
				ZLog::PrintV("\t\t\t%s\tclear\n", szDylib);
				clear_num++;
				clear_data_size += load_command_size;
				pLoadCommand += BO(plc->cmdsize);
				continue;
			}
			ZLog::PrintV("\t\t\t%s\n", szDylib);
		}
		new_load_command_size += load_command_size;
		memcpy(new_load_command_data, pLoadCommand, load_command_size);
		new_load_command_data += load_command_size;
		pLoadCommand += BO(plc->cmdsize);
	}
	pLoadCommand -= m_pHeader->sizeofcmds;

	m_pHeader->ncmds = BO(BO(m_pHeader->ncmds) - clear_num);
	m_pHeader->sizeofcmds = BO(BO(m_pHeader->sizeofcmds) - clear_data_size);
	new_load_command_data -= new_load_command_size;
	memset(pLoadCommand, 0, old_load_command_size);
	memcpy(pLoadCommand, new_load_command_data, new_load_command_size);
	free(new_load_command_data);
}


std::vector<std::string> ZArchO::ListDylibs()
{
    std::vector<std::string> dylibList;
    if (NULL == m_pHeader) {
        return dylibList;
    }

    uint8_t* pLoadCommand = m_pBase + m_uHeaderSize;
    for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
        load_command* plc = (load_command*)pLoadCommand;
        const uint32_t cmd = BO(plc->cmd);
        if (LC_LOAD_DYLIB == cmd || LC_LOAD_WEAK_DYLIB == cmd ||
            LC_REEXPORT_DYLIB == cmd || LC_LOAD_UPWARD_DYLIB == cmd) {
            dylib_command* dlc = (dylib_command*)pLoadCommand;
            const uint32_t nameOffset = BO(dlc->dylib.name.offset);
            if (nameOffset < BO(plc->cmdsize)) {
                const char* dylib = (const char*)(pLoadCommand + nameOffset);
                dylibList.emplace_back(dylib);
            }
        }
        pLoadCommand += BO(plc->cmdsize);
    }
    return dylibList;
}

bool ZArchO::ChangeDylibPath(const char* oldPath, const char* newPath)
{
    if (NULL == m_pHeader || NULL == oldPath || NULL == newPath) {
        return false;
    }

    uint8_t* pLoadCommand = m_pBase + m_uHeaderSize;
    bool pathChanged = false;
    const uint32_t newPathLength = (uint32_t)strlen(newPath);

    for (uint32_t i = 0; i < BO(m_pHeader->ncmds); i++) {
        load_command* plc = (load_command*)pLoadCommand;
        const uint32_t cmd = BO(plc->cmd);
        if (LC_LOAD_DYLIB == cmd || LC_LOAD_WEAK_DYLIB == cmd ||
            LC_REEXPORT_DYLIB == cmd || LC_LOAD_UPWARD_DYLIB == cmd) {
            dylib_command* dlc = (dylib_command*)pLoadCommand;
            const uint32_t commandSize = BO(plc->cmdsize);
            const uint32_t nameOffset = BO(dlc->dylib.name.offset);
            if (nameOffset < commandSize) {
                char* currentPath = (char*)(pLoadCommand + nameOffset);
                if (0 == strcmp(currentPath, oldPath)) {
                    const uint32_t available = commandSize - nameOffset;
                    if (newPathLength + 1 > available) {
                        ZLog::Error(">>> Insufficient space to update dylib path!\n");
                        return false;
                    }
                    memset(currentPath, 0, available);
                    memcpy(currentPath, newPath, newPathLength);
                    ZLog::PrintV(">>> Dylib Path Changed: %s -> %s\n", oldPath, newPath);
                    pathChanged = true;
                }
            }
        }
        pLoadCommand += BO(plc->cmdsize);
    }

    if (!pathChanged) {
        ZLog::PrintV(">>> Old Dylib Path Not Found: %s\n", oldPath);
    }
    return pathChanged;
}
