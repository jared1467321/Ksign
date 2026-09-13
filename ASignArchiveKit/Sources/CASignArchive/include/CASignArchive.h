#ifndef CASIGN_ARCHIVE_H
#define CASIGN_ARCHIVE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*asign_archive_progress_cb)(double progress, void *userdata);

/// Extracts a ZIP-compatible archive into destination_path.
/// Existing files are overwritten. Returns a minizip-ng status code (0 on success).
int32_t asign_archive_extract(
    const char *archive_path,
    const char *destination_path,
    asign_archive_progress_cb progress_cb,
    void *userdata
);

/// Creates a ZIP archive containing source_path, preserving source_path's basename.
/// compression_level follows zlib/minizip semantics: 0=store, 1=fast, -1=default, 9=best.
/// total_uncompressed_size is used only for byte-accurate progress reporting.
/// Returns a minizip-ng status code (0 on success).
int32_t asign_archive_create(
    const char *archive_path,
    const char *source_path,
    int16_t compression_level,
    int64_t total_uncompressed_size,
    asign_archive_progress_cb progress_cb,
    void *userdata
);

#ifdef __cplusplus
}
#endif

#endif /* CASIGN_ARCHIVE_H */
