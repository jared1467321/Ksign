#ifndef NB_THEME_PICKING_H
#define NB_THEME_PICKING_H
#include <stddef.h>
#include <stdint.h>

/* No rendering or platform dependency. IDs are snapshot-local, never persisted. */
enum NBPaintKind { NBCanvas, NBBackground, NBFill, NBOverlay, NBControl, NBForeground, NBStroke, NBShadow, NBChrome };
typedef struct { uint64_t group, id; double order; } NBPaintLayer;
typedef struct {
    double x, y, width, height, alpha;
    uint64_t owner;
    size_t ancestors_offset, ancestors_count;
    size_t layers_offset, layers_count;
    int kind, path_hit, covers;
} NBPaintTarget;

/* Input order is a stable identity tie-break, NOT paint order.
   Returns visible candidates front first. out has capacity count. */
size_t nb_theme_pick(const NBPaintTarget *targets, size_t count,
                     const uint64_t *ancestors, size_t ancestors_count,
                     const NBPaintLayer *layers, size_t layers_count,
                     double x, double y, size_t *out);
#endif
