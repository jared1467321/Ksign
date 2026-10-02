#include "bundle.h"
#include "common.h"
#include "macho.h"
#include "sys/stat.h"
#include "sys/types.h"
#include "mz.h"
#include "mz_zip.h"
#include "mz_strm.h"
#include "mz_zip_rw.h"
#include <openssl/evp.h>
#ifndef _WIN32
#include <unistd.h>
#include <limits.h>
#endif

static bool GetSymbolicLinkTarget(const string& strPath, string& strTarget)
{
#ifdef _WIN32
	(void)strPath;
	strTarget.clear();
	return false;
#else
	struct stat st = { 0 };
	if (0 != lstat(strPath.c_str(), &st) || !S_ISLNK(st.st_mode)) {
		strTarget.clear();
		return false;
	}

	size_t bufferSize = (st.st_size > 0) ? (size_t)st.st_size + 1 : (size_t)PATH_MAX + 1;
	vector<char> buffer(bufferSize, 0);
	ssize_t length = readlink(strPath.c_str(), buffer.data(), buffer.size() - 1);
	if (length < 0) {
		strTarget.clear();
		return false;
	}

	strTarget.assign(buffer.data(), (size_t)length);
	return true;
#endif
}


static bool PathExistsNoFollow(const string& path)
{
#ifndef _WIN32
    struct stat st {};
    return 0 == lstat(path.c_str(), &st);
#else
    return ZFile::IsFileExists(path.c_str());
#endif
}

static string NormalizeArchiveLogicalPath(string path)
{
    replace(path.begin(), path.end(), '\\', '/');
    while (!path.empty() && '/' == path.front()) {
        path.erase(path.begin());
    }
    while (!path.empty() && '/' == path.back()) {
        path.pop_back();
    }
    return path;
}

static bool IsSafeArchiveRelativePath(const string& path)
{
    if (path.empty() || '/' == path.front() || '\\' == path.front() || string::npos != path.find('\\')) {
        return false;
    }
    size_t start = 0;
    while (start <= path.size()) {
        size_t end = path.find('/', start);
        if (string::npos == end) {
            end = path.size();
        }
        if (end - start == 2 && path[start] == '.' && path[start + 1] == '.') {
            return false;
        }
        if (end == path.size()) {
            break;
        }
        start = end + 1;
    }
    return true;
}

static bool IsCodeSignatureRelativePath(const string& relativePath)
{
    return relativePath == "_CodeSignature" ||
           0 == relativePath.rfind("_CodeSignature/", 0) ||
           string::npos != relativePath.find("/_CodeSignature/") ||
           (relativePath.size() > 15 && 0 == relativePath.compare(relativePath.size() - 15, 15, "/_CodeSignature"));
}

void ZBundle::SetArchiveBacking(const string& archivePath,
                                const string& archiveRootPath,
                                const vector<string>& deletedPaths)
{
    m_strArchivePath = archivePath;
    m_strArchiveRootPath = NormalizeArchiveLogicalPath(archiveRootPath);
    m_setArchiveDeletedPaths.clear();
    for (const string& value : deletedPaths) {
        string normalized = NormalizeArchiveLogicalPath(value);
        if (!normalized.empty()) {
            m_setArchiveDeletedPaths.insert(normalized);
        }
    }
}

bool ZBundle::IsArchiveDeleted(const string& relativePath) const
{
    string normalized = NormalizeArchiveLogicalPath(relativePath);
    if (IsCodeSignatureRelativePath(normalized)) {
        return true;
    }
    for (const string& deleted : m_setArchiveDeletedPaths) {
        if (normalized == deleted ||
            (normalized.size() > deleted.size() &&
             0 == normalized.compare(0, deleted.size(), deleted) &&
             '/' == normalized[deleted.size()])) {
            return true;
        }
    }
    return false;
}

ZBundle::ZBundle()
{
	m_pSignAssets = NULL;
	m_pSignAsset = NULL;
	m_bForceSign = false;
	m_bWeakInject = false;
	m_bRemoveProvision = false;
	m_bEnableDocuments = false;
	m_bRemoveExtensions = false;
	m_bRemoveWatchApp = false;
	m_bRemoveUISupportedDevices = false;
	m_bInjectExtensions = false;
}

bool ZBundle::FindAppFolder(const string& strFolder, string& strAppFolder)
{
	if (ZFile::IsPathSuffix(strFolder, ".app") || ZFile::IsPathSuffix(strFolder, ".appex")) {
		strAppFolder = strFolder;
		return true;
	}

	ZFile::EnumFolder(strFolder.c_str(), true, [&](bool bFolder, const string& strPath) {
		string strName = ZUtil::GetBaseName(strPath.c_str());
		if ("__MACOSX" == strName) {
			return true;
		}
		return false;
	}, [&](bool bFolder, const string& strPath) {
		if (bFolder) {
			if (ZFile::IsPathSuffix(strPath, ".app") || ZFile::IsPathSuffix(strPath, ".appex")) {
				strAppFolder = strPath;
				return true;
			}
		}
		return false;
	});

	return (!strAppFolder.empty());
}

bool ZBundle::GetSignFolderInfo(const string& strFolder, jvalue& jvNode, bool bGetName)
{
	string strInfoPlistData;
	string strInfoPlistPath = strFolder + "/Info.plist";
	ZFile::ReadFile(strInfoPlistPath.c_str(), strInfoPlistData);

	jvalue jvInfo;
	jvInfo.read_plist(strInfoPlistData);
	string strBundleId = jvInfo["CFBundleIdentifier"];
	string strBundleExe = jvInfo["CFBundleExecutable"];
	string strBundleVersion = jvInfo["CFBundleVersion"];
	if (strBundleId.empty() || strBundleExe.empty()) {
		return false;
	}

	string strInfoSHA1;
	string strInfoSHA256;
	ZSHA::SHABase64(strInfoPlistData, strInfoSHA1, strInfoSHA256);

	jvNode["bundle_id"] = strBundleId;
	jvNode["bundle_version"] = strBundleVersion;
	jvNode["bundle_executable"] = strBundleExe;
	jvNode["sha1"] = strInfoSHA1;
	jvNode["sha256"] = strInfoSHA256;
	if (!jvNode.has("path")) {
		jvNode["path"] = strFolder.substr(m_strAppFolder.size() + 1);
	}

	if (bGetName) {
		string strBundleName = jvInfo["CFBundleDisplayName"];
		if (strBundleName.empty()) {
			strBundleName = jvInfo["CFBundleName"].as_cstr();
		}
		jvNode["name"] = strBundleName;
	}

	return true;
}

bool ZBundle::BuildFileIndex()
{
    m_indexedFiles.clear();
    m_indexedFolders.clear();
    m_archiveEntries.clear();

    if (!ZFile::EnumFolder(m_strAppFolder.c_str(), true, NULL, [&](bool bFolder, const string& strPath) {
        if (bFolder) {
            m_indexedFolders.push_back(strPath);
        } else {
            m_indexedFiles.push_back(strPath);
        }
        return false;
    })) {
        return false;
    }

    if (!m_strArchivePath.empty() && !m_strArchiveRootPath.empty()) {
        return AddArchiveFileIndex();
    }
    return true;
}

bool ZBundle::AddArchiveFileIndex()
{
    void* reader = mz_zip_reader_create();
    if (NULL == reader) {
        return false;
    }
    int32_t err = mz_zip_reader_open_file(reader, m_strArchivePath.c_str());
    if (MZ_OK != err) {
        mz_zip_reader_delete(&reader);
        return false;
    }

    void* zipHandle = NULL;
    err = mz_zip_reader_get_zip_handle(reader, &zipHandle);
    if (MZ_OK != err || NULL == zipHandle) {
        mz_zip_reader_close(reader);
        mz_zip_reader_delete(&reader);
        return false;
    }

    const string prefix = m_strArchiveRootPath + "/";
    err = mz_zip_reader_goto_first_entry(reader);
    while (MZ_OK == err) {
        mz_zip_file* info = NULL;
        if (MZ_OK != mz_zip_reader_entry_get_info(reader, &info) || NULL == info || NULL == info->filename) {
            err = MZ_FORMAT_ERROR;
            break;
        }

        string archiveName = info->filename;
        // IPA member names are required to use forward slashes. Do not quietly
        // normalize backslashes here: treating them as separators could turn a
        // malformed member into a different logical path than the archive stores.
        if (string::npos != archiveName.find('\\')) {
            err = MZ_FORMAT_ERROR;
            break;
        }
        if (archiveName.size() > prefix.size() && 0 == archiveName.compare(0, prefix.size(), prefix)) {
            string relative = archiveName.substr(prefix.size());
            while (!relative.empty() && '/' == relative.back()) {
                relative.pop_back();
            }

            if (!relative.empty()) {
                if (!IsSafeArchiveRelativePath(relative)) {
                    err = MZ_FORMAT_ERROR;
                    break;
                }
                if (IsArchiveDeleted(relative)) {
                    err = mz_zip_reader_goto_next_entry(reader);
                    continue;
                }
                const string logicalPath = m_strAppFolder + "/" + relative;
                const bool isDirectory = (MZ_OK == mz_zip_reader_entry_is_dir(reader));
                if (isDirectory) {
                    if (!PathExistsNoFollow(logicalPath) &&
                        std::find(m_indexedFolders.begin(), m_indexedFolders.end(), logicalPath) == m_indexedFolders.end()) {
                        m_indexedFolders.push_back(logicalPath);
                    }
                } else if (!PathExistsNoFollow(logicalPath)) {
                    ArchiveEntry archiveEntry;
                    archiveEntry.cdPosition = mz_zip_get_entry(zipHandle);
                    archiveEntry.isSymlink = (MZ_OK == mz_zip_attrib_is_symlink(info->external_fa, info->version_madeby));
                    if (archiveEntry.isSymlink) {
                        if (NULL != info->linkname && '\0' != info->linkname[0]) {
                            archiveEntry.symlinkTarget = info->linkname;
                        } else if (info->uncompressed_size >= 0 && info->uncompressed_size <= 65536) {
                            if (MZ_OK == mz_zip_reader_entry_open(reader)) {
                                vector<char> target((size_t)info->uncompressed_size + 1, 0);
                                int32_t amount = 0;
                                if (info->uncompressed_size > 0) {
                                    amount = mz_zip_reader_entry_read(reader, target.data(), (int32_t)info->uncompressed_size);
                                }
                                int32_t closeStatus = mz_zip_reader_entry_close(reader);
                                if (amount >= 0 && closeStatus == MZ_OK) {
                                    archiveEntry.symlinkTarget.assign(target.data(), (size_t)amount);
                                }
                            }
                        }
                    }
                    // Last duplicate wins for the merged logical resource view.
                    m_archiveEntries[logicalPath] = archiveEntry;
                    if (std::find(m_indexedFiles.begin(), m_indexedFiles.end(), logicalPath) == m_indexedFiles.end()) {
                        m_indexedFiles.push_back(logicalPath);
                    }

                    // ZIPs are allowed to omit explicit directory entries. Add all
                    // logical parents so nested bundle discovery still works.
                    size_t slash = relative.find('/');
                    while (slash != string::npos) {
                        string folder = m_strAppFolder + "/" + relative.substr(0, slash);
                        if (!PathExistsNoFollow(folder) &&
                            std::find(m_indexedFolders.begin(), m_indexedFolders.end(), folder) == m_indexedFolders.end()) {
                            m_indexedFolders.push_back(folder);
                        }
                        slash = relative.find('/', slash + 1);
                    }
                }
            }
        }
        err = mz_zip_reader_goto_next_entry(reader);
    }

    if (MZ_END_OF_LIST == err) {
        err = MZ_OK;
    }
    int32_t closeStatus = mz_zip_reader_close(reader);
    mz_zip_reader_delete(&reader);
    if (MZ_OK == err && MZ_OK != closeStatus) {
        err = closeStatus;
    }
    return MZ_OK == err;
}

bool ZBundle::GetLogicalSymbolicLinkTarget(const string& strPath, string& strTarget) const
{
    if (GetSymbolicLinkTarget(strPath, strTarget)) {
        return true;
    }
    if (PathExistsNoFollow(strPath)) {
        strTarget.clear();
        return false;
    }
    auto it = m_archiveEntries.find(strPath);
    if (it != m_archiveEntries.end() && it->second.isSymlink) {
        strTarget = it->second.symlinkTarget;
        return true;
    }
    strTarget.clear();
    return false;
}

bool ZBundle::HashLogicalFile(const string& strPath,
                              string& strSHA1Base64,
                              string& strSHA256Base64,
                              void* archiveReader) const
{
    if (PathExistsNoFollow(strPath)) {
        return ZSHA::SHABase64File(strPath.c_str(), strSHA1Base64, strSHA256Base64);
    }

    auto it = m_archiveEntries.find(strPath);
    if (it == m_archiveEntries.end() || it->second.isSymlink || it->second.cdPosition < 0) {
        return false;
    }

    void* ownedReader = NULL;
    void* reader = archiveReader;
    if (NULL == reader) {
        ownedReader = mz_zip_reader_create();
        if (NULL == ownedReader || MZ_OK != mz_zip_reader_open_file(ownedReader, m_strArchivePath.c_str())) {
            if (NULL != ownedReader) {
                mz_zip_reader_delete(&ownedReader);
            }
            return false;
        }
        reader = ownedReader;
    }

    void* zipHandle = NULL;
    bool success = false;
    if (MZ_OK == mz_zip_reader_get_zip_handle(reader, &zipHandle) && NULL != zipHandle &&
        MZ_OK == mz_zip_goto_entry(zipHandle, it->second.cdPosition) &&
        MZ_OK == mz_zip_entry_read_open(zipHandle, 0, NULL)) {
        EVP_MD_CTX* sha1Context = EVP_MD_CTX_new();
        EVP_MD_CTX* sha256Context = EVP_MD_CTX_new();
        bool digestOK = NULL != sha1Context && NULL != sha256Context &&
                        1 == EVP_DigestInit_ex(sha1Context, EVP_sha1(), NULL) &&
                        1 == EVP_DigestInit_ex(sha256Context, EVP_sha256(), NULL);

        uint8_t buffer[64 * 1024];
        int32_t read = 0;
        while (digestOK && (read = mz_zip_entry_read(zipHandle, buffer, (int32_t)sizeof(buffer))) > 0) {
            digestOK = 1 == EVP_DigestUpdate(sha1Context, buffer, (size_t)read) &&
                       1 == EVP_DigestUpdate(sha256Context, buffer, (size_t)read);
        }
        if (read < 0) {
            digestOK = false;
        }
        int32_t closeEntry = mz_zip_entry_read_close(zipHandle, NULL, NULL, NULL);
        if (digestOK && MZ_OK == closeEntry) {
            uint8_t sha1[EVP_MAX_MD_SIZE];
            uint8_t sha256[EVP_MAX_MD_SIZE];
            unsigned int sha1Length = 0;
            unsigned int sha256Length = 0;
            digestOK = 1 == EVP_DigestFinal_ex(sha1Context, sha1, &sha1Length) &&
                       1 == EVP_DigestFinal_ex(sha256Context, sha256, &sha256Length);
            if (digestOK) {
                jbase64 b64;
                strSHA1Base64 = b64.encode(string((const char*)sha1, sha1Length));
                strSHA256Base64 = b64.encode(string((const char*)sha256, sha256Length));
                success = !strSHA1Base64.empty() && !strSHA256Base64.empty();
            }
        }
        EVP_MD_CTX_free(sha1Context);
        EVP_MD_CTX_free(sha256Context);
    }

    if (NULL != ownedReader) {
        mz_zip_reader_close(ownedReader);
        mz_zip_reader_delete(&ownedReader);
    }
    return success;
}

void ZBundle::EnsureIndexedFile(const string& strFile)
{
	if (std::find(m_indexedFiles.begin(), m_indexedFiles.end(), strFile) == m_indexedFiles.end()) {
		m_indexedFiles.push_back(strFile);
	}
}

static bool IsPathWithinFolder(const string& strPath, const string& strFolder)
{
	if (strPath.size() < strFolder.size() || 0 != strPath.compare(0, strFolder.size(), strFolder)) {
		return false;
	}
	if (strPath.size() == strFolder.size()) {
		return true;
	}
	char ch = strPath[strFolder.size()];
	return ('/' == ch || '\\' == ch);
}

static bool IsMobileInstallationWatchPlaceholderBundle(const string& strBundlePath)
{
	if (!ZFile::IsPathSuffix(strBundlePath, ".app") && !ZFile::IsPathSuffix(strBundlePath, ".appex")) {
		return false;
	}

	// TestFlight/App Store delivery can contain synthetic watch bundles under
	// com.apple.WatchPlaceholder. Their Info.plist deliberately names a
	// CFBundleExecutable (usually "Executable") even though no Mach-O exists.
	// Require both the container path and Apple's MI placeholder marker so a
	// genuinely broken ordinary app/extension still fails signing normally.
	string strNormalizedPath = strBundlePath;
	replace(strNormalizedPath.begin(), strNormalizedPath.end(), '\\', '/');
	const string strWatchPlaceholder = "com.apple.WatchPlaceholder/";
	if (string::npos == strNormalizedPath.find("/" + strWatchPlaceholder) &&
		0 != strNormalizedPath.rfind(strWatchPlaceholder, 0)) {
		return false;
	}

	jvalue jvInfo;
	if (!jvInfo.read_plist_from_file("%s/Info.plist", strBundlePath.c_str())) {
		return false;
	}
	return jvInfo.has("CF_MIPlaceholderConstructorVersion");
}

bool ZBundle::GetObjectsToSign(const string& strFolder, jvalue& jvInfo)
{
	// The app tree is indexed once and reused by both object discovery and
	// CodeResources generation. This replaces multiple full recursive walks.
	if (m_indexedFiles.empty() && m_indexedFolders.empty()) {
		if (!BuildFileIndex()) {
			return false;
		}
	}

	vector<string> placeholderBundles;
	for (const string& strPath : m_indexedFolders) {
		if (IsMobileInstallationWatchPlaceholderBundle(strPath)) {
			placeholderBundles.push_back(strPath);
			string strRelativePath = strPath.substr(m_strAppFolder.size() + 1);
			ZLog::PrintV(">>> Skip MobileInstallation Watch placeholder: %s\n", strRelativePath.c_str());
		}
	}

	auto isInsidePlaceholder = [&](const string& strPath) {
		for (const string& strPlaceholder : placeholderBundles) {
			if (IsPathWithinFolder(strPath, strPlaceholder)) {
				return true;
			}
		}
		return false;
	};

	vector<string> allBundles;
	for (const string& strPath : m_indexedFolders) {
		if (isInsidePlaceholder(strPath)) {
			continue;
		}
		if (ZFile::IsPathSuffix(strPath, ".app") ||
			ZFile::IsPathSuffix(strPath, ".appex") ||
			ZFile::IsPathSuffix(strPath, ".framework") ||
			ZFile::IsPathSuffix(strPath, ".xctest")) {
			allBundles.push_back(strPath);
		}
	}

	// Keep the existing dependency rule: nested bundles are always signed
	// before their parents. Equal-depth entries retain the index traversal
	// order, matching the original depth-first discovery behavior.
	sort(allBundles.begin(), allBundles.end(), [](const string& a, const string& b) {
		size_t depthA = count(a.begin(), a.end(), '/');
		size_t depthB = count(b.begin(), b.end(), '/');
		return depthA > depthB;
	});

	for (const string& bundlePath : allBundles) {
		jvalue jvNode;
		if (GetSignFolderInfo(bundlePath, jvNode)) {
			jvInfo["folders"].push_back(jvNode);
		}
	}

	for (const string& strPath : m_indexedFiles) {
		// Preserve MobileInstallation watch placeholders byte-for-byte as parent
		// resources. They are metadata bundles, not independently signable code.
		if (isInsidePlaceholder(strPath)) {
			continue;
		}
		if (string::npos != strPath.find(".dSYM") ||
			string::npos != strPath.find("_WatchKitStub")) {
			continue;
		}

		string strLinkTarget;
		if (GetSymbolicLinkTarget(strPath, strLinkTarget)) {
			continue;
		}

		bool bMachO = false;
		FILE* fp = NULL;
#ifdef _WIN32
		fopen_s(&fp, strPath.c_str(), "rb");
#else
		fp = fopen(strPath.c_str(), "rb");
#endif
		if (fp) {
			uint32_t magic = 0;
			if (1 == fread(&magic, sizeof(magic), 1, fp)) {
				bMachO = (magic == MH_MAGIC || magic == MH_CIGAM ||
						  magic == MH_MAGIC_64 || magic == MH_CIGAM_64 ||
						  magic == FAT_MAGIC || magic == FAT_CIGAM);
			}
			fclose(fp);
		}

		if (bMachO) {
			jvInfo["files"].push_back(strPath.substr(m_strAppFolder.size() + 1));
		}
	}

	return true;
}

bool ZBundle::GenerateCodeResources(const string& strFolder, jvalue& jvCodeRes)
{
	if (m_indexedFiles.empty() && m_indexedFolders.empty()) {
		if (!BuildFileIndex()) {
			return false;
		}
	}

	set<string> setFiles;
	const string strPrefix = strFolder + "/";

	// Reuse the single app-tree index instead of recursively walking the bundle
	// for every nested signing node. Files created during signing (notably
	// nested CodeResources and profiles) are appended to the index as they are
	// produced, while removed files are filtered here by existence.
	for (const string& strPath : m_indexedFiles) {
		if (strPath.size() <= strPrefix.size() || 0 != strPath.compare(0, strPrefix.size(), strPrefix)) {
			continue;
		}
		string strLinkTarget;
		const bool hasDiskPath = PathExistsNoFollow(strPath);
		const bool hasArchivePath = (m_archiveEntries.find(strPath) != m_archiveEntries.end());
		if (!hasDiskPath && !hasArchivePath) {
			continue;
		}

		string strNode = strPath.substr(strPrefix.size());
		ZUtil::StringReplace(strNode, "\\", "/");
		setFiles.insert(strNode);
	}

	jvalue jvInfo;
	jvInfo.read_plist_from_file("%s/Info.plist", strFolder.c_str());
	string strBundleExe = jvInfo["CFBundleExecutable"];

#ifdef _WIN32
	iconv ic;
	strBundleExe = ic.U82A(strBundleExe);
#endif

	setFiles.erase("_CodeSignature/CodeResources");
	setFiles.erase(strBundleExe);

	struct ResourceHash
	{
		string key;
		string sha1;
		string sha256;
		bool isSymlink = false;
		bool hashOK = true;
		string symlinkTarget;
	};

	vector<ResourceHash> hashes;
	hashes.reserve(setFiles.size());
	for (const string& strKey : setFiles) {
		if (m_bRemoveProvision && strKey == "embedded.mobileprovision") {
			string strProvFile = strFolder + "/embedded.mobileprovision";
			remove(strProvFile.c_str());
			ZLog::Print(">>> Removed embedded.mobileprovision\n");
			continue;
		}

		ResourceHash item;
		item.key = strKey;
		string strFile = strFolder + "/" + strKey;
		item.isSymlink = GetLogicalSymbolicLinkTarget(strFile, item.symlinkTarget);
		hashes.push_back(std::move(item));
	}

	// File hashing is independent. Hash in parallel into fixed result slots,
	// then commit to the plist serially in the same sorted-key order as before.
	// This keeps CodeResources byte-for-byte stable while using multiple cores.
	const size_t workerCount = (hashes.size() >= 8) ? ZUtil::GetWorkerCount(hashes.size()) : 1;
	auto openArchiveReader = [&]() -> void* {
		if (m_strArchivePath.empty()) {
			return NULL;
		}
		void* reader = mz_zip_reader_create();
		if (NULL == reader || MZ_OK != mz_zip_reader_open_file(reader, m_strArchivePath.c_str())) {
			if (NULL != reader) {
				mz_zip_reader_delete(&reader);
			}
			return NULL;
		}
		return reader;
	};
	auto closeArchiveReader = [&](void*& reader) {
		if (NULL != reader) {
			mz_zip_reader_close(reader);
			mz_zip_reader_delete(&reader);
		}
	};

	if (workerCount <= 1) {
		void* reader = openArchiveReader();
		for (ResourceHash& item : hashes) {
			if (item.isSymlink) {
				continue;
			}
			string strFile = strFolder + "/" + item.key;
			item.hashOK = HashLogicalFile(strFile, item.sha1, item.sha256, reader);
		}
		closeArchiveReader(reader);
	} else {
		atomic<size_t> next(0);
		vector<thread> workers;
		workers.reserve(workerCount);
		for (size_t worker = 0; worker < workerCount; worker++) {
			workers.emplace_back([&]() {
				void* reader = openArchiveReader();
				for (;;) {
					size_t index = next.fetch_add(1, std::memory_order_relaxed);
					if (index >= hashes.size()) {
						break;
					}
					ResourceHash& item = hashes[index];
					if (item.isSymlink) {
						continue;
					}
					string strFile = strFolder + "/" + item.key;
					item.hashOK = HashLogicalFile(strFile, item.sha1, item.sha256, reader);
				}
				closeArchiveReader(reader);
			});
		}
		for (thread& worker : workers) {
			worker.join();
		}
	}

	for (const ResourceHash& item : hashes) {
		if (!item.isSymlink && !item.hashOK) {
			ZLog::ErrorV(">>> Can't hash logical resource: %s/%s\n", strFolder.c_str(), item.key.c_str());
			return false;
		}
	}

	jvCodeRes.clear();
	jvCodeRes["files"] = jvalue(jvalue::E_OBJECT);
	jvCodeRes["files2"] = jvalue(jvalue::E_OBJECT);

	for (ResourceHash& item : hashes) {
		string strKey = item.key;
#ifdef _WIN32
		strKey = ic.A2U8(strKey);
#endif

		bool bomit1 = false;
		bool bomit2 = false;

		if (ZFile::IsPathSuffix(strKey, ".lproj/locversion.plist")) {
			bomit1 = true;
			bomit2 = true;
		}

		if (ZFile::IsPathSuffix(strKey, ".DS_Store") || "Info.plist" == strKey || "PkgInfo" == strKey) {
			bomit2 = true;
		}

		if (item.isSymlink) {
			// Apple's V2 resource envelope seals the symbolic link itself, not the
			// bytes reached by following it. V1 only contains regular files.
			if (!bomit2) {
				jvCodeRes["files2"][strKey]["symlink"] = item.symlinkTarget;
				if (string::npos != strKey.rfind(".lproj/")) {
					jvCodeRes["files2"][strKey]["optional"] = true;
				}
			}
			continue;
		}

		if (!bomit1) {
			if (string::npos != strKey.rfind(".lproj/")) {
				jvCodeRes["files"][strKey]["hash"] = "data:" + item.sha1;
				jvCodeRes["files"][strKey]["optional"] = true;
			} else {
				jvCodeRes["files"][strKey] = "data:" + item.sha1;
			}
		}

		if (!bomit2) {
			jvCodeRes["files2"][strKey]["hash"] = "data:" + item.sha1;
			jvCodeRes["files2"][strKey]["hash2"] = "data:" + item.sha256;
			if (string::npos != strKey.rfind(".lproj/")) {
				jvCodeRes["files2"][strKey]["optional"] = true;
			}
		}
	}

	jvCodeRes["rules"]["^.*"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/"]["optional"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/"]["weight"] = 1000.0;
	jvCodeRes["rules"]["^.*\\.lproj/locversion.plist$"]["omit"] = true;
	jvCodeRes["rules"]["^.*\\.lproj/locversion.plist$"]["weight"] = 1100.0;
	jvCodeRes["rules"]["^Base\\.lproj/"]["weight"] = 1010.0;
	jvCodeRes["rules"]["^version.plist$"] = true;

	jvCodeRes["rules2"]["^.*"] = true;
	jvCodeRes["rules2"][".*\\.dSYM($|/)"]["weight"] = 11.0;
	jvCodeRes["rules2"]["^(.*/)?\\.DS_Store$"]["omit"] = true;
	jvCodeRes["rules2"]["^(.*/)?\\.DS_Store$"]["weight"] = 2000.0;
	jvCodeRes["rules2"]["^.*\\.lproj/"]["optional"] = true;
	jvCodeRes["rules2"]["^.*\\.lproj/"]["weight"] = 1000.0;
	jvCodeRes["rules2"]["^.*\\.lproj/locversion.plist$"]["omit"] = true;
	jvCodeRes["rules2"]["^.*\\.lproj/locversion.plist$"]["weight"] = 1100.0;
	jvCodeRes["rules2"]["^Base\\.lproj/"]["weight"] = 1010.0;
	jvCodeRes["rules2"]["^Info\\.plist$"]["omit"] = true;
	jvCodeRes["rules2"]["^Info\\.plist$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^PkgInfo$"]["omit"] = true;
	jvCodeRes["rules2"]["^PkgInfo$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^embedded\\.provisionprofile$"]["weight"] = 20.0;
	jvCodeRes["rules2"]["^version\\.plist$"]["weight"] = 20.0;

	return true;
}

void ZBundle::GetChangedFiles(jvalue& jvNode, vector<string>& arrChangedFiles)
{
	if (jvNode.has("files")) {
		for (size_t i = 0; i < jvNode["files"].size(); i++) {
			arrChangedFiles.push_back(jvNode["files"][i]);
		}
	}

	if (jvNode.has("folders")) {
		for (size_t i = 0; i < jvNode["folders"].size(); i++) {
			jvalue& jvSubNode = jvNode["folders"][i];
			GetChangedFiles(jvSubNode, arrChangedFiles);
			string strPath = jvSubNode["path"];
			arrChangedFiles.push_back(strPath + "/_CodeSignature/CodeResources");
			arrChangedFiles.push_back(strPath + "/" + jvSubNode["bundle_executable"].as_string());
		}
	}
}

void ZBundle::GetNodeChangedFiles(jvalue& jvNode)
{
	if (jvNode.has("folders")) {
		for (size_t i = 0; i < jvNode["folders"].size(); i++) {
			GetNodeChangedFiles(jvNode["folders"][i]);
		}
	}

	vector<string> arrChangedFiles;
	GetChangedFiles(jvNode, arrChangedFiles);
	for (size_t i = 0; i < arrChangedFiles.size(); i++) {
		jvNode["changed"].push_back(arrChangedFiles[i]);
	}

	if ("/" == jvNode["path"]) { // root
		jvNode["changed"].push_back("embedded.mobileprovision");
	}
}

static bool IsAppExtensionPath(const string& strPath)
{
	// Top-level app extension: PlugIns/<name>.appex or Extensions/<name>.appex.
	// Restrict to a single path component under PlugIns/Extensions so watch-app
	// and other nested .appex bundles (different arch/container) are left alone.
	if (!ZFile::IsPathSuffix(strPath, ".appex")) {
		return false;
	}
	if (1 != count(strPath.begin(), strPath.end(), '/')) {
		return false;
	}
	return (0 == strPath.rfind("PlugIns/", 0) || 0 == strPath.rfind("Extensions/", 0));
}

bool ZBundle::SignNode(jvalue& jvNode)
{
	if (jvNode.has("files")) {
		for (size_t i = 0; i < jvNode["files"].size(); i++) {
			string strFile = jvNode["files"][i];
			ZLog::PrintV(">>> SignFile: \t%s\n", strFile.c_str());
			ZMachO macho;
			if (macho.InitV("%s/%s", m_strAppFolder.c_str(), strFile.c_str())) {
				if (!macho.Sign(m_pSignAsset, m_bForceSign, "", "", "", "")) {
					return false;
				}
			} else {
				ZLog::WarnV(">>> Warning: Skipping non-Mach-O file: \t%s\n", strFile.c_str());
			}
		}
	}
	
	if (jvNode.has("folders")) {
		for (size_t i = 0; i < jvNode["folders"].size(); i++) {
			if (!SignNode(jvNode["folders"][i])) {
				return false;
			}
		}
	}

	jbase64 b64;
	string strInfoSHA1;
	string strInfoSHA256;
	string strFolder = jvNode["path"];
	string strBundleId = jvNode["bundle_id"];
	string strBundleExe = jvNode["bundle_executable"];
	b64.decode(jvNode["sha1"].as_cstr(), strInfoSHA1);
	b64.decode(jvNode["sha256"].as_cstr(), strInfoSHA256);
	if (strBundleId.empty() || strBundleExe.empty() || strInfoSHA1.empty() ||
		strInfoSHA256.empty()) {
		ZLog::ErrorV(">>> Can't get BundleID or BundleExecute or Info.plist SHASum in Info.plist! %s\n", strFolder.c_str());
		return false;
	}

#ifdef _WIN32
	iconv ic;
	strBundleExe = ic.U82A(strBundleExe);
#endif

	string strBaseFolder = m_strAppFolder;
	if ("/" != strFolder) {
		strBaseFolder += "/";
		strBaseFolder += strFolder;
	}

	string strExePath = strBaseFolder + "/" + strBundleExe;
	ZLog::PrintV(">>> SignFolder: %s, (%s)\n", ("/" == strFolder) ? ZUtil::GetBaseName(m_strAppFolder.c_str()) : strFolder.c_str(), strBundleExe.c_str());

	ZMachO macho;
	if (!macho.Init(strExePath.c_str())) {
		ZLog::ErrorV(">>> Can't parse BundleExecute file! %s\n", strExePath.c_str());
		return false;
	}

	bool bForceSign = m_bForceSign;
	if ("/" == strFolder) { // inject/remove dylib before CodeResources generation
		for (const string& strDylibFile : m_arrInjectDylibs) {
			if (macho.InjectDylib(m_bWeakInject, strDylibFile.c_str())) {
				bForceSign = true;
			}
		}
		if (!m_setRemoveDylibs.empty()) {
			macho.RemoveDylibs(m_setRemoveDylibs);
			for (const string& name : m_setRemoveDylibs) {
				string baseName = name;
				if (baseName.find("@executable_path/") == 0) {
					baseName = baseName.substr(17);
				}
				ZFile::RemoveFileV("%s/%s", m_strAppFolder.c_str(), baseName.c_str());
			}
			bForceSign = true;
		}
	} else if (m_bInjectExtensions && !m_arrInjectDylibNames.empty() && IsAppExtensionPath(strFolder)) {
		// App extensions run as separate processes and don't inherit the main
		// app's injected dylibs, so inject them here too. The dylibs stay as a
		// single shared copy at the app root, referenced from the extension
		// executable via a relative path back up to it.
		string strPrefix;
		for (size_t i = 0, n = 1 + (size_t)count(strFolder.begin(), strFolder.end(), '/'); i < n; i++) {
			strPrefix += "../";
		}
		for (const string& strName : m_arrInjectDylibNames) {
			string strLoadPath = "@executable_path/" + strPrefix + strName;
			if (macho.InjectDylib(m_bWeakInject, strLoadPath.c_str())) {
				bForceSign = true;
			}
		}
	}

	// The matched profile must land in the bundle BEFORE CodeResources is
	// generated: the seal hashes every file in the bundle, so a profile
	// written after sealing leaves the bundle failing Apple's verifier with
	// "a sealed resource is missing or invalid" (codesign --verify --strict).
	if (m_pSignAssets) {
		auto endsWith = [](const string& str, const string& suffix) {
			return str.size() >= suffix.size() && 0 == str.compare(str.size()-suffix.size(), suffix.size(), suffix);
		};
		for (auto it = m_pSignAssets->rbegin(); it != m_pSignAssets->rend(); ++it) {
			m_pSignAsset = &(*it);
			if (endsWith(m_pSignAsset->m_strApplicationId, strBundleId)) {
				if (!ZFile::WriteFileV(m_pSignAsset->m_strProvData, "%s/%s/embedded.mobileprovision", m_strAppFolder.c_str(), strFolder.c_str())) {
					ZLog::ErrorV(">>> Can't write embedded.mobileprovision!\n");
					return false;
				}
				EnsureIndexedFile(strBaseFolder + "/embedded.mobileprovision");
				bForceSign = true;
				break;
			}
		}
	}

	ZFile::CreateFolderV("%s/_CodeSignature", strBaseFolder.c_str());
	string strCodeResFile = strBaseFolder + "/_CodeSignature/CodeResources";

	jvalue jvCodeRes;
	if (!bForceSign) {
		jvCodeRes.read_plist_from_file(strCodeResFile.c_str());
	}

	if (bForceSign || jvCodeRes.is_null()) { // create
		if (!GenerateCodeResources(strBaseFolder, jvCodeRes)) {
			ZLog::ErrorV(">>> Create CodeResources failed! %s\n", strBaseFolder.c_str());
			return false;
		}
	} else if (jvNode.has("changed")) { // use existsed
		for (size_t i = 0; i < jvNode["changed"].size(); i++) {
			string strFile = jvNode["changed"][i].as_cstr();
			string strRealFile = m_strAppFolder + "/" + strFile;

			string strFileSHA1;
			string strFileSHA256;
			if (!ZSHA::SHABase64File(strRealFile.c_str(), strFileSHA1, strFileSHA256)) {
				ZLog::ErrorV(">>> Can't get changed file SHASum! %s", strFile.c_str());
				return false;
			}

			string strKey = strFile;
			if ("/" != strFolder) {
				strKey = strFile.substr(strFolder.size() + 1);
			}

			jvCodeRes["files"][strKey] = "data:" + strFileSHA1;
			jvCodeRes["files2"][strKey]["hash"] = "data:" + strFileSHA1;
			jvCodeRes["files2"][strKey]["hash2"] = "data:" + strFileSHA256;

			ZLog::DebugV("\t\tChanged file: %s, %s\n", strFileSHA1.c_str(), strKey.c_str());
		}
	}

	string strCodeResData;
	jvCodeRes.style_write_plist(strCodeResData);
	if (!ZFile::WriteFile(strCodeResFile.c_str(), strCodeResData)) {
		ZLog::ErrorV("\tWriting CodeResources failed! %s\n", strCodeResFile.c_str());
		return false;
	}
	EnsureIndexedFile(strCodeResFile);

	if (!macho.Sign(m_pSignAsset, bForceSign, strBundleId, strInfoSHA1, strInfoSHA256, strCodeResData)) {
		return false;
	}

	return true;
}

bool ZBundle::ModifyPluginsBundleId(const string& strOldBundleId, const string& strNewBundleId)
{
	vector<string> arrFolders;
	ZFile::EnumFolder(m_strAppFolder.c_str(), true, NULL, [&](bool bFolder, const string& strPath) {
		if (bFolder) {
			if (ZFile::IsPathSuffix(strPath, ".app") || ZFile::IsPathSuffix(strPath, ".appex")) {
				arrFolders.push_back(strPath);
			}
		}
		return false;
	});

	for (const string& strFolder: arrFolders) {
		jvalue jvInfo;
		if (!jvInfo.read_plist_from_file("%s/Info.plist", strFolder.c_str())) {
			ZLog::WarnV(">>> Can't find Plugin's Info.plist! %s\n", strFolder.c_str());
			continue;
		}

		string strOldPIBundleID = jvInfo["CFBundleIdentifier"];
		string strNewPIBundleID = strOldPIBundleID;
		ZUtil::StringReplace(strNewPIBundleID, strOldBundleId, strNewBundleId);
		jvInfo["CFBundleIdentifier"] = strNewPIBundleID;
		ZLog::PrintV(">>> BundleId: \t%s -> %s, Plugin\n", strOldPIBundleID.c_str(), strNewPIBundleID.c_str());

		if (jvInfo.has("WKCompanionAppBundleIdentifier")) {
			string strOldWKCBundleID = jvInfo["WKCompanionAppBundleIdentifier"];
			string strNewWKCBundleID = strOldWKCBundleID;
			ZUtil::StringReplace(strNewWKCBundleID, strOldBundleId, strNewBundleId);
			jvInfo["WKCompanionAppBundleIdentifier"] = strNewWKCBundleID;
			ZLog::PrintV(">>> BundleId: \t%s -> %s, Plugin-WKCompanionAppBundleIdentifier\n", strOldWKCBundleID.c_str(), strNewWKCBundleID.c_str());
		}

		if (jvInfo.has("NSExtension")) {
			if (jvInfo["NSExtension"].has("NSExtensionAttributes")) {
				if (jvInfo["NSExtension"]["NSExtensionAttributes"].has("WKAppBundleIdentifier")) {
					string strOldWKBundleID = jvInfo["NSExtension"]["NSExtensionAttributes"]["WKAppBundleIdentifier"];
					string strNewWKBundleID = strOldWKBundleID;
					ZUtil::StringReplace(strNewWKBundleID, strOldBundleId, strNewBundleId);
					jvInfo["NSExtension"]["NSExtensionAttributes"]["WKAppBundleIdentifier"] = strNewWKBundleID;
					ZLog::PrintV(">>> BundleId: \t%s -> %s, NSExtension-NSExtensionAttributes-WKAppBundleIdentifier\n", strOldWKBundleID.c_str(), strNewWKBundleID.c_str());
				}
			}
		}

		jvInfo.style_write_plist_to_file("%s/Info.plist", strFolder.c_str());
	}

	return true;
}

static bool GetPngSize(const string& strData, uint32_t& uWidth, uint32_t& uHeight)
{
	static const uint8_t pngMagic[8] = { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
	if (strData.size() < 24 || 0 != memcmp(strData.data(), pngMagic, 8)) {
		return false;
	}
	const uint8_t* p = (const uint8_t*)strData.data();
	if (0 != memcmp(p + 12, "IHDR", 4)) {
		return false;
	}
	uWidth = ((uint32_t)p[16] << 24) | ((uint32_t)p[17] << 16) | ((uint32_t)p[18] << 8) | p[19];
	uHeight = ((uint32_t)p[20] << 24) | ((uint32_t)p[21] << 16) | ((uint32_t)p[22] << 8) | p[23];
	return (uWidth > 0 && uHeight > 0);
}

bool ZBundle::ChangeAppIcon()
{
	string strIconData;
	if (!ZFile::ReadFile(m_strIconFile.c_str(), strIconData)) {
		ZLog::ErrorV(">>> Can't read icon file! %s\n", m_strIconFile.c_str());
		return false;
	}

	uint32_t uWidth = 0;
	uint32_t uHeight = 0;
	if (!GetPngSize(strIconData, uWidth, uHeight)) {
		ZLog::ErrorV(">>> Invalid icon file! Only PNG format is supported. %s\n", m_strIconFile.c_str());
		return false;
	}
	if (uWidth != uHeight) {
		ZLog::WarnV(">>> Warning: Icon is not square! (%ux%u)\n", uWidth, uHeight);
	}

	jvalue jvInfo;
	if (!jvInfo.read_plist_from_file("%s/Info.plist", m_strAppFolder.c_str())) {
		ZLog::ErrorV(">>> Can't find app's Info.plist! %s\n", m_strAppFolder.c_str());
		return false;
	}

	vector<string> arrIconNames;
	const char* arrIconKeys[] = { "CFBundleIcons", "CFBundleIcons~ipad" };
	for (const char* szKey : arrIconKeys) {
		if (jvInfo.has(szKey) && jvInfo[szKey].has("CFBundlePrimaryIcon")) {
			jvalue& jvPrimary = jvInfo[szKey]["CFBundlePrimaryIcon"];
			if (jvPrimary.has("CFBundleIconFiles") && jvPrimary["CFBundleIconFiles"].is_array()) {
				jvalue& jvFiles = jvPrimary["CFBundleIconFiles"];
				for (size_t i = 0; i < jvFiles.size(); i++) {
					string strName = jvFiles[i];
					if (!strName.empty()) {
						arrIconNames.push_back(strName);
					}
				}
			}
			// iOS 11+ prefers the Assets.car icon referenced by CFBundleIconName;
			// drop it so the replaced PNG files take effect
			jvPrimary.erase("CFBundleIconName");
		}
	}

	if (arrIconNames.empty() && jvInfo.has("CFBundleIconFiles") && jvInfo["CFBundleIconFiles"].is_array()) {
		jvalue& jvFiles = jvInfo["CFBundleIconFiles"];
		for (size_t i = 0; i < jvFiles.size(); i++) {
			string strName = jvFiles[i];
			if (!strName.empty()) {
				arrIconNames.push_back(strName);
			}
		}
	}

	if (arrIconNames.empty() && jvInfo.has("CFBundleIconFile")) {
		string strName = jvInfo["CFBundleIconFile"];
		if (!strName.empty()) {
			arrIconNames.push_back(strName);
		}
	}

	if (arrIconNames.empty()) { // no icon declared at all, create fresh entries
		jvalue jvFiles;
		jvFiles.push_back("AppIcon60x60");
		jvInfo["CFBundleIcons"]["CFBundlePrimaryIcon"]["CFBundleIconFiles"] = jvFiles;
		jvInfo["CFBundleIcons~ipad"]["CFBundlePrimaryIcon"]["CFBundleIconFiles"] = jvFiles;
		arrIconNames.push_back("AppIcon60x60");
	}

	// overwrite every bundle-root png matching a declared icon name prefix
	vector<string> arrIconFiles;
	ZFile::EnumFolder(m_strAppFolder.c_str(), false, NULL, [&](bool bFolder, const string& strPath) {
		if (!bFolder && ZFile::IsPathSuffix(strPath, ".png")) {
			string strBaseName = ZUtil::GetBaseName(strPath.c_str());
			for (const string& strName : arrIconNames) {
				if (0 == strncmp(strBaseName.c_str(), strName.c_str(), strName.size())) {
					arrIconFiles.push_back(strPath);
					break;
				}
			}
		}
		return false;
	});

	if (arrIconFiles.empty()) { // declared but missing on disk
		arrIconFiles.push_back(m_strAppFolder + "/" + arrIconNames[0] + "@2x.png");
	}

	int nReplaced = 0;
	for (const string& strPath : arrIconFiles) {
		if (ZFile::WriteFile(strPath.c_str(), strIconData)) {
			nReplaced++;
			ZLog::DebugV("\t\tIcon: %s\n", strPath.substr(m_strAppFolder.size() + 1).c_str());
		} else {
			ZLog::WarnV(">>> Warning: Can't write icon file! %s\n", strPath.c_str());
		}
	}
	if (0 == nReplaced) {
		ZLog::ErrorV(">>> Can't write any icon file!\n");
		return false;
	}

	if (!jvInfo.style_write_plist_to_file("%s/Info.plist", m_strAppFolder.c_str())) {
		ZLog::ErrorV(">>> Can't write app's Info.plist! %s\n", m_strAppFolder.c_str());
		return false;
	}

	ZLog::PrintV(">>> AppIcon: \t%s (%ux%u) -> %d file(s)\n", ZUtil::GetBaseName(m_strIconFile.c_str()), uWidth, uHeight, nReplaced);
	return true;
}

bool ZBundle::ModifyBundleInfo(const string& strBundleId, const string& strBundleVersion, const string& strDisplayName)
{
	jvalue jvInfo;
	if (!jvInfo.read_plist_from_file("%s/Info.plist", m_strAppFolder.c_str())) {
		ZLog::ErrorV(">>> Can't find app's Info.plist! %s\n", m_strAppFolder.c_str());
		return false;
	}

	if (!strBundleId.empty()) {
		string strOldBundleId = jvInfo["CFBundleIdentifier"];
		jvInfo["CFBundleIdentifier"] = strBundleId;
		ZLog::PrintV(">>> BundleId: \t%s -> %s\n", strOldBundleId.c_str(), strBundleId.c_str());
		ModifyPluginsBundleId(strOldBundleId, strBundleId);
	}

	if (!strDisplayName.empty()) {

		string strNewDisplayName = strDisplayName;

#ifdef _WIN32
		iconv ic;
		strNewDisplayName = ic.A2U8(strDisplayName);
#endif

		string strOldDisplayName = jvInfo["CFBundleDisplayName"];
		if (strOldDisplayName.empty()) {
			strOldDisplayName = jvInfo["CFBundleName"].as_cstr();
		}

		jvInfo["CFBundleName"] = strNewDisplayName;
		jvInfo["CFBundleDisplayName"] = strNewDisplayName;

		jvalue jvInfoStrings;
		if (jvInfoStrings.read_plist_from_file("%s/zh_CN.lproj/InfoPlist.strings", m_strAppFolder.c_str())) {
			jvInfoStrings["CFBundleName"] = strNewDisplayName;
			jvInfoStrings["CFBundleDisplayName"] = strNewDisplayName;
			jvInfoStrings.style_write_plist_to_file("%s/zh_CN.lproj/InfoPlist.strings", m_strAppFolder.c_str());
		}

		jvInfoStrings.clear();
		if (jvInfoStrings.read_plist_from_file("%s/zh-Hans.lproj/InfoPlist.strings", m_strAppFolder.c_str())) {
			jvInfoStrings["CFBundleName"] = strNewDisplayName;
			jvInfoStrings["CFBundleDisplayName"] = strNewDisplayName;
			jvInfoStrings.style_write_plist_to_file("%s/zh-Hans.lproj/InfoPlist.strings", m_strAppFolder.c_str());
		}

#ifdef _WIN32
		strOldDisplayName = ic.U82A(strOldDisplayName);
		strNewDisplayName = ic.U82A(strNewDisplayName);
#endif

		ZLog::PrintV(">>> BundleName: %s -> %s\n", strOldDisplayName.c_str(), strNewDisplayName.c_str());
	}

	if (!strBundleVersion.empty()) {
		string strOldBundleVersion = jvInfo["CFBundleVersion"];
		jvInfo["CFBundleVersion"] = strBundleVersion;
		jvInfo["CFBundleShortVersionString"] = strBundleVersion;
		ZLog::PrintV(">>> BundleVersion: %s -> %s\n", strOldBundleVersion.c_str(), strBundleVersion.c_str());
	}

	jvInfo.style_write_plist_to_file("%s/Info.plist", m_strAppFolder.c_str());
	return true;
}

void ZBundle::ApplyAppModifications()
{

	if (m_bEnableDocuments) {
		jvalue jvInfo;
		jvInfo.read_plist_from_file("%s/Info.plist", m_strAppFolder.c_str());
		jvInfo["UISupportsDocumentBrowser"] = true;
		jvInfo["UIFileSharingEnabled"] = true;
		jvInfo.style_write_plist_to_file("%s/Info.plist", m_strAppFolder.c_str());
		m_bForceSign = true;
		ZLog::Print(">>> Enabled documents support\n");
	}

	if (!m_strMinVersion.empty()) {
		jvalue jvInfo;
		jvInfo.read_plist_from_file("%s/Info.plist", m_strAppFolder.c_str());
		string strOldVersion = jvInfo["MinimumOSVersion"];
		jvInfo["MinimumOSVersion"] = m_strMinVersion;
		jvInfo.style_write_plist_to_file("%s/Info.plist", m_strAppFolder.c_str());
		m_bForceSign = true;
		ZLog::PrintV(">>> MinimumOSVersion: %s -> %s\n", strOldVersion.c_str(), m_strMinVersion.c_str());
	}

	if (m_bRemoveExtensions) {
		const char* extDirs[] = {"PlugIns", "Extensions"};
		for (const char* dir : extDirs) {
			string strPath = m_strAppFolder + "/" + dir;
			if (ZFile::IsFolder(strPath.c_str())) {
				ZFile::RemoveFolder(strPath.c_str());
				ZLog::PrintV(">>> Removed %s\n", dir);
				m_bForceSign = true;
			}
		}
	}

	if (m_bRemoveWatchApp) {
		const char* watchDirs[] = {"Watch", "WatchKit", "com.apple.WatchPlaceholder"};
		for (const char* dir : watchDirs) {
			string strPath = m_strAppFolder + "/" + dir;
			if (ZFile::IsFolder(strPath.c_str())) {
				ZFile::RemoveFolder(strPath.c_str());
				ZLog::PrintV(">>> Removed %s\n", dir);
				m_bForceSign = true;
			}
		}
	}

	if (m_bRemoveUISupportedDevices) {
		jvalue jvInfo;
		jvInfo.read_plist_from_file("%s/Info.plist", m_strAppFolder.c_str());
		if (jvInfo.has("UISupportedDevices")) {
			jvInfo.erase("UISupportedDevices");
			jvInfo.style_write_plist_to_file("%s/Info.plist", m_strAppFolder.c_str());
			m_bForceSign = true;
			ZLog::Print(">>> Removed UISupportedDevices\n");
		}
	}
}

bool ZBundle::SignFolder(ZSignAsset* pSignAsset,
							const string& strFolder,
							const string& strBundleId,
							const string& strBundleVersion,
							const string& strDisplayName,
							const vector<string>& arrInjectDylibs,
							const vector<string>& arrRemoveDylibNames,
							bool bForce,
							bool bWeakInject,
							bool bEnableCache,
							bool bRemoveProvision)
{
	m_bForceSign = bForce;
	m_pSignAsset = pSignAsset;
	m_indexedFiles.clear();
	m_indexedFolders.clear();
	m_bWeakInject = bWeakInject;
	m_bRemoveProvision = bRemoveProvision;
	m_setRemoveDylibs.clear();
	for (const string& name : arrRemoveDylibNames) {
		if (name.find('/') != string::npos) {
			m_setRemoveDylibs.insert(name);
		} else {
			m_setRemoveDylibs.insert("@executable_path/" + name);
		}
	}
	if (NULL == m_pSignAsset) {
		return false;
	}

	if (!FindAppFolder(strFolder, m_strAppFolder)) {
		ZLog::ErrorV(">>> Can't find app folder! %s\n", strFolder.c_str());
		return false;
	}

	ApplyAppModifications();

	if (!m_strIconFile.empty()) {
		m_bForceSign = true;
		if (!ChangeAppIcon()) {
			return false;
		}
	}

	if (!strBundleId.empty() || !strDisplayName.empty() || !strBundleVersion.empty()) {
		m_bForceSign = true;
		if (!ModifyBundleInfo(strBundleId, strBundleVersion, strDisplayName)) {
			return false;
		}
	}

	ZFile::RemoveFileV("%s/embedded.mobileprovision", m_strAppFolder.c_str());
	if (!pSignAsset->m_strProvData.empty()) {
		if (!ZFile::WriteFileV(pSignAsset->m_strProvData, "%s/embedded.mobileprovision", m_strAppFolder.c_str())) { // embedded.mobileprovision
			ZLog::ErrorV(">>> Can't write embedded.mobileprovision!\n");
			return false;
		}
	}

	if (!arrInjectDylibs.empty()) {
		m_bForceSign = true;
		for (const string& strDylibFile : arrInjectDylibs) {
			string strFileName = ZUtil::GetBaseName(strDylibFile.c_str());
			if (ZFile::CopyFileV(strDylibFile.c_str(), "%s/%s", m_strAppFolder.c_str(), strFileName.c_str())) {
				m_arrInjectDylibs.push_back("@executable_path/" + strFileName);
				m_arrInjectDylibNames.push_back(strFileName);
			}
		}
	}

	string strCacheName;
	ZSHA::SHA1Text(m_strAppFolder, strCacheName);
	if (!ZFile::IsFileExistsV("./.zsign_cache/%s.json", strCacheName.c_str())) {
		m_bForceSign = true;
	}

	jvalue jvRoot;
	if (m_bForceSign) {
		if (!BuildFileIndex()) {
			ZLog::ErrorV(">>> Can't index app folder! %s\n", m_strAppFolder.c_str());
			return false;
		}
		jvRoot["path"] = "/";
		jvRoot["root"] = m_strAppFolder;
		if (!GetSignFolderInfo(m_strAppFolder, jvRoot, true)) {
			ZLog::ErrorV(">>> Can't get BundleID, BundleVersion, or BundleExecute in Info.plist! %s\n", m_strAppFolder.c_str());
			return false;
		}
		if (!GetObjectsToSign(m_strAppFolder, jvRoot)) {
			return false;
		}
		GetNodeChangedFiles(jvRoot);
	} else {
		jvRoot.read_from_file("./.zsign_cache/%s.json", strCacheName.c_str());
	}

	string strAppName = jvRoot["name"];

#ifdef _WIN32
	iconv ic;
	strAppName = ic.U82A(strAppName);
#endif

	ZLog::PrintV(">>> Signing: \t%s ...\n", m_strAppFolder.c_str());
	ZLog::PrintV(">>> AppName: \t%s\n", strAppName.c_str());
	ZLog::PrintV(">>> BundleId: \t%s\n", jvRoot["bundle_id"].as_cstr());
	ZLog::PrintV(">>> Version: \t%s\n", jvRoot["bundle_version"].as_cstr());
	ZLog::PrintV(">>> TeamId: \t%s\n", m_pSignAsset->m_strTeamId.c_str());
	ZLog::PrintV(">>> SubjectCN: \t%s\n", m_pSignAsset->m_strSubjectCN.c_str());
	ZLog::PrintV(">>> ReadCache: \t%s\n", m_bForceSign ? "NO" : "YES");

	if (SignNode(jvRoot)) {
		if (bEnableCache) {
			ZFile::CreateFolder("./.zsign_cache");
			jvRoot.style_write_to_file("./.zsign_cache/%s.json", strCacheName.c_str());
		}
		return true;
	}

	return false;
}

bool ZBundle::SignFolder(list<ZSignAsset>* pSignAssets,
						const string& strFolder,
						const string& strBundleId,
						const string& strBundleVersion,
						const string& strDisplayName,
						const vector<string>& arrInjectDylibs,
						const vector<string>& arrRemoveDylibNames,
						bool bForce,
						bool bWeakInject,
						bool bEnableCache,
						bool bRemoveProvision)
{
	m_pSignAssets = pSignAssets;
	return SignFolder(&m_pSignAssets->front(), strFolder, strBundleId, strBundleVersion, strDisplayName, arrInjectDylibs, arrRemoveDylibNames, bForce, bWeakInject, bEnableCache, bRemoveProvision);
}
