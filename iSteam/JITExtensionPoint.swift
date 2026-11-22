#if os(iOS)
import ExtensionFoundation

@available(iOS 26.0, *)
extension AppExtensionPoint {
    @Definition
    static var akatsubakiJITHelper: AppExtensionPoint {
        Name("AkatsubakiJITHelper")
    }
}
#endif
