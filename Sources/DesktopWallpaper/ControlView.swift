import ServiceManagement
import SwiftUI
import WallpaperCore

struct ControlView: View {
    @ObservedObject var model: ControlModel
    @ObservedObject var engine: DesktopEngine

    var body: some View {
        TabView {
            library.tabItem { Label("壁纸", systemImage: "photo.on.rectangle") }
            displays.tabItem { Label("显示器", systemImage: "display.2") }
            AutomationView(model: model).tabItem { Label("自动切换", systemImage: "clock.arrow.circlepath") }
            playback.tabItem { Label("设置", systemImage: "gearshape") }
        }
        .padding(12)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Label(engine.status, systemImage: model.settings.manuallyPaused ? "pause.circle" : "display")
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.settings.manuallyPaused ? "继续播放" : "暂停播放") { model.update { $0.manuallyPaused.toggle() } }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .sheet(isPresented: $model.urlSheet) {
            VStack(alignment: .leading, spacing: 16) {
                Text("导入网页地址").font(.headline)
                TextField("https://example.com/wallpaper", text: $model.urlText)
                HStack {
                    Spacer()
                    Button("取消") { model.urlSheet = false }.keyboardShortcut(.cancelAction)
                    Button("导入") {
                        model.urlSheet = false
                        model.addRemote(model.urlText)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 440)
        }
        .sheet(item: $model.generationSheet) { kind in
            switch kind {
            case .image:
                GenerationView(generation: model.generation, onClose: { model.generationSheet = nil }, onSave: model.saveGenerated)
            case .video:
                VideoGenerationView(generation: model.videoGeneration, onClose: { model.generationSheet = nil }, onSave: model.saveGeneratedVideo)
            }
        }
        .alert("动态壁纸", isPresented: Binding(
            get: { model.message != nil },
            set: { if !$0 { model.message = nil } }
        )) {
            Button("好", role: .cancel) { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var library: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $model.selectedID) {
                    ForEach(model.settings.wallpapers) { item in
                        Label(item.title, systemImage: sourceIcon(item.source)).tag(item.id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack {
                    Menu {
                        Button("导入本地文件或文件夹…", action: model.addLocal)
                        Button("导入网页地址…") { model.urlText = ""; model.urlSheet = true }
                        Button("添加内置演示", action: model.addDemo)
                    } label: {
                        Label("导入", systemImage: "plus")
                    }
                    .disabled(model.importing)
                    Spacer()
                    if model.importing { ProgressView().controlSize(.small) }
                    generationMenu
                }
                .padding(10)
            }
            .frame(width: 230)
            Divider()
            if let item = model.selected {
                detail(item)
            } else {
                ContentUnavailableView {
                    Label("添加你的第一张壁纸", systemImage: "photo.on.rectangle")
                } description: {
                    Text("导入 JPG、JPEG、PNG 图片、本地视频或网页壁纸。也可以先试用内置演示。")
                } actions: {
                    HStack {
                        generationMenu
                        Button("添加内置演示", action: model.addDemo)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var generationMenu: some View {
        Menu {
            Button("生成图片…") { model.generationSheet = .image }
            Button("生成视频…") { model.generationSheet = .video }
        } label: {
            Label("AI 生成", systemImage: "sparkles")
        }
    }

    private func detail(_ item: Wallpaper) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(item.title, systemImage: sourceIcon(item.source)).font(.title2.weight(.semibold))
                    Text(item.source.url.isFileURL ? item.source.url.path : item.source.url.absoluteString)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                HStack {
                    Button("应用到桌面") {
                        model.update { $0.applyWallpaper(item.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("预览") { model.preview(item) }
                }
                if let issue = engine.issues[item.id] {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Divider()
                TextField("名称", text: Binding(
                    get: { model.settings.wallpaper(item.id)?.title ?? "" },
                    set: { value in model.changeWallpaper(item.id) { $0.title = value } }
                ))
                switch item.source {
                case .video, .image:
                    Picker("缩放方式", selection: Binding(
                        get: { model.settings.wallpaper(item.id)?.fit ?? .fill },
                        set: { value in model.changeWallpaper(item.id) { $0.fit = value } }
                    )) {
                        Text("填满（裁切）").tag(VideoFit.fill)
                        Text("完整（留边）").tag(VideoFit.fit)
                    }
                    if case .video = item.source {
                        Slider(value: Binding(
                            get: { model.settings.wallpaper(item.id)?.volume ?? 0 },
                            set: { value in model.changeWallpaper(item.id) { $0.volume = value } }
                        ), in: 0...1) { Text("音量") }
                    }
                case .localWeb, .remoteWeb:
                    Toggle("转发桌面鼠标移动和左键动作", isOn: Binding(
                        get: { model.settings.wallpaper(item.id)?.interactive ?? false },
                        set: { value in model.changeWallpaper(item.id) { $0.interactive = value } }
                    ))
                }
                Divider()
                HStack {
                    if item.source.url.isFileURL {
                        Button("导出为屏保…") { model.exportSaver(item) }
                    }
                    Spacer()
                    Button("从壁纸库移除", role: .destructive) { model.remove(item.id) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
    }

    private var displays: some View {
        Form {
            Section {
                Picker("布局", selection: binding(\.layout)) {
                    Text("每个显示器独立").tag(DisplayLayout.independent)
                    Text("跨屏铺满").tag(DisplayLayout.span)
                }
                if model.settings.layout == .span {
                    assignmentPicker("跨屏壁纸", selection: binding(\.spanAssignment))
                } else {
                    assignmentPicker("默认壁纸", selection: binding(\.defaultAssignment))
                }
            } footer: {
                Text("选择「使用自动切换」后，播放列表、定时与应用规则会在对应屏幕上生效。")
            }
            if model.settings.layout == .independent {
                Section("已连接的显示器") {
                    ForEach(engine.displays) { screen in
                        HStack {
                            assignmentPicker(screen.name, selection: Binding(
                                get: { model.settings.assignment(for: screen.id) },
                                set: { value in model.update { $0.displayAssignments[screen.id] = value } }
                            ))
                            if model.settings.displayAssignments[screen.id] != nil {
                                Button("继承默认") { model.update { $0.displayAssignments.removeValue(forKey: screen.id) } }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var playback: some View {
        Form {
            Section("性能") {
                Toggle("全屏应用覆盖显示器时暂停", isOn: binding(\.pauseOnFullscreen))
                Toggle("使用电池时暂停", isOn: binding(\.pauseOnBattery))
                Button("重新加载桌面壁纸", action: engine.reload)
            }
            Section("系统") {
                Toggle("登录时启动", isOn: Binding(
                    get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                    set: model.setLaunchAtLogin
                ))
                if model.loginStatus == .requiresApproval {
                    Button("在系统设置中允许登录项") { SMAppService.openSystemSettingsLoginItems() }
                }
                Text("屏保可从壁纸详情导出。双击导出的 .saver 安装，再到系统设置中选择。")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<Value>(_ path: WritableKeyPath<EngineSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: path] }, set: { value in model.update { $0[keyPath: path] = value } })
    }

    private func assignmentPicker(_ label: String, selection: Binding<Assignment>) -> some View {
        Picker(label, selection: selection) {
            Text("系统壁纸").tag(Assignment.off)
            Text("使用自动切换").tag(Assignment.automatic)
            ForEach(model.settings.wallpapers) { item in
                Text(item.title).tag(Assignment.wallpaper(item.id))
            }
        }
    }

    private func sourceIcon(_ source: WallpaperSource) -> String {
        switch source {
        case .video: "film"
        case .image: "photo"
        case .localWeb: "safari"
        case .remoteWeb: "globe"
        }
    }
}

private struct AutomationView: View {
    @ObservedObject var model: ControlModel

    var body: some View {
        Form {
            Section {
                Picker("添加到规则的壁纸", selection: $model.chosenWallpaper) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach(model.settings.wallpapers) { item in Text(item.title).tag(Optional(item.id)) }
                }
            } footer: {
                Text("前台应用规则优先，然后使用当前时间段的规则，最后使用播放列表。")
            }
            Section("循环播放列表") {
                Stepper(value: Binding(
                    get: { model.settings.intervalSeconds / 60 },
                    set: { value in model.update { $0.intervalSeconds = value * 60 } }
                ), in: 1...1440) {
                    Text("每 \(model.settings.intervalSeconds / 60) 分钟切换")
                }
                ForEach(Array(model.settings.playlist.enumerated()), id: \.offset) { index, id in
                    HStack {
                        Text(model.settings.wallpaper(id)?.title ?? "已移除的壁纸")
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                            .help("向上移动").disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                            .help("向下移动").disabled(index + 1 >= model.settings.playlist.count)
                        removeButton { model.update { _ = $0.playlist.remove(at: index) } }
                    }
                }
                HStack {
                    Button("添加壁纸") {
                        if let id = validSelection {
                            model.update {
                                if $0.playlist.isEmpty { $0.playlistStart = .now }
                                $0.playlist.append(id)
                            }
                        }
                    }
                    .disabled(validSelection == nil)
                    Button("从头播放") { model.update { $0.playlistStart = .now } }
                        .disabled(model.settings.playlist.isEmpty)
                }
            }
            Section("每日时间") {
                ForEach(model.settings.schedule.sorted { $0.minute < $1.minute }) { rule in
                    HStack {
                        Text(String(format: "%02d:%02d", rule.minute / 60, rule.minute % 60)).monospacedDigit()
                        Text(rule.wallpaperID.flatMap(model.settings.wallpaper)?.title ?? "恢复播放列表")
                        Spacer()
                        removeButton { model.update { $0.schedule.removeAll { $0.minute == rule.minute } } }
                    }
                }
                DatePicker("从此时开始", selection: $model.ruleDate, displayedComponents: [.hourAndMinute])
                HStack {
                    Button("设为所选壁纸") { addSchedule(validSelection) }.disabled(validSelection == nil)
                    Button("恢复播放列表") { addSchedule(nil) }
                }
            }
            Section("前台应用") {
                ForEach(model.settings.apps) { rule in
                    HStack {
                        Text(rule.name)
                        Text(model.settings.wallpaper(rule.wallpaperID)?.title ?? "").foregroundStyle(.secondary)
                        Spacer()
                        removeButton { model.update { $0.apps.removeAll { $0.bundleID == rule.bundleID } } }
                    }
                }
                Button("选择应用…") {
                    if let id = validSelection { model.addApplicationRule(for: id) }
                }
                .disabled(validSelection == nil)
            }
        }
        .formStyle(.grouped)
    }

    private var validSelection: UUID? {
        (model.chosenWallpaper ?? model.selectedID).flatMap { model.settings.wallpaper($0)?.id }
    }

    private func move(_ index: Int, by offset: Int) {
        model.update { $0.playlist.swapAt(index, index + offset) }
    }

    private func addSchedule(_ id: UUID?) {
        let clock = Calendar.current.dateComponents([.hour, .minute], from: model.ruleDate)
        let minute = (clock.hour ?? 0) * 60 + (clock.minute ?? 0)
        model.update {
            $0.schedule.removeAll { $0.minute == minute }
            $0.schedule.append(ScheduleRule(minute: minute, wallpaperID: id))
        }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { Image(systemName: "minus.circle") }.help("移除")
    }
}
