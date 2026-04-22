#!/usr/bin/env swift
// HTML → PNG 렌더러 (WKWebView 스냅샷 사용)
// 실행: swift render_background.swift <html_path> <output_png_path>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 3 else {
    print("Usage: swift render_background.swift <html> <output.png>")
    exit(1)
}

let htmlURL  = URL(fileURLWithPath: args[1])
let outURL   = URL(fileURLWithPath: args[2])
let W: CGFloat = 640
let H: CGFloat = 480

class Renderer: NSObject, WKNavigationDelegate {
    let wv: WKWebView
    let out: URL
    var done = false

    init(out: URL) {
        self.out = out
        let cfg = WKWebViewConfiguration()
        wv = WKWebView(frame: NSRect(x: 0, y: 0, width: W, height: H), configuration: cfg)
        super.init()
        wv.navigationDelegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let cfg = WKSnapshotConfiguration()
            cfg.rect = NSRect(x: 0, y: 0, width: W, height: H)
            cfg.snapshotWidth = NSNumber(value: Double(W * 2))   // @2x
            self.wv.takeSnapshot(with: cfg) { img, err in
                guard let img else { print("snapshot failed: \(err!)"); exit(1) }
                let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
                let png = rep.representation(using: .png, properties: [.interlaced: false])!
                try! png.write(to: self.out)
                print("✓ background written to \(self.out.path)")
                self.done = true
            }
        }
    }
}

// NSApplication 초기화 (WKWebView 실행에 필요)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let r = Renderer(out: outURL)
r.wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())

// RunLoop 진행
let deadline = Date().addingTimeInterval(15)
while !r.done && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
}
guard r.done else { print("timeout"); exit(1) }
