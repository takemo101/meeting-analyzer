import Foundation
import MeetingAnalyzerKit

let arguments = Array(CommandLine.arguments.dropFirst())
if MeetingAnalyzerApp.isGUILaunch(arguments) {
    if isatty(STDIN_FILENO) == 1, MeetingAnalyzerApp.openAppFromTerminal() { exit(0) }
    MeetingAnalyzerApp.launchGUI()
} else {
    exit(await MeetingAnalyzerApp.runCLI(arguments))
}
