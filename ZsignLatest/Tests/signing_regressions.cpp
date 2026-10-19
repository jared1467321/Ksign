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

extern "C" int32_t __real_mz_zip_reader_open_file(void*, const char*);
extern "C" int32_t __wrap_mz_zip_reader_open_file(void* reader, const char* path)
{
	if (countReads) readerOpens++;
	return __real_mz_zip_reader_open_file(reader, path);
}

extern "C" int32_t __real_mz_zip_entry_read_open(void*, uint8_t, const char*);
extern "C" int32_t __wrap_mz_zip_entry_read_open(void* handle, uint8_t raw, const char* password)
{
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
	CheckPool();
	if (argc != 5 && argc != 6) return 2;
	const string source = argv[1], destination = argv[2], overlay = argv[3], root = argv[4];
	const bool filesystem = argc == 6 && string(argv[5]) == "--filesystem";
	if (!filesystem) {
		assert(MZ_OK == asign_archive_materialize_signing_inputs(source.c_str(), root.c_str(), overlay.c_str(), 0));
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
	ZBundle bundle;
	if (!filesystem) bundle.SetArchiveBacking(source, root, {"Deleted", "embedded.mobileprovision"});
	for (int run = 0; run < 2; run++) {
		resourceReads.clear();
		readerOpens = 0;
		countReads = true;
		assert(bundle.SignFolder(&asset, overlay, "", "", "", {}, {}, true, false, false, false));
		countReads = false;
		assert(resourceReads.empty() == filesystem);
		for (const auto& resource : resourceReads) assert(resource.second == 1);
		// One index reader plus at most one retained reader per hashing lane.
		assert(readerOpens <= 1 + ZUtil::GetWorkerCount(6));
	}
	assert(MZ_OK == asign_archive_rebuild_with_overlay(source.c_str(), destination.c_str(), root.c_str(),
		overlay.c_str(), "Deleted\nembedded.mobileprovision", 1, 0, nullptr, nullptr));
	return 0;
}
