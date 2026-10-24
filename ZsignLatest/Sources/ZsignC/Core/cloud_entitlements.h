#pragma once
#include "common/json.h"
#include <set>

// A compatibility-patched local app must not accidentally opt into CloudKit
// simply because its signing profile contains somebody else's cloud containers.
// Keep profile values for cloud capability keys that the original app used.
// Other entitlements (identity, keychain, app groups, etc.) are untouched.
inline bool FilterCloudEntitlements(const string& source, const vector<string>& originalKeys, string& output)
{
    output = source;
    if (source.empty()) return true;
    jvalue entitlements;
    if (!entitlements.read_plist(source) || !entitlements.is_object()) return false;
    const set<string> allowed(originalKeys.begin(), originalKeys.end());
    vector<string> keys;
    entitlements.get_keys(keys);
    bool changed = false;
    for (const string& key : keys) {
        if ((key.rfind("com.apple.developer.icloud-", 0) == 0 ||
             key.rfind("com.apple.developer.ubiquity-", 0) == 0) && !allowed.count(key)) {
            entitlements.erase(key.c_str());
            changed = true;
        }
    }
    if (changed) entitlements.style_write_plist(output);
    return true;
}
