#include "common.h"
#include "json.h"
#include "mach-o.h"
#include "openssl.h"
#include "signing.h"
#include "macho.h"

ZMachO::ZMachO()
{
	m_pBase = NULL;
	m_sSize = 0;
}

ZMachO::~ZMachO()
{
	Free();
}

bool ZMachO::Init(const char* szFile)
{
	m_strFile = szFile;
	return OpenFile(szFile);
}

bool ZMachO::InitV(const char* szPath, ...)
{
	FORMAT_V(szPath, szFile);
	return Init(szFile);
}

bool ZMachO::Free()
{
	FreeArchOes();
	return CloseFile();
}

bool ZMachO::NewArchO(uint8_t* pBase, uint32_t uLength)
{
	ZArchO* archo = new ZArchO();
	if (archo->Init(pBase, uLength)) {
		m_arrArchOes.push_back(archo);
		return true;
	}
	delete archo;
	return false;
}

void ZMachO::FreeArchOes()
{
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		ZArchO* archo = m_arrArchOes[i];
		delete archo;
	}
	m_arrArchOes.clear();
}

bool ZMachO::OpenFile(const char* szPath)
{
	if (!Free()) {
		return false;
	}

	m_sSize = 0;
	m_pBase = (uint8_t*)ZFile::MapFile(szPath, 0, 0, &m_sSize, false);
	if (NULL != m_pBase) {
		uint32_t magic = *((uint32_t*)m_pBase);
		if (FAT_CIGAM == magic || FAT_MAGIC == magic) {
			fat_header* pFatHeader = (fat_header*)m_pBase;
			int nFatArch = (FAT_MAGIC == magic) ? pFatHeader->nfat_arch : LE(pFatHeader->nfat_arch);
			for (int i = 0; i < nFatArch; i++) {
				fat_arch* pFatArch = (fat_arch*)(m_pBase + sizeof(fat_header) + sizeof(fat_arch) * i);
				uint8_t* pArchBase = m_pBase + ((FAT_MAGIC == magic) ? pFatArch->offset : LE(pFatArch->offset));
				uint32_t uArchLength = (FAT_MAGIC == magic) ? pFatArch->size : LE(pFatArch->size);
				if (!NewArchO(pArchBase, uArchLength)) {
					ZLog::ErrorV(">>> Invalid arch file in fat mach-o file!\n");
					return false;
				}
			}
		} else if (MH_MAGIC == magic || MH_CIGAM == magic || MH_MAGIC_64 == magic || MH_CIGAM_64 == magic) {
			if (!NewArchO(m_pBase, (uint32_t)m_sSize)) {
				ZLog::ErrorV(">>> Invalid mach-o file!\n");
				return false;
			}
		} else {
			ZLog::ErrorV(">>> Invalid mach-o file (magic: 0x%08x)!\n", magic);
			return false;
		}
	}

	return (!m_arrArchOes.empty());
}

bool ZMachO::CloseFile()
{
	if (NULL == m_pBase || m_sSize <= 0) {
		return true;
	}

	if (!ZFile::UnmapFile((void*)m_pBase, m_sSize)) {
		ZLog::ErrorV(">>> CodeSign write(munmap) failed! Error: %p, %lu, %s\n", m_pBase, m_sSize, strerror(errno));
		return false;
	}
	// Only forget the mapping after munmap succeeds. FreeArchOes must not
	// clear it first, and subsequent Free/destructor calls must be harmless.
	m_pBase = NULL;
	m_sSize = 0;
	return true;
}

void ZMachO::PrintInfo()
{
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		ZArchO* archo = m_arrArchOes[i];
		archo->PrintInfo();
	}
}

bool ZMachO::CheckSignature() const
{
	return std::all_of(m_arrArchOes.cbegin(), m_arrArchOes.cend(), 
		[](ZArchO const * archo) {
			return archo->IsSigned();
		}
	);
}

bool ZMachO::Sign(ZSignAsset* pSignAsset, bool bForce, string strBundleId, string strInfoSHA1, string strInfoSHA256, const string& strCodeResourcesData)
{
	if (NULL == pSignAsset || NULL == m_pBase || m_arrArchOes.empty()) {
		return false;
	}

	if (strBundleId.empty()) {
		jvalue info; info.read_plist(m_arrArchOes.front()->m_strInfoPlist);
		strBundleId = info["CFBundleIdentifier"].as_string();
		if (strBundleId.empty()) strBundleId = ZUtil::GetBaseName(m_strFile.c_str());
	}
	// Reserve every slice before any page hashing/signing. Growth changes load
	// commands, so pre-existing page hashes cannot be reused after resizing.
	vector<uint32_t> signatureSizes;
	bool grow = false;
	for (ZArchO* archo : m_arrArchOes) {
		uint32_t required = archo->RequiredCodeSignSpace(pSignAsset, strBundleId);
		if (required == 0 || (uint64_t)archo->m_uCodeLength + required > UINT32_MAX) return false;
		signatureSizes.push_back(required);
		grow = grow || archo->m_pCodeSignSegment == NULL ||
			(uint64_t)archo->m_uCodeLength + required > archo->m_uLength;
	}
	if (grow) {
		if (!ReallocCodeSignSpace(signatureSizes)) return false;
		bForce = true;
	}

	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		ZArchO* archo = m_arrArchOes[i];
		if (strInfoSHA1.empty() || strInfoSHA256.empty()) {
			if (archo->m_strInfoPlist.empty()) {
				strInfoSHA1.append(20, 0);
				strInfoSHA256.append(32, 0);
			} else {
				ZSHA::SHA(archo->m_strInfoPlist, strInfoSHA1, strInfoSHA256);
			}
		}

		if (!archo->Sign(pSignAsset, bForce, strBundleId, strInfoSHA1, strInfoSHA256, strCodeResourcesData)) {
			return false;
		}
	}

	return CloseFile();
}

bool ZMachO::PatchDylibs(const vector<pair<string, string>>& rewrites, const vector<string>& injections, bool weak)
{
	bool success = true;
	for (const auto& rewrite : rewrites) success = ChangeDylibPath(rewrite.first.c_str(), rewrite.second.c_str()) && success;
	for (const string& path : injections) success = InjectDylib(weak, path.c_str()) && success;
	return success;
}

bool ZMachO::ReallocCodeSignSpace(const vector<uint32_t>& signatureSizes)
{
	ZLog::Warn(">>> Realloc CodeSignature space... \n");

#ifndef _WIN32
	// Growing the signature replaces the inode. Keep the executable's mode
	// instead of inheriting the temporary file's fopen/umask permissions.
	struct stat originalStat = {};
	if (0 != stat(m_strFile.c_str(), &originalStat)) {
		return false;
	}
#endif

#ifndef _WIN32
	if (m_arrArchOes.size() == 1) {
		ZArchO* archo = m_arrArchOes[0];
		uint32_t newLength = std::max(archo->m_uLength, archo->m_uCodeLength + signatureSizes[0]);
		// A thin Mach-O can extend its inode, retaining mode, hard links and
		// framework aliases without copying the original executable.
		int fd = open(m_strFile.c_str(), O_RDWR);
		if (fd < 0) return false;
		bool ok = archo->SetCodeSignSpace(newLength) && CloseFile();
		if (ok) ok = ftruncate(fd, newLength) == 0;
		close(fd);
		return ok && OpenFile(m_strFile.c_str());
	}
#endif

	vector<uint32_t> arrMachOesSizes;
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		string strNewArchOFile;
		ZUtil::StringFormatV(strNewArchOFile, "%s.archo.%d", m_strFile.c_str(), i);
		uint32_t uNewLength = m_arrArchOes[i]->ReallocCodeSignSpace(strNewArchOFile, signatureSizes[i]);
		if (uNewLength <= 0) {
			ZLog::Error(">>> Failed!\n");
			return false;
		}
		arrMachOesSizes.push_back(uNewLength);
	}
	ZLog::Warn(">>> Success!\n");

	if (1 == m_arrArchOes.size()) {
		string strNewArchOFile = m_strFile + ".archo.0";
#ifndef _WIN32
		if (0 != chmod(strNewArchOFile.c_str(), originalStat.st_mode & 07777)) {
			return false;
		}
#endif
		CloseFile();
		ZFile::RemoveFile(m_strFile.c_str());
		if (0 == rename(strNewArchOFile.c_str(), m_strFile.c_str())) {
			return OpenFile(m_strFile.c_str());
		}
	} else { //fat
		uint32_t uAlign = 16384;
		vector<fat_arch> arrArches;
		fat_header fath = *((fat_header*)m_pBase);
		int nFatArch = (FAT_MAGIC == fath.magic) ? fath.nfat_arch : LE(fath.nfat_arch);
		for (int i = 0; i < nFatArch; i++) {
			fat_arch arch = *((fat_arch*)(m_pBase + sizeof(fat_header) + sizeof(fat_arch) * i));
			arrArches.push_back(arch);
		}
		CloseFile();

		if (arrArches.size() != m_arrArchOes.size()) {
			return false;
		}

		uint32_t uFatHeaderSize = sizeof(fat_header) + (uint32_t)arrArches.size() * sizeof(fat_arch);
		uint32_t uPadding1 = (uAlign - uFatHeaderSize % uAlign);
		uint32_t uOffset = uFatHeaderSize + uPadding1;
		for (size_t i = 0; i < arrArches.size(); i++) {
			fat_arch& arch = arrArches[i];
			uint32_t& uMachOSize = arrMachOesSizes[i];

			arch.align = (FAT_MAGIC == fath.magic) ? 14 : BE((uint32_t)14);
			arch.offset = (FAT_MAGIC == fath.magic) ? uOffset : BE(uOffset);
			arch.size = (FAT_MAGIC == fath.magic) ? uMachOSize : BE(uMachOSize);

			uOffset += uMachOSize;
			uOffset = uOffset + (uAlign - uOffset % uAlign);
		}

		string strNewFatMachOFile = m_strFile + ".fato";

		string strFatHeader;
		strFatHeader.append((const char*)&fath, sizeof(fat_header));
		for (size_t i = 0; i < arrArches.size(); i++) {
			fat_arch& arch = arrArches[i];
			strFatHeader.append((const char*)&arch, sizeof(fat_arch));
		}

		string strPadding1;
		strPadding1.append(uPadding1, 0);

		ZFile::AppendFile(strNewFatMachOFile.c_str(), strFatHeader);
		ZFile::AppendFile(strNewFatMachOFile.c_str(), strPadding1);

		for (size_t i = 0; i < arrArches.size(); i++) {
			size_t sSize = 0;
			string strNewArchOFile = m_strFile + ".archo." + std::to_string(i);
			uint8_t* pData = (uint8_t*)ZFile::MapFile(strNewArchOFile.c_str(), 0, 0, &sSize, true);
			if (NULL == pData) {
				ZFile::RemoveFile(strNewFatMachOFile.c_str());
				return false;
			}
			string strPadding;
			strPadding.append((uAlign - sSize % uAlign), 0);

			ZFile::AppendFile(strNewFatMachOFile.c_str(), (const char*)pData, sSize);
			ZFile::AppendFile(strNewFatMachOFile.c_str(), strPadding);

			ZFile::UnmapFile((void*)pData, sSize);
			ZFile::RemoveFile(strNewArchOFile.c_str());
		}

#ifndef _WIN32
		if (0 != chmod(strNewFatMachOFile.c_str(), originalStat.st_mode & 07777)) {
			return false;
		}
#endif
		ZFile::RemoveFile(m_strFile.c_str());
		if (0 == rename(strNewFatMachOFile.c_str(), m_strFile.c_str())) {
			return OpenFile(m_strFile.c_str());
		}
	}

	return false;
}

bool ZMachO::InjectDylib(bool bWeakInject, const char* szDylibFile)
{
	ZLog::WarnV(">>> InjectDylib: %s %s... \n", szDylibFile, bWeakInject ? "(weak)" : "");

	vector<uint32_t> arrMachOesSizes;
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		if (!m_arrArchOes[i]->InjectDylib(bWeakInject, szDylibFile)) {
			ZLog::Error(">>> Failed!\n");
			return false;
		}
	}
	ZLog::Warn(">>> Success!\n");
	return true;
}


bool ZMachO::ChangeDylibPath(const char* oldPath, const char* newPath)
{
    ZLog::WarnV(">>> Change DyLib Path: %s -> %s ... \n", oldPath, newPath);
    bool changed = true;
    for (size_t i = 0; i < m_arrArchOes.size(); i++) {
        if (!m_arrArchOes[i]->ChangeDylibPath(oldPath, newPath)) {
            changed = false;
        }
    }
    if (changed) {
        ZLog::Warn(">>> Successfully changed all dylib paths!\n");
    }
    return changed;
}

std::vector<std::string> ZMachO::ListDylibs()
{
    std::vector<std::string> dylibs;
    for (size_t i = 0; i < m_arrArchOes.size(); i++) {
        std::vector<std::string> archDylibs = m_arrArchOes[i]->ListDylibs();
        for (const auto& dylib : archDylibs) {
            if (std::find(dylibs.begin(), dylibs.end(), dylib) == dylibs.end()) {
                dylibs.push_back(dylib);
            }
        }
    }
    ZLog::WarnV(">>> Found %zu dylibs.\n", dylibs.size());
    return dylibs;
}

void ZMachO::RemoveDylibs(const set<string>& setDylibs)
{
	for (size_t i = 0; i < m_arrArchOes.size(); i++) {
		m_arrArchOes[i]->RemoveDylibs(setDylibs);
	}
}
