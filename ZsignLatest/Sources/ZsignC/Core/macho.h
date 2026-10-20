#pragma once
#include "archo.h"

class ZMachO
{
public:
	ZMachO();
	~ZMachO();

public:
	bool Init(const char* szFile);
	bool InitV(const char* szPath, ...);
	bool Free();
	void PrintInfo();
	bool CheckSignature() const;
	bool Sign(ZSignAsset* pSignAsset,
				bool bForce, 
				string strBundleId, 
				string strInfoSHA1, 
				string strInfoSHA256, 
				const string& strCodeResourcesData,
                const ZSignAsset::PreparedBlob* resourceHashes = NULL);
	bool InjectDylib(bool bWeakInject, const char* szDylibFile);
	bool ChangeDylibPath(const char* oldPath, const char* newPath);
	bool PatchDylibs(const vector<pair<string, string>>& rewrites, const vector<string>& injections, bool weak);
	std::vector<std::string> ListDylibs();
	void RemoveDylibs(const set<string>& setDylibs);

private:
	bool OpenFile(const char* szPath);
	bool CloseFile();

	bool NewArchO(uint8_t* pBase, uint32_t uLength);
	void FreeArchOes();
	bool ReallocCodeSignSpace(const vector<uint32_t>& signatureSizes);

private:
	size_t			m_sSize;
	string			m_strFile;
	uint8_t*		m_pBase;
	vector<ZArchO*> m_arrArchOes;
};
