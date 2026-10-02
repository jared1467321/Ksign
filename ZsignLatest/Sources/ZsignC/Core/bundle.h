#pragma once
#include "common.h"
#include "json.h"
#include "openssl.h"
#include <vector>
#include <list>
#include <set>
#include <map>
#include <stdint.h>

class ZBundle
{
public:
	ZBundle();

public:
	void SetArchiveBacking(const string& archivePath,
						 const string& archiveRootPath,
						 const vector<string>& deletedPaths);

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
	bool SignNode(jvalue& jvNode);
	void GetNodeChangedFiles(jvalue& jvNode);
	void GetChangedFiles(jvalue& jvNode, vector<string>& arrChangedFiles);
	bool ModifyPluginsBundleId(const string& strOldBundleId, const string& strNewBundleId);
	bool ModifyBundleInfo(const string& strBundleId, const string& strBundleVersion, const string& strDisplayName);
	bool ChangeAppIcon();

private:
	bool FindAppFolder(const string& strFolder, string& strAppFolder);
	bool BuildFileIndex();
	bool AddArchiveFileIndex();
	void EnsureIndexedFile(const string& strFile);
	bool IsArchiveDeleted(const string& relativePath) const;
	bool GetLogicalSymbolicLinkTarget(const string& strPath, string& strTarget) const;
	bool HashLogicalFile(const string& strPath, string& strSHA1Base64, string& strSHA256Base64, void* archiveReader = NULL) const;
	bool GetObjectsToSign(const string& strFolder, jvalue& jvInfo);
	bool GetSignFolderInfo(const string& strFolder, jvalue& jvNode, bool bGetName = false);

private:
	bool GenerateCodeResources(const string& strFolder, jvalue& jvCodeRes);

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

	struct ArchiveEntry {
		int64_t cdPosition = -1;
		bool isSymlink = false;
		string symlinkTarget;
	};
	string			m_strArchivePath;
	string			m_strArchiveRootPath;
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
