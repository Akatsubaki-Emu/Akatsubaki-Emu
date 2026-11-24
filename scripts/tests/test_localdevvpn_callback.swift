import Foundation

@main
struct LocalDevVPNCallbackTests {
    static func main() {
        let cases: [(String, Bool)] = [
            ("com.xthrx.istem://localdevvpn?status=connected", true),
            ("com.xthrx.istem://localdevvpn?status=Connected", true),
            ("com.xthrx.istem://localdevvpn", true),
            ("com.xthrx.istem://localdevvpn?status=failed", false),
            ("com.xthrx.istem://localdevvpn?status=disconnected", false),
            ("com.xthrx.istem://localdevvpn?status=connecting", false),
            ("com.xthrx.istem://other?status=connected", false),
            ("com.xthrx.istem://localdevvpn?status=connected&status=failed", false),
            ("com.xthrx.istem://localdevvpn?status=failed&status=connected", false),
            ("com.xthrx.istem://localdevvpn?status=", false)
        ]

        for (rawURL, expected) in cases {
            guard let url = URL(string: rawURL) else {
                fatalError("Invalid test URL: \(rawURL)")
            }
            let actual = LocalDevVPNCallback.didConnect(url)
            precondition(
                actual == expected,
                "Unexpected callback result for \(rawURL): expected \(expected), got \(actual)"
            )
        }

        print("LocalDevVPN callback status tests passed (\(cases.count) cases).")
    }
}
