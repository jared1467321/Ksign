#include "bundle.h"
#include "macho.h"
#include "CASignArchive.h"
#include "mz.h"
#include "mz_zip.h"
#include <stdexcept>
#include <openssl/sha.h>
#include <openssl/evp.h>
#include "signing.h"
#include <openssl/cms.h>
#include <openssl/pem.h>
#include <openssl/pkcs12.h>

// Test-only linker wrappers count archive reads without instrumenting the app.
static mutex readMutex;
static map<string, size_t> resourceReads;
static bool countReads = false;
static atomic<size_t> readerOpens(0);
static atomic<size_t> directorySteps(0);
static atomic<size_t> resourceStats(0);
static atomic<size_t> sealMaps(0);
static set<thread::id> binaryMapThreads;
static bool countExtraction = false;
static atomic<size_t> extractionReaderOpens(0);
static set<thread::id> extractionThreads;

extern "C" int __real_lstat(const char*, struct stat*);
extern "C" int __wrap_lstat(const char* path, struct stat* st)
{
	if (countReads && ZFile::IsPathSuffix(path, ".dat")) resourceStats++;
	return __real_lstat(path, st);
}

extern "C" int32_t __real_mz_zip_reader_goto_next_entry(void*);
extern "C" int32_t __wrap_mz_zip_reader_goto_next_entry(void* reader)
{
	if (countReads) directorySteps++;
	return __real_mz_zip_reader_goto_next_entry(reader);
}

extern "C" int32_t __real_mz_zip_reader_open_file(void*, const char*);
extern "C" int32_t __wrap_mz_zip_reader_open_file(void* reader, const char* path)
{
	if (countReads) readerOpens++;
	if (countExtraction) extractionReaderOpens++;
	return __real_mz_zip_reader_open_file(reader, path);
}

extern "C" int32_t __real_mz_zip_entry_read_open(void*, uint8_t, const char*);
extern "C" int32_t __wrap_mz_zip_entry_read_open(void* handle, uint8_t raw, const char* password)
{
	if (countExtraction) {
		lock_guard<mutex> lock(readMutex);
		extractionThreads.insert(this_thread::get_id());
	}
	if (countReads && !raw) {
		mz_zip_file* info = nullptr;
		if (MZ_OK == mz_zip_entry_get_info(handle, &info) && info && info->filename &&
			ZFile::IsPathSuffix(info->filename, ".dat")) {
			lock_guard<mutex> lock(readMutex);
			resourceReads[info->filename]++;
		}
	}
	return __real_mz_zip_entry_read_open(handle, raw, password);
}

// Count actual code-page hashing, rather than adding production timings.
static atomic<size_t> pageSHA1(0), pageSHA256(0);
static bool countPages = false;
static atomic<size_t> rootParses(0);
static atomic<size_t> digestContexts(0);
extern "C" EVP_MD_CTX* __real_EVP_MD_CTX_new();
extern "C" EVP_MD_CTX* __wrap_EVP_MD_CTX_new() {
    if (countPages) digestContexts++;
    return __real_EVP_MD_CTX_new();
}
extern "C" int __real_EVP_DigestUpdate(EVP_MD_CTX*, const void*, size_t);
extern "C" int __wrap_EVP_DigestUpdate(EVP_MD_CTX* ctx, const void* bytes, size_t size) {
    if (countPages && size == 4096) {
        int type = EVP_MD_CTX_get_type(ctx);
        if (type == NID_sha1) pageSHA1++;
        if (type == NID_sha256) pageSHA256++;
    }
    return __real_EVP_DigestUpdate(ctx, bytes, size);
}
static atomic<size_t> patchMaps(0);
static bool countPatchMaps = false;
extern "C" void* __real_mmap(void*, size_t, int, int, int, off_t);
extern "C" void* __wrap_mmap(void* address, size_t length, int prot, int flags, int fd, off_t offset) {
    if (countPatchMaps) patchMaps++;
    if (countReads) {
        char path[4096] = {};
        const string link = "/proc/self/fd/" + to_string(fd);
        if (readlink(link.c_str(), path, sizeof(path) - 1) > 0) {
            if (ZFile::IsPathSuffix(path, "/_CodeSignature/CodeResources")) sealMaps++;
            if (ZFile::IsPathSuffix(path, ".dylib")) {
                lock_guard<mutex> lock(readMutex);
                binaryMapThreads.insert(this_thread::get_id());
            }
        }
    }
    return __real_mmap(address, length, prot, flags, fd, offset);
}

static atomic<size_t> p12Parses(0);
extern "C" int __real_PKCS12_parse(PKCS12*, const char*, EVP_PKEY**, X509**, STACK_OF(X509)**);
extern "C" int __wrap_PKCS12_parse(PKCS12* p12, const char* password, EVP_PKEY** key, X509** cert, STACK_OF(X509)** chain) {
    p12Parses++;
    return __real_PKCS12_parse(p12, password, key, cert, chain);
}

static void CheckPreparedMetadata() {
    ZSignAsset asset;
    assert(asset.Init("", "", "", "", "", true, false, false));
    auto entitlement = [](const string& value) { return "<plist><dict><key>value</key><string>" + value + "</string></dict></plist>"; };
    asset.m_strEntitleData = entitlement("first");
    const auto& first = asset.PreparedEntitlements(true);
    assert(first.xml.data.find("first") != string::npos);
    assert(&first == &asset.PreparedEntitlements(true));
    assert(asset.PreparedEntitlements(false).xml.data.find("first") == string::npos);
    asset.m_strEntitleData = entitlement("second");
    const auto& second = asset.PreparedEntitlements(true);
    assert(second.xml.data.find("second") != string::npos && second.xml.data.find("first") == string::npos);
    string sha1, sha256; ZSHA::SHA(second.xml.data, sha1, sha256);
    assert(second.xml.sha1 == sha1 && second.xml.sha256 == sha256);
    asset.m_strSubjectCN = "First certificate";
    const string requirement = asset.PreparedRequirements("test.first").data;
    assert(requirement != asset.PreparedRequirements("test.second").data);
    asset.m_strSubjectCN = "Second certificate";
    assert(requirement != asset.PreparedRequirements("test.first").data);
    assert(asset.Init("", "", "", "", "", true, true, false));
    assert(asset.PreparedEntitlements(true).xml.data.empty());
}

static void CheckPatches(const string& sequential, const string& batched) {
    const string oldPath = "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate";
    const string newPath = "@rpath/CydiaSubstrate.framework/CydiaSubstrate";
    { ZMachO macho; assert(macho.Init(sequential.c_str())); assert(macho.InjectDylib(true, oldPath.c_str())); assert(macho.Free()); }
    string original; assert(ZFile::ReadFile(sequential.c_str(), original));
    assert(ZFile::WriteFile(batched.c_str(), original));
    vector<string> injections = {"@executable_path/A.dylib", "@executable_path/A.dylib", "@executable_path/B.dylib"};
    patchMaps = 0; countPatchMaps = true;
    { ZMachO macho; assert(macho.Init(sequential.c_str())); assert(macho.ChangeDylibPath(oldPath.c_str(), newPath.c_str())); assert(macho.Free()); }
    for (const string& path : injections) {
        ZMachO macho; assert(macho.Init(sequential.c_str())); assert(macho.InjectDylib(true, path.c_str())); assert(macho.Free());
    }
    countPatchMaps = false; assert(patchMaps == 4);
    patchMaps = 0; countPatchMaps = true;
    { ZMachO macho; assert(macho.Init(batched.c_str())); assert(macho.PatchDylibs({{oldPath, newPath}}, injections, true)); assert(macho.Free()); }
    countPatchMaps = false; assert(patchMaps == 1);
    string expected, actual;
    assert(ZFile::ReadFile(sequential.c_str(), expected) && ZFile::ReadFile(batched.c_str(), actual));
    assert(expected == actual);
}

extern "C" X509* __real_PEM_read_bio_X509(BIO*, X509**, pem_password_cb*, void*);
extern "C" X509* __wrap_PEM_read_bio_X509(BIO* bio, X509** cert, pem_password_cb* cb, void* ctx) {
    rootParses++;
    return __real_PEM_read_bio_X509(bio, cert, cb, ctx);
}

static void SignBinary(const string& path, ZSignAsset& asset, size_t pages) {
    struct stat before = {};
    assert(stat(path.c_str(), &before) == 0);
    ZMachO macho;
    assert(macho.Init(path.c_str()));
    pageSHA1 = 0; pageSHA256 = 0; digestContexts = 0; countPages = true;
    assert(macho.Sign(&asset, true, "test.binary", "", "", ""));
    countPages = false;
    assert(pageSHA1 == (asset.m_bSHA256Only ? 0 : pages) && pageSHA256 == pages);
    const size_t slices = pages / 256;
    assert(digestContexts <= slices * ZUtil::GetWorkerCount(256) * (asset.m_bSHA256Only ? 1 : 2));
    struct stat after = {};
    assert(stat(path.c_str(), &after) == 0);
    assert((before.st_mode & 07777) == (after.st_mode & 07777));
    // Thin signature growth keeps the existing inode, including hard links.
    if (pages == 256) assert(before.st_ino == after.st_ino);
}

static void CheckCMS(const string& p12, const string& provision, const string& binary) {
    ZSignAsset asset;
    assert(asset.Init("", p12, provision, "", "test", false, false, false));
    rootParses = 0;
    size_t bound = asset.CMSSignatureSizeBound();
    assert(bound > 0 && rootParses == 2);
    string data(12000, 'd'), cd1(20, 'a'), cd256(32, 'b'), cms;
    for (int i = 0; i < 20; i++) {
        assert(asset.GenerateCMS(data, "<plist><dict/></plist>", cd1, cd256, cms));
        assert(cms.size() + 8 <= bound);
        const unsigned char* cursor = (const unsigned char*)cms.data();
        auto parsed = unique_ptr<CMS_ContentInfo, decltype(&CMS_ContentInfo_free)>(
            d2i_CMS_ContentInfo(NULL, &cursor, cms.size()), CMS_ContentInfo_free);
        auto content = unique_ptr<BIO, decltype(&BIO_free)>(BIO_new_mem_buf(data.data(), data.size()), BIO_free);
        assert(parsed && content);
        assert(CMS_verify(parsed.get(), NULL, NULL, content.get(), NULL,
            CMS_NO_SIGNER_CERT_VERIFY | CMS_BINARY) == 1);
    }
    assert(rootParses == 2); // chain parsed once across all signatures
    SignBinary(binary, asset, 256);
    assert(rootParses == 2);
    p12Parses = 0;
    ZSignAsset retained;
    {
        ZSignSession session;
        for (int i = 0; i < 8; i++) {
            ZSignAsset copy;
            assert(session.InitAsset(copy, p12, provision, "", "test", false));
            assert(copy.m_strTeamId == asset.m_strTeamId && copy.m_strEntitleData == asset.m_strEntitleData);
            copy.m_strEntitleData = "<plist><dict/></plist>";
        }
        assert(p12Parses == 1);
        assert(session.InitAsset(retained, p12, provision, "", "test", false));
        assert(retained.m_strEntitleData == asset.m_strEntitleData);
        ZSignAsset invalid;
        assert(!session.InitAsset(invalid, p12, provision, "", "wrong password", false));
        string original;
        assert(ZFile::ReadFile(provision.c_str(), original));
        assert(ZFile::WriteFile(provision.c_str(), "changed provision"));
        assert(!session.InitAsset(invalid, p12, provision, "", "test", false));
        assert(ZFile::WriteFile(provision.c_str(), original));
        assert(session.InitAsset(retained, p12, provision, "", "test", false));
        assert(p12Parses == 3); // original, wrong password, restored input
    }
    // Ref-counted credentials survive the batch and maintain a valid CMS.
    assert(retained.GenerateCMS(data, "<plist><dict/></plist>", cd1, cd256, cms));
    const unsigned char* cursor = (const unsigned char*)cms.data();
    CMS_ContentInfo* parsed = d2i_CMS_ContentInfo(NULL, &cursor, cms.size());
    BIO* content = BIO_new_mem_buf(data.data(), data.size());
    assert(parsed && content && CMS_verify(parsed, NULL, NULL, content, NULL, CMS_NO_SIGNER_CERT_VERIFY | CMS_BINARY) == 1);
    CMS_ContentInfo_free(parsed); BIO_free(content);
    vector<shared_ptr<ZSignAsset>> lanes;
    for (size_t i = 0; i < ZUtil::GetWorkerCount(6); i++) {
        auto copy = make_shared<ZSignAsset>();
        assert(copy->CloneFrom(retained));
        lanes.push_back(copy);
    }
    ZUtil::ParallelFor(24, lanes.size(), [&](size_t, size_t lane) {
        string output;
        assert(lanes[lane]->GenerateCMS(data, "<plist><dict/></plist>", cd1, cd256, output));
        const unsigned char* bytes = (const unsigned char*)output.data();
        CMS_ContentInfo* signedCMS = d2i_CMS_ContentInfo(NULL, &bytes, output.size());
        BIO* input = BIO_new_mem_buf(data.data(), data.size());
        assert(signedCMS && input && CMS_verify(signedCMS, NULL, NULL, input, NULL, CMS_NO_SIGNER_CERT_VERIFY | CMS_BINARY) == 1);
        CMS_ContentInfo_free(signedCMS); BIO_free(input);
    });
    // Reinitializing must release/reset the previous credentials and chain.
    assert(asset.Init("", "", "", "", "", true, true, false));
    assert(asset.CMSSignatureSizeBound() == 0);
}

static void CheckPool()
{
	auto checkBatch = []() {
		for (size_t count : {size_t(0), size_t(1), size_t(7), size_t(4099)}) {
			vector<atomic<int>> visits(count);
			for (auto& visit : visits) visit.store(0);
			ZUtil::ParallelFor(count, ZUtil::GetWorkerCount(count), [&](size_t i, size_t lane) {
				assert(lane < 6);
				visits[i]++;
			}, 16);
			for (auto& visit : visits) assert(visit == 1);
		}
	};
	vector<thread> callers;
	for (int i = 0; i < 4; i++) callers.emplace_back(checkBatch);
	for (auto& caller : callers) caller.join();
	atomic<int> nested(0);
	ZUtil::ParallelFor(8, 4, [&](size_t, size_t) {
		ZUtil::ParallelFor(8, 4, [&](size_t, size_t) { nested++; });
	});
	assert(nested == 64);
	bool caught = false;
	try {
		ZUtil::ParallelFor(32, 4, [](size_t i, size_t) {
			if (i == 3) throw runtime_error("test task failure");
		});
	} catch (const runtime_error&) {
		caught = true;
	}
	assert(caught);
	checkBatch();
}

int main(int argc, char** argv)
{
    CheckPreparedMetadata();
    if (argc == 4 && string(argv[1]) == "--patches") { CheckPatches(argv[2], argv[3]); return 0; }
    if (argc == 5 && string(argv[1]) == "--cms") { CheckCMS(argv[2], argv[3], argv[4]); return 0; }
    if (argc == 4 && string(argv[1]) == "--binary") {
        ZSignAsset asset;
        assert(asset.Init("", "", "", "", "", true, string(argv[3]) == "sha256", false));
        if (string(argv[3]) == "large") asset.m_strEntitleData =
            "<plist><dict><key>large</key><string>" + string(70000, 'x') + "</string></dict></plist>";
        SignBinary(argv[2], asset, string(argv[3]) == "fat" ? 512 : 256);
        return 0;
    }

	if ((argc == 5 || argc == 6) && (string(argv[1]) == "--extract" || string(argv[1]) == "--plan")) {
		asign_archive_index* index = nullptr;
		int32_t result = asign_archive_index_open(argv[2], &index);
        uint8_t* digests = nullptr; size_t digestSize = 0;
		if (result == MZ_OK) result = asign_archive_index_materialize_with_plan(index, "Payload/Test.app", argv[3],
			argc == 6 && string(argv[1]) == "--extract" ? 1 : 0, (uint32_t)strtoul(argv[4], nullptr, 10),
            argc == 6 && string(argv[1]) == "--plan" ? argv[5] : nullptr,
            argc == 6 && string(argv[1]) == "--plan" ? argv[5] : nullptr, &digests, &digestSize);
        if (result == MZ_OK && string(argv[1]) == "--plan")
            assert(ZFile::WriteFile((string(argv[3]) + "/digests.bin").c_str(), (const char*)digests, digestSize));
        asign_archive_free_buffer(digests);
		asign_archive_index_close(index);
		return result == MZ_OK ? 0 : 1;
	}
	CheckPool();
	if (argc != 5 && argc != 6) return 2;
	const string source = argv[1], destination = argv[2], overlay = argv[3], root = argv[4];
	const bool filesystem = argc == 6 && string(argv[5]) == "--filesystem";
    const string mode = argc == 6 ? argv[5] : "";
    const bool fused = mode == "--fused" || mode == "--fused-overlay" || mode == "--canonical";
    const bool overlayResource = mode == "--overlay" || mode == "--fused-overlay";
	const bool profiles = argc == 6 && string(argv[5]) == "--profiles";
	asign_archive_index* index = nullptr;
	assert(MZ_OK == asign_archive_index_open(source.c_str(), &index));
	size_t manifestSize = 0;
	const uint8_t* manifestBytes = asign_archive_index_manifest(index, &manifestSize);
	assert(manifestBytes != nullptr);
	const string manifest((const char*)manifestBytes, manifestSize);
    string resourceDigests;
	if (!filesystem) {
		countExtraction = true;
        uint8_t* digests = nullptr; size_t digestSize = 0;
		assert(MZ_OK == asign_archive_index_materialize_with_plan(index, root.c_str(), overlay.c_str(), 0,
			(uint32_t)ZUtil::GetWorkerCount(4), "Deleted\nembedded.mobileprovision",
            "Deleted",
            fused ? &digests : nullptr, fused ? &digestSize : nullptr));
        if (mode == "--canonical") assert(!ZFile::IsFileExists((overlay + "/Deleted/Old.dylib").c_str()));
        if (digests) resourceDigests.assign((const char*)digests, digestSize);
        asign_archive_free_buffer(digests);
		countExtraction = false;
		assert(extractionReaderOpens <= ZUtil::GetWorkerCount(4));
		assert(!extractionThreads.empty());
		if (ZUtil::GetWorkerCount(4) > 1) assert(extractionThreads.size() > 1);
	}
    if (overlayResource) assert(ZFile::WriteFile((overlay + "/root.dat").c_str(), "last duplicate wins edited"));
	// A direct dylib injection adds to the sparse overlay; resources stay in ZIP.
	assert(ZFile::IsFileExists((overlay + "/root.dat").c_str()) == (filesystem || overlayResource));
	ZFile::RemoveFolderV("%s/Deleted", overlay.c_str());
	ZFile::RemoveFolderV("%s/_CodeSignature", overlay.c_str());
	ZFile::RemoveFileV("%s/embedded.mobileprovision", overlay.c_str());
	string injected;
	assert(ZFile::ReadFile((overlay + "/Standalone.dylib").c_str(), injected));
	assert(ZFile::WriteFile((overlay + "/Injected.dylib").c_str(), injected));
	ZSignAsset asset;
	assert(asset.Init("", "", "", "", "", true, false, false));
	list<ZSignAsset> assets;
	if (profiles) {
		for (const string id : {"test.main", "test.framework", "test.extension", "test.nested", "test.versioned"}) {
			assets.emplace_back();
			assert(assets.back().Init("", "", "", "", "", true, false, false));
			assets.back().m_strApplicationId = "TEAM." + id;
			assets.back().m_strProvData = "profile:" + id;
		}
	}
	ZBundle bundle;
	if (!filesystem) bundle.SetArchiveBacking(source, root, {"Deleted", "embedded.mobileprovision"}, manifest, resourceDigests);
	for (int run = 0; run < 2; run++) {
		resourceReads.clear();
		readerOpens = 0;
		directorySteps = 0;
		resourceStats = 0;
        sealMaps = 0; binaryMapThreads.clear();
		countReads = true;
		assert(profiles ? bundle.SignFolder(&assets, overlay, "", "", "", {}, {}, true, false, false, false) :
			bundle.SignFolder(&asset, overlay, "", "", "", {}, {}, true, false, false, false));
		countReads = false;
        assert(sealMaps == 0); // Generated resource seals reuse their in-memory digests.
        if (mode == "--canonical" && ZUtil::GetWorkerCount(6) > 1) {
            // Parent sealing may mmap signed dylibs on the coordinator too.
            // At least one additional thread must have mapped the signing input.
            assert(binaryMapThreads.size() > 1);
        }
		assert(resourceReads.empty() == (filesystem || fused));
		for (const auto& resource : resourceReads) assert(resource.second == 1);
		// One index reader plus at most one retained reader per hashing lane.
		assert(readerOpens <= 1 + ZUtil::GetWorkerCount(6));
		assert(directorySteps == 0);
		if (!filesystem && !overlayResource) assert(resourceStats == 0);
	}
    if (fused) {
        ZBundle invalid;
        invalid.SetArchiveBacking(source, root, {"Deleted"}, manifest, "ASHSH001x");
        assert(!invalid.SignFolder(&asset, overlay, "", "", "", {}, {}, true, false, false, false));
    }
	assert(MZ_OK == asign_archive_index_rebuild(index, destination.c_str(), root.c_str(),
		overlay.c_str(), profiles ? "Deleted" : "Deleted\nembedded.mobileprovision", 1, 0, nullptr, nullptr));
	if (!filesystem) {
		bundle.SetArchiveBacking(source, root, {}, "ASIDX001truncated");
		assert(!bundle.SignFolder(&asset, overlay, "", "", "", {}, {}, true, false, false, false));
	}
	asign_archive_index_close(index);
	return 0;
}
