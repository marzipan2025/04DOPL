import Foundation

let sourceURL = URL(fileURLWithPath: "/Users/byeongsukim/04Hurst 102test/삼국지045(제9부-조조와유비5).wma")
let ffmpegPath = "/opt/homebrew/bin/ffmpeg"
let ffprobePath = "/opt/homebrew/bin/ffprobe"

func runFFmpeg(args: [String]) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: ffmpegPath)
    task.arguments = args
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch { return false }
}

let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("hurst-remux-test.mp4")

let fallbackArgs = [
    "-y", "-i", sourceURL.path,
    "-vn",
    "-c:a", "aac", "-b:a", "192k",
    "-sn",
    "-movflags", "+faststart",
    tempURL.path
]

print("Running fallbackArgs:", fallbackArgs.joined(separator: " "))
if runFFmpeg(args: fallbackArgs) {
    print("Fallback success: \(tempURL.path)")
} else {
    print("Fallback failed")
}
