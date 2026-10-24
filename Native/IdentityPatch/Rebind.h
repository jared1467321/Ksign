#ifndef ASIGN_IDENTITY_REBIND_H
#define ASIGN_IDENTITY_REBIND_H
#include <stddef.h>
typedef struct {
    const char *name;
    void *original;
    void *replacement;
} AsignIdentityBinding;
void AsignIdentityRebind(const AsignIdentityBinding *bindings, size_t count, const char *scope);
#endif
