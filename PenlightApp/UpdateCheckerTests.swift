import Foundation

@main
struct UpdateCheckerTest {
    static func main() {
        expect(ReleaseVersion.parts("v1.4.0") == [1, 4, 0], "v-prefixed tag")
        expect(ReleaseVersion.parts("1.10") == [1, 10], "plain version")
        expect(ReleaseVersion.parts("v2.0.0-beta") == [2, 0, 0], "pre-release suffix is ignored")
        expect(ReleaseVersion.parts("latest") == nil, "non-version tag")
        expect(ReleaseVersion.parts("v1..0") == nil, "empty part")

        expect(ReleaseVersion.isNewer("v1.5.0", than: "1.4.0"), "minor bump")
        expect(ReleaseVersion.isNewer("v1.10.0", than: "1.9.3"), "numeric, not text, comparison")
        expect(ReleaseVersion.isNewer("v2", than: "1.9.9"), "major bump with fewer parts")
        expect(ReleaseVersion.isNewer("v1.4.1", than: "1.4"), "patch beyond a shorter version")
        expect(!ReleaseVersion.isNewer("v1.4.0", than: "1.4.0"), "same version")
        expect(!ReleaseVersion.isNewer("v1.4", than: "1.4.0"), "missing parts count as zero")
        expect(!ReleaseVersion.isNewer("v1.3.9", than: "1.4.0"), "older version")
        expect(!ReleaseVersion.isNewer("nightly", than: "1.4.0"), "unparseable tag is never newer")
        print("UpdateChecker self-tests passed")
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            FileHandle.standardError.write("FAIL: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
