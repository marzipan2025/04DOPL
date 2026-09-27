import AVFoundation
import AppKit
import os
import Accelerate
import CoreImage

/// Pre-analyzed audio energy frame for audio visualization.
struct AudioEnergyFrame {
    let rms: Float       // Overall RMS level (0–1)
}

private let urlLog = Logger(subsystem: "com.hurst.app", category: "url")

@MainActor
class VideoSampler: ObservableObject {
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var legibleOutput: AVPlayerItemLegibleOutput?
    private var subtitleDelegate: SubtitleDelegate?
    private var timer: Timer?
    private var lastPixelBuffer: CVPixelBuffer?
    private var endObserver: Any?   // AVPlayerItem 재생 종료 알림 토큰
    private var videoFrameGeneration: UInt64 = 0
    private var lastRenderSignature: RenderSignature?

    private struct RenderSignature: Equatable {
        let gridSize: Int
        let displayW: Int
        let displayH: Int
        let frameGeneration: UInt64
        let zoomPermille: Int
        // 줌 중심도 서명에 들어가야 한다. 빠지면 일시정지 상태에서 커서 기준으로 확대할 때
        // 배율이 같은 구간(한계에 붙었을 때)에서 화면이 갱신되지 않는다.
        let centerXPermille: Int
        let centerYPermille: Int
    }

    // 콘텐츠 줌 (기본 화면 대비 배율). 1.0 이 뜻하는 기본 화면은 모드마다 다르다 —
    // 전체화면은 fit(레터박스), 창 모드는 창을 꽉 채운 중앙 크롭이다. 두 모드가 원래
    // 그렇게 다르게 그리므로, 배율은 각자의 기본 화면 위에 얹힌다.
    //   fit    = 기본 화면 그대로 (배율 1.0)
    //   fill   = 비율 유지로 화면을 꽉 채움(넘치는 부분 크롭) — 전체화면 전용(⌘1)
    //   custom = 핀치 제스처로 만든 임의 배율
    enum ContentZoom: Equatable {
        case fit
        case fill
        case custom(CGFloat)
    }
    @Published var contentZoom: ContentZoom = .fit

    /// 콘텐츠 줌의 중심 — 원본 프레임의 정규화 좌표(0~1, 기본 정중앙).
    /// 핀치는 커서 아래 지점을 붙잡아 두므로 확대하는 동안 이 값이 움직인다.
    @Published private(set) var contentCenter = CGPoint(x: 0.5, y: 0.5)

    private static let defaultContentCenter = CGPoint(x: 0.5, y: 0.5)

    static let maxContentZoom: CGFloat = 8.0

    /// fit 대비 fill 배율. 디스플레이/비디오 비율이 같으면 1.
    private func fillScale(dispW: CGFloat, dispH: CGFloat, videoAspect: CGFloat) -> CGFloat {
        let displayAspect = dispW / dispH
        return displayAspect > videoAspect
            ? displayAspect / videoAspect
            : videoAspect / displayAspect
    }

    /// 현재 모드의 실효 배율 (fit 기준 1.0).
    private func effectiveZoom(dispW: CGFloat, dispH: CGFloat, videoAspect: CGFloat) -> CGFloat {
        switch contentZoom {
        case .fit:              return 1.0
        case .fill:             return fillScale(dispW: dispW, dispH: dispH, videoAspect: videoAspect)
        case .custom(let z):    return z
        }
    }

    /// 현재 표시 상태의 실효 콘텐츠 줌 (fit=1). 피크 레이어 등 외부 뷰 동기화용.
    func currentEffectiveZoom() -> CGFloat {
        let dispW = currentDisplaySize.width, dispH = currentDisplaySize.height
        guard dispW > 0, dispH > 0, videoSize.width > 0, videoSize.height > 0 else { return 1 }
        return effectiveZoom(dispW: dispW, dispH: dispH,
                             videoAspect: videoSize.width / videoSize.height)
    }

    /// 영상 전체가 화면에서 차지하는 크기(기본 화면 × 줌)와 디스플레이 크기.
    /// 커서 앵커 계산과 피크 레이어 오프셋이 같은 값을 봐야 도트와 실영상이 어긋나지 않는다.
    ///
    /// 기본 화면은 모드마다 다르다. 전체화면은 fit(화면 안에 다 들어옴), 창 모드는
    /// fill(창을 꽉 채우고 넘치는 쪽을 자름) — 각 모드가 실제로 그리는 방식 그대로다.
    ///
    /// `displaySize` 를 주면 그걸 쓴다. 창을 끌어 늘리는 중에는 SwiftUI 레이아웃이 먼저
    /// 새 크기로 그리고 `currentDisplaySize` 는 그 뒤에 갱신돼서, 저장된 값을 쓰면 피크
    /// 레이어가 한 프레임씩 뒤처진다.
    private func zoomedContentSize(displaySize: CGSize? = nil) -> (scaled: CGSize, display: CGSize)? {
        let size = displaySize ?? currentDisplaySize
        let dispW = size.width, dispH = size.height
        guard dispW > 0, dispH > 0, videoSize.width > 0, videoSize.height > 0 else { return nil }
        let videoAspect = videoSize.width / videoSize.height
        let wide = dispW / dispH > videoAspect      // 화면이 영상보다 옆으로 넓은가
        let fitsHeight = isFullscreen ? wide : !wide
        // fit  은 짧은 쪽에 맞춘다 → 넓은 화면이면 높이가 한계.
        // fill 은 긴 쪽에 맞춘다  → 넓은 화면이면 너비가 한계.
        let baseW: CGFloat, baseH: CGFloat
        if fitsHeight {
            baseH = dispH; baseW = baseH * videoAspect
        } else {
            baseW = dispW; baseH = baseW / videoAspect
        }
        let zoom = effectiveZoom(dispW: dispW, dispH: dispH, videoAspect: videoAspect)
        return (CGSize(width: baseW * zoom, height: baseH * zoom),
                CGSize(width: dispW, height: dispH))
    }

    /// 중심을 원본 밖으로 나가지 못하게 되돌린다. 이걸 매 줌 단계마다 하지 않으면
    /// 축소할 때 가장자리에 빈 영역이 생긴다.
    /// 보이는 영역이 그 축의 원본을 다 덮으면(레터박스가 생기는 축) 움직일 여지가 없어 0.5 로 고정된다.
    private func clampContentCenter() {
        guard let g = zoomedContentSize() else {
            setContentCenter(Self.defaultContentCenter)
            return
        }
        func clamp(_ v: CGFloat, visible: CGFloat, scaled: CGFloat) -> CGFloat {
            guard scaled > 0 else { return 0.5 }
            let half = min(visible, scaled) / scaled / 2   // 보이는 폭의 절반(원본 기준 비율)
            guard half < 0.5 else { return 0.5 }
            return min(max(v, half), 1 - half)
        }
        setContentCenter(CGPoint(
            x: clamp(contentCenter.x, visible: g.display.width,  scaled: g.scaled.width),
            y: clamp(contentCenter.y, visible: g.display.height, scaled: g.scaled.height)
        ))
    }

    /// 값이 실제로 달라질 때만 발행한다. 창 크기 변경 경로에서도 불리므로,
    /// 같은 값을 다시 넣어 레이아웃 도중 불필요한 갱신을 만들지 않는다.
    private func setContentCenter(_ p: CGPoint) {
        guard p != contentCenter else { return }
        contentCenter = p
    }

    /// 핀치 제스처 증분 적용. 현재 실효 배율에서 이어서 커스텀 배율로 전환.
    ///
    /// `anchor` 는 커서 위치(디스플레이 좌표, 좌상단 원점). 주면 그 지점의 영상이 제자리에
    /// 머무르도록 중심을 옮긴다 — 화면 한가운데가 아니라 보고 있던 곳이 커진다.
    /// nil 이면 예전처럼 중앙 기준으로 확대된다.
    func zoomBy(magnification delta: CGFloat, anchor: CGPoint? = nil) {
        guard let before = zoomedContentSize() else { return }
        let current = currentEffectiveZoom()
        let next = min(max(current * (1 + delta), 1.0), Self.maxContentZoom)
        // 한계(1.0 / max)에 붙은 뒤에도 앵커 보정을 계속하면 배율은 그대로인데 화면만
        // 밀린다. 배율이 실제로 변할 때만 중심을 건드린다.
        guard next != current else { return }

        if let anchor, before.scaled.width > 0, before.scaled.height > 0, current > 0 {
            // 커서 아래의 원본 좌표(정규화)를 먼저 구하고, 새 배율에서 그 점이 같은 화면
            // 위치에 오도록 중심을 역산한다.
            let scaledAfter = CGSize(width:  before.scaled.width  * (next / current),
                                     height: before.scaled.height * (next / current))
            let dx = anchor.x - before.display.width  / 2
            let dy = anchor.y - before.display.height / 2
            let u = CGPoint(x: contentCenter.x + dx / before.scaled.width,
                            y: contentCenter.y + dy / before.scaled.height)
            setContentCenter(CGPoint(x: u.x - dx / scaledAfter.width,
                                     y: u.y - dy / scaledAfter.height))
        }

        if next <= 1.0 {
            // 배율을 완전히 풀면 기본 화면으로 돌아온다. 창 모드에는 ⌘0/⌘1 같은 복귀
            // 수단이 없어서(⌘0 은 창 크기 조절이다), 여기서 되돌리지 않으면 한쪽으로
            // 치우친 크롭에 갇힌다. 전체화면은 fit 이라 어차피 중앙 고정이다.
            contentZoom = .fit
            setContentCenter(Self.defaultContentCenter)
        } else {
            contentZoom = .custom(next)
            clampContentCenter()
        }
    }

    /// 확대해서 보고 있는 위치를 옮긴다(⌘ 드래그). `dx`/`dy` 는 화면에서 끈 거리(포인트).
    /// 화면을 오른쪽으로 끌면 영상도 오른쪽으로 따라와야 하므로 원본에서 읽는 위치는 왼쪽으로 간다.
    ///
    /// 확대하지 않았으면 아무 일도 하지 않는다. 창 모드의 기본 화면(꽉 채운 크롭)은 넘치는
    /// 축에 여유가 남아 있어 그냥 두면 배율 1.0에서도 움직이는데, 그러면 핀치를 조금
    /// 건드렸다 놓는 순간 중앙으로 되돌아가 버려서 앞뒤가 맞지 않는다.
    func panBy(dx: CGFloat, dy: CGFloat) {
        guard currentEffectiveZoom() > 1, let g = zoomedContentSize(),
              g.scaled.width > 0, g.scaled.height > 0 else { return }
        setContentCenter(CGPoint(x: contentCenter.x - dx / g.scaled.width,
                                 y: contentCenter.y - dy / g.scaled.height))
        clampContentCenter()
    }

    /// 확대 상태 여부. ⌘ 드래그를 창 이동에서 가로챌지 판단하는 데 쓴다.
    var isContentZoomed: Bool { currentEffectiveZoom() > 1 }

    /// 피크(실영상) 레이어가 놓일 자리 — **영상 전체**가 그려질 크기와, 창 중앙 기준 이동량.
    /// 도트는 원본에서 읽는 위치를 옮기고 피크는 레이어를 옮긴다 — 둘이 같아야 피크로
    /// 넘어갈 때 화면이 튀지 않는다.
    ///
    /// 크기를 영상 전체로 주는 게 핵심이다. 창 크기 레이어에 배율만 걸면 `.resizeAspectFill`
    /// 이 넘치는 부분을 레이어 안에서 이미 잘라 버려서, 옮겨도 잘려나간 영상이 아니라
    /// 뒤의 검은 배경이 드러난다.
    func peekContentLayout(displaySize: CGSize) -> (size: CGSize, offset: CGSize)? {
        guard let g = zoomedContentSize(displaySize: displaySize) else { return nil }
        return (g.scaled,
                CGSize(width:  (0.5 - contentCenter.x) * g.scaled.width,
                       height: (0.5 - contentCenter.y) * g.scaled.height))
    }

    func zoomToFit()  { contentZoom = .fit;  contentCenter = Self.defaultContentCenter }
    func zoomToFill() { contentZoom = .fill; contentCenter = Self.defaultContentCenter }

    @Published var dotColors: [[CGColor]] = []
    @Published var videoSize: CGSize = .zero
    @Published var isPlaying = false
    @Published var urlLoadError: String?     // URL 또는 ffmpeg 처리 실패 등
    @Published var isLoadingMedia: Bool = false   // remux / 웹 URL 해석 진행 중 표시용
    /// yt-dlp 로 해석한 웹 페이지 URL 의 제목. ContentView 가 최근 항목 제목 보강에 사용.
    @Published var resolvedURLTitle: ResolvedURLTitle?
    @Published var isStaticContent: Bool = false  // 이미지 모드 — 플레이 기능 비활성화
    @Published var isAudioMode: Bool = false      // 오디오 전용 모드 — 영상 없이 시각화
    @Published var backgroundDotAlpha: Double = 0.40
    
    // 볼륨 영속성 (0.0 ~ 1.2)
    private static let volumeKey = "hurst.volume"
    private var lastVolume: Float = 1.0

    private var activeRemuxTempURL: URL?
    /// open 요청마다 증가. 비동기 URL 해석 결과가 늦게 도착했을 때 무시하기 위한 토큰.
    private var openGeneration: UInt64 = 0
    // 오디오 시각화용 사전 분석 데이터
    private var audioEnergyFrames: [AudioEnergyFrame] = []
    private var audioAnalysisRate: Double = 30.0
    private var audioAnalysisTask: Task<Void, Never>?

    // 자막
    @Published var hasSubtitles: Bool = false
    @Published var showSubtitles: Bool = true
    @Published var currentSubtitle: String = ""
    @Published var hasExternalSubtitle: Bool = false
    private enum SubtitleMode: Equatable {
        case off
        case embedded
        case external
    }
    private var subtitleMode: SubtitleMode = .off
    private var legibleGroup: AVMediaSelectionGroup?
    private var firstLegibleOption: AVMediaSelectionOption?
    private var hasEmbeddedSubtitle: Bool = false
    // 외부 자막(.srt, .smi). 로드 시 embedded 보다 우선.
    private var externalCues: [SubtitleCue] = []
    private var externalTimeObserver: Any?

    // 오버레이 효과
    enum OverlayEffect: Equatable {
        case none
        case border       // play/pause: 테두리 전체
        case row(Int)     // 볼륨: 1-based visible row (위=1)
        case col(Int)     // seek: 1-based visible col (왼쪽=1)
    }
    @Published var overlayEffect: OverlayEffect = .none
    @Published var overlayProgress: Double = 0.0
    @Published var overlayBlinks: Int = 1
    @Published var overlayIsAlert: Bool = false   // 한계치 도달 시 true -> 악센트 색상으로 강제
    private var overlayStartTime: Date?
    private let overlayDuration: TimeInterval = 0.5

    var currentDisplaySize: CGSize = .zero
    var isFullscreen: Bool = false

    // 점 크기/간격 (w,s,a,d,z 키로 조절)
    // 제약: dotDiameter ≥ 8, gridSize ≥ dotDiameter + minGap
    //       (gap = gridSize − dotDiameter ≥ 1 → 점끼리 붙지 않음)
    // 마지막 값은 UserDefaults에 저장되어 다음 실행 시 복원. z 초기화는 기본값으로 되돌림.
    private let defaultGridSize: CGFloat = 40
    private let defaultDotDiameter: CGFloat = 16
    private let dotDiameterMin: CGFloat = 8
    private let minGap: CGFloat = 1
    private static let gridSizeKey    = "hurst.gridSize"
    private static let dotDiameterKey = "hurst.dotDiameter"
    @Published var gridSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(gridSize), forKey: Self.gridSizeKey) }
    }
    @Published var dotDiameter: CGFloat {
        didSet { UserDefaults.standard.set(Double(dotDiameter), forKey: Self.dotDiameterKey) }
    }

    // 자막 글자 크기 ([/] 키로 조절). 기본 18pt, 최소 18pt, 4pt씩 최대 54pt까지.
    // 값이 바뀌면 Canvas가 re-render되어 도트 숨김 영역이 즉시 갱신됨.
    let subtitleFontMin: CGFloat = 18
    let subtitleFontDefault: CGFloat = 18
    let subtitleFontStep: CGFloat = 4
    let subtitleFontMaxSteps: Int = 9
    private static let subtitleFontSizeKey = "hurst.subtitleFontSize"
    @Published var subtitleFontSize: CGFloat {
        didSet { UserDefaults.standard.set(Double(subtitleFontSize), forKey: Self.subtitleFontSizeKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        var d = (defaults.object(forKey: Self.dotDiameterKey) as? Double).map { CGFloat($0) } ?? defaultDotDiameter
        var g = (defaults.object(forKey: Self.gridSizeKey)    as? Double).map { CGFloat($0) } ?? defaultGridSize
        // 저장된 값이 현재 제약을 위반할 수 있으니 방어적으로 clamp
        d = max(dotDiameterMin, d)
        g = max(d + minGap, g)
        self.dotDiameter = d
        self.gridSize = g

        let subMin = 18 as CGFloat
        let subDefault = 18 as CGFloat
        let subStep = 4 as CGFloat
        let subMaxSteps = 9
        let subMax = subMin + subStep * CGFloat(subMaxSteps)
        var s = (defaults.object(forKey: Self.subtitleFontSizeKey) as? Double).map { CGFloat($0) } ?? subDefault
        s = max(subMin, min(subMax, s))
        // 스텝 경계로 스냅 (저장값이 오염됐을 경우 방어)
        let steps = (s - subMin) / subStep
        s = subMin + subStep * CGFloat(Int(steps.rounded()))
        self.subtitleFontSize = s
        
        // 저장된 볼륨 복원 (기본값 1.0)
        self.lastVolume = (defaults.object(forKey: Self.volumeKey) as? Float) ?? 1.0
    }

    func increaseDotSize() {
        // 점 크기는 gridSize - minGap 까지만 (gap ≥ 1)
        dotDiameter = min(gridSize - minGap, dotDiameter + 2)
    }

    func decreaseDotSize() {
        dotDiameter = max(dotDiameterMin, dotDiameter - 2)
    }

    func increaseGap() {
        gridSize += 2
    }

    func decreaseGap() {
        // gridSize는 dotDiameter + minGap 아래로 내려갈 수 없음 (gap ≥ 1)
        gridSize = max(dotDiameter + minGap, gridSize - 2)
    }

    func resetDotSettings() {
        gridSize = defaultGridSize
        dotDiameter = defaultDotDiameter
    }

    func increaseSubtitleSize() {
        let maxSize = subtitleFontMin + subtitleFontStep * CGFloat(subtitleFontMaxSteps)
        subtitleFontSize = min(maxSize, subtitleFontSize + subtitleFontStep)
    }

    func decreaseSubtitleSize() {
        subtitleFontSize = max(subtitleFontMin, subtitleFontSize - subtitleFontStep)
    }

    // MARK: - Open

    /// 외부 진입점. AVFoundation이 지원 안 하는 컨테이너(mkv/webm/avi 등)는 ffmpeg로 remux 후 재생.
    /// 이미지 확장자면 정적 이미지 모드로 로드 (플레이 관련 기능은 비활성).
    func open(url: URL) {
        openGeneration &+= 1
        isLoadingMedia = false
        startTimerIfNeeded()
        // 이미지 파일은 별도 경로로 처리
        if url.isFileURL && Self.isImageFile(url: url) {
            openImage(url: url)
            return
        }

        cleanup()
        // 기존 remux 임시 파일 제거
        if let prev = activeRemuxTempURL {
            try? FileManager.default.removeItem(at: prev)
            activeRemuxTempURL = nil
        }

        // 로컬 파일이고 AVFoundation이 지원 안 하는 확장자면 remux
        if url.isFileURL && Self.needsRemux(url: url) {
            isLoadingMedia = true
            Task.detached { [weak self] in
                let outcome = await Self.remuxToMP4(source: url)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isLoadingMedia = false
                    switch outcome {
                    case .success(let tempURL):
                        self.activeRemuxTempURL = tempURL
                        self.loadPlayable(url: tempURL)
                    case .failure(let message):
                        self.urlLoadError = message
                    }
                }
            }
        } else {
            loadPlayable(url: url)
        }
    }

    /// AVPlayer가 바로 재생 가능한 URL을 로드
    private func loadPlayable(url: URL) {
        let asset = AVURLAsset(url: url)
        let generation = openGeneration
        let item = AVPlayerItem(asset: asset)

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: outputSettings)
        item.add(output)
        videoOutput = output

        // 자막 출력(attributed string 푸시). 플레이어 렌더링은 억제하고 우리가 직접 그린다.
        let legible = AVPlayerItemLegibleOutput(mediaSubtypesForNativeRepresentation: [])
        legible.suppressesPlayerRendering = true
        let delegate = SubtitleDelegate { [weak self] strings in
            Task { @MainActor in
                guard let self else { return }
                // showSubtitles가 꺼져 있으면 갱신만 받아서 버리지 않고 비운다.
                let text = strings
                    .map { $0.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                self.currentSubtitle = text
            }
        }
        legible.setDelegate(delegate, queue: .main)
        item.add(legible)
        self.legibleOutput = legible
        self.subtitleDelegate = delegate

        player = AVPlayer(playerItem: item)
        player?.volume = lastVolume

        // 자막 초기 상태 리셋
        hasSubtitles = false
        currentSubtitle = ""
        legibleGroup = nil
        firstLegibleOption = nil
        hasEmbeddedSubtitle = false

        // 오디오 파일은 즉시 오디오 모드 진입 (타이머 시작 전 placeholder 방지)
        if url.isFileURL && Self.isAudioFile(url: url) {
            isAudioMode = true
        }

        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    // 비디오 트랙 있음 → 비디오 모드
                    self.isAudioMode = false
                    let naturalSize = try await track.load(.naturalSize)
                    let transform   = try await track.load(.preferredTransform)
                    let transformed = naturalSize.applying(transform)
                    let absSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
                    self.videoSize = (absSize.width > 0 && absSize.height > 0) ? absSize : naturalSize
                } else {
                    // 비디오 트랙 없음 → 오디오 전용 모드
                    self.isAudioMode = true
                }
                // 오디오 모드일 때 로컬 파일이면 빠른 볼륨 추출 후 재생
                if self.isAudioMode && url.isFileURL {
                    let fileURL = url
                    self.audioAnalysisTask = Task.detached { [weak self] in
                        let result = VideoSampler.analyzeAudioFile(url: fileURL)
                        await MainActor.run { [weak self] in
                            self?.audioEnergyFrames = result.frames
                            self?.audioAnalysisRate = result.rate
                            
                            // 분석이 눈 깜짝할 새 끝나므로 곧바로 재생 시작
                            self?.player?.play()
                            self?.isPlaying = true
                        }
                    }
                } else {
                    // 비디오이거나 외부 URL 오디오인 경우 바로 재생
                    self.player?.play()
                    self.isPlaying = true
                }
            } catch {
                print("Failed to load video track: \(error)")
                // 원격 URL 은 403 등으로 열리지 않으면 조용히 멈춰 있지 말고 알린다.
                if !url.isFileURL {
                    guard self.openGeneration == generation else { return }
                    urlLog.error("AVPlayer failed to open \(url.absoluteString, privacy: .public): \(String(describing: error), privacy: .public)")
                    self.urlLoadError = "영상을 열 수 없습니다.\n\n\(error.localizedDescription)"
                    return
                }
                self.player?.play()
                self.isPlaying = true
            }
        }

        // legible(자막) 트랙 탐지 및 자동 선택
        Task { [weak self] in
            guard let self else { return }
            do {
                let group = try await asset.loadMediaSelectionGroup(for: .legible)
                await MainActor.run {
                    guard let group else { return }
                    let options = group.options.filter {
                        !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                    }
                    self.legibleGroup = group
                    self.firstLegibleOption = options.first
                    self.hasEmbeddedSubtitle = !options.isEmpty
                    self.updateHasSubtitlesFlag()
                    if self.hasExternalSubtitle {
                        self.subtitleMode = .external
                    } else if self.showSubtitles && !options.isEmpty {
                        self.subtitleMode = .embedded
                    } else {
                        self.subtitleMode = .off
                    }
                    self.applySubtitleMode()
                }
            } catch {
                // legible 그룹이 없는 자산은 정상(자막 없음)
            }
        }

        // 재생 종료 감지 → ContentView 에 알림. 이전 observer 가 있으면 먼저 제거.
        if let prev = endObserver { NotificationCenter.default.removeObserver(prev) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.isPlaying = false
                NotificationCenter.default.post(name: .playbackEnded, object: nil)
            }
        }

        // 재생 시작(play / isPlaying)은 위 Task 내부 조건(분석 완료 후 등)으로 이동됨.

        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleCurrentFrame() }
        }
        // .common 모드로 등록 → 마우스 홀드(일반 peek) 등 이벤트 트래킹 중에도 계속 샘플링.
        // (.default 모드 타이머는 마우스를 누르고 있는 동안 멈춰 dotColors가 동결됨)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// 자막 표시 토글. 자막 트랙(내장/외장 어느 쪽이든)이 없으면 아무 일도 하지 않음.
    /// 외부/내장 자막이 모두 있으면 외부 → 내장 → OFF 순서로 순환한다.
    func toggleSubtitles() {
        let modes = availableSubtitleModesInCycleOrder()
        guard !modes.isEmpty else { return }

        let current = effectiveSubtitleMode()
        let nextIndex = modes.firstIndex(of: current).map { ($0 + 1) % modes.count } ?? 0
        subtitleMode = modes[nextIndex]
        applySubtitleMode()
    }

    // MARK: - External Subtitle (.srt / .smi)

    /// Shift+C 로 선택된 외부 자막 파일 로드. 성공 시 true, 실패 시 false.
    /// 이미 내장 자막이 선택되어 있더라도 외부 자막이 우선한다.
    func loadExternalSubtitle(url: URL) -> Bool {
        guard let raw = Self.readSubtitleText(url: url) else { return false }
        let ext = url.pathExtension.lowercased()
        let cues: [SubtitleCue]
        switch ext {
        case "srt": cues = Self.parseSRT(raw)
        case "smi": cues = Self.parseSMI(raw)
        default:    return false
        }
        guard !cues.isEmpty else { return false }

        // 이전 외부 자막 상태 초기화
        removeExternalTimeObserver()
        externalCues = cues
        hasExternalSubtitle = true
        updateHasSubtitlesFlag()
        subtitleMode = .external
        showSubtitles = true

        installExternalTimeObserver()
        applySubtitleMode()
        return true
    }

    private func clearExternalSubtitleState() {
        removeExternalTimeObserver()
        externalCues = []
        hasExternalSubtitle = false
        updateHasSubtitlesFlag()
        if subtitleMode == .external {
            subtitleMode = hasEmbeddedSubtitle && showSubtitles ? .embedded : .off
        }
        applySubtitleMode()
    }

    private func updateHasSubtitlesFlag() {
        hasSubtitles = hasEmbeddedSubtitle || hasExternalSubtitle
    }

    var subtitleModeLabel: String? {
        switch effectiveSubtitleMode() {
        case .off:
            return hasSubtitles ? "SUBTITLE OFF" : nil
        case .embedded:
            return "EMBEDDED SUB"
        case .external:
            return "EXTERNAL SUB"
        }
    }

    private func availableSubtitleModesInCycleOrder() -> [SubtitleMode] {
        var modes: [SubtitleMode] = []
        if hasExternalSubtitle { modes.append(.external) }
        if hasEmbeddedSubtitle { modes.append(.embedded) }
        if !modes.isEmpty { modes.append(.off) }
        return modes
    }

    private func effectiveSubtitleMode() -> SubtitleMode {
        switch subtitleMode {
        case .embedded where hasEmbeddedSubtitle:
            return .embedded
        case .external where hasExternalSubtitle:
            return .external
        default:
            return .off
        }
    }

    private func applySubtitleMode() {
        let mode = effectiveSubtitleMode()
        subtitleMode = mode
        showSubtitles = mode != .off

        if let item = player?.currentItem, let group = legibleGroup {
            switch mode {
            case .embedded:
                if let opt = firstLegibleOption {
                    item.select(opt, in: group)
                } else {
                    item.select(nil, in: group)
                }
                currentSubtitle = ""

            case .external:
                item.select(nil, in: group)
                if let current = player?.currentTime().seconds {
                    updateExternalSubtitle(at: current)
                } else {
                    currentSubtitle = ""
                }

            case .off:
                item.select(nil, in: group)
                currentSubtitle = ""
            }
        } else if mode == .external, let current = player?.currentTime().seconds {
            updateExternalSubtitle(at: current)
        } else {
            currentSubtitle = ""
        }
    }

    private func removeExternalTimeObserver() {
        if let obs = externalTimeObserver {
            player?.removeTimeObserver(obs)
            externalTimeObserver = nil
        }
    }

    private func installExternalTimeObserver() {
        removeExternalTimeObserver()
        guard let player else { return }
        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        externalTimeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor [weak self] in
                self?.updateExternalSubtitle(at: seconds)
            }
        }
    }

    private func updateExternalSubtitle(at seconds: TimeInterval) {
        guard hasExternalSubtitle, showSubtitles else { return }
        // 외부 자막 큐는 시작시간 오름차순 정렬되어 있음. 선형 탐색으로 충분.
        var text = ""
        for cue in externalCues {
            if cue.start <= seconds && seconds < cue.end {
                text = cue.text
                break
            }
            if cue.start > seconds { break }
        }
        if currentSubtitle != text {
            currentSubtitle = text
        }
    }

    // MARK: 외부 자막 파서

    /// 파일을 UTF-8 → CP949 → EUC-KR → Latin-1 순으로 시도 (SMI 는 주로 CP949/EUC-KR).
    private static func readSubtitleText(url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // BOM 제거 고려. String(data:encoding: .utf8) 은 유효 UTF-8 아니면 nil.
        if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        let cp949 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosKorean.rawValue))
        if cp949 != kCFStringEncodingInvalidId,
           let s = String(data: data, encoding: String.Encoding(rawValue: cp949)) {
            return s
        }
        let eucKr = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue))
        if eucKr != kCFStringEncodingInvalidId,
           let s = String(data: data, encoding: String.Encoding(rawValue: eucKr)) {
            return s
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func parseSRT(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        for block in blocks {
            let raw = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            // 타임스탬프 라인 위치: 보통 0 또는 1 (인덱스 번호 있는 경우)
            var tsIdx = -1
            for (i, line) in lines.enumerated() {
                if line.contains("-->") { tsIdx = i; break }
            }
            guard tsIdx >= 0 else { continue }
            let tsLine = lines[tsIdx]
            guard let arrow = tsLine.range(of: "-->") else { continue }
            let startStr = String(tsLine[..<arrow.lowerBound]).trimmingCharacters(in: .whitespaces)
            let endTail  = String(tsLine[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            // 종료 측엔 스타일 정보가 붙을 수 있어 첫 토큰만 사용
            let endStr = endTail.split(separator: " ", maxSplits: 1).first.map(String.init) ?? endTail
            guard let start = parseSRTTimestamp(startStr),
                  let end   = parseSRTTimestamp(endStr),
                  end > start else { continue }
            let bodyLines = lines.dropFirst(tsIdx + 1)
            var body = bodyLines.joined(separator: "\n")
            // SRT 의 <i>/<b>/<font>... 등 간단한 태그는 제거
            body = body.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            body = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues
    }

    private static func parseSRTTimestamp(_ s: String) -> TimeInterval? {
        // HH:MM:SS,mmm  또는  HH:MM:SS.mmm
        let unified = s.replacingOccurrences(of: ",", with: ".")
        let parts = unified.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]),
              let m = Double(parts[1]),
              let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }

    /// SAMI(.smi) 파서. `<SYNC Start=NNN>` 블록을 시간 순으로 추출.
    /// `&nbsp;` 단일/`<P>` 빈 블록은 "자막 지우기" 마커로 이전 큐 종료.
    /// 복수 언어가 있으면 첫 `<P>` 언어를 사용 (KRCC/ENCC 등).
    private static func parseSMI(_ text: String) -> [SubtitleCue] {
        let pattern = #"<SYNC\s+Start\s*=\s*(\d+)[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        struct Event { let time: TimeInterval; let bodyRange: NSRange }
        var events: [Event] = []
        events.reserveCapacity(matches.count)
        for (i, m) in matches.enumerated() {
            guard m.numberOfRanges >= 2 else { continue }
            let msStr = ns.substring(with: m.range(at: 1))
            guard let ms = Int(msStr) else { continue }
            let bodyStart = m.range.location + m.range.length
            let bodyEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : ns.length
            let bodyRange = NSRange(location: bodyStart, length: max(0, bodyEnd - bodyStart))
            events.append(Event(time: TimeInterval(ms) / 1000.0, bodyRange: bodyRange))
        }

        var cues: [SubtitleCue] = []
        for i in 0..<events.count {
            let e = events[i]
            let chunk = ns.substring(with: e.bodyRange)
            let cleaned = cleanSMIChunk(chunk)
            let nextTime = (i + 1 < events.count) ? events[i + 1].time : (e.time + 10.0)
            if cleaned.isEmpty {
                // 클리어 마커: 이전 cue 가 이 시점을 넘어 지속되도록 기록됐다면 잘라준다.
                if var last = cues.last, last.end > e.time {
                    last = SubtitleCue(start: last.start, end: e.time, text: last.text)
                    cues[cues.count - 1] = last
                }
                continue
            }
            cues.append(SubtitleCue(start: e.time, end: nextTime, text: cleaned))
        }
        return cues
    }

    private static func cleanSMIChunk(_ chunk: String) -> String {
        var s = chunk
        // 첫 <P ...> 이후만 사용 (SYNC 블록 선두의 공백/주석 제거)
        if let r = s.range(of: "<P[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[r.upperBound...])
        }
        // 블록 닫는 태그에서 잘라냄
        if let r = s.range(of: "</(SYNC|BODY|SAMI)>", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[..<r.lowerBound])
        }
        // 다른 언어용 <P> 블록이 이어지면 첫 언어만 사용
        if let r = s.range(of: "<P[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            s = String(s[..<r.lowerBound])
        }
        // <BR> → 개행
        s = s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
        // 나머지 태그 제거
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // 엔티티 디코드
        s = decodeHTMLEntities(s)
        // 각 줄 트림 후 빈 줄 제거
        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let filtered = lines.filter { !$0.isEmpty }
        return filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeHTMLEntities(_ input: String) -> String {
        var s = input
        let pairs: [(String, String)] = [
            ("&nbsp;", " "),
            ("&amp;",  "&"),
            ("&lt;",   "<"),
            ("&gt;",   ">"),
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;",  "'")
        ]
        for (k, v) in pairs {
            s = s.replacingOccurrences(of: k, with: v, options: .caseInsensitive)
        }
        // 수치 엔티티 &#NNN;  —  간단히 ASCII/BMP 범위만 복원
        let pattern = "&#(\\d+);"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let ns = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            // 뒤에서부터 치환 (range shift 방지)
            var result = s
            for m in matches.reversed() {
                guard m.numberOfRanges >= 2 else { continue }
                let numStr = (result as NSString).substring(with: m.range(at: 1))
                guard let code = UInt32(numStr), let scalar = Unicode.Scalar(code) else { continue }
                let replacement = String(scalar)
                result = (result as NSString).replacingCharacters(in: m.range, with: replacement)
            }
            s = result
        }
        return s
    }

    // MARK: - Image Open

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "bmp", "tiff", "tif", "heic", "heif", "webp"
    ]

    /// 이미지 확장자 판별. ContentView가 "마지막 재생" 기록 대상 여부 결정에 사용.
    static func isImageFile(url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// 오디오 전용 파일 확장자. AVFoundation 네이티브 재생 가능한 것만.
    /// ogg/wma는 unsupportedExtensions 경유로 remux 후 재생.
    private static let audioExtensions: Set<String> = [
        "mp3", "aac", "m4a", "flac", "wav", "aiff", "aif"
    ]

    /// 오디오 확장자 판별.
    static func isAudioFile(url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    /// 정적 이미지 로드 — 한 번만 샘플링하고, 크기/간격 변경에 대응하도록 타이머만 유지.
    private func openImage(url: URL) {
        cleanup()
        if let prev = activeRemuxTempURL {
            try? FileManager.default.removeItem(at: prev)
            activeRemuxTempURL = nil
        }

        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            urlLoadError = "이미지를 열 수 없습니다: \(url.lastPathComponent)"
            return
        }
        guard let buffer = Self.makePixelBuffer(from: cgImage) else {
            urlLoadError = "이미지 변환에 실패했습니다."
            return
        }

        lastPixelBuffer = buffer
        isStaticContent = true
        isPlaying = false
        videoSize = CGSize(width: cgImage.width, height: cgImage.height)

        // 이미지 모드에서는 AVPlayer/videoOutput 없이 캐시된 버퍼를 반복 샘플링.
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleCurrentFrame() }
        }
        // .common 모드로 등록 → 마우스 홀드(일반 peek) 등 이벤트 트래킹 중에도 계속 샘플링.
        // (.default 모드 타이머는 마우스를 누르고 있는 동안 멈춰 dotColors가 동결됨)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// CGImage → CVPixelBuffer(BGRA). 기존 샘플링 경로(`sampleCurrentFrame`)와 호환되는 포맷.
    private static func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        let width = image.width
        let height = image.height
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb
        )
        guard status == kCVReturnSuccess, let buffer = pb else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        guard let ctx = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - Remux (ffmpeg)

    /// AVFoundation이 지원 안 하는 컨테이너 목록
    private static let unsupportedExtensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "wmv", "ogv", "ogg", "wma",
        "rmvb", "rm", "ts", "m2ts", "mts", "vob", "asf", "divx", "xvid"
    ]

    private static func needsRemux(url: URL) -> Bool {
        unsupportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 번들 내 임베드된 ffmpeg 우선 탐색, 없으면 Homebrew 등 알려진 경로.
    nonisolated private static func ffmpegPath() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") {
            candidates.append(bundled.path)
        }
        candidates += [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/opt/local/bin/ffmpeg"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    nonisolated private static func remuxToMP4(source: URL) async -> ResolveOutcome {
        guard let ffmpegPath = ffmpegPath() else {
            return .failure("ffmpeg이 설치되어 있지 않습니다.\n터미널에서 실행하세요:\n  brew install ffmpeg")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hurst-remux-\(UUID().uuidString).mp4")

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // ffprobe로 비디오/오디오 코덱을 먼저 확인.
                // AVFoundation이 MP4 컨테이너에서 디코드 가능한 코덱만 copy,
                // 그 외(VP9/VP8/AV1/Theora 등)는 재인코딩이 필요.
                // 이전엔 stream copy가 "성공"하지만 AVFoundation이 화면을 못 그려
                // 오디오만 들리는 버그가 있었음.
                let videoCodec = probeCodec(path: source.path, streamType: "v", ffmpegPath: ffmpegPath)
                let audioCodec = probeCodec(path: source.path, streamType: "a", ffmpegPath: ffmpegPath)
                let subtitleCodec = probeCodec(path: source.path, streamType: "s", ffmpegPath: ffmpegPath)

                let mp4SafeVideo: Set<String> = ["h264", "hevc", "mpeg4", "mjpeg", "prores"]
                let mp4SafeAudio: Set<String> = ["aac", "mp3", "ac3", "alac", "eac3"]
                // mov_text 변환은 텍스트 기반 자막만 가능. PGS/VobSub 등 비트맵 자막을
                // mov_text로 지정하면 remux 전체가 실패해 재인코딩 fallback으로 빠지므로
                // (BluRay 립 mkv가 통째로 못 열리던 원인) 비트맵 자막은 드롭한다.
                let textSubtitles: Set<String> = ["subrip", "srt", "ass", "ssa", "mov_text", "text", "webvtt"]

                // probe 실패(nil) 시엔 기존 동작 유지(copy 시도). 확실히 비호환일 때만 재인코딩.
                let copyVideo = (videoCodec == nil) || mp4SafeVideo.contains(videoCodec!)
                let copyAudio = (audioCodec == nil) || mp4SafeAudio.contains(audioCodec!)
                let convertSubtitle = subtitleCodec.map { textSubtitles.contains($0) } ?? false

                func baseArgs(subtitle: Bool) -> [String] {
                    var args = ["-y", "-i", source.path]
                    args += copyVideo ? ["-c:v", "copy"] : ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23"]
                    // HEVC를 MP4로 stream copy 할 때, ffmpeg은 기본으로 hev1 태그를 쓴다.
                    // Apple AVFoundation은 hev1은 디코드 못하고 hvc1만 받아들여서
                    // "오디오만 나오고 영상은 안 보임" 현상이 발생. 태그를 hvc1로 강제.
                    if copyVideo && videoCodec == "hevc" {
                        args += ["-tag:v", "hvc1"]
                    }
                    args += copyAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
                    args += subtitle ? ["-c:s", "mov_text"] : ["-sn"]
                    // 로컬 임시 파일 재생이라 +faststart(moov 앞으로 옮기는 2차 패스) 불필요.
                    // 대용량 파일에서 remux 시간을 절반으로 줄인다.
                    args += [tempURL.path]
                    return args
                }

                if runFFmpeg(path: ffmpegPath, args: baseArgs(subtitle: convertSubtitle)) {
                    continuation.resume(returning: .success(tempURL))
                    return
                }

                // 자막 변환이 문제였을 수 있으므로, 여전히 stream copy 유지한 채 자막만 드롭 후 재시도
                if convertSubtitle {
                    try? FileManager.default.removeItem(at: tempURL)
                    if runFFmpeg(path: ffmpegPath, args: baseArgs(subtitle: false)) {
                        continuation.resume(returning: .success(tempURL))
                        return
                    }
                }

                // 최후 수단: 전체 재인코딩 (느림)
                try? FileManager.default.removeItem(at: tempURL)
                let fallbackArgs = [
                    "-y", "-i", source.path,
                    "-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
                    "-c:a", "aac", "-b:a", "192k",
                    "-sn",
                    tempURL.path
                ]

                if runFFmpeg(path: ffmpegPath, args: fallbackArgs) {
                    continuation.resume(returning: .success(tempURL))
                    return
                }

                try? FileManager.default.removeItem(at: tempURL)
                continuation.resume(returning: .failure("ffmpeg 변환에 실패했습니다. 파일이 손상됐거나 지원하지 않는 형식일 수 있습니다."))
            }
        }
    }

    /// ffprobe로 스트림 코덱 이름을 반환. streamType: "v" (비디오) or "a" (오디오).
    /// ffprobe가 없거나 해당 스트림이 없으면 nil.
    nonisolated private static func probeCodec(path: String, streamType: String, ffmpegPath: String) -> String? {
        let dir = (ffmpegPath as NSString).deletingLastPathComponent
        let ffprobePath = "\(dir)/ffprobe"
        guard FileManager.default.isExecutableFile(atPath: ffprobePath) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: ffprobePath)
        task.arguments = [
            "-v", "error",
            "-select_streams", "\(streamType):0",
            "-show_entries", "stream=codec_name",
            "-of", "default=nw=1:nk=1",
            path
        ]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let codec = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return (codec?.isEmpty == false) ? codec : nil
        } catch {
            return nil
        }
    }

    nonisolated private static func runFFmpeg(path: String, args: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - URL Open

    enum ResolveOutcome {
        case success(URL)
        case failure(String)
    }

    struct ResolvedURLTitle: Equatable {
        let sourceURL: String
        let title: String
    }

    /// URL 문자열로 열기.
    /// YouTube 등 웹 페이지 URL 은 yt-dlp 로 직접 재생 가능한 스트림 URL 을 얻어 연다.
    /// 그 외에는 직접 재생 가능한 URL 로 간주하고 바로 연다.
    func openURL(_ urlString: String) {
        startTimerIfNeeded()
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed) else {
            urlLoadError = "잘못된 URL입니다."
            return
        }

        guard Self.needsWebResolve(url: url) else {
            open(url: url)
            return
        }

        // 이전 미디어를 즉시 정리 — 해석 중 재생 위치 복원이 이전 플레이어를 잡지 않도록.
        cleanup()
        if let prev = activeRemuxTempURL {
            try? FileManager.default.removeItem(at: prev)
            activeRemuxTempURL = nil
        }
        openGeneration &+= 1
        let generation = openGeneration
        isLoadingMedia = true
        Task.detached { [weak self] in
            let outcome = await Self.resolveYouTubeToLocalFile(source: trimmed)
            await MainActor.run { [weak self] in
                guard let self, self.openGeneration == generation else { return }
                self.isLoadingMedia = false
                switch outcome {
                case .success(let localURL, let title):
                    if let title {
                        self.resolvedURLTitle = ResolvedURLTitle(sourceURL: trimmed, title: title)
                    }
                    // open(url:)이 내부에서 기존 activeRemuxTempURL을 먼저 정리하므로,
                    // 지금 만든 파일은 그 호출이 끝난 다음에 등록해야 곧바로 지워지지 않는다.
                    self.open(url: localURL)
                    self.activeRemuxTempURL = localURL
                case .failure(let message):
                    self.urlLoadError = message
                }
            }
        }
    }

    // MARK: - Web URL 해석 (yt-dlp + ffmpeg)

    enum WebResolveOutcome {
        case success(URL, title: String?)
        case failure(String)
    }

    private static let webResolveHosts: [String] = [
        "youtube.com", "youtu.be", "youtube-nocookie.com"
    ]

    /// yt-dlp 해석이 필요한 페이지 URL 인지. (YouTube 계열 호스트)
    static func needsWebResolve(url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return webResolveHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// video-only + audio-only 를 따로 골라 AVFoundation이 그대로 디코드하는 코덱(H.264 + AAC)만
    /// 받는다. YouTube 는 이미 하나로 합쳐진 스트림(예: 과거의 itag 18)을 더 이상 안정적으로 주지
    /// 않는다 — 주는 시점도, PO Token 요구 여부도 들쑥날쑥하다. video-only(avc1)/audio-only(mp4a)
    /// DASH 스트림은 항상 존재해서 그 둘을 yt-dlp 로 내려받아(자체 재시도/타임아웃 포함) 로컬에서
    /// 합친다 — video/audio URL을 직접 ffmpeg 에 물려 스트리밍하는 방식은 googlevideo 쪽 연결이
    /// 끊김 신호 없이 멈추는 경우가 있어(스톨) yt-dlp 자체 다운로더를 쓴다.
    nonisolated private static let ytdlpVideoAudioSelector =
        "bestvideo[vcodec^=avc1]+bestaudio[acodec^=mp4a]/best[vcodec^=avc1][acodec^=mp4a]"

    nonisolated private static func ytdlpPath() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "yt-dlp") {
            candidates.append(bundled.path)
        }
        candidates += [
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
            "/opt/local/bin/yt-dlp",
            NSHomeDirectory() + "/.local/bin/yt-dlp"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// deno(yt-dlp가 YouTube의 JS 챌린지를 풀 때 쓰는 JS 런타임) 경로. 번들 내장분 우선.
    nonisolated private static func denoPath() -> String? {
        var candidates: [String] = []
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "deno") {
            candidates.append(bundled.path)
        }
        candidates += [
            "/opt/homebrew/bin/deno",
            "/usr/local/bin/deno",
            "/opt/local/bin/deno",
            NSHomeDirectory() + "/.local/bin/deno"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// yt-dlp를 실행하고 exit code / stdout / stderr을 돌려준다.
    nonisolated private static func runYTDLP(ytdlpPath: String, arguments: [String], source: String, timeout: TimeInterval = 60) -> (exitCode: Int32, stdout: String, stderr: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: ytdlpPath)
        task.arguments = arguments
        // GUI 앱은 PATH 가 최소한이라 Homebrew 경로를 보강.
        // (yt-dlp 가 YouTube 해석에 쓰는 JS 런타임(deno 등)을 찾을 수 있도록)
        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"]
        env["PATH"] = (extraPaths + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"])
            .joined(separator: ":")
        task.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        let startedAt = Date()
        urlLog.info("yt-dlp start: \(ytdlpPath, privacy: .public) \(source, privacy: .public)")
        do {
            try task.run()
        } catch {
            return (-1, "", "")
        }

        // 네트워크 정체 대비 타임아웃.
        let timeoutItem = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        // 파이프 버퍼가 차서 멈추지 않도록 종료 대기 전에 먼저 읽는다.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        timeoutItem.cancel()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        urlLog.info("yt-dlp exit \(task.terminationStatus) in \(Date().timeIntervalSince(startedAt), format: .fixed(precision: 1))s")
        if !stderr.isEmpty {
            urlLog.info("yt-dlp stderr: \(stderr, privacy: .public)")
        }
        return (task.terminationStatus, stdout, stderr)
    }

    /// yt-dlp로 video-only(avc1) + audio-only(mp4a) 스트림을 내려받아 로컬 mp4 파일 하나로 합친다.
    /// yt-dlp 자체 다운로더는 재시도/소켓 타임아웃을 갖고 있어, video/audio URL을 직접 ffmpeg에
    /// 물려 스트리밍하는 것보다 googlevideo 쪽 연결이 응답 없이 멈추는 상황에 훨씬 강하다.
    /// 병합은 --merge-output-format으로 yt-dlp가 내장 ffmpeg 호출을 통해 직접 수행한다.
    nonisolated private static func resolveYouTubeToLocalFile(source: String) async -> WebResolveOutcome {
        guard let ytdlp = ytdlpPath() else {
            return .failure("yt-dlp가 설치되어 있지 않습니다.\n터미널에서 실행하세요:\n  brew install yt-dlp")
        }
        guard let ffmpeg = ffmpegPath() else {
            return .failure("ffmpeg이 설치되어 있지 않습니다.\n터미널에서 실행하세요:\n  brew install ffmpeg")
        }
        let ffmpegDir = (ffmpeg as NSString).deletingLastPathComponent

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hurst-ytdl-\(UUID().uuidString).mp4")

        // avc1+mp4a DASH 스트림은 대개 JS 챌린지 없이도 풀리지만, deno가 있으면 명시적으로
        // 넘겨 YouTube 쪽 변경에 좀 더 안전하게 대응한다(PATH 탐색에 기대지 않음).
        var arguments = [
            "--no-playlist", "--no-warnings", "--quiet",
            "-f", ytdlpVideoAudioSelector,
            "--merge-output-format", "mp4",
            "--ffmpeg-location", ffmpegDir,
            "--retries", "5", "--fragment-retries", "5", "--socket-timeout", "20"
        ]
        if let deno = denoPath() {
            arguments += ["--js-runtimes", "deno:\(deno)"]
        }
        arguments += [
            "-o", tempURL.path,
            "--print", "after_move:%(title)j",
            "--", source
        ]

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // 완료 후(병합 파일이 최종 위치로 옮겨진 뒤) 제목 한 줄을 출력.
                let result = runYTDLP(ytdlpPath: ytdlp, arguments: arguments, source: source, timeout: 1800)

                guard result.exitCode == 0, FileManager.default.fileExists(atPath: tempURL.path) else {
                    try? FileManager.default.removeItem(at: tempURL)
                    let err = result.stderr
                        .split(whereSeparator: \.isNewline)
                        .last
                        .map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    var message = "영상을 내려받는 데 실패했습니다."
                    if !err.isEmpty { message += "\n\n" + err }
                    continuation.resume(returning: .failure(message))
                    return
                }

                var title: String?
                if let last = result.stdout.split(whereSeparator: \.isNewline).last,
                   let data = String(last).trimmingCharacters(in: .whitespaces).data(using: .utf8),
                   let decoded = try? JSONDecoder().decode(String.self, from: data) {
                    let t = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
                    title = t.isEmpty ? nil : t
                }

                urlLog.info("yt-dlp downloaded+merged: \(tempURL.path, privacy: .public)")
                continuation.resume(returning: .success(tempURL, title: title))
            }
        }
    }

    // MARK: - Controls

    func seek(toSeconds seconds: Double) {
        guard let player else { return }
        let safeSeconds = max(0, seconds)
        if let item = player.currentItem {
            let duration = item.duration.seconds
            let clamped: Double
            if duration.isFinite && duration > 0 {
                clamped = min(safeSeconds, max(0, duration - 0.25))
            } else {
                clamped = safeSeconds
            }
            player.seek(
                to: CMTime(seconds: clamped, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        } else {
            player.seek(to: CMTime(seconds: safeSeconds, preferredTimescale: 600))
        }
        startTimerIfNeeded()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
        startTimerIfNeeded()
        showOverlay(.border, blinks: 2)
    }

    // MARK: - Peek (우상단 도트 누르고 있는 동안 실제 영상 재생)

    /// 피크 전용 AVPlayerLayer 부착용. 읽기 전용. 외부에서 play()/pause() 직접 호출 금지 —
    /// 반드시 peekStart()/peekEnd()를 통해 상태 일관성 유지.
    var previewPlayer: AVPlayer? { player }

    /// 현재 원본 프레임을 CGImage로 반환(도트화 전 원본 픽셀).
    /// 비디오는 출력에서 가장 최신 프레임을 받아오고, 실패 시 마지막 픽셀버퍼로 폴백.
    /// 이미지 모드는 openImage에서 세팅한 lastPixelBuffer를 그대로 사용.
    func currentFrameCGImage() -> CGImage? {
        var buffer = lastPixelBuffer
        if let output = videoOutput, let player {
            let time = player.currentTime()
            if time.isValid, !time.isIndefinite,
               let fresh = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                buffer = fresh
            }
        }
        guard let pixelBuffer = buffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return CIContext().createCGImage(ciImage, from: ciImage.extent)
    }

    /// 피크 시작: 강제 재생. 이전 상태(play/pause)와 무관하게 재생 시작.
    func peekStart() {
        guard let player else { return }
        player.play()
        isPlaying = true
    }

    /// 피크 종료: 무조건 일시정지. 사양상 뗀 후엔 항상 pause.
    func peekEnd() {
        player?.pause()
        isPlaying = false
    }

    // 숫자키: fraction = 0.1 ~ 0.9
    func seek(toFraction fraction: Double) {
        guard let player, let item = player.currentItem else { return }
        Task {
            let duration = try? await item.asset.load(.duration)
            guard let d = duration, d.isValid, !d.isIndefinite, d.seconds > 0 else { return }
            let target = CMTime(seconds: d.seconds * fraction, preferredTimescale: 600)
            await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            startTimerIfNeeded()
            showOverlay(.col(seekCol(fraction: fraction)), blinks: 1)
        }
    }

    // 콤마/마침표: 가로 한 칸 단위 이동
    func seekByColumn(delta: Int) {
        guard let player, let item = player.currentItem else { return }
        let duration = item.duration
        guard duration.isValid && !duration.isIndefinite && duration.seconds > 0 else { return }

        let visibleCols = max(1, (dotColors.first?.count ?? 2) - 2)
        let colWidth    = duration.seconds / Double(visibleCols)
        let current     = player.currentTime().seconds
        let rawTarget   = current + Double(delta) * colWidth

        let atStart = delta < 0 && rawTarget <= 0
        let atEnd   = delta > 0 && rawTarget >= duration.seconds
        let clamped = min(max(0, rawTarget), duration.seconds)

        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        let fraction = clamped / duration.seconds
        startTimerIfNeeded()
        showOverlay(.col(seekCol(fraction: fraction)),
                    blinks: (atStart || atEnd) ? 2 : 1,
                    alert: atStart || atEnd)
    }

    // 방향키: ±seconds
    func seek(by seconds: Double) {
        guard let player, let item = player.currentItem else { return }
        let current = player.currentTime()
        let target  = CMTimeAdd(current, CMTime(seconds: seconds, preferredTimescale: 600))
        player.seek(to: target,
                    toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
        
        Task {
            let duration = try? await item.asset.load(.duration)
            guard let d = duration, d.isValid, !d.isIndefinite, d.seconds > 0 else { return }
            let fraction = target.seconds / d.seconds
            startTimerIfNeeded()
            showOverlay(.col(seekCol(fraction: fraction)), blinks: 1)
        }
    }

    // 볼륨 위 (최대 120%)
    func volumeUp() {
        guard let player else { return }
        let visibleRows = max(1, dotColors.count - 2)
        let step = Float(1.0) / Float(visibleRows)
        let maxVol: Float = 1.2
        let atMax = player.volume >= maxVol - step * 0.5  // 엡실론: 반 칸 이내면 최대로 간주
        if !atMax { 
            player.volume = min(maxVol, player.volume + step)
            lastVolume = player.volume
            UserDefaults.standard.set(lastVolume, forKey: Self.volumeKey)
        }
        startTimerIfNeeded()
        showOverlay(.row(volumeRow(volume: Double(player.volume), visibleRows: visibleRows)),
                    blinks: atMax ? 2 : 1, alert: atMax)
    }

    // 볼륨 아래
    func volumeDown() {
        guard let player else { return }
        let visibleRows = max(1, dotColors.count - 2)
        let step = Float(1.0) / Float(visibleRows)
        let atMin = player.volume <= step * 0.5           // 엡실론: 반 칸 이내면 최소로 간주
        if !atMin { 
            player.volume = max(0.0, player.volume - step)
            lastVolume = player.volume
            UserDefaults.standard.set(lastVolume, forKey: Self.volumeKey)
        }
        startTimerIfNeeded()
        showOverlay(.row(volumeRow(volume: Double(player.volume), visibleRows: visibleRows)),
                    blinks: atMin ? 2 : 1, alert: atMin)
    }

    // MARK: - Helpers

    // 볼륨 % → 가장 가까운 가로 줄 (1-based, 위=120%)
    // 120%(1.2) → row 1, 0% → row visibleRows.
    // 기본값(100%) 은 전체의 1/6 지점(위에서 visibleRows/6 번째 줄).
    private func volumeRow(volume: Double, visibleRows: Int) -> Int {
        let maxVol = 1.2
        let fraction = (maxVol - max(0, min(maxVol, volume))) / maxVol
        let r = Int(fraction * Double(visibleRows) + 0.5)
        return max(1, min(visibleRows, r == 0 ? 1 : r))
    }

    // seek 목표 fraction → 가장 가까운 세로 줄 (1-based, 왼쪽=0%)
    private func seekCol(fraction: Double) -> Int {
        let visibleCols = max(1, (dotColors.first?.count ?? 2) - 2)
        let c = Int(fraction * Double(visibleCols) + 0.5)
        return max(1, min(visibleCols, c == 0 ? 1 : c))
    }

    // MARK: - Overlay

    /// 플레이리스트 경계(처음/마지막)에서 더 이상 이동할 수 없을 때 악센트 테두리 깜빡임.
    func triggerBorderBlink() {
        startTimerIfNeeded()
        showOverlay(.border, blinks: 2, alert: true)
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleCurrentFrame() }
        }
        // .common 모드로 등록 → 마우스 홀드(일반 peek) 등 이벤트 트래킹 중에도 계속 샘플링.
        // (.default 모드 타이머는 마우스를 누르고 있는 동안 멈춰 dotColors가 동결됨)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func showOverlay(_ effect: OverlayEffect, blinks: Int, alert: Bool = false) {
        overlayEffect = effect
        overlayBlinks = blinks
        overlayProgress = 0
        overlayIsAlert = alert
        overlayStartTime = Date()
    }

    private func updateOverlay() {
        guard let startTime = overlayStartTime else { return }
        let elapsed = Date().timeIntervalSince(startTime)
        if elapsed >= overlayDuration {
            overlayProgress = 0
            overlayEffect = .none
            overlayIsAlert = false
            overlayStartTime = nil
        } else {
            overlayProgress = elapsed / overlayDuration
        }
    }

    // MARK: - Audio Analysis & Visualization

    /// 로컬 오디오 파일의 주파수 에너지를 사전 분석.
    /// ~30 frames/sec 해상도의 AudioEnergyFrame 배열과 실제 분석 레이트를 반환.
    /// 메모리 효율을 위해 스트리밍 방식으로 청크 단위 처리.
    nonisolated private static func analyzeAudioFile(url: URL) -> (frames: [AudioEnergyFrame], rate: Double) {
        guard let audioFile = try? AVAudioFile(forReading: url) else { return ([], 30) }
        let format = audioFile.processingFormat
        let sampleRate = Float(format.sampleRate)
        guard audioFile.length > 0, sampleRate > 0 else { return ([], 30) }

        let hopSize = max(1, Int(sampleRate / 30.0))
        let chunkCapacity: AVAudioFrameCount = 65536
        guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else { return ([], 30) }

        var frames: [AudioEnergyFrame] = []
        var residual: [Float] = []
        var startIndex = 0
        let rmsWindowSize = 2048

        while audioFile.framePosition < audioFile.length {
            do { try audioFile.read(into: chunkBuffer) } catch { break }
            guard let channelData = chunkBuffer.floatChannelData, chunkBuffer.frameLength > 0 else { break }
            let count = Int(chunkBuffer.frameLength)
            residual.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: count))

            while startIndex + rmsWindowSize <= residual.count {
                var rms: Float = 0
                residual.withUnsafeBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    vDSP_rmsqv(base.advanced(by: startIndex), 1, &rms, vDSP_Length(rmsWindowSize))
                }

                frames.append(AudioEnergyFrame(rms: rms))
                startIndex += hopSize
            }

            // 앞부분을 매번 당기면 O(n) 비용이 커서, 충분히 누적됐을 때만 한 번에 정리.
            if startIndex >= residual.count {
                residual.removeAll(keepingCapacity: true)
                startIndex = 0
            } else if startIndex > 65536 {
                residual.removeFirst(startIndex)
                startIndex = 0
            }
        }

        guard !frames.isEmpty else { return ([], 30) }

        let maxRms = frames.map(\.rms).max()!

        let normalized = frames.map { f in
            AudioEnergyFrame(rms: maxRms > 0 ? f.rms / maxRms : 0)
        }

        return (normalized, Double(sampleRate) / Double(hopSize))
    }

    /// 오디오 모드에서 호출: 일반적인 바 형태의 이퀄라이저 렌더링.
    /// 배경은 디폴트 C9CFE5 색상을, 바(세로줄)는 사용자가 고른 악센트 색상 사용.
    private func generateAudioDotColors() {
        guard let player else { return }
        let currentTime = max(0, player.currentTime().seconds)
        let dispW = currentDisplaySize.width  > 0 ? currentDisplaySize.width  : 480
        let dispH = currentDisplaySize.height > 0 ? currentDisplaySize.height : 320
        let cols = max(3, Int(dispW / gridSize))
        let rows = max(3, Int(dispH / gridSize))

        let rate: Double
        if !audioEnergyFrames.isEmpty {
            rate = audioAnalysisRate
        } else {
            rate = 30.0
        }

        // 100ms 간격으로 우측으로 파형이 이동 (크롤 속도 100ms)
        let timerInterval = 0.100
        var barHeights = [Int](repeating: 0, count: cols)

        // quantizedTime을 사용해 100ms 구간 동안은 시간 값을 완전히 고정시켜
        // 프레임 사이사이의 스무딩(슬라이딩)으로 인한 깜빡임 방지
        let step = floor(currentTime / timerInterval)
        let quantizedTime = step * timerInterval

        for col in 0..<cols {
            let t = quantizedTime - Double(col) * timerInterval
            var rms: Float = 0
            
            if t >= 0 && !audioEnergyFrames.isEmpty {
                let idx = Int(t * rate)
                let clamped = max(0, min(audioEnergyFrames.count - 1, idx))
                rms = audioEnergyFrames[clamped].rms
            }
            
            // 음악의 볼륨에 따른 기본 높이 계산 (최대 높이를 rows-1로 제한하여 +1 여유를 둠)
            var h = Int(Double(rms) * Double(max(0, rows - 1)))
            
            // 재생 중이라면 (과거/미래/분석완료 여부를 떠나) 모든 위치에 무조건 1칸을 강제로 더함
            if self.isPlaying {
                h += 1
            }
            
            barHeights[col] = min(rows, h)
        }

        var newColors: [[CGColor]] = []
        newColors.reserveCapacity(rows)

        // 지정색상 (배경 점들은 외부에서 정해진 backgroundDotAlpha 적용)
        let baseBg = NSColor(red: 201.0/255.0, green: 207.0/255.0, blue: 229.0/255.0, alpha: CGFloat(self.backgroundDotAlpha)).cgColor
        let accentColor = AppAccentColor.current.nsColor.cgColor

        for row in 0..<rows {
            var rowColors: [CGColor] = []
            rowColors.reserveCapacity(cols)

            // SwiftUI Coordinate 관점에서 row 0은 화면의 맨 위, rows-1은 화면의 맨 아래.
            // 아래에서부터 100분위만큼 찹니다.
            for col in 0..<cols {
                let h = barHeights[col]
                // barHeights가 0이면 불 안 들어옴. rows이면 꽉 참.
                if row >= rows - h {
                    rowColors.append(accentColor)
                } else {
                    rowColors.append(baseBg)
                }
            }
            newColors.append(rowColors)
        }

        dotColors = newColors
    }

    // MARK: - Frame Sampling

    private func sampleCurrentFrame() {
        updateOverlay()

        // 오디오 전용 모드: 주파수 분석 기반 시각화
        if isAudioMode {
            generateAudioDotColors()
            return
        }

        // 비디오 모드: 최신 프레임을 AVPlayerItemVideoOutput에서 가져온다.
        // 이미지 모드: videoOutput/player가 nil이므로 이 블록은 건너뛰고
        // `openImage`에서 세팅한 lastPixelBuffer를 재사용한다.
        var didAdvanceFrame = false
        if let output = videoOutput, let player {
            let hostTime = CACurrentMediaTime()
            let displayTime = output.itemTime(forHostTime: hostTime)
            let currentTime = player.currentTime()

            let candidateTimes: [CMTime] = [displayTime, currentTime]
            for time in candidateTimes where time.isValid && !time.isIndefinite {
                if output.hasNewPixelBuffer(forItemTime: time),
                   let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
                    lastPixelBuffer = buffer
                    videoFrameGeneration &+= 1
                    didAdvanceFrame = true
                    break
                }
            }

            if !didAdvanceFrame,
               let buffer = output.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) {
                lastPixelBuffer = buffer
            }
        }
        guard let pixelBuffer = lastPixelBuffer else { return }

        // 비디오가 멈춰 있거나(새 프레임 없음), 이미지 모드(프레임 고정)일 때는
        // gridSize/창 크기 변화가 없으면 동일 픽셀 버퍼를 반복 샘플링할 필요가 없다.
        let sigAspect = videoSize.height > 0 ? videoSize.width / videoSize.height : 1
        let sigZoom = effectiveZoom(
            dispW: max(currentDisplaySize.width, 1),
            dispH: max(currentDisplaySize.height, 1),
            videoAspect: sigAspect
        )
        let sig = RenderSignature(
            gridSize: Int(gridSize.rounded()),
            displayW: Int(currentDisplaySize.width.rounded()),
            displayH: Int(currentDisplaySize.height.rounded()),
            frameGeneration: videoFrameGeneration,
            zoomPermille: Int((sigZoom * 1000).rounded()),
            centerXPermille: Int((contentCenter.x * 1000).rounded()),
            centerYPermille: Int((contentCenter.y * 1000).rounded())
        )
        if !didAdvanceFrame, sig == lastRenderSignature {
            return
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let bufWidth    = CVPixelBufferGetWidth(pixelBuffer)
        let bufHeight   = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        let dispW = currentDisplaySize.width  > 0 ? currentDisplaySize.width  : CGFloat(bufWidth)  / 2
        let dispH = currentDisplaySize.height > 0 ? currentDisplaySize.height : CGFloat(bufHeight) / 2

        // 격자는 **창 전체**를 채운다.
        //
        // 예전에는 창 안에 비디오를 fit-inside 로 맞춘 영역에서 셀 수를 뽑아, 창 비율이
        // 영상과 다르면 도트가 가운데 띠에만 나왔다. 그러면 피크(영상은 창을 꽉 채움)와
        // 도트 모드의 화면이 어긋나고, 자막 앵커가 창 하단이 아니라 그 띠의 하단에
        // 붙어서 피크로 넘어가면 자막이 화면 한가운데 뜬다.
        //
        // 이제 셀 수를 창 크기에서 뽑고, 원본에서 **창 비율에 맞는 중앙 영역만** 읽는다.
        // 넘치는 가장자리는 잘린다 — 피크가 영상을 채우는 방식과 똑같아서, 두 모드가
        // 같은 화면을 보여준다.
        //
        // 늘리는 방식(원본 전체를 격자에 억지로 매핑)은 쓰면 안 된다. 점 하나가 그
        // 위치의 색을 가져오는 구조라, 점을 작고 촘촘하게 할수록 도트가 이미지에
        // 가까워지고 그러면 늘어난 그림이 그대로 드러난다.
        let videoAspect  = CGFloat(bufWidth) / CGFloat(bufHeight)
        let zoom = effectiveZoom(dispW: dispW, dispH: dispH, videoAspect: videoAspect)

        // 격자 크기와 읽어올 원본 영역.
        //
        // **전체화면은 예전 계산을 그대로 쓴다.** 거기서는 피크가 .resizeAspect
        // (레터박스)로 바뀌어 창 모드처럼 채우면 어긋나고, ⌘0(fit)/⌘1(fill)/핀치 줌이
        // 전부 "fit = 1.0" 을 기준으로 정의돼 있다.
        let cols: Int
        let rows: Int
        let srcW: CGFloat
        let srcH: CGFloat

        if isFullscreen {
            let fittedW: CGFloat
            let fittedH: CGFloat
            if dispW / dispH > videoAspect {
                fittedH = dispH; fittedW = fittedH * videoAspect
            } else {
                fittedW = dispW; fittedH = fittedW / videoAspect
            }
            let scaledW = fittedW * zoom
            let scaledH = fittedH * zoom
            let visibleW = min(dispW, scaledW)
            let visibleH = min(dispH, scaledH)
            cols = max(1, Int(visibleW / gridSize))
            rows = max(1, Int(visibleH / gridSize))
            srcW = CGFloat(bufWidth)  * (visibleW / scaledW)
            srcH = CGFloat(bufHeight) * (visibleH / scaledH)
        } else {
            // 창 모드: 격자가 창 전체를 덮고, 원본에서 창 비율에 맞는 영역만 읽는다.
            // 피크의 .resizeAspectFill 과 같은 방식이라 두 모드가 같은 화면이 된다.
            //
            // 여기서는 줌이 그냥 나눗셈이다. 기본 화면(줌 1.0)이 이미 창을 꽉 채우고 있어
            // 확대하면 읽는 영역이 그만큼 좁아질 뿐, 전체화면처럼 "확대해도 화면 안에
            // 들어오는" 경우가 없다. 격자는 창 전체 기준이므로 줌과 무관하게 그대로다.
            cols = max(1, Int(dispW / gridSize))
            rows = max(1, Int(dispH / gridSize))
            let windowAspect = dispW / dispH
            let baseW: CGFloat, baseH: CGFloat
            if windowAspect > videoAspect {
                baseW = CGFloat(bufWidth)             // 창이 더 넓다 → 위아래를 자름
                baseH = baseW / windowAspect
            } else {
                baseH = CGFloat(bufHeight)            // 더 길다 → 좌우를 자름
                baseW = baseH * windowAspect
            }
            srcW = baseW / zoom
            srcH = baseH / zoom
        }

        // 읽기 시작점은 줌 중심(핀치 앵커)을 따라간다. 확대하지 않았으면 중심이 0.5 라
        // 예전과 같은 (bufWidth - srcW) / 2 가 된다.
        // 중심이 가장자리로 치우쳐도 원본 밖을 읽지 않도록 여기서 한 번 더 가둔다.
        let srcX0 = min(max(contentCenter.x * CGFloat(bufWidth)  - srcW / 2, 0),
                        max(CGFloat(bufWidth)  - srcW, 0))
        let srcY0 = min(max(contentCenter.y * CGFloat(bufHeight) - srcH / 2, 0),
                        max(CGFloat(bufHeight) - srcH, 0))

        var newColors: [[CGColor]] = []
        newColors.reserveCapacity(rows)

        for row in 0..<rows {
            // stride 를 쓰지 않고 정규화해서 매핑한다. 예전처럼 `max(1.0, srcH/rows)` 로
            // 잡으면, 행 수가 원본 세로 픽셀 수를 넘는 순간(세로로 긴 창 + 좁은 간격)
            // 아래쪽 행이 전부 마지막 스캔라인을 읽어 화면 아래가 한 줄로 뭉개진다.
            let sampleY = min(max(0, Int(srcY0 + (CGFloat(row) + 0.5) / CGFloat(rows) * srcH)),
                              bufHeight - 1)
            var rowColors: [CGColor] = []
            rowColors.reserveCapacity(cols)

            for col in 0..<cols {
                let sampleX = min(max(0, Int(srcX0 + (CGFloat(col) + 0.5) / CGFloat(cols) * srcW)),
                                  bufWidth - 1)
                let offset  = sampleY * bytesPerRow + sampleX * 4
                let ptr = baseAddress.advanced(by: offset).assumingMemoryBound(to: UInt8.self)

                let b = CGFloat(ptr[0]) / 255.0
                let g = CGFloat(ptr[1]) / 255.0
                let r = CGFloat(ptr[2]) / 255.0
                rowColors.append(CGColor(red: r, green: g, blue: b, alpha: 1.0))
            }
            newColors.append(rowColors)
        }

        dotColors = newColors
        lastRenderSignature = sig
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs); endObserver = nil }
        videoFrameGeneration = 0
        lastRenderSignature = nil
        // 외부 자막의 time observer 는 player nil 이 되기 전에 제거해야 한다.
        removeExternalTimeObserver()
        externalCues = []
        hasExternalSubtitle = false
        subtitleMode = .off
        player?.pause()
        player = nil
        videoOutput = nil
        legibleOutput = nil
        subtitleDelegate = nil
        legibleGroup = nil
        firstLegibleOption = nil
        hasEmbeddedSubtitle = false
        lastPixelBuffer = nil
        dotColors = []
        videoSize = .zero
        contentZoom = .fit
        isPlaying = false
        isStaticContent = false
        isAudioMode = false
        audioEnergyFrames = []
        audioAnalysisTask?.cancel()
        audioAnalysisTask = nil
        hasSubtitles = false
        currentSubtitle = ""
    }

    func resetAppState() {
        cleanup()
        if let prev = activeRemuxTempURL {
            try? FileManager.default.removeItem(at: prev)
            activeRemuxTempURL = nil
        }
        urlLoadError = nil
        overlayEffect = .none
        overlayProgress = 0
        overlayBlinks = 1
        overlayIsAlert = false
        overlayStartTime = nil
        showSubtitles = true
        backgroundDotAlpha = 0.40
        gridSize = defaultGridSize
        dotDiameter = defaultDotDiameter
        subtitleFontSize = subtitleFontDefault
        lastVolume = 1.0
    }
}

// MARK: - External subtitle cue

/// 외부 자막 파일(.srt/.smi) 에서 파싱된 단일 큐.
fileprivate struct SubtitleCue {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

// MARK: - Subtitle delegate

/// AVPlayerItemLegibleOutput 푸시 델리게이트. 별도 NSObject로 분리한 이유:
/// 프로토콜 콜백이 메인 액터 격리가 아니기 때문에, @MainActor인 VideoSampler에서 직접 구현 불가.
final class SubtitleDelegate: NSObject, AVPlayerItemLegibleOutputPushDelegate {
    private let onSamples: ([NSAttributedString]) -> Void
    init(_ cb: @escaping ([NSAttributedString]) -> Void) {
        self.onSamples = cb
    }
    func legibleOutput(_ output: AVPlayerItemLegibleOutput,
                       didOutputAttributedStrings strings: [NSAttributedString],
                       nativeSampleBuffers: [Any],
                       forItemTime itemTime: CMTime) {
        onSamples(strings)
    }
}
