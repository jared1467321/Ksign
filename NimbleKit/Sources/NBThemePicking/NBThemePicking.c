#include "NBThemePicking.h"
#include <math.h>
#include <stdlib.h>

static int descends(const NBPaintTarget *a, const NBPaintTarget *b,
                    const uint64_t *path) {
    if (!b->owner) return 0;
    for (size_t i = 0; i < a->ancestors_count; ++i)
        if (path[a->ancestors_offset + i] == b->owner) return 1;
    return 0;
}

static int backdrop(const NBPaintTarget *t) {
    return t->kind == NBCanvas || t->kind == NBBackground;
}

static int front(const NBPaintTarget *a, const NBPaintTarget *b,
                 const uint64_t *path, const NBPaintLayer *layers) {
    /* Native navigation/tab backgrounds paint over canvases extended under
       their safe areas, but not over their own hosted labels/buttons. */
    if (a->kind == NBChrome && b->kind == NBCanvas) return 1;
    /* Only explicitly declared sibling layers have a known z-order. */
    for (size_t i = 0; i < a->layers_count; ++i)
        for (size_t j = 0; j < b->layers_count; ++j) {
            NBPaintLayer al = layers[a->layers_offset + i];
            NBPaintLayer bl = layers[b->layers_offset + j];
            if (al.group == bl.group && al.id != bl.id && al.order != bl.order)
                return al.order > bl.order;
        }
    if (descends(a, b, path))
        return (backdrop(b) || (b->kind == NBControl && a->kind == NBCanvas)) && a->kind != NBShadow;
    if (descends(b, a, path))
        return a->kind == NBOverlay;
    return 0;
}

static int specificity(int kind) {
    switch (kind) {
        case NBStroke: case NBForeground: return 4;
        case NBControl: return 3;
        case NBFill: case NBOverlay: return 2;
        case NBBackground: case NBChrome: return 1;
        case NBShadow: return -1;
        default: return 0;
    }
}

static int preferred(const NBPaintTarget *a, const NBPaintTarget *b) {
    double aa = a->width * a->height, ba = b->width * b->height;
    if (aa > fmax(ba * 4, ba + 1600)) return 0;
    if (ba > fmax(aa * 4, aa + 1600)) return 1;
    int sa = specificity(a->kind), sb = specificity(b->kind);
    if (sa != sb) return sa > sb;
    if (aa != ba) return aa < ba;
    return a->ancestors_count > b->ancestors_count;
}

size_t nb_theme_pick(const NBPaintTarget *ts, size_t count,
                     const uint64_t *path, size_t path_count,
                     const NBPaintLayer *layers, size_t layer_count,
                     double x, double y, size_t *out) {
    if (!count || !ts || !out || !isfinite(x) || !isfinite(y)) return 0;
    unsigned char *live = calloc(count, 1);
    size_t *hits = calloc(count, sizeof(size_t));
    if (!live || !hits) { free(live); free(hits); return 0; }
    size_t n = 0;
    for (size_t i = 0; i < count; ++i) {
        const NBPaintTarget *t = &ts[i];
        if (t->ancestors_offset > path_count ||
            t->ancestors_count > path_count - t->ancestors_offset ||
            (t->ancestors_count && !path) ||
            t->layers_offset > layer_count ||
            t->layers_count > layer_count - t->layers_offset ||
            (t->layers_count && !layers)) continue;
        if (!t->path_hit || !isfinite(t->alpha) || t->alpha <= 0.02 ||
            !isfinite(t->x) || !isfinite(t->y) ||
            !isfinite(t->width) || !isfinite(t->height) ||
            t->width <= 0 || t->height <= 0) continue;
        if (x < t->x || y < t->y || x >= t->x + t->width || y >= t->y + t->height) continue;
        hits[n++] = i;
        live[i] = 1;
    }
    /* Only opaque paint with known ordering hides another owner. Transparent
       paint keeps the contributing lower layer editable. Foreground rectangles
       and controls never claim opaque coverage of their whole layout bounds. */
    for (size_t i = 0; i < n; ++i)
        for (size_t j = 0; j < n; ++j)
            if (i != j && ts[hits[j]].covers && ts[hits[j]].alpha >= 0.999 &&
                front(&ts[hits[j]], &ts[hits[i]], path, layers)) {
                live[hits[i]] = 0;
                break;
            }

    /* Build indegrees once, then consume the partial order in O(H^2).
       No pairwise ownership work runs during ordinary app rendering. */
    size_t *indegree = calloc(n ? n : 1, sizeof(size_t));
    if (!indegree) { free(live); free(hits); return 0; }
    for (size_t i = 0; i < n; ++i)
        if (live[hits[i]])
            for (size_t j = 0; j < n; ++j)
                if (i != j && live[hits[j]] && front(&ts[hits[j]], &ts[hits[i]], path, layers))
                    ++indegree[i];
    size_t emitted = 0;
    for (;;) {
        size_t best = n;
        for (size_t i = 0; i < n; ++i)
            if (live[hits[i]] && !indegree[i] &&
                (best == n || preferred(&ts[hits[i]], &ts[hits[best]]))) best = i;
        if (best == n) break; /* Contradictory metadata fails closed. */
        out[emitted++] = hits[best];
        live[hits[best]] = 0;
        for (size_t i = 0; i < n; ++i)
            if (live[hits[i]] && front(&ts[hits[best]], &ts[hits[i]], path, layers))
                --indegree[i];
    }
    free(indegree);
    free(live);
    free(hits);
    return emitted;
}
