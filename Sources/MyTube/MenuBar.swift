import SwiftUI

/// 메뉴 막대 미니 플레이어: 앱 창을 다 닫거나 다른 일을 하면서도 제목·재생·15초·다음을 조작
struct MenuBarView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var now = NowPlaying.shared
    @ObservedObject private var listen = ListenMode.shared
    @ObservedObject private var listenPlayer = ListenPlayer.shared
    @ObservedObject private var queue = PlayQueue.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if now.isActive, let id = now.id {
                HStack(alignment: .top, spacing: 10) {
                    AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { Color.secondary.opacity(0.15) }
                    }
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(now.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        Text(now.channel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Label(now.source == .listen ? "듣기 모드" : "재생 창", systemImage: now.source == .listen ? "headphones" : "play.rectangle")
                            .font(.caption2).foregroundStyle(theme.style)
                    }
                }
                ScrubBar(compact: true)
                HStack(spacing: 16) {
                    Button { now.skip(-15) } label: { Image(systemName: "gobackward.15") }
                    Button { now.togglePlay() } label: {
                        Image(systemName: now.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 28)).foregroundStyle(theme.style)
                    }
                    Button { now.skip(15) } label: { Image(systemName: "goforward.15") }
                    Button { now.next() } label: { Image(systemName: "forward.end.fill") }
                        .disabled(queue.entries.isEmpty)
                    Spacer()
                    SpeedMenu { rate in
                        Text(PlaybackSpeed.label(rate)).font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 6).frame(height: 20)
                            .background(Capsule().strokeBorder(Color.secondary.opacity(0.6)))
                    }
                }
                .buttonStyle(.borderless)
                .font(.system(size: 15))
                HStack {
                    if now.source == .listen {
                        Button(MiniPlayerWindow.shared.isVisible ? "듣기 창 앞으로" : "듣기 창 보이기") { MiniPlayerWindow.shared.show() }
                        Button("영상으로 보기") { listenPlayer.switchToVideo() }
                    }
                    Spacer()
                    Button("멈추고 닫기") {
                        if now.source == .listen { listenPlayer.stop() } else { PlayerWindowController.shared.closePlayer() }
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            } else {
                Label("재생 중인 영상이 없어요", systemImage: "play.slash")
                    .foregroundStyle(.secondary)
            }

            Divider()
            Toggle(isOn: $listen.isOn) {
                Label("듣기 모드 (영상 누르면 소리만)", systemImage: "headphones")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if !queue.entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("다음 재생 (\(queue.entries.count)개)").font(.caption).foregroundStyle(.secondary)
                    ForEach(queue.entries.prefix(3)) { entry in
                        Button { queue.play(entry) } label: {
                            Text(entry.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                    }
                }
            }

            Divider()
            HStack {
                Button("MyTube 열기") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("종료") { NSApp.terminate(nil) }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(14)
        .frame(width: 320)
    }
}
