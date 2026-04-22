import AVFoundation

let url = URL(fileURLWithPath: "/Users/byeongsukim/04Hurst 102test/test_out.mp4")
do {
    let file = try AVAudioFile(forReading: url)
    print("Success: \(file.length) frames at \(file.processingFormat.sampleRate)Hz")
} catch {
    print("Error: \(error)")
}
