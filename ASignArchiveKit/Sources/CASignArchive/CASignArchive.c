#include "CASignArchive.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "mz.h"
#include "mz_strm.h"
#include "mz_zip.h"
#include "mz_zip_rw.h"

typedef struct asign_progress_state_s {
    asign_archive_progress_cb callback;
    void *userdata;
    int64_t total;
    int64_t completed;
    int64_t current_size;
} asign_progress_state;

static void asign_report_progress(asign_progress_state *state, int64_t current_position) {
    if (state == NULL || state->callback == NULL)
        return;

    double progress = 0.0;
    if (state->total > 0) {
        int64_t position = state->completed + current_position;
        if (position < 0)
            position = 0;
        if (position > state->total)
            position = state->total;
        progress = (double)position / (double)state->total;
    }

    state->callback(progress, state->userdata);
}

static int32_t asign_reader_entry_cb(void *handle, void *userdata, mz_zip_file *file_info, const char *path) {
    (void)handle;
    (void)path;

    asign_progress_state *state = (asign_progress_state *)userdata;
    if (state == NULL)
        return MZ_OK;

    state->completed += state->current_size;
    state->current_size = (file_info != NULL && file_info->uncompressed_size > 0)
        ? file_info->uncompressed_size
        : 0;
    asign_report_progress(state, 0);
    return MZ_OK;
}

static int32_t asign_reader_progress_cb(void *handle, void *userdata, mz_zip_file *file_info, int64_t position) {
    (void)handle;
    (void)file_info;
    asign_report_progress((asign_progress_state *)userdata, position);
    return MZ_OK;
}

static int32_t asign_reader_overwrite_cb(void *handle, void *userdata, mz_zip_file *file_info, const char *path) {
    (void)handle;
    (void)userdata;
    (void)file_info;
    (void)path;
    return MZ_OK;
}

static int32_t asign_writer_entry_cb(void *handle, void *userdata, mz_zip_file *file_info) {
    (void)handle;

    asign_progress_state *state = (asign_progress_state *)userdata;
    if (state == NULL)
        return MZ_OK;

    state->completed += state->current_size;
    // Stored symlinks have a link target but no regular-file payload. minizip-ng
    // reports the target file's stat() size before it switches to link storage,
    // so counting that value would make byte progress jump ahead incorrectly.
    state->current_size = (file_info != NULL && file_info->linkname == NULL && file_info->uncompressed_size > 0)
        ? file_info->uncompressed_size
        : 0;
    asign_report_progress(state, 0);
    return MZ_OK;
}

static int32_t asign_writer_progress_cb(void *handle, void *userdata, mz_zip_file *file_info, int64_t position) {
    (void)handle;
    (void)file_info;
    asign_report_progress((asign_progress_state *)userdata, position);
    return MZ_OK;
}

static int32_t asign_writer_overwrite_cb(void *handle, void *userdata, const char *path) {
    (void)handle;
    (void)userdata;
    (void)path;
    return MZ_OK;
}

static int32_t asign_writer_add_symlink(void *writer, const char *path, const char *root_path, int16_t compression_level) {
    struct stat st;
    if (lstat(path, &st) != 0)
        return MZ_READ_ERROR;
    if (!S_ISLNK(st.st_mode))
        return MZ_OK;

    size_t capacity = st.st_size > 0 ? (size_t)st.st_size + 1 : 256;
    char *target = NULL;
    ssize_t target_length = -1;

    for (;;) {
        char *grown = (char *)realloc(target, capacity + 1);
        if (grown == NULL) {
            free(target);
            return MZ_MEM_ERROR;
        }
        target = grown;

        target_length = readlink(path, target, capacity);
        if (target_length < 0) {
            free(target);
            return MZ_READ_ERROR;
        }
        if ((size_t)target_length < capacity)
            break;

        if (capacity > (SIZE_MAX / 2) - 1) {
            free(target);
            return MZ_MEM_ERROR;
        }
        capacity *= 2;
    }

    target[target_length] = '\0';

    size_t root_length = strlen(root_path);
    if (strncmp(path, root_path, root_length) != 0) {
        free(target);
        return MZ_PARAM_ERROR;
    }

    const char *filename_in_zip = path + root_length;
    while (*filename_in_zip == '/' || *filename_in_zip == '\\')
        filename_in_zip++;

    if (*filename_in_zip == '\0') {
        free(target);
        return MZ_PARAM_ERROR;
    }

    mz_zip_file file_info;
    memset(&file_info, 0, sizeof(file_info));

    // IPA symlinks use the conventional Info-ZIP representation: the entry
    // is marked as a POSIX symlink and its *payload* is the link target. Do
    // not set file_info.linkname here. minizip-ng uses linkname to emit its
    // UNIX1 (0x000d) extra-field representation with a zero-byte payload,
    // which MobileInstallation does not restore correctly for these apps.
    file_info.version_madeby = (uint16_t)((MZ_HOST_SYSTEM_OSX_DARWIN << 8) | 45);
    file_info.compression_method = compression_level == 0
        ? MZ_COMPRESS_METHOD_STORE
        : MZ_COMPRESS_METHOD_DEFLATE;
    file_info.filename = filename_in_zip;
    file_info.uncompressed_size = target_length;
    file_info.flag = MZ_ZIP_FLAG_UTF8;
    file_info.modified_date = st.st_mtime;
    file_info.accessed_date = st.st_atime;
    file_info.creation_date = st.st_ctime;

    uint32_t src_attrib = (uint32_t)st.st_mode;
    uint32_t dos_attrib = 0;
    if (mz_zip_attrib_convert(
            MZ_HOST_SYSTEM_OSX_DARWIN,
            src_attrib,
            MZ_HOST_SYSTEM_MSDOS,
            &dos_attrib
        ) == MZ_OK) {
        file_info.external_fa = dos_attrib;
    }
    file_info.external_fa |= (src_attrib << 16);

    int32_t err = mz_zip_writer_add_buffer(
        writer,
        target,
        (int32_t)target_length,
        &file_info
    );

    free(target);
    return err;
}

static int32_t asign_writer_add_symlinks_recursive(
    void *writer,
    const char *path,
    const char *root_path,
    int16_t compression_level
) {
    struct stat st;
    if (lstat(path, &st) != 0)
        return MZ_READ_ERROR;

    if (S_ISLNK(st.st_mode))
        return asign_writer_add_symlink(writer, path, root_path, compression_level);

    if (!S_ISDIR(st.st_mode))
        return MZ_OK;

    DIR *dir = opendir(path);
    if (dir == NULL)
        return MZ_OPEN_ERROR;

    int32_t err = MZ_OK;
    struct dirent *entry = NULL;

    while (err == MZ_OK && (entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;

        size_t path_length = strlen(path);
        size_t name_length = strlen(entry->d_name);
        int needs_slash = path_length > 0 && path[path_length - 1] != '/';
        size_t child_length = path_length + (needs_slash ? 1 : 0) + name_length + 1;

        char *child = (char *)malloc(child_length);
        if (child == NULL) {
            err = MZ_MEM_ERROR;
            break;
        }

        memcpy(child, path, path_length);
        size_t offset = path_length;
        if (needs_slash)
            child[offset++] = '/';
        memcpy(child + offset, entry->d_name, name_length + 1);

        err = asign_writer_add_symlinks_recursive(
            writer,
            child,
            root_path,
            compression_level
        );
        free(child);
    }

    closedir(dir);
    return err;
}

static int64_t asign_reader_total_size(void *reader, int32_t *status) {
    int64_t total = 0;
    int32_t err = mz_zip_reader_goto_first_entry(reader);

    if (err == MZ_END_OF_LIST) {
        *status = MZ_OK;
        return 0;
    }

    while (err == MZ_OK) {
        mz_zip_file *file_info = NULL;
        err = mz_zip_reader_entry_get_info(reader, &file_info);
        if (err != MZ_OK)
            break;

        if (file_info != NULL && file_info->uncompressed_size > 0) {
            if (INT64_MAX - total < file_info->uncompressed_size) {
                total = INT64_MAX;
            } else {
                total += file_info->uncompressed_size;
            }
        }

        err = mz_zip_reader_goto_next_entry(reader);
    }

    if (err == MZ_END_OF_LIST)
        err = MZ_OK;

    *status = err;
    return total;
}

int32_t asign_archive_extract(
    const char *archive_path,
    const char *destination_path,
    asign_archive_progress_cb progress_cb,
    void *userdata
) {
    if (archive_path == NULL || destination_path == NULL)
        return MZ_PARAM_ERROR;

    void *reader = mz_zip_reader_create();
    if (reader == NULL)
        return MZ_MEM_ERROR;

    int32_t err = mz_zip_reader_set_recover(reader, 1);
    if (err == MZ_OK)
        err = mz_zip_reader_open_file(reader, archive_path);

    asign_progress_state state = {
        .callback = progress_cb,
        .userdata = userdata,
        .total = 0,
        .completed = 0,
        .current_size = 0
    };

    if (err == MZ_OK) {
        state.total = asign_reader_total_size(reader, &err);
    }

    if (err == MZ_OK) {
        mz_zip_reader_set_overwrite_cb(reader, &state, asign_reader_overwrite_cb);
        mz_zip_reader_set_entry_cb(reader, &state, asign_reader_entry_cb);
        mz_zip_reader_set_progress_cb(reader, &state, asign_reader_progress_cb);
        mz_zip_reader_set_progress_interval(reader, 50);
        if (progress_cb != NULL)
            progress_cb(0.0, userdata);

        err = mz_zip_reader_save_all(reader, destination_path);
    }

    int32_t close_err = mz_zip_reader_close(reader);
    mz_zip_reader_delete(&reader);

    if (err == MZ_OK && close_err != MZ_OK)
        err = close_err;

    if (err == MZ_OK && progress_cb != NULL)
        progress_cb(1.0, userdata);

    return err;
}

int32_t asign_archive_create(
    const char *archive_path,
    const char *source_path,
    int16_t compression_level,
    int64_t total_uncompressed_size,
    asign_archive_progress_cb progress_cb,
    void *userdata
) {
    if (archive_path == NULL || source_path == NULL)
        return MZ_PARAM_ERROR;

    void *writer = mz_zip_writer_create();
    if (writer == NULL)
        return MZ_MEM_ERROR;

    asign_progress_state state = {
        .callback = progress_cb,
        .userdata = userdata,
        .total = total_uncompressed_size > 0 ? total_uncompressed_size : 0,
        .completed = 0,
        .current_size = 0
    };

    mz_zip_writer_set_compress_method(
        writer,
        compression_level == 0 ? MZ_COMPRESS_METHOD_STORE : MZ_COMPRESS_METHOD_DEFLATE
    );
    mz_zip_writer_set_compress_level(writer, compression_level);
    // Let the normal recursive pass skip symlinks. We add them explicitly
    // afterward using the IPA-compatible payload representation instead of
    // minizip-ng's zero-payload UNIX1 extra-field representation.
    mz_zip_writer_set_follow_links(writer, 0);
    mz_zip_writer_set_store_links(writer, 0);
    mz_zip_writer_set_overwrite_cb(writer, &state, asign_writer_overwrite_cb);
    mz_zip_writer_set_entry_cb(writer, &state, asign_writer_entry_cb);
    mz_zip_writer_set_progress_cb(writer, &state, asign_writer_progress_cb);
    mz_zip_writer_set_progress_interval(writer, 50);

    int32_t err = mz_zip_writer_open_file(writer, archive_path, 0, 0);

    char *root_path = NULL;
    if (err == MZ_OK) {
        root_path = strdup(source_path);
        if (root_path == NULL) {
            err = MZ_MEM_ERROR;
        } else {
            char *slash = strrchr(root_path, '/');
            if (slash != NULL) {
                // Keep the trailing slash so stripping root_path produces
                // "Payload/..." rather than "/Payload/...".
                slash[1] = '\0';
            } else {
                root_path[0] = '\0';
            }
        }
    }

    if (err == MZ_OK) {
        if (progress_cb != NULL)
            progress_cb(0.0, userdata);
        err = mz_zip_writer_add_path(writer, source_path, root_path, 0, 1);
        if (err == MZ_OK) {
            err = asign_writer_add_symlinks_recursive(
                writer,
                source_path,
                root_path,
                compression_level
            );
        }
    }

    free(root_path);

    int32_t close_err = mz_zip_writer_close(writer);
    mz_zip_writer_delete(&writer);

    if (err == MZ_OK && close_err != MZ_OK)
        err = close_err;

    if (err == MZ_OK && progress_cb != NULL)
        progress_cb(1.0, userdata);

    return err;
}

// MARK: - Archive-backed sparse signing helpers

typedef struct asign_string_set_s {
    char **items;
    size_t count;
    size_t capacity;
} asign_string_set;

static void asign_string_set_free(asign_string_set *set) {
    if (set == NULL)
        return;
    for (size_t i = 0; i < set->count; i++)
        free(set->items[i]);
    free(set->items);
    set->items = NULL;
    set->count = 0;
    set->capacity = 0;
}

static int asign_string_set_contains(const asign_string_set *set, const char *value) {
    if (set == NULL || value == NULL)
        return 0;
    for (size_t i = 0; i < set->count; i++) {
        if (strcmp(set->items[i], value) == 0)
            return 1;
    }
    return 0;
}

static int32_t asign_string_set_add(asign_string_set *set, const char *value) {
    if (set == NULL || value == NULL)
        return MZ_PARAM_ERROR;
    if (asign_string_set_contains(set, value))
        return MZ_OK;
    if (set->count == set->capacity) {
        size_t next = set->capacity == 0 ? 32 : set->capacity * 2;
        char **grown = (char **)realloc(set->items, next * sizeof(char *));
        if (grown == NULL)
            return MZ_MEM_ERROR;
        set->items = grown;
        set->capacity = next;
    }
    set->items[set->count] = strdup(value);
    if (set->items[set->count] == NULL)
        return MZ_MEM_ERROR;
    set->count++;
    return MZ_OK;
}

static int asign_path_component_is_parent(const char *start, size_t length) {
    return length == 2 && start[0] == '.' && start[1] == '.';
}

static int asign_relative_path_is_safe(const char *path) {
    if (path == NULL || path[0] == '\0' || path[0] == '/' || path[0] == '\\')
        return 0;
    if (strchr(path, '\\') != NULL)
        return 0;

    const char *component = path;
    const char *cursor = path;
    for (;;) {
        if (*cursor == '/' || *cursor == '\0') {
            size_t length = (size_t)(cursor - component);
            if (asign_path_component_is_parent(component, length))
                return 0;
            if (*cursor == '\0')
                break;
            component = cursor + 1;
        }
        cursor++;
    }
    return 1;
}

static char *asign_trimmed_root_copy(const char *root) {
    if (root == NULL)
        return NULL;
    size_t length = strlen(root);
    while (length > 0 && (root[length - 1] == '/' || root[length - 1] == '\\'))
        length--;
    if (length == 0)
        return NULL;
    char *copy = (char *)malloc(length + 1);
    if (copy == NULL)
        return NULL;
    memcpy(copy, root, length);
    copy[length] = '\0';
    return copy;
}

static int asign_entry_relative_to_root(const char *entry, const char *root, const char **relative) {
    if (entry == NULL || root == NULL || relative == NULL)
        return 0;
    size_t root_length = strlen(root);
    if (strncmp(entry, root, root_length) != 0)
        return 0;
    if (entry[root_length] == '\0') {
        *relative = entry + root_length;
        return 1;
    }
    if (entry[root_length] != '/')
        return 0;
    *relative = entry + root_length + 1;
    return 1;
}

static int asign_path_has_suffix(const char *path, const char *suffix) {
    size_t path_length = strlen(path);
    size_t suffix_length = strlen(suffix);
    return path_length >= suffix_length && strcmp(path + path_length - suffix_length, suffix) == 0;
}

static char *asign_join_path(const char *base, const char *relative) {
    if (base == NULL || relative == NULL)
        return NULL;
    size_t base_length = strlen(base);
    size_t relative_length = strlen(relative);
    int slash = base_length > 0 && base[base_length - 1] != '/';
    size_t length = base_length + (slash ? 1 : 0) + relative_length + 1;
    char *joined = (char *)malloc(length);
    if (joined == NULL)
        return NULL;
    memcpy(joined, base, base_length);
    size_t offset = base_length;
    if (slash)
        joined[offset++] = '/';
    memcpy(joined + offset, relative, relative_length + 1);
    return joined;
}

static int32_t asign_make_parent_directories(const char *path) {
    char *copy = strdup(path);
    if (copy == NULL)
        return MZ_MEM_ERROR;
    char *slash = strrchr(copy, '/');
    if (slash == NULL) {
        free(copy);
        return MZ_OK;
    }
    *slash = '\0';
    if (copy[0] == '\0') {
        free(copy);
        return MZ_OK;
    }

    char *cursor = copy + 1;
    while (*cursor != '\0') {
        if (*cursor == '/') {
            *cursor = '\0';
            if (mkdir(copy, 0755) != 0 && errno != EEXIST) {
                free(copy);
                return MZ_WRITE_ERROR;
            }
            *cursor = '/';
        }
        cursor++;
    }
    if (mkdir(copy, 0755) != 0 && errno != EEXIST) {
        free(copy);
        return MZ_WRITE_ERROR;
    }
    free(copy);
    return MZ_OK;
}

// Resolve duplicate ZIP names before selecting sparse inputs or emitting output.
// zsign's logical archive index uses the last central-directory entry for a name.
typedef struct asign_entry_position_s {
    char *name;
    int64_t position;
} asign_entry_position;

typedef struct asign_entry_index_s {
    asign_entry_position *entries;
    size_t count;
} asign_entry_index;

static void asign_entry_index_free(asign_entry_index *index) {
    for (size_t i = 0; i < index->count; i++)
        free(index->entries[i].name);
    free(index->entries);
}

static int asign_entry_position_compare(const void *lhs, const void *rhs) {
    const asign_entry_position *a = lhs, *b = rhs;
    int name_order = strcmp(a->name, b->name);
    if (name_order != 0)
        return name_order;
    return (a->position > b->position) - (a->position < b->position);
}

static int32_t asign_entry_index_build(void *reader, asign_entry_index *index, void **zip_handle) {
    int32_t err = mz_zip_reader_get_zip_handle(reader, zip_handle);
    if (err != MZ_OK)
        return err;
    size_t capacity = 0;
    err = mz_zip_reader_goto_first_entry(reader);
    while (err == MZ_OK) {
        mz_zip_file *info = NULL;
        err = mz_zip_reader_entry_get_info(reader, &info);
        if (err != MZ_OK)
            break;
        if (info == NULL || info->filename == NULL) {
            err = MZ_FORMAT_ERROR;
            break;
        }
        if (index->count == capacity) {
            size_t next = capacity == 0 ? 64 : capacity * 2;
            asign_entry_position *grown = realloc(index->entries, next * sizeof(*grown));
            if (grown == NULL) {
                err = MZ_MEM_ERROR;
                break;
            }
            index->entries = grown;
            capacity = next;
        }
        char *name = strdup(info->filename);
        if (name == NULL) {
            err = MZ_MEM_ERROR;
            break;
        }
        index->entries[index->count++] = (asign_entry_position){name, mz_zip_get_entry(*zip_handle)};
        err = mz_zip_reader_goto_next_entry(reader);
    }
    if (err != MZ_END_OF_LIST)
        return err;
    if (index->count > 1)
        qsort(index->entries, index->count, sizeof(*index->entries), asign_entry_position_compare);
    size_t unique = 0;
    for (size_t i = 0; i < index->count; i++) {
        if (i + 1 < index->count && strcmp(index->entries[i].name, index->entries[i + 1].name) == 0)
            free(index->entries[i].name);
        else
            index->entries[unique++] = index->entries[i];
    }
    index->count = unique;
    return MZ_OK;
}

static int asign_entry_index_is_current(const asign_entry_index *index, const char *name, void *zip_handle) {
    size_t lo = 0, hi = index->count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        int order = strcmp(name, index->entries[mid].name);
        if (order == 0)
            return index->entries[mid].position == mz_zip_get_entry(zip_handle);
        if (order < 0)
            hi = mid;
        else
            lo = mid + 1;
    }
    return 0;
}

// CRC mismatches remain fatal. A complete decoded stream alone cannot prove
// whether its bytes or the stored checksum are corrupt; raw copying would retain
// a stale checksum anyway. Normalize only with independent evidence of validity.

int32_t asign_archive_enumerate_entries(
    const char *archive_path,
    asign_archive_entry_cb entry_cb,
    void *userdata
) {
    if (archive_path == NULL || entry_cb == NULL)
        return MZ_PARAM_ERROR;

    void *reader = mz_zip_reader_create();
    if (reader == NULL)
        return MZ_MEM_ERROR;

    int32_t err = mz_zip_reader_set_recover(reader, 1);
    if (err == MZ_OK)
        err = mz_zip_reader_open_file(reader, archive_path);
    if (err == MZ_OK)
        err = mz_zip_reader_goto_first_entry(reader);

    while (err == MZ_OK) {
        mz_zip_file *file_info = NULL;
        err = mz_zip_reader_entry_get_info(reader, &file_info);
        if (err != MZ_OK)
            break;
        if (file_info == NULL || file_info->filename == NULL || file_info->uncompressed_size < 0) {
            err = MZ_FORMAT_ERROR;
            break;
        }

        uint8_t is_directory = mz_zip_reader_entry_is_dir(reader) == MZ_OK ? 1 : 0;
        uint8_t is_symlink = (mz_zip_attrib_is_symlink(file_info->external_fa, file_info->version_madeby) == MZ_OK ||
                              (file_info->linkname != NULL && file_info->linkname[0] != '\0')) ? 1 : 0;
        err = entry_cb(file_info->filename, file_info->uncompressed_size, is_directory, is_symlink, userdata);
        if (err != MZ_OK)
            break;

        err = mz_zip_reader_goto_next_entry(reader);
    }

    if (err == MZ_END_OF_LIST)
        err = MZ_OK;
    int32_t close_err = mz_zip_reader_close(reader);
    mz_zip_reader_delete(&reader);
    if (err == MZ_OK && close_err != MZ_OK)
        err = close_err;
    return err;
}

void asign_archive_free_buffer(void *buffer) {
    free(buffer);
}

int32_t asign_archive_read_entry(
    const char *archive_path,
    const char *entry_path,
    int64_t max_bytes,
    uint8_t **out_data,
    int64_t *out_size
) {
    if (archive_path == NULL || entry_path == NULL || out_data == NULL || out_size == NULL ||
        max_bytes < 0 || !asign_relative_path_is_safe(entry_path))
        return MZ_PARAM_ERROR;

    *out_data = NULL;
    *out_size = 0;

    void *reader = mz_zip_reader_create();
    if (reader == NULL)
        return MZ_MEM_ERROR;

    int32_t err = mz_zip_reader_set_recover(reader, 1);
    if (err == MZ_OK)
        err = mz_zip_reader_open_file(reader, archive_path);
    if (err == MZ_OK)
        err = mz_zip_reader_goto_first_entry(reader);

    uint8_t *selected_data = NULL;
    int64_t selected_size = 0;
    int found = 0;

    while (err == MZ_OK) {
        mz_zip_file *file_info = NULL;
        err = mz_zip_reader_entry_get_info(reader, &file_info);
        if (err != MZ_OK)
            break;
        if (file_info == NULL || file_info->filename == NULL || file_info->uncompressed_size < 0) {
            err = MZ_FORMAT_ERROR;
            break;
        }

        if (strcmp(file_info->filename, entry_path) == 0) {
            if (mz_zip_reader_entry_is_dir(reader) == MZ_OK) {
                err = MZ_FORMAT_ERROR;
                break;
            }
            if (file_info->uncompressed_size > max_bytes ||
                (uint64_t)file_info->uncompressed_size > (uint64_t)SIZE_MAX) {
                err = MZ_BUF_ERROR;
                break;
            }

            size_t size = (size_t)file_info->uncompressed_size;
            uint8_t *candidate = (uint8_t *)malloc(size > 0 ? size : 1);
            if (candidate == NULL) {
                err = MZ_MEM_ERROR;
                break;
            }

            err = mz_zip_reader_entry_open(reader);
            if (err != MZ_OK) {
                free(candidate);
                break;
            }

            size_t offset = 0;
            while (offset < size) {
                size_t remaining = size - offset;
                int32_t request = remaining > (size_t)INT32_MAX ? INT32_MAX : (int32_t)remaining;
                int32_t count = mz_zip_reader_entry_read(reader, candidate + offset, request);
                if (count < 0) {
                    err = count;
                    break;
                }
                if (count == 0) {
                    err = MZ_READ_ERROR;
                    break;
                }
                offset += (size_t)count;
            }

            int32_t close_entry_err = mz_zip_reader_entry_close(reader);
            if (err == MZ_OK && close_entry_err != MZ_OK)
                err = close_entry_err;
            if (err != MZ_OK) {
                free(candidate);
                break;
            }

            free(selected_data);
            selected_data = candidate;
            selected_size = (int64_t)size;
            found = 1;
        }

        err = mz_zip_reader_goto_next_entry(reader);
    }

    if (err == MZ_END_OF_LIST)
        err = MZ_OK;
    int32_t close_err = mz_zip_reader_close(reader);
    mz_zip_reader_delete(&reader);
    if (err == MZ_OK && close_err != MZ_OK)
        err = close_err;

    if (err != MZ_OK) {
        free(selected_data);
        return err;
    }
    if (!found)
        return ASIGN_ARCHIVE_NOT_FOUND;

    *out_data = selected_data;
    *out_size = selected_size;
    return MZ_OK;
}

static int asign_is_macho_magic(uint32_t magic) {
    return magic == 0xfeedfaceU || magic == 0xcefaedfeU ||
           magic == 0xfeedfacfU || magic == 0xcffaedfeU ||
           magic == 0xcafebabeU || magic == 0xbebafecaU ||
           magic == 0xcafebabfU || magic == 0xbfbafecaU;
}

static int32_t asign_current_entry_is_macho(void *reader, int *is_macho) {
    if (reader == NULL || is_macho == NULL)
        return MZ_PARAM_ERROR;
    *is_macho = 0;
    int32_t err = mz_zip_reader_entry_open(reader);
    if (err != MZ_OK)
        return err;
    uint32_t magic = 0;
    int32_t read = mz_zip_reader_entry_read(reader, &magic, (int32_t)sizeof(magic));
    // Closing an intentionally short read may report a CRC/stream error on some
    // methods. We only used this open as a four-byte probe, so ignore close status.
    (void)mz_zip_reader_entry_close(reader);
    if (read < 0)
        return read;
    if (read == (int32_t)sizeof(magic))
        *is_macho = asign_is_macho_magic(magic);
    return MZ_OK;
}

static int asign_symlink_target_stays_within_root(const char *relative_path, const char *target) {
    if (relative_path == NULL || target == NULL || target[0] == '\0' || target[0] == '/' || target[0] == '\\')
        return 0;

    // Start at the symlink's parent directory depth inside the .app, then
    // resolve the target lexically. A `..` is legal only while there is still
    // a parent component to consume; reaching below zero would escape the app.
    int depth = 0;
    for (const char *p = relative_path; *p != '\0'; p++) {
        if (*p == '/')
            depth++;
    }

    const char *component = target;
    for (const char *p = target;; p++) {
        if (*p == '/' || *p == '\0') {
            size_t length = (size_t)(p - component);
            if (length == 2 && component[0] == '.' && component[1] == '.') {
                if (depth == 0)
                    return 0;
                depth--;
            } else if (!(length == 0 || (length == 1 && component[0] == '.'))) {
                depth++;
            }
            if (*p == '\0')
                break;
            component = p + 1;
        }
    }
    return 1;
}

static int32_t asign_save_current_symlink(void *reader, mz_zip_file *file_info, const char *relative_path, const char *destination) {
    if (reader == NULL || file_info == NULL || relative_path == NULL || destination == NULL)
        return MZ_PARAM_ERROR;

    const char *target = file_info->linkname;
    char *owned_target = NULL;
    if (target == NULL || target[0] == '\0') {
        if (file_info->uncompressed_size < 0 || file_info->uncompressed_size >= UINT16_MAX)
            return MZ_FORMAT_ERROR;
        size_t size = (size_t)file_info->uncompressed_size;
        owned_target = (char *)malloc(size + 1);
        if (owned_target == NULL)
            return MZ_MEM_ERROR;
        int32_t err = mz_zip_reader_entry_open(reader);
        if (err != MZ_OK) {
            free(owned_target);
            return err;
        }
        size_t offset = 0;
        while (offset < size) {
            int32_t chunk = (int32_t)((size - offset) > INT32_MAX ? INT32_MAX : (size - offset));
            int32_t read = mz_zip_reader_entry_read(reader, owned_target + offset, chunk);
            if (read < 0) {
                (void)mz_zip_reader_entry_close(reader);
                free(owned_target);
                return read;
            }
            if (read == 0)
                break;
            offset += (size_t)read;
        }
        int32_t close_err = mz_zip_reader_entry_close(reader);
        if (offset != size || (close_err != MZ_OK && close_err != MZ_CRC_ERROR)) {
            free(owned_target);
            return MZ_READ_ERROR;
        }
        owned_target[size] = '\0';
        target = owned_target;
    }

    // IPA framework links are relative (for example Versions/Current/Foo).
    // Permit internal `..` components, but reject any target that can lexically
    // escape above the root app workspace.
    if (!asign_symlink_target_stays_within_root(relative_path, target)) {
        free(owned_target);
        return MZ_FORMAT_ERROR;
    }

    int32_t err = asign_make_parent_directories(destination);
    if (err == MZ_OK) {
        (void)unlink(destination);
        if (symlink(target, destination) != 0)
            err = MZ_WRITE_ERROR;
    }
    free(owned_target);
    return err;
}

int32_t asign_archive_extract_entry(
    const char *archive_path,
    const char *entry_path,
    const char *destination_path
) {
    if (archive_path == NULL || entry_path == NULL || destination_path == NULL ||
        !asign_relative_path_is_safe(entry_path))
        return MZ_PARAM_ERROR;

    void *reader = mz_zip_reader_create();
    if (reader == NULL)
        return MZ_MEM_ERROR;

    int32_t err = mz_zip_reader_set_recover(reader, 1);
    if (err == MZ_OK)
        err = mz_zip_reader_open_file(reader, archive_path);
    if (err == MZ_OK)
        err = mz_zip_reader_goto_first_entry(reader);

    int found = 0;
    while (err == MZ_OK) {
        mz_zip_file *file_info = NULL;
        err = mz_zip_reader_entry_get_info(reader, &file_info);
        if (err != MZ_OK)
            break;
        if (file_info == NULL || file_info->filename == NULL) {
            err = MZ_FORMAT_ERROR;
            break;
        }

        if (strcmp(file_info->filename, entry_path) == 0) {
            int is_dir = mz_zip_reader_entry_is_dir(reader) == MZ_OK;
            int is_symlink = mz_zip_attrib_is_symlink(file_info->external_fa, file_info->version_madeby) == MZ_OK ||
                             (file_info->linkname != NULL && file_info->linkname[0] != '\0');
            if (is_dir && !is_symlink) {
                err = asign_make_parent_directories(destination_path);
                if (err == MZ_OK && mkdir(destination_path, 0755) != 0 && errno != EEXIST)
                    err = MZ_WRITE_ERROR;
            } else if (is_symlink) {
                const char *basename = strrchr(entry_path, '/');
                basename = basename != NULL ? basename + 1 : entry_path;
                err = asign_save_current_symlink(reader, file_info, basename, destination_path);
            } else {
                err = asign_make_parent_directories(destination_path);
                if (err == MZ_OK) {
                    (void)unlink(destination_path);
                    err = mz_zip_reader_entry_save_file(reader, destination_path);
                }
            }
            if (err != MZ_OK)
                break;
            found = 1;
        }

        err = mz_zip_reader_goto_next_entry(reader);
    }

    if (err == MZ_END_OF_LIST)
        err = MZ_OK;
    int32_t close_err = mz_zip_reader_close(reader);
    mz_zip_reader_delete(&reader);
    if (err == MZ_OK && close_err != MZ_OK)
        err = close_err;
    if (err != MZ_OK)
        return err;
    return found ? MZ_OK : ASIGN_ARCHIVE_NOT_FOUND;
}

int32_t asign_archive_extract_prefix(
    const char *archive_path,
    const char *prefix_path,
    const char *destination_path
) {
    if (archive_path == NULL || prefix_path == NULL || destination_path == NULL ||
        !asign_relative_path_is_safe(prefix_path))
        return MZ_PARAM_ERROR;

    char *prefix = asign_trimmed_root_copy(prefix_path);
    if (prefix == NULL || !asign_relative_path_is_safe(prefix)) {
        free(prefix);
        return MZ_PARAM_ERROR;
    }

    void *reader = mz_zip_reader_create();
    if (reader == NULL) {
        free(prefix);
        return MZ_MEM_ERROR;
    }

    int32_t err = mz_zip_reader_set_recover(reader, 1);
    if (err == MZ_OK)
        err = mz_zip_reader_open_file(reader, archive_path);
    if (err == MZ_OK)
        err = mz_zip_reader_goto_first_entry(reader);

    int found = 0;
    while (err == MZ_OK) {
        mz_zip_file *file_info = NULL;
        err = mz_zip_reader_entry_get_info(reader, &file_info);
        if (err != MZ_OK)
            break;
        if (file_info == NULL || file_info->filename == NULL) {
            err = MZ_FORMAT_ERROR;
            break;
        }

        const char *relative = NULL;
        if (asign_entry_relative_to_root(file_info->filename, prefix, &relative)) {
            if (relative[0] != '\0' && !asign_relative_path_is_safe(relative)) {
                err = MZ_FORMAT_ERROR;
                break;
            }

            char *target = relative[0] == '\0' ? strdup(destination_path) : asign_join_path(destination_path, relative);
            if (target == NULL) {
                err = MZ_MEM_ERROR;
                break;
            }

            int is_dir = mz_zip_reader_entry_is_dir(reader) == MZ_OK;
            int is_symlink = mz_zip_attrib_is_symlink(file_info->external_fa, file_info->version_madeby) == MZ_OK ||
                             (file_info->linkname != NULL && file_info->linkname[0] != '\0');
            if (is_dir && !is_symlink) {
                err = asign_make_parent_directories(target);
                if (err == MZ_OK && mkdir(target, 0755) != 0 && errno != EEXIST)
                    err = MZ_WRITE_ERROR;
            } else if (is_symlink) {
                const char *symlink_relative = relative;
                if (relative[0] == '\0') {
                    const char *basename = strrchr(prefix, '/');
                    symlink_relative = basename != NULL ? basename + 1 : prefix;
                }
                err = asign_save_current_symlink(reader, file_info, symlink_relative, target);
            } else {
                err = asign_make_parent_directories(target);
                if (err == MZ_OK) {
                    (void)unlink(target);
                    err = mz_zip_reader_entry_save_file(reader, target);
                }
            }
            free(target);
            if (err != MZ_OK)
                break;
            found = 1;
        }

        err = mz_zip_reader_goto_next_entry(reader);
    }

    if (err == MZ_END_OF_LIST)
        err = MZ_OK;
    int32_t close_err = mz_zip_reader_close(reader);
    mz_zip_reader_delete(&reader);
    free(prefix);
    if (err == MZ_OK && close_err != MZ_OK)
        err = close_err;
    if (err != MZ_OK)
        return err;
    return found ? MZ_OK : ASIGN_ARCHIVE_NOT_FOUND;
}

int32_t asign_archive_materialize_signing_inputs(
    const char *archive_path,
    const char *root_entry_path,
    const char *destination_app_path,
    uint8_t include_info_plist_strings
) {
    if (archive_path == NULL || root_entry_path == NULL || destination_app_path == NULL)
        return MZ_PARAM_ERROR;

    char *root = asign_trimmed_root_copy(root_entry_path);
    if (root == NULL || !asign_relative_path_is_safe(root)) {
        free(root);
        return MZ_PARAM_ERROR;
    }

    if (mkdir(destination_app_path, 0755) != 0 && errno != EEXIST) {
        free(root);
        return MZ_WRITE_ERROR;
    }

    void *reader = mz_zip_reader_create();
    if (reader == NULL) {
        free(root);
        return MZ_MEM_ERROR;
    }
    int32_t err = mz_zip_reader_set_recover(reader, 1);
    if (err == MZ_OK)
        err = mz_zip_reader_open_file(reader, archive_path);
    asign_entry_index entries = {0};
    void *zip_handle = NULL;
    if (err == MZ_OK)
        err = asign_entry_index_build(reader, &entries, &zip_handle);
    if (err == MZ_OK)
        err = mz_zip_reader_goto_first_entry(reader);

    while (err == MZ_OK) {
        mz_zip_file *file_info = NULL;
        err = mz_zip_reader_entry_get_info(reader, &file_info);
        if (err != MZ_OK)
            break;

        if (file_info == NULL || file_info->filename == NULL) {
            err = MZ_FORMAT_ERROR;
            break;
        }
        if (!asign_entry_index_is_current(&entries, file_info->filename, zip_handle)) {
            err = mz_zip_reader_goto_next_entry(reader);
            continue;
        }

        const char *relative = NULL;
        if (file_info != NULL && file_info->filename != NULL &&
            asign_entry_relative_to_root(file_info->filename, root, &relative)) {
            if (relative[0] != '\0') {
                if (!asign_relative_path_is_safe(relative)) {
                    err = MZ_FORMAT_ERROR;
                    break;
                }

                int is_dir = mz_zip_reader_entry_is_dir(reader) == MZ_OK;
                int is_symlink = mz_zip_attrib_is_symlink(file_info->external_fa, file_info->version_madeby) == MZ_OK ||
                                 (file_info->linkname != NULL && file_info->linkname[0] != '\0');
                int selected = 0;
                if (is_symlink) {
                    selected = 1;
                } else if (!is_dir && asign_path_has_suffix(relative, "/Info.plist")) {
                    selected = 1;
                } else if (!is_dir && strcmp(relative, "Info.plist") == 0) {
                    selected = 1;
                } else if (!is_dir && include_info_plist_strings &&
                           (strcmp(relative, "InfoPlist.strings") == 0 || asign_path_has_suffix(relative, "/InfoPlist.strings"))) {
                    selected = 1;
                } else if (!is_dir && file_info->uncompressed_size >= 4) {
                    int is_macho = 0;
                    int32_t probe_err = asign_current_entry_is_macho(reader, &is_macho);
                    if (probe_err != MZ_OK) {
                        err = probe_err;
                        break;
                    }
                    selected = is_macho;
                }

                if (selected) {
                    char *destination = asign_join_path(destination_app_path, relative);
                    if (destination == NULL) {
                        err = MZ_MEM_ERROR;
                        break;
                    }
                    if (is_symlink) {
                        err = asign_save_current_symlink(reader, file_info, relative, destination);
                    } else {
                        err = asign_make_parent_directories(destination);
                        if (err == MZ_OK) {
                            // A later duplicate is authoritative. Remove any
                            // earlier regular file/symlink before writing so a
                            // type-changing duplicate cannot be followed through.
                            (void)unlink(destination);
                            err = mz_zip_reader_entry_save_file(reader, destination);
                        }
                    }
                    free(destination);
                    if (err != MZ_OK)
                        break;
                }
            }
        }

        err = mz_zip_reader_goto_next_entry(reader);
    }

    if (err == MZ_END_OF_LIST)
        err = MZ_OK;
    asign_entry_index_free(&entries);
    int32_t close_err = mz_zip_reader_close(reader);
    mz_zip_reader_delete(&reader);
    free(root);
    if (err == MZ_OK && close_err != MZ_OK)
        err = close_err;
    return err;
}

static int asign_deleted_path_matches(const char *relative, const char *deleted_paths) {
    if (relative == NULL || deleted_paths == NULL || deleted_paths[0] == '\0')
        return 0;
    const char *line = deleted_paths;
    while (*line != '\0') {
        const char *end = strchr(line, '\n');
        size_t length = end != NULL ? (size_t)(end - line) : strlen(line);
        while (length > 0 && (line[length - 1] == '/' || line[length - 1] == '\r'))
            length--;
        if (length > 0 && strncmp(relative, line, length) == 0 &&
            (relative[length] == '\0' || relative[length] == '/')) {
            return 1;
        }
        if (end == NULL)
            break;
        line = end + 1;
    }
    return 0;
}

static int asign_is_code_signature_path(const char *relative) {
    if (relative == NULL)
        return 0;
    if (strncmp(relative, "_CodeSignature/", 15) == 0 || strcmp(relative, "_CodeSignature") == 0)
        return 1;
    return strstr(relative, "/_CodeSignature/") != NULL || asign_path_has_suffix(relative, "/_CodeSignature");
}

static int32_t asign_writer_add_symlink_named(
    void *writer,
    const char *path,
    const char *filename_in_zip,
    int16_t compression_level
) {
    struct stat st;
    if (lstat(path, &st) != 0 || !S_ISLNK(st.st_mode))
        return MZ_READ_ERROR;

    size_t capacity = st.st_size > 0 ? (size_t)st.st_size + 1 : 256;
    char *target = NULL;
    ssize_t target_length = -1;
    for (;;) {
        char *grown = (char *)realloc(target, capacity + 1);
        if (grown == NULL) {
            free(target);
            return MZ_MEM_ERROR;
        }
        target = grown;
        target_length = readlink(path, target, capacity);
        if (target_length < 0) {
            free(target);
            return MZ_READ_ERROR;
        }
        if ((size_t)target_length < capacity)
            break;
        if (capacity > (SIZE_MAX / 2) - 1) {
            free(target);
            return MZ_MEM_ERROR;
        }
        capacity *= 2;
    }
    target[target_length] = '\0';

    mz_zip_file file_info;
    memset(&file_info, 0, sizeof(file_info));
    file_info.version_madeby = (uint16_t)((MZ_HOST_SYSTEM_OSX_DARWIN << 8) | 45);
    file_info.compression_method = compression_level == 0 ? MZ_COMPRESS_METHOD_STORE : MZ_COMPRESS_METHOD_DEFLATE;
    file_info.filename = filename_in_zip;
    file_info.uncompressed_size = target_length;
    file_info.flag = MZ_ZIP_FLAG_UTF8;
    file_info.modified_date = st.st_mtime;
    file_info.accessed_date = st.st_atime;
    file_info.creation_date = st.st_ctime;
    uint32_t src_attrib = (uint32_t)st.st_mode;
    uint32_t dos_attrib = 0;
    if (mz_zip_attrib_convert(MZ_HOST_SYSTEM_OSX_DARWIN, src_attrib, MZ_HOST_SYSTEM_MSDOS, &dos_attrib) == MZ_OK)
        file_info.external_fa = dos_attrib;
    file_info.external_fa |= (src_attrib << 16);

    int32_t err = mz_zip_writer_add_buffer(writer, target, (int32_t)target_length, &file_info);
    free(target);
    return err;
}

static int32_t asign_writer_add_overlay_file(
    void *writer,
    const char *disk_path,
    const char *archive_path,
    int16_t compression_level
) {
    struct stat st;
    if (lstat(disk_path, &st) != 0)
        return MZ_READ_ERROR;
    if (S_ISLNK(st.st_mode))
        return asign_writer_add_symlink_named(writer, disk_path, archive_path, compression_level);
    if (!S_ISREG(st.st_mode))
        return MZ_OK;
    return mz_zip_writer_add_file(writer, disk_path, archive_path);
}

static int32_t asign_append_new_overlay_entries(
    void *writer,
    const char *disk_root,
    const char *relative,
    const char *archive_root,
    int16_t compression_level,
    const char *deleted_paths,
    asign_string_set *already_written
) {
    char *directory_path = relative[0] == '\0' ? strdup(disk_root) : asign_join_path(disk_root, relative);
    if (directory_path == NULL)
        return MZ_MEM_ERROR;
    DIR *dir = opendir(directory_path);
    if (dir == NULL) {
        free(directory_path);
        return MZ_OPEN_ERROR;
    }

    int32_t err = MZ_OK;
    struct dirent *entry = NULL;
    while (err == MZ_OK && (entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;

        size_t rel_len = strlen(relative);
        size_t name_len = strlen(entry->d_name);
        size_t child_len = rel_len + (rel_len > 0 ? 1 : 0) + name_len + 1;
        char *child_rel = (char *)malloc(child_len);
        if (child_rel == NULL) {
            err = MZ_MEM_ERROR;
            break;
        }
        if (rel_len > 0)
            snprintf(child_rel, child_len, "%s/%s", relative, entry->d_name);
        else
            snprintf(child_rel, child_len, "%s", entry->d_name);

        char *child_disk = asign_join_path(disk_root, child_rel);
        size_t archive_len = strlen(archive_root) + 1 + strlen(child_rel) + 1;
        char *child_archive = (char *)malloc(archive_len);
        if (child_disk == NULL || child_archive == NULL) {
            free(child_rel);
            free(child_disk);
            free(child_archive);
            err = MZ_MEM_ERROR;
            break;
        }
        snprintf(child_archive, archive_len, "%s/%s", archive_root, child_rel);

        struct stat st;
        if (asign_deleted_path_matches(child_rel, deleted_paths)) {
            // Deletion has higher precedence than the sparse overlay. This also
            // prevents a deleted subtree that still contains an incidental
            // materialized file from being re-added during the final append pass.
        } else if (lstat(child_disk, &st) != 0) {
            err = MZ_READ_ERROR;
        } else if (S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode)) {
            err = asign_append_new_overlay_entries(writer, disk_root, child_rel, archive_root,
                                                    compression_level, deleted_paths, already_written);
        } else if (!asign_string_set_contains(already_written, child_archive)) {
            err = asign_writer_add_overlay_file(writer, child_disk, child_archive, compression_level);
            if (err == MZ_OK)
                err = asign_string_set_add(already_written, child_archive);
        }

        free(child_rel);
        free(child_disk);
        free(child_archive);
    }

    closedir(dir);
    free(directory_path);
    return err;
}

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
) {
    if (source_archive_path == NULL || destination_archive_path == NULL ||
        root_entry_path == NULL || overlay_app_path == NULL)
        return MZ_PARAM_ERROR;

    char *root = asign_trimmed_root_copy(root_entry_path);
    if (root == NULL || !asign_relative_path_is_safe(root)) {
        free(root);
        return MZ_PARAM_ERROR;
    }

    void *reader = mz_zip_reader_create();
    void *writer = mz_zip_writer_create();
    if (reader == NULL || writer == NULL) {
        if (reader != NULL) mz_zip_reader_delete(&reader);
        if (writer != NULL) mz_zip_writer_delete(&writer);
        free(root);
        return MZ_MEM_ERROR;
    }

    int32_t err = mz_zip_reader_set_recover(reader, 1);
    if (err == MZ_OK)
        err = mz_zip_reader_open_file(reader, source_archive_path);

    mz_zip_writer_set_compress_method(writer, compression_level == 0 ? MZ_COMPRESS_METHOD_STORE : MZ_COMPRESS_METHOD_DEFLATE);
    mz_zip_writer_set_compress_level(writer, compression_level);
    mz_zip_writer_set_follow_links(writer, 0);
    mz_zip_writer_set_store_links(writer, 0);
    if (err == MZ_OK)
        err = mz_zip_writer_open_file(writer, destination_archive_path, 0, 0);

    int64_t total_bytes = 0;
    if (err == MZ_OK) {
        int32_t size_status = MZ_OK;
        total_bytes = asign_reader_total_size(reader, &size_status);
        if (size_status != MZ_OK)
            err = size_status;
    }

    asign_entry_index entries = {0};
    void *zip_handle = NULL;
    if (err == MZ_OK)
        err = asign_entry_index_build(reader, &entries, &zip_handle);

    asign_string_set written = {0};
    int64_t processed = 0;
    if (err == MZ_OK) {
        if (progress_cb != NULL)
            progress_cb(0.0, userdata);
        err = mz_zip_reader_goto_first_entry(reader);
    }

    while (err == MZ_OK) {
        mz_zip_file *file_info = NULL;
        err = mz_zip_reader_entry_get_info(reader, &file_info);
        if (err != MZ_OK)
            break;
        if (file_info == NULL || file_info->filename == NULL) {
            err = MZ_FORMAT_ERROR;
            break;
        }

        // Emit exactly the duplicate that zsign hashed/materialized.
        if (!asign_entry_index_is_current(&entries, file_info->filename, zip_handle)) {
            err = mz_zip_reader_goto_next_entry(reader);
            continue;
        }

        const char *entry_name = file_info->filename;
        const char *relative = NULL;
        int under_root = asign_entry_relative_to_root(entry_name, root, &relative);
        int skip = 0;
        int replaced = 0;

        if (under_root && relative[0] != '\0') {
            if (!asign_relative_path_is_safe(relative)) {
                err = MZ_FORMAT_ERROR;
                break;
            }
            if ((omit_existing_code_signatures && asign_is_code_signature_path(relative)) ||
                asign_deleted_path_matches(relative, deleted_paths)) {
                skip = 1;
            } else {
                char *overlay = asign_join_path(overlay_app_path, relative);
                if (overlay == NULL) {
                    err = MZ_MEM_ERROR;
                    break;
                }
                struct stat st;
                if (lstat(overlay, &st) == 0 && !S_ISDIR(st.st_mode)) {
                    if (asign_string_set_contains(&written, entry_name)) {
                        // ZIP permits duplicate names. Once a logical path has been
                        // replaced, omit later duplicates so the signed archive has
                        // exactly one authoritative replacement entry.
                        replaced = 1;
                    } else {
                        err = asign_writer_add_overlay_file(writer, overlay, entry_name, compression_level);
                        if (err == MZ_OK) {
                            err = asign_string_set_add(&written, entry_name);
                            replaced = 1;
                        }
                    }
                }
                free(overlay);
                if (err != MZ_OK)
                    break;
            }
        }

        if (!skip && !replaced) {
            // minizip's write-open changes the method to STORE at level zero,
            // even in raw mode. Raw payloads must retain their source method:
            // a DEFLATE stream labeled STORE is not a valid resource. The level
            // is unused for raw compression; restore it for overlay additions.
            mz_zip_writer_set_compress_level(writer, MZ_COMPRESS_LEVEL_DEFAULT);
            err = mz_zip_writer_copy_from_reader(writer, reader);
            mz_zip_writer_set_compress_level(writer, compression_level);
            if (err != MZ_OK)
                break;
            err = asign_string_set_add(&written, entry_name);
            if (err != MZ_OK)
                break;
        }

        if (file_info->uncompressed_size > 0 && INT64_MAX - processed >= file_info->uncompressed_size)
            processed += file_info->uncompressed_size;
        if (progress_cb != NULL && total_bytes > 0)
            progress_cb((double)processed / (double)total_bytes, userdata);

        err = mz_zip_reader_goto_next_entry(reader);
    }
    if (err == MZ_END_OF_LIST)
        err = MZ_OK;

    if (err == MZ_OK) {
        err = asign_append_new_overlay_entries(writer, overlay_app_path, "", root,
                                               compression_level, deleted_paths, &written);
    }

    asign_entry_index_free(&entries);
    asign_string_set_free(&written);
    int32_t reader_close = mz_zip_reader_close(reader);
    int32_t writer_close = mz_zip_writer_close(writer);
    mz_zip_reader_delete(&reader);
    mz_zip_writer_delete(&writer);
    free(root);

    if (err == MZ_OK && reader_close != MZ_OK)
        err = reader_close;
    if (err == MZ_OK && writer_close != MZ_OK)
        err = writer_close;
    if (err == MZ_OK && progress_cb != NULL)
        progress_cb(1.0, userdata);
    return err;
}
