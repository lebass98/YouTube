import AVFoundation
import CoreAudio
import MediaPlayer
import SwiftUI

/// 지금 재생 중인 것 하나 (재생 창 영상이든 듣기 모드 소리든)
/// - 키보드 미디어 키(⏯ ⏭)·제어 센터 "지금 재생 중"·메뉴 막대 미니 플레이어가 모두 이것을 봄
/// - 재생 속도(채널마다 기억)·광고 구간 건너뛰기·시청 시간 기록도 여기서 붙임
/// - 이어폰(AirPods 등)을 빼서 소리가 맥 스피커로 바뀌면 멈춤
@MainActor
final class NowPlaying: ObservableObject {
    static let shared = NowPlaying()

    enum Source { case video, listen }

    @Published private(set) var id: String?
    @Published private(set) var title = ""
    @Published private(set) var channel = ""
    @Published private(set) var channelID: String?
    @Published private(set) var source = Source.video
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var rate: Float = 1
    @Published private(set) var chapters: [YTDLP.StreamInfo.Chapter] = []

    var thumbnailURL: URL? { id.map { URL(string: "https://i.ytimg.com/vi/\($0)/hqdefault.jpg")! } }
    var isActive: Bool { player != nil }

    private(set) weak var player: AVPlayer?
    private var timeObserver: Any?
    private weak var observedPlayer: AVPlayer?
    private var skipper: SegmentSkipper?
    private var artwork: MPMediaItemArtwork?

    private init() {
        setUpRemoteCommands()
        OutputWatcher.shared.start()
    }

    /// 재생을 시작할 때 (재생 창·듣기 모드 모두)
    func attach(_ player: AVPlayer, id: String, title: String, channel: String, channelID: String?,
                duration: Double?, chapters: [YTDLP.StreamInfo.Chapter], source: Source) {
        detachObserver()
        self.player = player
        self.id = id
        self.title = title
        self.channel = channel
        self.channelID = channelID
        self.source = source
        self.duration = duration ?? 0
        self.chapters = chapters
        artwork = nil
        // 채널마다 기억한 속도로
        let speed = PlaybackSpeed.speed(for: channelID)
        player.defaultRate = speed
        if player.rate > 0 { player.rate = speed }
        rate = speed
        // 광고·인트로 등 건너뛰기
        skipper = SegmentSkipper(player: player, videoID: id)
        // 1초마다: 위치·재생 여부 갱신, 시청 시간 기록
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        loadArtwork()
        updateInfo()
    }

    /// 재생을 끝낼 때 (그 플레이어가 지금 것일 때만)
    func detach(_ player: AVPlayer) {
        guard player === self.player else { return }
        detachObserver()
        self.player = nil
        id = nil
        isPlaying = false
        chapters = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    private func detachObserver() {
        if let timeObserver, let observedPlayer { observedPlayer.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observedPlayer = nil
        skipper = nil
    }

    private var lastStatsTick = Date()

    private func tick(_ seconds: Double) {
        guard let player else { return }
        position = seconds.isFinite ? seconds : 0
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }
        let playing = player.rate > 0
        if playing != isPlaying { isPlaying = playing }
        if playing, player.rate != rate, player.rate != 0 { rate = player.rate }
        skipper?.check(position)
        // 시청 시간: 실제로 흘러간 시간만 (속도와 무관하게 내가 쓴 시간)
        let now = Date()
        if playing { WatchStats.shared.add(seconds: min(now.timeIntervalSince(lastStatsTick), 2), channel: channel) }
        lastStatsTick = now
        updateInfo()
    }

    // MARK: 조작 (메뉴 막대·미디어 키·듣기 창이 씀)

    func togglePlay() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.play() }
        isPlaying = player.rate > 0
        updateInfo()
    }

    func play() { player?.play(); isPlaying = true; updateInfo() }
    func pause() { player?.pause(); isPlaying = false; updateInfo() }

    func skip(_ seconds: Double) {
        guard let player else { return }
        let target = max(0, player.currentTime().seconds + seconds)
        seek(to: duration > 0 ? min(target, duration - 1) : target)
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        position = seconds
        updateInfo()
    }

    /// 재생 속도 바꾸기 (이 채널 속도로 기억)
    func setRate(_ value: Float) {
        guard let player else { return }
        player.defaultRate = value
        if player.rate > 0 { player.rate = value }
        rate = value
        PlaybackSpeed.remember(value, for: channelID)
        Toast.shared.show("재생 속도 \(PlaybackSpeed.label(value))" + (channelID == nil ? "" : " (이 채널은 다음에도)"), seconds: 2)
        updateInfo()
    }

    func faster() { setRate(PlaybackSpeed.step(rate, by: 1)) }
    func slower() { setRate(PlaybackSpeed.step(rate, by: -1)) }

    /// 다음 영상 (대기열에서). 없으면 알려 줌
    func next() {
        guard let entry = PlayQueue.shared.popNext() else {
            Toast.shared.show("대기열에 다음 영상이 없어요", seconds: 2)
            return
        }
        Playback.open(entry.playerItem, listen: source == .listen)
    }

    // MARK: 제어 센터 "지금 재생 중"·미디어 키

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in MainActor.assumeIsolated { NowPlaying.shared.play() }; return .success }
        center.pauseCommand.addTarget { _ in MainActor.assumeIsolated { NowPlaying.shared.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { _ in MainActor.assumeIsolated { NowPlaying.shared.togglePlay() }; return .success }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { _ in MainActor.assumeIsolated { NowPlaying.shared.skip(15) }; return .success }
        center.skipBackwardCommand.addTarget { _ in MainActor.assumeIsolated { NowPlaying.shared.skip(-15) }; return .success }
        center.nextTrackCommand.addTarget { _ in MainActor.assumeIsolated { NowPlaying.shared.next() }; return .success }
        // 이전 곡 키: 처음으로 (3초 넘게 들었으면) — 대기열은 앞으로만 감
        center.previousTrackCommand.addTarget { _ in MainActor.assumeIsolated { NowPlaying.shared.seek(to: 0) }; return .success }
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let time = event.positionTime
            MainActor.assumeIsolated { NowPlaying.shared.seek(to: time) }
            return .success
        }
    }

    private func updateInfo() {
        guard player != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: channel,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType: source == .listen ? MPNowPlayingInfoMediaType.audio.rawValue : MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        MPRemoteCommandCenter.shared().nextTrackCommand.isEnabled = !PlayQueue.shared.entries.isEmpty
    }

    private func loadArtwork() {
        guard let url = thumbnailURL, let id else { return }
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), self.id == id else { return }
            artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            updateInfo()
        }
    }
}

// MARK: - 재생 시작 (재생 창 또는 듣기 모드)

@MainActor
enum Playback {
    /// listen: nil이면 지금 설정(듣기 모드 켜짐/꺼짐)을 따름
    static func open(_ item: PlayerItem, listen: Bool? = nil) {
        HoverPreview.shared.stop()
        if listen ?? ListenMode.shared.isOn {
            PlayerWindowController.shared.closePlayer()
            ListenPlayer.shared.play(item)
        } else {
            ListenPlayer.shared.stop()
            PlayerWindowController.shared.open(item)
        }
    }

    /// 영상이 끝까지 재생됐을 때: 본 영상으로 표시하고, 대기열에 다음이 있으면 이어서
    /// 돌려주는 값: 다음 영상을 틀었으면 true
    static func finished(_ id: String, listen: Bool) -> Bool {
        WatchMarks.shared.markWatched(id)
        guard PlayQueue.shared.autoAdvance, let next = PlayQueue.shared.popNext() else { return false }
        DebugLog.write("대기열 다음 영상: \(next.title)")
        Toast.shared.show("다음 영상: \(next.title)", seconds: 3)
        open(next.playerItem, listen: listen)
        return true
    }
}

/// 듣기 모드 켜짐/꺼짐 (켜져 있으면 영상을 누를 때 소리만 재생)
@MainActor
final class ListenMode: ObservableObject {
    static let shared = ListenMode()
    @Published var isOn = UserDefaults.standard.bool(forKey: "listenMode") {
        didSet {
            UserDefaults.standard.set(isOn, forKey: "listenMode")
            Toast.shared.show(isOn ? "듣기 모드 켜짐: 영상을 누르면 소리만 재생해요" : "듣기 모드 꺼짐: 영상을 누르면 재생 창에서 봐요", seconds: 3)
        }
    }
}

// MARK: - 재생 속도 (채널마다 기억)

enum PlaybackSpeed {
    static let choices: [Float] = [0.75, 1, 1.25, 1.5, 1.75, 2]

    private static var byChannel: [String: Float] {
        get { (UserDefaults.standard.dictionary(forKey: "speedByChannel") as? [String: Float]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "speedByChannel") }
    }

    /// 이 채널에서 마지막으로 쓴 속도 (처음 보는 채널은 1배)
    static func speed(for channelID: String?) -> Float {
        guard let channelID else { return 1 }
        return byChannel[channelID] ?? 1
    }

    static func remember(_ value: Float, for channelID: String?) {
        guard let channelID else { return }
        var all = byChannel
        all[channelID] = value == 1 ? nil : value
        byChannel = all
    }

    static func step(_ current: Float, by delta: Int) -> Float {
        let index = choices.firstIndex { $0 >= current - 0.01 } ?? 1
        return choices[max(0, min(choices.count - 1, index + delta))]
    }

    static func label(_ value: Float) -> String {
        value == Float(Int(value)) ? "\(Int(value))배" : String(format: "%g배", value)
    }
}

// MARK: - 이어폰을 빼면 멈춤

/// 소리 나가는 곳이 바뀌어 맥 내장 스피커가 되면(이어폰·AirPods를 뺐을 때) 재생을 멈춤
final class OutputWatcher: @unchecked Sendable {
    static let shared = OutputWatcher()
    private var started = false
    private var lastWasBuiltIn = OutputWatcher.isBuiltIn(OutputWatcher.defaultDevice())

    func start() {
        guard !started else { return }
        started = true
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main) { [weak self] _, _ in
            guard let self else { return }
            let builtIn = Self.isBuiltIn(Self.defaultDevice())
            let unplugged = builtIn && !self.lastWasBuiltIn
            self.lastWasBuiltIn = builtIn
            guard unplugged, UserDefaults.standard.object(forKey: "pauseOnUnplug") as? Bool ?? true else { return }
            MainActor.assumeIsolated {
                guard NowPlaying.shared.isPlaying else { return }
                NowPlaying.shared.pause()
                DebugLog.write("이어폰 빠짐 → 재생 멈춤")
                Toast.shared.show("이어폰이 빠져서 멈췄어요", seconds: 3)
            }
        }
    }

    private static func defaultDevice() -> AudioDeviceID {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    private static func isBuiltIn(_ device: AudioDeviceID) -> Bool {
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport == kAudioDeviceTransportTypeBuiltIn
    }
}
