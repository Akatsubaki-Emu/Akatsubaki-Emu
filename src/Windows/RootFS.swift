import Foundation

final class RootFS {
    static let shared = RootFS()
    private let fm = FileManager.default
    private init() {}

    var root: URL {
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WindowsRootFS", isDirectory: true)
        return url
    }

    func prepare() {
        let rootURL = root
        try? fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let dirs = ["Windows", "Program Files", "Program Files (x86)", "Users", "Temp"]
        for dir in dirs {
            try? fm.createDirectory(at: rootURL.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
    }
}
