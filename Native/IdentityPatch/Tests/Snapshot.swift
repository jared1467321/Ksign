// Appended to the actual OriginalCloudEntitlements implementation by check.py.
let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
func snapshot(_ name: String) throws -> OriginalCloudEntitlements.Snapshot? {
    try OriginalCloudEntitlements.snapshot(fixtures.appendingPathComponent(name))
}
let original = try snapshot("original")!
precondition(original.appGroups == ["group.original"])
precondition(original.keychainGroups == ["OLD.app", "OLD.shared", "group.original"])
precondition(original.containers == ["iCloud.original"])
let empty = try snapshot("empty")!
precondition(empty.appGroups == [] && empty.keychainGroups == [])
let malformed = try snapshot("malformed")!
precondition(malformed.appGroups == ["group.original"] && malformed.keychainGroups == ["OLD.app", "group.original"])
precondition(malformed.containers == ["iCloud.original"])
let malformedID = try snapshot("malformed-id")!
precondition(malformedID.keychainGroups == ["OLD.shared", "group.original"])
let mixed = try snapshot("mixed-groups")!
precondition(mixed.appGroups == nil && mixed.keychainGroups == nil)
precondition(mixed.containers == ["iCloud.original"])
let mixedCloud = try snapshot("mixed-cloud")!
let derOnly = try snapshot("der-only")
precondition(mixedCloud.containers == nil && mixedCloud.keys == original.keys)
precondition(mixedCloud.appGroups == original.appGroups && mixedCloud.keychainGroups == original.keychainGroups)
let mixedKeys = try snapshot("mixed-cloud-keys")!
precondition(mixedKeys.keys == nil && mixedKeys.containers == nil)
precondition(mixedKeys.appGroups == original.appGroups && mixedKeys.keychainGroups == original.keychainGroups)
for name in ["malformed-cloud", "malformed-services"] {
    let invalidCloud = try snapshot(name)!
    precondition(invalidCloud.keys == original.keys && invalidCloud.containers == nil)
    precondition(invalidCloud.appGroups == original.appGroups && invalidCloud.keychainGroups == original.keychainGroups)
}
precondition(derOnly == nil)
let unsigned = try snapshot("unsigned")
precondition(unsigned == nil)
print("Original capability snapshot checks passed")
