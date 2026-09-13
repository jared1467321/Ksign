#include "CASignArchive.h"

#include <stdlib.h>
#include <string.h>

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
    mz_zip_writer_set_follow_links(writer, 0);
    mz_zip_writer_set_store_links(writer, 1);
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
