import SwiftUI
import Combine

@MainActor final class PhoneModel: ObservableObject {
    @Published var connectionText = UserDefaults.standard.string(forKey: "computerConnection") ?? ""
    @Published var api: ComputerAPI?
    @Published var groups: [MaterialGroup] = []
    @Published var scope = "recent"
    @Published var busy = false
    @Published var loading = false
    @Published var status = "让手机和电脑连接同一 Wi-Fi"
    @Published var alertMessage: String?
    @Published var saved = Set(UserDefaults.standard.stringArray(forKey: "savedMedia") ?? [])
    private var refreshID = UUID()

    func connect(_ value: String? = nil) async {
        guard !busy else { return }
        do {
            let connection = try Connection(value ?? connectionText)
            let client = ComputerAPI(connection)
            loading = true; defer { loading = false }
            let reply = try await client.library(scope: scope)
            api = client; connectionText = connection.originalURL.absoluteString; groups = reply.groups
            UserDefaults.standard.set(connectionText, forKey: "computerConnection")
            status = "已连接电脑 · \(reply.totalGroups) 组 · \(reply.totalVideos) 个成品"
        } catch { alertMessage = "连接失败：\(error.localizedDescription)\n请确认电脑已开启手机取成品，并连接同一 Wi-Fi。" }
    }
    func refresh() async {
        guard let client = api else { return }
        let id = UUID(); refreshID = id; let currentScope = scope; loading = true
        defer { if id == refreshID { loading = false } }
        do {
            let reply = try await client.library(scope: currentScope)
            guard id == refreshID && currentScope == scope else { return }
            groups = reply.groups; status = "\(reply.totalGroups) 组 · \(reply.totalVideos) 个成品"
        } catch { if id == refreshID { alertMessage = error.localizedDescription } }
    }
    func save(_ videos: [MediaItem]) async {
        guard !busy, let client = api else { return }
        busy = true; defer { busy = false }
        do { try await LivePhotoMaker.authorize() } catch { alertMessage = error.localizedDescription; return }
        var success = 0; var failures: [String] = []
        for (index, video) in videos.enumerated() {
            if !video.originalCover { failures.append("第 \(index + 1) 个素材缺少已确认的原封面"); continue }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveMaterial-" + UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let movie = directory.appendingPathComponent("processed.mp4"), cover = directory.appendingPathComponent("original.jpg")
                status = "正在下载 \(index + 1)/\(videos.count)…"
                try await client.download(video.video, to: movie)
                try await client.download(video.cover, to: cover)
                status = "正在封装并保存实况 \(index + 1)/\(videos.count)…"
                try await Task.detached(priority: .userInitiated) {
                    try await LivePhotoMaker.makeAndSave(video: movie, cover: cover, directory: directory)
                }.value
                success += 1; saved.insert(video.id); UserDefaults.standard.set(Array(saved), forKey: "savedMedia")
            } catch { failures.append("第 \(index + 1) 个：\(error.localizedDescription)") }
        }
        status = "已保存 \(success) 张实况" + (failures.isEmpty ? "" : " · \(failures.count) 个未完成")
        alertMessage = status + (failures.isEmpty ? "，可在相册中长按播放。" : "\n" + failures.prefix(3).joined(separator: "\n"))
    }
    func acceptDeepLink(_ url: URL) {
        guard url.scheme == "livematerial", url.host == "connect",
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value else { return }
        Task { await connect(value) }
    }
}
