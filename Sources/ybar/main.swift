import Foundation
import YBarKit

// ybar is a single binary with two roles (sketchybar model):
//  - no domain arguments  -> daemon: owns the bar windows, renderer, event bus, IPC server
//  - domain arguments     -> thin client: serialize argv, send over the unix socket, print reply
let arguments = Array(CommandLine.arguments.dropFirst())

if let exit = CLIClient.runIfClient(arguments: arguments) {
    Foundation.exit(exit)
}

Daemon.main(arguments: arguments)
