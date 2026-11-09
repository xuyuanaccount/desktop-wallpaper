import AppKit
import AVFoundation
import SwiftUI
import WallpaperCore

struct GeneratedVideoPreview {
    let task: PendingVideoTask
    let url: URL
}

@MainActor
final class WallpaperVideoGeneration: ObservableObject {
    @Published private(set) var region = DashScopeRegion.beijing
    @Published var prompt = ""
    @Published var resolution = WallpaperVideoResolution.hd
    @Published var ratio = WallpaperVideoRatio.landscape
    @Published var duration = 5
    @Published var draftKey = ""
    @Published private(set) var hasKey = false
    @Published private(set) var editingKey = true
    @Published private(set) var pending: PendingVideoTask?
    @Published private(set) var output: GeneratedVideoPreview?
    @Published private(set) var running = false
    @Published private(set) var terminal = false
    @Published private(set) var progress: String?
    @Published var error: String?

    private let store: VideoDraftStore
    private let client = WanVideoClient()
    private var restored = false

    init(directory: URL) {
        store = VideoDraftStore(directory: directory)
        if let saved = UserDefaults.standard.string(forKey: "videoGenerationRegion"),
           let region = DashScopeRegion(rawValue: saved) {
            self.region = region
        }
    }

    var canGenerate: Bool {
        restored && pending == nil && !running && hasKey && !editingKey
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func open() {
        guard !running else { return }
        if !restored {
            do {
                pending = try store.load()
                if let pending { region = pending.region }
                restored = true
            } catch {
                self.error = "无法读取本地视频任务。\n\(error.localizedDescription)"
                return
            }
        }
        let terminalError = terminal ? error : nil
        refreshKey()
        if let terminalError { error = terminalError }
        if pending != nil && output == nil && !terminal { resume() }
    }

    func close() { draftKey = "" }

    func selectRegion(_ region: DashScopeRegion) {
        guard pending == nil, !running, region != self.region else { return }
        self.region = region
        UserDefaults.standard.set(region.rawValue, forKey: "videoGenerationRegion")
        refreshKey()
    }

    private func refreshKey() {
        draftKey = ""
        do {
            hasKey = try ImageGenerationKeychain.containsKey(for: region.keychainTarget)
            editingKey = !hasKey
            error = nil
        } catch {
            hasKey = false
            editingKey = true
            self.error = error.localizedDescription
        }
    }

    func editKey(_ editing: Bool) {
        draftKey = ""
        editingKey = editing
    }

    func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            error = ImageGenerationError.missingKey.localizedDescription
            return
        }
        do {
            try ImageGenerationKeychain.save(key, for: region.keychainTarget)
            hasKey = true
            editKey(false)
            error = nil
            if pending != nil && output == nil && !terminal { resume() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func generate() {
        guard canGenerate else { return }
        let prompt = prompt
        let resolution = resolution
        let ratio = ratio
        let duration = duration
        let region = region
        run(status: "正在提交视频任务…") {
            let key = try self.key(for: region)
            let taskID: String
            do {
                taskID = try await self.client.submit(prompt: prompt, resolution: resolution, ratio: ratio,
                                                      duration: duration, region: region, key: key)
            } catch is URLError {
                throw AppError("暂时无法确认任务是否已提交。请先在百炼控制台查看任务，再重新生成。")
            }
            let description = prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let task = PendingVideoTask(taskID: taskID, region: region, title: "AI 视频 · " + String(description.prefix(32)))
            self.pending = task
            try await self.resolve(task, key: key)
        }
    }

    func resume() {
        guard let pending, !terminal, !running, output == nil else { return }
        run(status: "正在查询原任务…") { try await self.resolve(pending) }
    }

    private func key(for region: DashScopeRegion) throws -> String {
        guard let key = try ImageGenerationKeychain.load(for: region.keychainTarget) else {
            hasKey = false
            editingKey = true
            throw ImageGenerationError.missingKey
        }
        return key
    }

    private func run(status: String, operation: @escaping () async throws -> Void) {
        running = true
        error = nil
        progress = status
        Task {
            defer { running = false }
            do {
                try await operation()
            } catch {
                terminal = (error as? VideoGenerationError)?.isTerminalTask == true
                self.error = error.localizedDescription
                progress = nil
            }
        }
    }

    private func resolve(_ task: PendingVideoTask, key savedKey: String? = nil) async throws {
        try store.save(task)
        let url = store.preview(for: task)
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try await PlayableVideo.check(url)
                output = GeneratedVideoPreview(task: task, url: url)
                progress = nil
                return
            } catch {
                try FileManager.default.removeItem(at: url)
            }
        }
        let key = try savedKey ?? key(for: task.region)
        let result = try await client.waitForResult(taskID: task.taskID, region: task.region, key: key) { state in
            self.progress = state == .pending ? "百炼正在排队…" : "正在生成视频…"
        }
        progress = "正在下载 MP4…"
        try await client.download(result, to: url)
        do {
            try await PlayableVideo.check(url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        output = GeneratedVideoPreview(task: task, url: url)
        progress = nil
    }

    func clear() throws {
        guard let pending, !running else { return }
        try store.clear(pending)
        self.pending = nil
        output = nil
        error = nil
        terminal = false
        progress = nil
    }
}

struct VideoGenerationView: View {
    @ObservedObject var generation: WallpaperVideoGeneration
    let onClose: () -> Void
    let onSave: (GeneratedVideoPreview, Bool) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 生成视频壁纸").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    LabeledContent("模型", value: "通义万相 2.7")
                    Picker("百炼地域", selection: Binding(get: { generation.region }, set: generation.selectRegion)) {
                        ForEach(DashScopeRegion.allCases) { region in Text(region.displayName).tag(region) }
                    }
                    .disabled(generation.pending != nil || generation.running)
                    keyControls.disabled(generation.running)
                    if generation.pending == nil {
                        TextField("描述画面和运动，例如云层缓缓流过雪山，镜头固定", text: $generation.prompt, axis: .vertical)
                            .lineLimit(3...6)
                            .accessibilityLabel("视频描述")
                            .disabled(generation.running)
                        HStack(spacing: 20) {
                            Picker("清晰度", selection: $generation.resolution) {
                                ForEach(WallpaperVideoResolution.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Picker("比例", selection: $generation.ratio) {
                                ForEach(WallpaperVideoRatio.allCases) { Text($0.rawValue).tag($0) }
                            }
                            Stepper("时长 \(generation.duration) 秒", value: $generation.duration, in: 2...15)
                        }
                        .disabled(generation.running)
                        Text("视频生成按时长和清晰度计费，默认 5 秒、720p。提交后可关闭此窗口，稍后回来查看。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let pending = generation.pending {
                        Text("任务 ID  \(pending.taskID)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    if let progress = generation.progress {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(progress)
                        }
                    }
                    if let error = generation.error {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let output = generation.output {
                        LoopingVideoPreview(url: output.url).id(output.url)
                            .frame(height: 250).accessibilityLabel("生成的视频预览")
                    }
                }
                .padding(1)
            }
            Divider()
            HStack {
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                if let output = generation.output {
                    Button("丢弃预览", role: .destructive) { clear() }
                    Button("保存到壁纸库") { save(output, apply: false) }
                    Button("保存并应用") { save(output, apply: true) }.buttonStyle(.borderedProminent)
                } else if generation.pending != nil, !generation.running {
                    Button("清除本地任务记录", role: .destructive) { clear() }
                    if !generation.terminal {
                        Button("继续查询", action: generation.resume)
                            .disabled(!generation.hasKey || generation.editingKey)
                    }
                } else if generation.pending == nil {
                    Button("生成视频", action: generation.generate)
                        .buttonStyle(.borderedProminent)
                        .disabled(!generation.canGenerate)
                }
            }
        }
        .padding(22)
        .frame(width: 640, height: generation.output == nil ? 445 : 610)
        .onAppear(perform: generation.open)
        .onDisappear(perform: generation.close)
    }

    @ViewBuilder private var keyControls: some View {
        HStack {
            if generation.editingKey {
                SecureField("百炼 API 密钥（\(generation.region.displayName)）", text: $generation.draftKey)
                Button("保存到钥匙串", action: generation.saveKey)
                    .disabled(generation.draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if generation.hasKey { Button("取消更换") { generation.editKey(false) } }
            } else {
                Label("已配置百炼 API 密钥", systemImage: "key").foregroundStyle(.secondary)
                Spacer()
                Button("更换") { generation.editKey(true) }
            }
        }
    }

    private func save(_ output: GeneratedVideoPreview, apply: Bool) {
        do {
            try onSave(output, apply)
            try generation.clear()
            onClose()
        } catch {
            generation.error = error.localizedDescription
        }
    }

    private func clear() {
        do { try generation.clear() } catch { generation.error = error.localizedDescription }
    }
}

private struct LoopingVideoPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> VideoView {
        VideoView(url: url, clock: nil, onReady: {}, onError: { _ in })
    }

    func updateNSView(_ view: VideoView, context: Context) {
        view.update(fit: .fit, volume: 0, playing: true)
    }

    static func dismantleNSView(_ view: VideoView, coordinator: ()) {
        view.update(fit: .fit, volume: 0, playing: false)
    }
}

enum PlayableVideo {
    static func check(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard playable && !tracks.isEmpty else { throw AppError("无法播放此文件，或文件没有视频轨道。") }
    }
}

private extension DashScopeRegion {
    var displayName: String { self == .beijing ? "北京" : "新加坡" }
    var keychainTarget: ImageGenerationTarget { self == .beijing ? .qwenBeijing : .qwenSingapore }
}
