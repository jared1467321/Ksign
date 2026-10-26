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
precondition(malformed.appGroups == ["group.original"] && malformed.keychainGroups == nil)
precondition(malformed.containers == ["iCloud.original"])
let malformedID = try snapshot("malformed-id")!
precondition(malformedID.keychainGroups == nil)
let mixed = try snapshot("mixed-groups")!
precondition(mixed.appGroups == nil && mixed.keychainGroups == nil)
precondition(mixed.containers == ["iCloud.original"])
let mixedCloud = try snapshot("mixed-cloud")
let derOnly = try snapshot("der-only")
precondition(mixedCloud == nil)
precondition(derOnly == nil)
let unsigned = try snapshot("unsigned")!
precondition(unsigned.appGroups == [] && unsigned.keychainGroups == [])
print("Original capability snapshot checks passed")
