#pragma once
#include "common.h"
#include "json.h"
#include "openssl.h"
#include <vector>
#include <list>
#include <set>
#include <map>
#include <stdint.h>
#include <unordered_map>
#include <unordered_set>

class ZBundle
{
public:
	ZBundle();
	~ZBundle();
	ZBundle(const ZBundle&) = delete;
	ZBundle& operator=(const ZBundle&) = delete;

public:
	void SetCloudEntitlementPolicy(const map<string, vector<string>>& policy) { m_cloudEntitlementPolicy = policy; }
	void SetArchiveBacking(const string& archivePath,
						 const string& archiveRootPath,
						 const vector<string>& deletedPaths,
						 string manifest = "", string resourceDigests = "");

	bool SignFolder(ZSignAsset* pSignAsset,
					const string& strFolder,
					const string& strBundleId,
					const string& strBundleVersion,
					const string& strDisplayName,
					const vector<string>& arrDylibFiles,
					const vector<string>& arrRemoveDylibNames,
					bool bForce,
					bool bWeakInject,
					bool bEnableCache,
					bool bRemoveProvision = false);

	bool SignFolder(list<ZSignAsset>* pSignAssets,
					const string& strFolder,
					const string& strBundleId,
					const string& strBundleVersion,
					const string& strDisplayName,
					const vector<string>& arrDylibFiles,
					const vector<string>& arrRemoveDylibNames,
					bool bForce,
					bool bWeakInject,
					bool bEnableCache,
					bool bRemoveProvision = false);

private:
	bool SignNode(jvalue& jvNode, vector<function<bool()>>* deferred = NULL);
    bool CanSignConcurrently(const jvalue& node) const;
	void GetNodeChangedFiles(jvalue& jvNode);
	void GetChangedFiles(jvalue& jvNode, vector<string>& arrChangedFiles);
	bool ModifyPluginsBundleId(const string& strOldBundleId, const string& strNewBundleId);
	bool ModifyBundleInfo(const string& strBundleId, const string& strBundleVersion, const string& strDisplayName);
	bool ChangeAppIcon();

private:
	bool FindAppFolder(const string& strFolder, string& strAppFolder);
	bool BuildFileIndex();
	void CloseArchiveReaders();
	bool AddArchiveFileIndex();
	bool SeedArchiveResourceDigests();
	void EnsureIndexedFile(const string& strFile, bool overlay = false);
	bool IndexOverlayFile(const string& strFile);
	bool HasOverlayPath(const string& strPath) const;
	void ForgetIndexedFile(const string& strFile);
	bool IsArchiveDeleted(const string& relativePath) const;
	bool GetLogicalSymbolicLinkTarget(const string& strPath, string& strTarget) const;
	bool HashLogicalFile(const string& strPath, string& strSHA1Base64, string& strSHA256Base64, void* archiveReader = NULL) const;
	bool GetObjectsToSign(const string& strFolder, jvalue& jvInfo);
	bool GetSignFolderInfo(const string& strFolder, jvalue& jvNode, bool bGetName = false);

private:
	bool GenerateCodeResources(const string& strFolder, const string& strBundleExe, string& output);

private:
	bool			m_bForceSign;
	bool			m_bWeakInject;
	bool			m_bRemoveProvision;
	ZSignAsset*		m_pSignAsset;
	list<ZSignAsset>*	m_pSignAssets;
	vector<string>	m_arrInjectDylibs;
	vector<string>	m_arrInjectDylibNames;
	set<string>		m_setRemoveDylibs;
	vector<string>	m_indexedFiles;
	vector<string>	m_indexedFolders;
	unordered_set<string> m_indexedFileSet;
	unordered_set<string> m_indexedFolderSet;
	map<string, vector<string>> m_cloudEntitlementPolicy;
	set<string> m_sortedFiles;
	struct OverlayFile {
		bool isSymlink = false;
		string symlinkTarget;
	};
	unordered_map<string, OverlayFile> m_overlayFiles;
	unordered_set<string> m_overlayFolders;
	unordered_set<string> m_overlayFoldedPaths;
	struct ResourceDigest {
		string sha1;
		string sha256;
	};
	// Only accessed by the signing thread, between parallel hashing batches.
	unordered_map<string, ResourceDigest> m_resourceDigests;
	vector<void*> m_archiveReaders;

	struct ArchiveEntry {
		int64_t cdPosition = -1;
		bool isSymlink = false;
		string symlinkTarget;
	};
	string			m_strArchivePath;
	string			m_strArchiveRootPath;
	string m_archiveManifest;
	string m_archiveResourceDigests;
	set<string>		m_setArchiveDeletedPaths;
	map<string, ArchiveEntry> m_archiveEntries;

private:
	void ApplyAppModifications();

public:
	bool		m_bEnableDocuments;
	string		m_strMinVersion;
	string		m_strIconFile;
	bool		m_bRemoveExtensions;
	bool		m_bRemoveWatchApp;
	bool		m_bRemoveUISupportedDevices;
	bool		m_bInjectExtensions;
	string			m_strAppFolder;
};
