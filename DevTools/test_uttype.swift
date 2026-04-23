import UniformTypeIdentifiers

if let t = UTType(filenameExtension: "wma") {
    print("wma supported: \(t.identifier)")
} else {
    print("wma unsupported")
}
