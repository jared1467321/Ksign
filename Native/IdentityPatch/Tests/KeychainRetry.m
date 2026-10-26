// No Foundation, Security framework or Objective-C runtime is needed. The
// runner inserts the production retry functions at the marker below. Opaque
// dictionaries model group eligibility and item selection independently of
// those functions; the native fixture tests the actual Objective-C mapping.
#include <assert.h>
#include <stddef.h>
#include <stdio.h>

@class NSDictionary;
typedef const void *CFDictionaryRef;
typedef const void *CFTypeRef;
typedef int OSStatus;
typedef int BOOL;
#define YES 1
#define NO 0
enum {
    errSecSuccess = 0, errSecItemNotFound = -25300,
    errSecDuplicateItem = -25299, errSecMissingEntitlement = -34018,
    errSecInteractionNotAllowed = -25308, errSecAuthFailed = -25293,
    errSecParam = -50
};
enum { Original, Fallback, Authorized, Unknown, Default };
typedef struct { int group, account, value; } Query;
static const Query OriginalQuery = {Original, 1, 10};
static const Query RepairedQuery = {Fallback, 1, 10};
static const Query AllowedQuery = {Authorized, 1, 10};
static const Query UnknownQuery = {Unknown, 1, 10};
static const Query DefaultQuery = {Default, 1, 10};
static int MappingKnown = 1, Calls, ResultReferences;
static int Values[2];
static OSStatus ForcedStatus, RetryStatus;

static NSDictionary *KeychainQuery(CFDictionaryRef raw) {
    const Query *query = raw;
    return (NSDictionary *)(MappingKnown && query->group == Original ? &RepairedQuery : query);
}

static void CFRelease(CFTypeRef value) {
    assert(value && ResultReferences > 0);
    --ResultReferences;
}

static OSStatus NativeCall(int operation, CFDictionaryRef raw, CFDictionaryRef attributes, CFTypeRef *result) {
    const Query *query = raw;
    ++Calls;
    if (result) *result = NULL;
    if (ForcedStatus) {
        OSStatus status = Calls == 1 ? ForcedStatus : RetryStatus;
        if (result && status == errSecSuccess) { *result = &Values[0]; ++ResultReferences; }
        return status;
    }
    if (query->group == Original || query->group == Unknown) {
        return operation == 0 ? errSecMissingEntitlement : errSecItemNotFound;
    }
    int slot = query->group == Authorized ? 1 : 0;
    if (operation == 0) {
        if (Values[slot]) return errSecDuplicateItem;
        Values[slot] = query->value;
    } else {
        if (!Values[slot]) return errSecItemNotFound;
        if (operation == 1 && result) { *result = &Values[slot]; ++ResultReferences; }
        if (operation == 2) Values[slot] = ((const Query *)attributes)->value;
        if (operation == 3) Values[slot] = 0;
    }
    return errSecSuccess;
}

static OSStatus SecItemAdd(CFDictionaryRef query, CFTypeRef *result) { return NativeCall(0, query, NULL, result); }
static OSStatus SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) { return NativeCall(1, query, NULL, result); }
static OSStatus SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributes) { return NativeCall(2, query, attributes, NULL); }
static OSStatus SecItemDelete(CFDictionaryRef query) { return NativeCall(3, query, NULL, NULL); }

// PRODUCTION_KEYCHAIN_WRAPPERS

static void Lifecycle(void) {
    CFTypeRef result = NULL;
    assert(AsignSecItemAdd(&OriginalQuery, NULL) == errSecSuccess);
    assert(Values[0] == 10);
    assert(AsignSecItemCopyMatching(&OriginalQuery, &result) == errSecSuccess);
    assert(result && *(const int *)result == 10);
    CFRelease(result);
    assert(AsignSecItemAdd(&OriginalQuery, NULL) == errSecDuplicateItem);
    Query update = {Default, 1, 20};
    assert(AsignSecItemUpdate(&OriginalQuery, &update) == errSecSuccess);
    assert(Values[0] == 20);
    assert(AsignSecItemCopyMatching(&DefaultQuery, NULL) == errSecSuccess);
    assert(AsignSecItemCopyMatching(&AllowedQuery, NULL) == errSecItemNotFound);
    assert(AsignSecItemDelete(&UnknownQuery) == errSecItemNotFound);
    MappingKnown = 0;
    assert(AsignSecItemDelete(&OriginalQuery) == errSecItemNotFound);
    assert(Values[0] == 20);
    MappingKnown = 1;
    assert(AsignSecItemAdd(&AllowedQuery, NULL) == errSecSuccess);
    assert(AsignSecItemDelete(&OriginalQuery) == errSecSuccess);
    assert(Values[0] == 0 && Values[1] == 10);
    assert(AsignSecItemCopyMatching(&OriginalQuery, NULL) == errSecItemNotFound);
    assert(AsignSecItemUpdate(&OriginalQuery, &update) == errSecItemNotFound);
    assert(AsignSecItemDelete(&OriginalQuery) == errSecItemNotFound);
    assert(Values[1] == 10 && ResultReferences == 0);
}

static void ErrorChecks(void) {
    const OSStatus errors[] = {errSecItemNotFound, errSecMissingEntitlement,
        errSecDuplicateItem, errSecInteractionNotAllowed, errSecAuthFailed, errSecParam};
    const Query *queries[] = {&OriginalQuery, &AllowedQuery, &UnknownQuery, &DefaultQuery};
    for (int known = 0; known < 2; ++known) {
        MappingKnown = known;
        for (unsigned e = 0; e < sizeof(errors) / sizeof(errors[0]); ++e) {
            ForcedStatus = errors[e];
            for (unsigned q = 0; q < sizeof(queries) / sizeof(queries[0]); ++q) {
                for (unsigned r = 0; r <= sizeof(errors) / sizeof(errors[0]); ++r) {
                    RetryStatus = r == sizeof(errors) / sizeof(errors[0]) ? errSecSuccess : errors[r];
                    for (int op = 0; op < 4; ++op) {
                        Calls = 0;
                        CFTypeRef result = NULL;
                        OSStatus status;
                        if (op == 0) status = AsignSecItemAdd(queries[q], &result);
                        else if (op == 1) status = AsignSecItemCopyMatching(queries[q], &result);
                        else if (op == 2) status = AsignSecItemUpdate(queries[q], &OriginalQuery);
                        else status = AsignSecItemDelete(queries[q]);
                        int retry = known && (ForcedStatus == errSecMissingEntitlement ||
                            (op != 0 && ForcedStatus == errSecItemNotFound && q == 0)) && (q == 0 || op == 2);
                        assert(status == (retry ? RetryStatus : ForcedStatus));
                        assert(Calls == (retry ? 2 : 1));
                        assert((result != NULL) == (op < 2 && status == errSecSuccess));
                        if (result) CFRelease(result);
                    }
                }
            }
        }
    }
    assert(ResultReferences == 0);
}

int main(void) {
    Lifecycle();
    ErrorChecks();
    puts("Keychain lifecycle and retry preservation checks passed");
    return 0;
}
