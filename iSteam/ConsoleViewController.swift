import UIKit

final class ConsoleViewController: UIViewController {
    private let game: GameEntry
    private let textView = UITextView()
    private let fpsLabel = UILabel()

    private var displayLink: CADisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var frameCount = 0
    private var logObserver: NSObjectProtocol?

    init(game: GameEntry) {
        self.game = game
        super.init(nibName: nil, bundle: nil)
        title = game.name
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        fpsLabel.translatesAutoresizingMaskIntoConstraints = false
        fpsLabel.textColor = .white
        fpsLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        fpsLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        fpsLabel.textAlignment = .center
        fpsLabel.text = "UI FPS: --"
        fpsLabel.layer.cornerRadius = 8
        fpsLabel.clipsToBounds = true

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.textColor = .white
        textView.backgroundColor = .clear
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)

        view.addSubview(textView)
        view.addSubview(fpsLabel)

        NSLayoutConstraint.activate([
            fpsLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            fpsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            fpsLabel.widthAnchor.constraint(equalToConstant: 90),
            fpsLabel.heightAnchor.constraint(equalToConstant: 30),

            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])

        startFrameMonitor()
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Stop",
            style: .plain,
            target: self,
            action: #selector(stopGuest)
        )

        textView.text = """
        Akatsubaki Emu
        ======

        Game:
        \(game.name)

        Executable:
        \(game.executablePath)

        Working directory:
        \(game.workingDirectory)

        Backend:
        Runtime router

        Display:
        Guest stdout/stderr text console; graphical rendering is not connected.

        Scope:
        Linux static ELF bring-up is supported by the diagnostic interpreter.
        Windows PE still requires a verified compatibility backend.
        """


        logObserver = NotificationCenter.default.addObserver(
            forName: .emulationLogDidWrite,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let message = notification.userInfo?["message"] as? String else { return }
            let stdoutPrefix = "[guest stdout] "
            let stderrPrefix = "[guest stderr] "
            if message.hasPrefix(stdoutPrefix) {
                self?.appendGuestOutput(String(message.dropFirst(stdoutPrefix.count)))
            } else if message.hasPrefix(stderrPrefix) {
                self?.appendGuestOutput("[stderr] " + String(message.dropFirst(stderrPrefix.count)))
            }
        }

        let executable = URL(fileURLWithPath: game.executablePath)
        let workingDirectory = URL(fileURLWithPath: game.workingDirectory)
        let accepted = GameLauncher.shared.launch(
            executable: executable,
            workingDirectory: workingDirectory,
            arguments: game.launchArguments
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.halted):
                self.appendStatus("\n\nGuest process exited.")
            case .success(.interrupted):
                self.appendStatus("\n\nGuest process stopped.")
            case .success(let exit):
                self.appendStatus("\n\nGuest process stopped: \(exit)")
            case .failure(let error):
                self.appendStatus("\n\nGuest launch failed: \(error.localizedDescription)")
            }
        }
        if accepted {
            GameStore.shared.recordLaunchAccepted(id: game.id)
            appendStatus("\n\nGuest launch accepted.")
        } else {
            appendStatus("\n\nNo verified runtime accepted this executable. See the emulation log.")
        }
    }


    deinit {
        if let logObserver {
            NotificationCenter.default.removeObserver(logObserver)
        }
    }

    private func appendGuestOutput(_ output: String) {
        guard !output.isEmpty else { return }
        textView.text.append(output)
        let maximumConsoleCharacters = 128 * 1024
        if textView.text.utf16.count > maximumConsoleCharacters {
            textView.text = String(textView.text.suffix(maximumConsoleCharacters))
        }
        textView.scrollRangeToVisible(NSRange(location: textView.text.utf16.count, length: 0))
    }

    private func appendStatus(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.textView.text.append(message)
        }
    }

    @objc private func stopGuest() {
        LinuxELFRuntime.shared.stop()
    }

    private func startFrameMonitor() {
        displayLink = CADisplayLink(
            target: self,
            selector: #selector(displayLinkTick(_:))
        )

        if #available(iOS 15.0, *) {
            displayLink?.preferredFrameRateRange = CAFrameRateRange(
                minimum: 24,
                maximum: 60,
                preferred: 60
            )
        } else {
            displayLink?.preferredFramesPerSecond = 60
        }

        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        frameCount += 1

        if lastFrameTime == 0 {
            lastFrameTime = link.timestamp
            return
        }

        let elapsed = link.timestamp - lastFrameTime

        if elapsed >= 0.5 {
            let fps = Double(frameCount) / elapsed
            fpsLabel.text = String(format: "UI FPS: %.0f", fps)
            frameCount = 0
            lastFrameTime = link.timestamp
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
        if isMovingFromParent || isBeingDismissed {
            LinuxELFRuntime.shared.stop()
        }
    }
}
