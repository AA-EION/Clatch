// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Issen Software Group
//
// Clatch for Linux: switch Claude Desktop accounts without signing out.
//
// A single-instance GTK application (libadwaita): a second `clatch` (a
// profile launcher, a claude:// link, the GNOME shortcut, a script) hands its
// arguments to the running one over D-Bus and exits.

import CGtk
import ClatchCore
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--version") {
    print("Clatch \(AppModel.version)")
    exit(0)
}
if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    Usage: clatch [option]
      (none)               Open Clatch's window
      --background         Start without opening the window (used at login)
      --launch <id>        Open a profile (what profile launchers run)
      --switcher           Open the profile switcher, or move to the next profile in it
      --switch-next        Open the next profile directly
      --add-account [name] Add an account
      --open-link <url>    Handle a claude:// link
      --settings           Open Clatch's settings
      --quit               Quit the running Clatch
      --version            Print the version
    """)
    exit(0)
}

MainLoop.attachMainQueue()

@MainActor
final class Application {
    let app: GPtr
    let model = AppModel()
    lazy var panel = Panel(model: model)
    let tray = Tray()
    private var started = false

    init() {
        app = g(adw_application_new(Desktop.appID, G_APPLICATION_HANDLES_COMMAND_LINE))
        model.app = app
        g_set_application_name("Clatch")
        onSignal(app, "startup") { [weak self] in self?.startup() }
        onSignal(app, "activate") { [weak self] in self?.panel.present() }
        connectCommandLine()
    }

    func run() -> Int32 {
        g_application_run(app.t(), CommandLine.argc, CommandLine.unsafeArgv)
    }

    private func startup() {
        // Keep running with no window open: Clatch lives in the notification area.
        g_application_hold(app.t())
        UI.installStyle()
        gtk_window_set_default_icon_name(Desktop.appID)
        model.requestPanel = { [weak self] in self?.panel.present(token: self?.model.activationToken) }
        model.observe { [weak self] in self?.modelChanged() }
        model.start()
        tray.onActivate = { [weak self] in self?.panel.toggle() }
        tray.start()
        started = true
    }

    private func modelChanged() {
        let text: String
        if model.isBusy { text = "Clatch: switching accounts…" }
        else if let active = model.state.active { text = "Clatch: \(active.name)" }
        else { text = "Clatch" }
        tray.setTooltip(text)
    }

    // MARK: - Command line (this process's, or another clatch's handed over)

    private func connectCommandLine() {
        typealias Fn = @MainActor (GPtr) -> Int32
        let handler: Fn = { [weak self] commandLine in self?.handle(commandLine) ?? 0 }
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32 = { _, commandLine, data in
            let fn = Unmanaged<Box<Fn>>.fromOpaque(data!).takeUnretainedValue().value
            nonisolated(unsafe) let commandLine = commandLine!
            return MainActor.assumeIsolated { fn(commandLine) }
        }
        clatch_connect(app, "command-line", unsafeBitCast(callback, to: GCallback.self),
                       Unmanaged.passRetained(Box(handler)).toOpaque(), nil)
    }

    private func handle(_ commandLine: GPtr) -> Int32 {
        var argc: Int32 = 0
        var args: [String] = []
        if let argv = g_application_command_line_get_arguments(commandLine.t(), &argc) {
            for i in 1..<max(Int(argc), 1) { if let a = argv[i] { args.append(String(cString: a)) } }
            g_strfreev(argv)
        }
        // The desktop's activation token for the invoking launcher, so windows may come forward (Wayland).
        if let data = g_application_command_line_get_platform_data(commandLine.t()) {
            let dict = V.readDict(data)
            if let token = (dict["activation-token"] ?? dict["desktop-startup-id"]).map(V.getString), !token.isEmpty {
                model.activationToken = token
            }
            g_variant_unref(data)
        }
        run(args)
        return 0
    }

    private func run(_ args: [String]) {
        var i = 0
        while i < args.count {
            let arg = args[i]
            let next = i + 1 < args.count ? args[i + 1] : nil
            switch arg {
            case "--background":
                // At login: stay in the tray. Without a tray (plain GNOME), there is nothing else to show anyway.
                return
            case "--launch":
                if let next, let id = UUID(uuidString: next) {
                    Log.write("A profile shortcut was opened")
                    model.open(id)
                }
                return
            case "--switch-next":
                model.store.load()
                if let id = model.store.state.next?.id { model.open(id) }
                return
            case "--switcher":
                model.hotKeyPressed(token: model.activationToken, fromPortal: false)
                return
            case "--add-account":
                Log.write("Command line: add account")
                model.addAccount(name: next ?? "", renameCurrentTo: nil)
                return
            case "--open-link":
                if let next { model.handle(link: next) }
                return
            case "--settings":
                model.show(.settings)
                panel.present(token: model.activationToken)
                return
            case "--quit":
                g_application_quit(app.t())
                return
            default:
                if arg.lowercased().hasPrefix("claude:") { model.handle(link: arg); return }
            }
            i += 1
        }
        // No action (started from the app grid, or a second time): open the window.
        panel.present(token: model.activationToken)
    }
}

let application = Application()
exit(application.run())
