import AppKit
import SwiftUI
import WallpaperCore

struct GeneratedWallpaperPreview {
    let title: String
    let image: NSImage
    let png: Data
    var target: ImageGenerationTarget? = nil
}

@MainActor
final class WallpaperGeneration: ObservableObject {
    private static let targetPreference = "imageGenerationTarget"

    @Published private(set) var target = UserDefaults.standard.string(forKey: targetPreference)
        .flatMap(ImageGenerationTarget.init(rawValue:)) ?? .openAI
    @Published var prompt = ""
    @Published var size = WallpaperImageSize.desktop
    @Published var quality = WallpaperImageQuality.medium
    @Published var draftKey = ""
    @Published private(set) var hasKey = false
    @Published private(set) var editingKey = true
    @Published private(set) var output: GeneratedWallpaperPreview?
    @Published private(set) var running = false
    @Published var error: String?

    private let client = ImageGenerationClient()
    private var request: Task<Void, Never>?

    var canGenerate: Bool {
        hasKey && !editingKey && !running && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func selectTarget(_ target: ImageGenerationTarget) {
        guard !running, self.target != target else { return }
        self.target = target
        UserDefaults.standard.set(target.rawValue, forKey: Self.targetPreference)
        open()
    }

    func open() {
        draftKey = ""
        error = nil
        do {
            hasKey = try ImageGenerationKeychain.containsKey(for: target)
            editingKey = !hasKey
        } catch {
            hasKey = false
            editingKey = true
            self.error = error.localizedDescription
        }
    }

    func editKey(_ editing: Bool) {
        draftKey = ""
        editingKey = editing
        error = nil
    }

    func saveKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else {
            error = ImageGenerationError.missingKey.localizedDescription
            return
        }
        do {
            try ImageGenerationKeychain.save(key, for: target)
            hasKey = true
            editKey(false)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func removeKey() {
        do {
            try ImageGenerationKeychain.remove(for: target)
            hasKey = false
            editKey(true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func generate() {
        guard canGenerate else { return }
        let text = prompt
        let size = size
        let quality = quality
        let target = target
        error = nil
        running = true
        request = Task {
            defer {
                running = false
                request = nil
            }
            do {
                guard let key = try ImageGenerationKeychain.load(for: target) else {
                    hasKey = false
                    editKey(true)
                    throw ImageGenerationError.missingKey
                }
                let png = try await client.generate(prompt: text, size: size, quality: quality, key: key, target: target)
                try Task.checkCancellation()
                guard let image = NSImage(data: png) else { throw ImageGenerationError.invalidImage }
                let description = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                output = GeneratedWallpaperPreview(
                    title: "AI · " + String(description.prefix(36)), image: image, png: png, target: target
                )
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancel() { request?.cancel() }

    func close() {
        cancel()
        draftKey = ""
    }

    func discardOutput() { output = nil }
}

struct GenerationView: View {
    @ObservedObject var generation: WallpaperGeneration
    let onClose: () -> Void
    let onSave: (GeneratedWallpaperPreview, Bool) throws -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI 生成壁纸").font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Picker("模型", selection: Binding(get: { generation.target }, set: generation.selectTarget)) {
                        ForEach(ImageGenerationTarget.allCases) { target in
                            Text(target.displayName).tag(target)
                        }
                    }
                    .disabled(generation.running)
                    keyControls
                    Divider()
                    TextField("描述你想要的桌面壁纸", text: $generation.prompt, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityLabel("壁纸描述")
                    HStack(spacing: 20) {
                        Picker("比例", selection: $generation.size) {
                            Text("16:9").tag(WallpaperImageSize.desktop)
                            Text("16:10").tag(WallpaperImageSize.macBook)
                            Text("21:9").tag(WallpaperImageSize.ultrawide)
                            Text("9:16 竖屏").tag(WallpaperImageSize.portrait)
                        }
                        if generation.target == .openAI {
                            Picker("画质", selection: $generation.quality) {
                                Text("低").tag(WallpaperImageQuality.low)
                                Text("中").tag(WallpaperImageQuality.medium)
                                Text("高").tag(WallpaperImageQuality.high)
                            }
                        }
                    }
                    .disabled(generation.running)
                    Text("描述会发送至 \(generation.target.providerName)，每次生成会使用对应服务的 API 额度。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let error = generation.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                    if let output = generation.output {
                        Image(nsImage: output.image)
                            .resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 230)
                            .accessibilityLabel("生成的壁纸预览")
                        if let target = output.target {
                            Text("生成模型  \(target.displayName)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(1)
            }
            Divider()
            HStack {
                Button("关闭", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                if generation.running {
                    ProgressView().controlSize(.small)
                    Text("正在生成…").foregroundStyle(.secondary)
                    Button("取消请求", action: generation.cancel)
                } else {
                    Button("生成", action: generation.generate)
                        .buttonStyle(.borderedProminent)
                        .disabled(!generation.canGenerate)
                    if let output = generation.output {
                        Button("保存到壁纸库") { save(output, apply: false) }
                        Button("保存并应用") { save(output, apply: true) }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 620, height: generation.output == nil ? 440 : 625)
        .onAppear(perform: generation.open)
        .onDisappear(perform: generation.close)
    }

    @ViewBuilder private var keyControls: some View {
        if generation.editingKey {
            HStack {
                SecureField(generation.target.keyLabel, text: $generation.draftKey)
                    .accessibilityLabel(generation.target.keyLabel)
                Button("保存到钥匙串", action: generation.saveKey)
                    .disabled(generation.draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if generation.hasKey { Button("取消更换") { generation.editKey(false) } }
            }
        } else {
            HStack {
                Label("已配置 \(generation.target.keyLabel)", systemImage: "key")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("更换") { generation.editKey(true) }
                Button("删除密钥", role: .destructive, action: generation.removeKey)
            }
            .disabled(generation.running)
        }
    }

    private func save(_ output: GeneratedWallpaperPreview, apply: Bool) {
        do {
            try onSave(output, apply)
            generation.discardOutput()
            onClose()
        } catch {
            generation.error = error.localizedDescription
        }
    }
}


private extension ImageGenerationTarget {
    var displayName: String {
        switch self {
        case .openAI: "OpenAI GPT Image 2.6 Flare"
        case .qwenBeijing: "Qwen Image 3.0 Pro · 北京"
        case .qwenSingapore: "Qwen Image 3.0 Pro · 新加坡"
        }
    }

    var providerName: String { self == .openAI ? "OpenAI" : "阿里云百炼" }

    var keyLabel: String {
        switch self {
        case .openAI: "OpenAI API 密钥"
        case .qwenBeijing: "百炼 API 密钥（北京）"
        case .qwenSingapore: "百炼 API 密钥（新加坡）"
        }
    }
}
