import SwiftUI
import AVKit

@main struct LiveMaterialPhoneApp: App {
    @StateObject private var model = PhoneModel()
    var body: some Scene {
        WindowGroup {
            PhoneHome().environmentObject(model).tint(Color(red: 0.90, green: 0.18, blue: 0.25))
                .onOpenURL { model.acceptDeepLink($0) }
        }
    }
}

struct PhoneHome: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var scanning = false
    @State private var preview: MediaItem?
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Image("BrandLogo").resizable().scaledToFill().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("实况素材工作台").font(.title3.bold())
                            Text("手机取成品 · 原生实况保存").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    if model.api == nil { connectionCard }
                    else {
                        Picker("素材范围", selection: $model.scope) {
                            Text("最近任务").tag("recent"); Text("全部成品").tag("all")
                        }.pickerStyle(.segmented).disabled(model.busy)
                        Text(model.status).font(.subheadline).foregroundStyle(.secondary)
                        if model.groups.isEmpty { Text("这里还没有成品，请先在电脑处理，或切换到全部成品查看。").foregroundStyle(.secondary).padding(.vertical, 24) }
                        ForEach(model.groups) { group in groupCard(group) }
                    }
                    Text("电脑和客户端需保持运行。保存后在 iPhone 相册长按播放，实况保持静音。").font(.caption).foregroundStyle(.secondary)
                }.padding(20)
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if model.api != nil {
                        ToolbarItem(placement: .topBarLeading) { Button("扫码换电脑") { scanning = true }.disabled(model.busy) }
                        ToolbarItem(placement: .topBarTrailing) { Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.loading || model.busy) }
                    }
                }
                .refreshable { await model.refresh() }
                .task(id: model.scope) { if model.api != nil { await model.refresh() } }
                .sheet(isPresented: $scanning) { QRScanner { value in scanning = false; Task { await model.connect(value) } } }
                .sheet(item: $preview) { video in if let url = model.api?.imageURL(video.video) { MoviePreview(url: url) } }
                .alert("实况素材", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
                    Button("好") { model.alertMessage = nil }
                } message: { Text(model.alertMessage ?? "") }
                .safeAreaInset(edge: .bottom) {
                    if model.busy { HStack { ProgressView(); Text(model.status).font(.footnote) }.padding().frame(maxWidth: .infinity).background(.regularMaterial) }
                }
        }
    }
    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("连接你的电脑").font(.headline)
            Text("在电脑端打开“手机取成品”，然后扫描二维码。").font(.subheadline).foregroundStyle(.secondary)
            Button { scanning = true } label: { Label("扫描电脑二维码", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent)
            TextField("或粘贴电脑连接地址", text: $model.connectionText).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder)
            Button("连接电脑") { Task { await model.connect() } }.disabled(model.loading || model.connectionText.isEmpty)
            if model.loading { ProgressView("正在连接…") }
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
    private func groupCard(_ group: MaterialGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group.title).font(.headline)
            ForEach(Array(group.videos.enumerated()), id: \.element.id) { index, video in
                HStack(spacing: 12) {
                    Button { preview = video } label: {
                        AsyncImage(url: model.api?.imageURL(video.preview)) { image in image.resizable().scaledToFill() }
                        placeholder: { Color.gray.opacity(0.12).overlay(Image(systemName: "play.fill")) }
                            .frame(width: 62, height: 78).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("视频 \(String(format: "%02d", index + 1))").font(.subheadline.bold())
                        Text(ByteCountFormatter.string(fromByteCount: video.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        if !video.originalCover { Text("原封面未确认").font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer(minLength: 4)
                    Button(model.saved.contains(video.id) ? "再存实况" : "保存为实况") { Task { await model.save([video]) } }
                        .font(.subheadline).buttonStyle(.bordered).disabled(model.busy || !video.originalCover)
                }
            }
            Button { Task { await model.save(group.videos) } } label: { Label("保存整组实况（\(group.videos.count)）", systemImage: "livephoto").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).disabled(model.busy)
        }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 18))
    }
}

private struct MoviePreview: View {
    let url: URL
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player).ignoresSafeArea().onAppear { let value = AVPlayer(url: url); value.isMuted = true; player = value; value.play() }
            .onDisappear { player?.pause(); player = nil }
    }
}
