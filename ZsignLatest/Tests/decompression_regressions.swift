import Foundation

@main struct DecompressionRegressions {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let expected = try Data(contentsOf: root.appendingPathComponent("expected.bin"))
        for name in ["data.tar", "data.tar.gz", "data.tar.bz2", "data.tar.lzma", "data.tar.xz"] {
            let destination = root.appendingPathComponent("output-" + name)
            try extractDebPayload(Data(contentsOf: root.appendingPathComponent(name)), name: name, to: destination)
            let actual = try Data(contentsOf: destination.appendingPathComponent("Library/Frameworks/Test.framework/resource.bin"))
            precondition(actual == expected, name)
        }
        do {
            try extractDebPayload(Data(), name: "unsupported", to: root.appendingPathComponent("unsupported"))
            preconditionFailure("Unsupported payload accepted")
        } catch TweakHandlerError.unsupportedFileExtension(_) {}
        do {
            try extractDebPayload(Data(contentsOf: root.appendingPathComponent("unsafe.tar")), name: "data.tar", to: root.appendingPathComponent("unsafe"))
            preconditionFailure("Unsafe payload accepted")
        } catch TweakHandlerError.decompressionFailed(_) {}
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.txt").path))
        print("Passed real SWCompression plain/gzip/bzip2/lzma/xz payload extraction and path rejection.")
    }
}
