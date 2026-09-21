import Foundation
import YBarKit

// A peer closing its socket mid-reply must surface as EPIPE from write(),
// not as a process-killing SIGPIPE — covers both the daemon and CLI roles.
signal(SIGPIPE, SIG_IGN)

// ybar is a single binary with two roles (sketchybar model):
//  - no domain arguments  -> daemon: owns the bar windows, renderer, event bus, IPC server
//  - domain arguments     -> thin client: serialize argv, send over the unix socket, print reply
// plus the local verbs (`ybar start|stop|restart|status`, `ybar theme …`,
// `ybar autostart …`), which never touch the socket: they work with no daemon
// running, and must not become one.
let arguments = Array(CommandLine.arguments.dropFirst())

if let exit = LocalVerbs.run(arguments: arguments, instanceName: Version.instanceName) {
    Foundation.exit(exit)
}

if let exit = CLIClient.runIfClient(arguments: arguments) {
    Foundation.exit(exit)
}

Daemon.main(arguments: arguments)
