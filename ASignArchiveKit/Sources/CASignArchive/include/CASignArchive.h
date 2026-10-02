#ifndef CASIGN_ARCHIVE_H
#define CASIGN_ARCHIVE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*asign_archive_progress_cb)(double progress, void *userdata);

/// Custom non-error result used by exact-entry/prefix helpers when no matching
/// ZIP member exists. All negative results remain minizip-ng status codes.
#define ASIGN_ARCHIVE_NOT_FOUND 1

typedef int32_t (*asign_archive_entry_cb)(
    const char *path,
    int64_t uncompressed_size,
    uint8_t is_directory,
    uint8_t is_symlink,
    void *userdata
);

/// Enumerates central-directory entries in archive order without extracting them.
/// Duplicate names are intentionally preserved in the callback stream.
int32_t asign_archive_enumerate_entries(
    const char *archive_path,
    asign_archive_entry_cb entry_cb,
    void *userdata
);

/// Reads the final occurrence of entry_path into a malloc-owned buffer. The
/// caller must release non-NULL output with asign_archive_free_buffer().
/// max_bytes prevents accidentally materializing large resources in memory.
int32_t asign_archive_read_entry(
    const char *archive_path,
    const char *entry_path,
    int64_t max_bytes,
    uint8_t **out_data,
    int64_t *out_size
);

/// Selectively extracts the final occurrence of one entry.
int32_t asign_archive_extract_entry(
    const char *archive_path,
    const char *entry_path,
    const char *destination_path
);

/// Selectively extracts an entry or subtree prefix into destination_path.
/// destination_path corresponds to prefix_path itself; descendants are placed
/// beneath it. Only matching members are inflated.
int32_t asign_archive_extract_prefix(
    const char *archive_path,
    const char *prefix_path,
    const char *destination_path
);

void asign_archive_free_buffer(void *buffer);

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

/// Materializes only files needed by the signing/modification pipeline from a
/// root app inside an IPA: every Info.plist, every Mach-O, symbolic links, and
/// optionally localized InfoPlist.strings. destination_app_path is the sparse
/// on-disk root corresponding to root_entry_path (for example Payload/Foo.app).
int32_t asign_archive_materialize_signing_inputs(
    const char *archive_path,
    const char *root_entry_path,
    const char *destination_app_path,
    uint8_t include_info_plist_strings
);

/// Builds a final IPA by raw-copying untouched members from source_archive_path,
/// replacing/adding files found in overlay_app_path, and omitting app-relative
/// paths listed in newline-delimited deleted_paths. When
/// omit_existing_code_signatures is non-zero, existing _CodeSignature entries
/// are omitted so regenerated sparse signatures replace them.
/// Replacement/new files use compression_level; untouched members keep their
/// original compressed bytes and ZIP metadata.
int32_t asign_archive_rebuild_with_overlay(
    const char *source_archive_path,
    const char *destination_archive_path,
    const char *root_entry_path,
    const char *overlay_app_path,
    const char *deleted_paths,
    uint8_t omit_existing_code_signatures,
    int16_t compression_level,
    asign_archive_progress_cb progress_cb,
    void *userdata
);

#ifdef __cplusplus
}
#endif

#endif /* CASIGN_ARCHIVE_H */
