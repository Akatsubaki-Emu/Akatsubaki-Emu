import SwiftUI
import StosSign_Common

extension String: @retroactive Error {}
extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

final class SharedModel: ObservableObject {
    @AppStorage("AnisetteServer") var anisetteServerURL = "https://ani.sidestore.io"
    var session: AppleAPISession?
    var account: Account?
    var team: Team?

    init() {
        AnisetteDataHelper.shared.url = URL(string: anisetteServerURL)
    }
}

final class DataManager {
    static let shared = DataManager()
    let model = SharedModel()
}
