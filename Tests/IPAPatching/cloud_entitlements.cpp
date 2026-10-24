#include "cloud_entitlements.h"
#include <cassert>
#include <iostream>

int main() {
    jvalue profile;
    profile["application-identifier"] = "NEW.org.example.signer";
    profile["com.apple.developer.team-identifier"] = "NEW";
    profile["com.apple.security.application-groups"].push_back("group.org.example.signer");
    profile["keychain-access-groups"].push_back("NEW.*");
    profile["aps-environment"] = "production";
    profile["com.apple.developer.icloud-container-identifiers"].push_back("iCloud.org.example.signer");
    profile["com.apple.developer.icloud-services"] = "*";
    profile["com.apple.developer.icloud-container-environment"].push_back("Production");
    profile["com.apple.developer.ubiquity-container-identifiers"].push_back("iCloud.org.example.signer");
    profile["com.apple.developer.ubiquity-kvstore-identifier"] = "NEW.*";
    string source;
    profile.style_write_plist(source);
    string output;
    assert(FilterCloudEntitlements(source, {}, output));
    jvalue local;
    assert(local.read_plist(output));
    assert(local.size() == 5);
    assert(local["application-identifier"] == "NEW.org.example.signer");
    assert(local["com.apple.developer.team-identifier"] == "NEW");
    assert(local["com.apple.security.application-groups"][0] == "group.org.example.signer");
    assert(local["keychain-access-groups"][0] == "NEW.*");
    assert(local["aps-environment"] == "production");
    assert(!local.has("com.apple.developer.icloud-container-identifiers"));

    // Another bundle using CloudKit keeps the profile's permitted values;
    // no container from the original developer is granted or fabricated.
    assert(FilterCloudEntitlements(source,
        {"com.apple.developer.icloud-container-identifiers", "com.apple.developer.icloud-services"}, output));
    jvalue cloud;
    assert(cloud.read_plist(output));
    assert(cloud.size() == 7);
    assert(cloud["com.apple.developer.icloud-container-identifiers"][0] == "iCloud.org.example.signer");
    assert(cloud["com.apple.developer.icloud-services"] == "*");
    assert(!cloud.has("com.apple.developer.ubiquity-kvstore-identifier"));
    assert(FilterCloudEntitlements(source, {"com.apple.developer.ubiquity-kvstore-identifier"}, output));
    jvalue kvs;
    assert(kvs.read_plist(output));
    assert(kvs.size() == 6);
    assert(kvs["com.apple.developer.ubiquity-kvstore-identifier"] == "NEW.*");

    vector<string> all;
    profile.get_keys(all);
    assert(FilterCloudEntitlements(source, all, output) && output == source);
    assert(FilterCloudEntitlements("", {}, output) && output.empty());
    assert(!FilterCloudEntitlements("damaged plist", {}, output));
    string array;
    jvalue(jvalue::E_ARRAY).style_write_plist(array);
    assert(!FilterCloudEntitlements(array, {}, output));
    // Filtering one bundle must never mutate the shared profile/session.
    string unchanged;
    profile.style_write_plist(unchanged);
    assert(source == unchanged);
    std::cout << "Per-bundle cloud entitlement filtering passed\n";
}
