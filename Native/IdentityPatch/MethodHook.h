#pragma once
#import <objc/runtime.h>
#include <stdlib.h>
#include "TypeEncoding.h"

// These hooks have at most two explicit arguments. Check every argument, not
// only the result and count: an SDK can change an object to a scalar or block.
static inline BOOL AsignMethodMatches(Method method, const char *result,
                                     const char *first, const char *second) {
    unsigned count = 2 + (first != NULL) + (second != NULL);
    if (!method || (second && !first) || method_getNumberOfArguments(method) != count) return NO;
    char *type = method_copyReturnType(method);
    BOOL valid = AsignTypeMatches(type, result);
    free(type);
    const char *arguments[] = {"@", ":", first, second};
    for (unsigned i = 0; valid && i < count; ++i) {
        type = method_copyArgumentType(method, i);
        valid = AsignTypeMatches(type, arguments[i]);
        free(type);
    }
    return valid;
}

static inline BOOL AsignHookMethod(Class cls, SEL selector, IMP replacement, IMP *original,
                                  const char *result, const char *first, const char *second) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!AsignMethodMatches(method, result, first, second)) return NO;
    IMP previous = method_getImplementation(method);
    if (previous == replacement) return YES;
    // Make the forwarding target available before publishing the hook. Add an
    // override for inherited methods rather than modifying the superclass.
    if (original) *original = previous;
    if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
        previous = method_setImplementation(method, replacement);
        if (original) *original = previous;
    }
    return YES;
}
