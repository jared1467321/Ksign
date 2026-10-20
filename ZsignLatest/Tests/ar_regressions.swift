import Foundation

@main struct ARRegressions {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func member(_ name: String, _ value: Data) -> Data {
            func padded(_ value: String, _ length: Int) -> String { value + String(repeating: " ", count: length - value.utf8.count) }
            let header = padded(name, 16) + padded("0", 12) + padded("0", 6) + padded("0", 6) + padded("100644", 8) + padded(String(value.count), 10) + "`\n"
            var data = Data(header.utf8); data.append(value)
            if value.count % 2 != 0 { data.append(0x0a) }
            return data
        }
        let url = root.appendingPathComponent("fixture.deb")
        var valid = Data("!<arch>\n".utf8)
        valid.append(member("first", Data("odd".utf8)))
        valid.append(member("data.tar.gz", Data(repeating: 42, count: 10000)))
        try valid.write(to: url)
        let contents = try await AR(with: url).extract()
        precondition(contents.count == 2 && contents[0].name == "first" && contents[0].content == Data("odd".utf8))
        precondition(contents[1].content == Data(repeating: 42, count: 10000))
        for invalid in [Data(), Data("bad".utf8), valid.prefix(15), valid.dropLast(12)] {
            try Data(invalid).write(to: url)
            do { _ = try await AR(with: url).extract(); preconditionFailure("Invalid AR accepted") }
            catch is ARError {}
        }
        print("Passed mapped AR members, alignment and malformed/truncated package rejection.")
    }
}
