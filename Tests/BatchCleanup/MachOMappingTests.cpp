#include "common.h"
#include "macho.h"
#include <fstream>

// Linux host regression: exercise the production mapper/parser and inspect
// actual VM mappings, rather than relying on heap-leak detection for mmap.
static size_t mappings(const string& path)
{
    std::ifstream maps("/proc/self/maps");
    assert(maps.is_open());
    size_t count = 0;
    string line;
    while (std::getline(maps, line)) {
        if (line.find(path) != string::npos) ++count;
    }
    return count;
}

int main()
{
    char path[] = "/tmp/ksign-mapping-test-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    mach_header_64 header = {};
    header.magic = MH_MAGIC_64;
    header.filetype = MH_EXECUTE;
    assert(write(fd, &header, sizeof(header)) == sizeof(header));
    close(fd);

    for (int i = 0; i < 100; ++i) {
        {
            ZMachO macho;
            assert(macho.Init(path));
            assert(mappings(path) == 1);
            const bool freed = macho.Free();
            assert(mappings(path) == 0);
            assert(freed);
            assert(macho.Free());
            assert(macho.Init(path));
            assert(macho.Init(path)); // Reopening must release the old mapping.
            assert(mappings(path) == 1);
        }
        assert(mappings(path) == 0); // Destructor without explicit Free.
    }

    fd = open(path, O_WRONLY);
    assert(fd >= 0);
    header.magic = 0;
    assert(write(fd, &header, sizeof(header)) == sizeof(header));
    close(fd);
    {
        ZMachO macho;
        assert(!macho.Init(path));
    }
    assert(mappings(path) == 0); // Failed initialization also owns a mapping.
    unlink(path);
    puts("Mach-O mapping cleanup: passed");
}
