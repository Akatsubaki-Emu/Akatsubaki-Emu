import UIKit
#if !os(tvOS)
import UniformTypeIdentifiers
import WebKit
#endif

#if os(tvOS)
final class LibraryViewController: UIViewController {
    private let stack = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Akatsubaki Emu"
        view.backgroundColor = .black
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fillEqually
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 100),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -100),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 300)
        ])
        let heading = UILabel()
        heading.text = "Akatsubaki Emu"
        heading.font = .systemFont(ofSize: 44, weight: .bold)
        heading.textAlignment = .center
        stack.addArrangedSubview(heading)
        stack.addArrangedSubview(makeButton("Launch session") { [weak self] in
            self?.navigationController?.pushViewController(LaunchSetupViewController(), animated: true)
        })
        stack.addArrangedSubview(makeButton("Steam Store") { [weak self] in
            let alert = UIAlertController(
                title: "Steam Store",
                message: "Embedded web browsing is not available in the tvOS build. Use the iOS build to browse the Steam Store inside Akatsubaki Emu.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        })
        stack.addArrangedSubview(makeButton("Settings") { [weak self] in
            self?.navigationController?.pushViewController(SettingsViewController(), animated: true)
        })
    }

    private func makeButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.cornerStyle = .large
        let button = UIButton(configuration: config)
        button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        return button
    }
}
#else
final class LibraryViewController: UIViewController, UIDocumentPickerDelegate {
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let statusLabel = UILabel()
    private var pickerPurpose: PickerPurpose = .game

    private enum PickerPurpose { case game, operatingSystem, externalDrive, libraryBackup }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Akatsubaki Emu"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Settings", style: .plain, target: self, action: #selector(openSettings))
        buildMenu()
    }

    private func buildMenu() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 22, left: 20, bottom: 28, right: 20)
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        ])

        let heading = UILabel()
        heading.text = "Ready to play?"
        heading.font = .systemFont(ofSize: 34, weight: .bold)
        stack.addArrangedSubview(heading)
        let subtitle = UILabel()
        subtitle.text = "Choose a session or set up an operating system."
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0
        stack.addArrangedSubview(subtitle)

        stack.addArrangedSubview(makeButton("Continue from Last Session", detail: "Restore the last saved VM configuration", symbol: "arrow.clockwise", primary: true) { [weak self] in self?.continueLastSession() })
        stack.addArrangedSubview(makeButton("Launch", detail: "Open the full session setup page", symbol: "play.fill", primary: true) { [weak self] in self?.showLaunchFlow() })
        stack.addArrangedSubview(makeButton("My Games", detail: "Browse imported executables", symbol: "gamecontroller", primary: false) { [weak self] in
            self?.navigationController?.pushViewController(GameLibraryViewController(), animated: true)
        })
        stack.addArrangedSubview(makeButton("Steam Store", detail: "Browse the official Steam Store", symbol: "cart", primary: false) { [weak self] in self?.openSteamStore() })
        stack.addArrangedSubview(makeButton("Import Custom OS", detail: "Choose an OS image or disk file", symbol: "externaldrive.badge.plus", primary: false) { [weak self] in self?.importOperatingSystem() })
        stack.addArrangedSubview(makeButton("Browse External Drive", detail: "Open USB, SD card, or Files-provider storage", symbol: "externaldrive", primary: false) { [weak self] in self?.browseExternalDrive() })
        stack.addArrangedSubview(makeButton("Import Game / Executable", detail: "Add a Windows PE or Linux ELF file", symbol: "plus.rectangle.on.folder", primary: false) { [weak self] in self?.importGame() })
        stack.addArrangedSubview(makeButton("Export Library Backup", detail: "Save game metadata and per-game profiles as JSON", symbol: "square.and.arrow.up", primary: false) { [weak self] in self?.exportLibraryBackup() })
        stack.addArrangedSubview(makeButton("Import Library Backup", detail: "Merge a validated Akatsubaki Emu JSON backup", symbol: "square.and.arrow.down", primary: false) { [weak self] in self?.importLibraryBackup() })
        stack.addArrangedSubview(makeButton("Runtime Capability Report", detail: "See which DroidDeck-style engines are actually available", symbol: "checkmark.shield", primary: false) { [weak self] in self?.showRuntimeCapabilities() })
        stack.addArrangedSubview(makeButton("Settings", detail: "Display, VM, input, and diagnostics", symbol: "gearshape", primary: false) { [weak self] in self?.openSettings() })
        statusLabel.textColor = .secondaryLabel
        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.numberOfLines = 0
        stack.addArrangedSubview(statusLabel)
        updateOSStatus()
    }

    private func updateOSStatus() {
        let osStatus: String
        if let os = UserDefaults.standard.string(forKey: "iSteam.customOSPath") {
            osStatus = "Imported OS image: " + URL(fileURLWithPath: os).lastPathComponent + "\nSaved locally; OS boot integration is not yet implemented."
        } else { osStatus = "No custom OS image imported." }
        let driveName = ExternalDriveStore.shared.rememberedName
        statusLabel.text = osStatus + (driveName.map { "\nRemembered Files location: " + $0 + "\nProvider access is revalidated when the location is used." } ?? "\nExternal storage is accessed through the iOS Files picker.")
    }

    private func makeButton(_ title: String, detail: String, symbol: String, primary: Bool, action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.subtitle = detail
        config.image = UIImage(systemName: symbol)
        config.imagePlacement = .leading
        config.imagePadding = 12
        config.titleAlignment = .leading
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 18, leading: 18, bottom: 18, trailing: 18)
        config.baseBackgroundColor = primary ? .systemBlue : .secondarySystemGroupedBackground
        config.baseForegroundColor = primary ? .white : .label
        let button = UIButton(configuration: config)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 82).isActive = true
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    @objc private func openSettings() { navigationController?.pushViewController(SettingsViewController(), animated: true) }

    private func continueLastSession() {
        guard let session = VMSaveSlotStore.shared.lastSession() else {
            let alert = UIAlertController(
                title: "Saved disk unavailable",
                message: "The last session has no valid disk-image bookmark. Open Launch Setup and choose the guest disk again.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            alert.addAction(UIAlertAction(title: "Set up a session", style: .default) { [weak self] _ in self?.showLaunchFlow() })
            present(alert, animated: true)
            return
        }
        navigationController?.pushViewController(
            VMDisplayViewController(configuration: session.configuration, diskImage: session.diskImageURL,
                                     writableDiskImage: session.writableDiskImageURL),
            animated: true
        )
    }
    private func showLaunchFlow() { navigationController?.pushViewController(LaunchSetupViewController(), animated: true) }
    private func openSteamStore() {
        guard let url = URL(string: "https://store.steampowered.com/") else {
            showMessage("Steam Store", "The Steam Store URL is invalid.")
            return
        }
        // Use WKWebView so the store stays embedded in Akatsubaki Emu on iOS and tvOS.
        let browser = SteamStoreViewController(url: url)
        present(UINavigationController(rootViewController: browser), animated: true)
    }

    private func browseExternalDrive() {
        pickerPurpose = .externalDrive
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item, .folder, .data, .diskImage], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }
    private func importGame() {
        pickerPurpose = .game
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .item], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }
    private func exportLibraryBackup() {
        do {
            let directory = FileManager.default.temporaryDirectory
            let destination = directory.appendingPathComponent("iSteam-library-\(Int(Date().timeIntervalSince1970)).json")
            try GameLibraryTransferStore.shared.export(to: destination)
            let picker = UIDocumentPickerViewController(forExporting: [destination], asCopy: true)
            present(picker, animated: true)
        } catch {
            showMessage("Backup export failed", error.localizedDescription)
        }
    }

    private func importLibraryBackup() {
        pickerPurpose = .libraryBackup
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    private func showRuntimeCapabilities() {
        let lines = DroidDeckPortFeature.allCases.map { feature in
            "\(feature.rawValue): \(feature.readiness.rawValue) — \(feature.explanation)"
        }
        let report = lines.joined(separator: "\n\n")
        let alert = UIAlertController(title: "Runtime Capability Report", message: report, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        alert.addAction(UIAlertAction(title: "Copy report", style: .default) { [weak self] _ in
            UIPasteboard.general.string = report
            self?.showMessage("Copied", "The runtime capability report was copied to the clipboard.")
        })
        present(alert, animated: true)
    }

    private func importOperatingSystem() {
        pickerPurpose = .operatingSystem
        var types: [UTType] = [.data, .diskImage]
        if let iso = UTType(filenameExtension: "iso") { types.append(iso) }
        if let qcow = UTType(filenameExtension: "qcow2") { types.append(qcow) }
        if let img = UTType(filenameExtension: "img") { types.append(img) }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let source = urls.first else { return }
        if pickerPurpose == .libraryBackup {
            do {
                let imported = try GameLibraryTransferStore.shared.importBackup(from: source)
                showMessage("Backup imported", "Added \(imported) new game entr\(imported == 1 ? "y" : "ies"). Existing game IDs were left unchanged. Executable paths in the backup are metadata only and may need to be re-imported on this device.")
            } catch {
                showMessage("Backup import failed", error.localizedDescription)
            }
            return
        }
        if pickerPurpose == .externalDrive {
            do {
                try ExternalDriveStore.shared.remember(source)
                updateOSStatus()
                showMessage("External storage selected", "Selected \(source.lastPathComponent). iOS grants access through Files while the provider is available. This selection is remembered where iOS permits bookmarks; the current engine does not yet expose a raw USB block device to a guest OS.")
            } catch { showMessage("Storage access", "The file is available for this session, but iOS could not save a persistent bookmark: \(error.localizedDescription)") }
            return
        }
        if pickerPurpose == .operatingSystem {
            do {
                let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                let dir = support.appendingPathComponent("OperatingSystems", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let destination = dir.appendingPathComponent(source.lastPathComponent)
                try ExternalDriveStore.shared.copyDocument(at: source, to: destination)
                UserDefaults.standard.set(destination.path, forKey: "iSteam.customOSPath")
                updateOSStatus()
                showMessage("OS image imported", "Saved \(destination.lastPathComponent). The current VM engine does not yet boot imported ISO/disk images.")
            } catch { showMessage("Import failed", error.localizedDescription) }
            return
        }
        do {
            _ = try ExternalDriveStore.shared.withAccess(to: source) { readableSource -> GuestExecutableFormat in
                let formatResult = GuestProcessManager.shared.inspect(readableSource)
                guard case let .success(format) = formatResult,
                      format == .windowsPE || format == .linuxELF else {
                    throw NSError(domain: "iSteam.Import", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "Unsupported executable. Import a Windows PE or Linux ELF executable."
                    ])
                }
                if format == .windowsPE {
                    _ = try WindowsPELoader().load(readableSource)
                } else {
                    try ELFValidator.validate(url: readableSource)
                }
                return format
            }
            let fm = FileManager.default
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let dir = support.appendingPathComponent("Games", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let id = UUID()
            let gameDir = dir.appendingPathComponent(id.uuidString, isDirectory: true)
            try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
            var keepGameDirectory = false
            defer {
                if !keepGameDirectory { try? fm.removeItem(at: gameDir) }
            }
            let destination = gameDir.appendingPathComponent(source.lastPathComponent)
            try ExternalDriveStore.shared.copyDocument(at: source, to: destination)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            let entry = GameEntry(
                id: id,
                name: source.deletingPathExtension().lastPathComponent,
                executablePath: destination.path,
                workingDirectory: gameDir.path
            )
            guard GameStore.shared.add(entry) else {
                throw NSError(domain: "iSteam.Import", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The game library could not be saved. Existing library data was preserved."
                ])
            }
            keepGameDirectory = true
            showMessage("Game imported", source.lastPathComponent + " added to the library.")
        } catch { showMessage("Import failed", error.localizedDescription) }
    }

    private func showMessage(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

#endif

#if !os(tvOS)
private final class GameLibraryViewController: UITableViewController {
    private var games: [GameEntry] = []

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "My Games"
        tableView.rowHeight = 64
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        games = GameStore.shared.search("")
        tableView.reloadData()
        if games.isEmpty {
            let empty = UILabel()
            empty.text = "No imported games yet. Import a Windows PE or Linux ELF executable first."
            empty.textAlignment = .center
            empty.numberOfLines = 0
            empty.textColor = .secondaryLabel
            empty.layoutMargins = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
            tableView.backgroundView = empty
        } else {
            tableView.backgroundView = nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        games.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: "game")
        let game = games[indexPath.row]
        cell.textLabel?.text = game.name
        cell.detailTextLabel?.text = URL(fileURLWithPath: game.executablePath).lastPathComponent
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            ConsoleViewController(game: games[indexPath.row]),
            animated: true
        )
    }
}
#endif

#if !os(tvOS)
private final class SteamStoreViewController: UIViewController, WKNavigationDelegate {
    private let url: URL
    private let webView = WKWebView(frame: .zero)

    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Steam Store"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Close",
            style: .done,
            target: self,
            action: #selector(closeStore)
        )
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        webView.load(URLRequest(url: url))
    }

    @objc private func closeStore() {
        dismiss(animated: true)
    }
}

#endif
