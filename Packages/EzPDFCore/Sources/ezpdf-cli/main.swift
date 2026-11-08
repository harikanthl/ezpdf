import AppKit
import EzPDFCore

setvbuf(stdout, nil, _IONBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

Task { @MainActor in
    let code = await CLI.run(args)
    exit(code)
}
app.run()
