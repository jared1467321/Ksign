#include "bundle.h"
#include "CASignArchive.h"
#include "mz.h"
#include "mz_zip.h"
#include <stdexcept>

// Test-only linker wrappers count archive reads without instrumenting the app.
static mutex readMutex;
static map<string, size_t> resourceReads;
static bool countReads = false;
static atomic<size_t> readerOpens(0);
static atomic<size_t> directorySteps(0);
static atomic<size_t> resourceStats(0);
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
	if ((argc == 5 || argc == 6) && string(argv[1]) == "--extract") {
		asign_archive_index* index = nullptr;
		int32_t result = asign_archive_index_open(argv[2], &index);
		if (result == MZ_OK) result = asign_archive_index_materialize(index, "Payload/Test.app", argv[3],
			argc == 6 ? 1 : 0, (uint32_t)strtoul(argv[4], nullptr, 10));
		asign_archive_index_close(index);
		return result == MZ_OK ? 0 : 1;
	}
	CheckPool();
	if (argc != 5 && argc != 6) return 2;
	const string source = argv[1], destination = argv[2], overlay = argv[3], root = argv[4];
	const bool filesystem = argc == 6 && string(argv[5]) == "--filesystem";
	const bool profiles = argc == 6 && string(argv[5]) == "--profiles";
	asign_archive_index* index = nullptr;
	assert(MZ_OK == asign_archive_index_open(source.c_str(), &index));
	size_t manifestSize = 0;
	const uint8_t* manifestBytes = asign_archive_index_manifest(index, &manifestSize);
	assert(manifestBytes != nullptr);
	const string manifest((const char*)manifestBytes, manifestSize);
	if (!filesystem) {
		countExtraction = true;
		assert(MZ_OK == asign_archive_index_materialize(index, root.c_str(), overlay.c_str(), 0,
			(uint32_t)ZUtil::GetWorkerCount(4)));
		countExtraction = false;
		assert(extractionReaderOpens <= ZUtil::GetWorkerCount(4));
		assert(!extractionThreads.empty());
		if (ZUtil::GetWorkerCount(4) > 1) assert(extractionThreads.size() > 1);
	}
	// A direct dylib injection adds to the sparse overlay; resources stay in ZIP.
	assert(ZFile::IsFileExists((overlay + "/root.dat").c_str()) == filesystem);
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
	if (!filesystem) bundle.SetArchiveBacking(source, root, {"Deleted", "embedded.mobileprovision"}, manifest);
	for (int run = 0; run < 2; run++) {
		resourceReads.clear();
		readerOpens = 0;
		directorySteps = 0;
		resourceStats = 0;
		countReads = true;
		assert(profiles ? bundle.SignFolder(&assets, overlay, "", "", "", {}, {}, true, false, false, false) :
			bundle.SignFolder(&asset, overlay, "", "", "", {}, {}, true, false, false, false));
		countReads = false;
		assert(resourceReads.empty() == filesystem);
		for (const auto& resource : resourceReads) assert(resource.second == 1);
		// One index reader plus at most one retained reader per hashing lane.
		assert(readerOpens <= 1 + ZUtil::GetWorkerCount(6));
		assert(directorySteps == 0);
		if (!filesystem) assert(resourceStats == 0);
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
