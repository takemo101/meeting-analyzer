import Foundation
import MeetingAnalyzerKit

let arguments = Array(CommandLine.arguments.dropFirst())
if MeetingAnalyzerApp.isGUILaunch(arguments) {
    MeetingAnalyzerApp.launchGUI()
} else {
    exit(await MeetingAnalyzerApp.runCLI(arguments))
}
