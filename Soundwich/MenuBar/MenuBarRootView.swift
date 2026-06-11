import SwiftUI
import CoreAudio

struct MenuBarRootView: View {
    @StateObject private var deviceManager = AudioDeviceManager()
    @StateObject private var processManager = AudioProcessManager()
    @StateObject private var router = AudioRouter()
    @StateObject private var loginItem = LoginItemManager()
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            if showingSettings {
                settingsContent
            } else {
                mainContent
            }
        }
        .padding(16)
        .frame(width: 400, height: 430, alignment: .topLeading)
        .task {
            await deviceManager.refresh()
            processManager.start()
            // Soundwich is a fully manual tool. We never auto-route — the user is always
            // in control. Saved routes are remembered for convenience (checkmarked in the
            // menu) but require an explicit selection to engage.
        }
        .onChange(of: processManager.processes) { _, newProcesses in
            // Keep engaged taps in sync: tear down when the app quits, and re-create
            // when a browser spawns a new audio helper so the tap covers it.
            router.syncWithProcesses(newProcesses, outputs: deviceManager.outputDevices)
            // App (re)appearing can also trigger restore of a forcibly-released route.
            router.reconcileDevices(outputs: deviceManager.outputDevices, processes: newProcesses)
        }
        .onChange(of: deviceManager.outputDevices) { _, newOutputs in
            // Device removed → release route (audio → system default). Device back →
            // auto-restore a route that was released because it vanished.
            router.reconcileDevices(outputs: newOutputs, processes: processManager.processes)
        }
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            systemSection

            Divider()

            sectionLabel("Apps")

            if let err = router.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .padding(.horizontal, 2)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    let rows = makeRows()
                    if rows.isEmpty {
                        emptyState
                    } else {
                        ForEach(rows) { row in
                            RowView(
                                row: row,
                                outputs: deviceManager.outputDevices,
                                onSelect: { device in
                                    router.setRoute(
                                        processes: row.processes,
                                        bundleID: row.bundleID,
                                        appName: row.appName,
                                        output: device
                                    )
                                },
                                onClear: {
                                    router.clearRoute(bundleID: row.bundleID)
                                }
                            )
                            Divider()
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            // Fixed height ≈ 4 app rows; longer lists scroll within this area.
            .frame(height: 216)

            Divider()

            footer
        }
    }

    // MARK: - Settings

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Settings")

            Toggle(isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("로그인 시 시작")
                        .font(.body)
                    Text("맥을 켜면 Soundwich가 자동으로 실행됩니다")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if let err = loginItem.lastError {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { loginItem.refresh() }
    }

    // MARK: - System section

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("System")
            HStack(spacing: 10) {
                Image(systemName: "hifispeaker.2.fill")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("출력 장치")
                        .font(.body)
                    Text(deviceManager.defaultOutput?.name ?? "—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                DevicePopUpButton(
                    devices: deviceManager.outputDevices,
                    selectedUID: deviceManager.defaultOutput?.uid,
                    placeholder: "장치 선택",
                    showClear: false,
                    onSelect: { deviceManager.setDefaultOutput($0) },
                    onClear: {}
                )
                .frame(width: 160)
                .help("시스템 출력 장치 변경")
            }
            .padding(.vertical, 4)
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("재생 중인 앱이 없어요")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("앱이 소리를 내기 시작하면 여기에 표시됩니다")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var header: some View {
        HStack {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 24, height: 19)
            Text(showingSettings ? "설정" : "Soundwich")
                .font(.headline)
            Spacer()

            if showingSettings {
                Button {
                    showingSettings = false
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("뒤로")
            } else {
                Button {
                    processManager.refresh()
                    Task { await deviceManager.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("새로고침")

                Button {
                    loginItem.refresh()
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .help("설정")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("종료")
        }
    }

    private var footer: some View {
        HStack {
            Text("\(router.activeRoutes.count)개 활성 · \(router.store.routes.count)개 저장됨")
            Spacer()
            Text("v0.24")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    // MARK: - Row building

    /// "재생 중" OR "저장된 라우팅 있음" 만 표시.
    /// 같은 앱의 helper 프로세스들(Chrome Helper 등)은 bundleID 기준으로 한 행에 묶는다.
    /// 저장된 라우팅이 있고 앱이 꺼져 있어도 행을 보여서 편집 가능하게.
    private func makeRows() -> [Row] {
        // Group every audio process by its canonical bundleID — one row per app.
        let grouped = Dictionary(grouping: processManager.processes.filter { $0.bundleID != nil },
                                 by: { $0.bundleID! })

        var rows: [Row] = []

        for (bundleID, processes) in grouped {
            let savedRoute = router.savedRoute(forBundleID: bundleID)
            let isPlaying = processes.contains { $0.isRunningOutput }
            // Skip apps that are neither playing nor configured
            guard isPlaying || savedRoute != nil else { continue }
            let representative = processes.first { $0.icon != nil } ?? processes[0]
            rows.append(Row(
                bundleID: bundleID,
                appName: representative.name,
                icon: representative.icon,
                processes: processes,
                isPlaying: isPlaying,
                savedRoute: savedRoute,
                activeRoute: router.activeRoute(forBundleID: bundleID),
                pendingOutputUID: router.pendingRoutes[bundleID]
            ))
        }

        // Saved routes for apps that aren't currently running
        for (bundleID, saved) in router.store.routes where grouped[bundleID] == nil {
            rows.append(Row(
                bundleID: bundleID,
                appName: saved.appName,
                icon: nil,
                processes: [],
                isPlaying: false,
                savedRoute: saved,
                activeRoute: nil,
                pendingOutputUID: nil
            ))
        }

        // Stable alphabetical order — rows stay put regardless of playing/idle state.
        // Visual distinction (audible wave icon, active route subtitle) carries that info instead.
        return rows.sorted { lhs, rhs in
            lhs.appName.localizedCompare(rhs.appName) == .orderedAscending
        }
    }
}

// MARK: - Row model

private struct Row: Identifiable {
    let bundleID: String
    let appName: String
    let icon: NSImage?
    let processes: [AudioProcess]
    let isPlaying: Bool
    let savedRoute: RoutingStore.SavedRoute?
    let activeRoute: AudioRouter.ActiveRouteInfo?
    /// Target outputUID while a route is being engaged (Bluetooth wake can take 1–2s).
    let pendingOutputUID: String?

    var id: String { bundleID }
    var isRunning: Bool { !processes.isEmpty }
}

// MARK: - Row view

private struct RowView: View {
    let row: Row
    let outputs: [AudioDevice]
    let onSelect: (AudioDevice) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            iconView

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.appName)
                        .font(.body)
                        .lineLimit(1)
                        .foregroundStyle(row.isRunning ? .primary : .secondary)
                    if !row.isRunning {
                        Text("꺼짐")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.gray.opacity(0.2), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }

                subtitle
            }

            Spacer()

            // The popup shows REALITY, not the saved wish: engaged route (or the one
            // being engaged) → its device; otherwise "시스템 기본" since the app's
            // audio actually follows the system default until a route is engaged.
            DevicePopUpButton(
                devices: outputs,
                selectedUID: row.pendingOutputUID ?? row.activeRoute?.outputDeviceUID,
                placeholder: "시스템 기본",
                showClear: row.savedRoute != nil,
                onSelect: onSelect,
                onClear: onClear
            )
            .frame(width: 160)
            .help("출력 장치 선택")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var subtitle: some View {
        if let active = row.activeRoute {
            HStack(spacing: 4) {
                Image(systemName: "arrow.right").font(.caption2)
                Text(active.outputDeviceName).font(.caption)
            }
            .foregroundStyle(.green)
        } else if let saved = row.savedRoute {
            HStack(spacing: 4) {
                Image(systemName: "arrow.right.circle.dotted").font(.caption2)
                Text("저장됨: \(saved.outputDeviceName)").font(.caption)
            }
            .foregroundStyle(.secondary)
        } else if row.isPlaying {
            Text("재생 중 · 기본 출력")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("유휴")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = row.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 24, height: 24)
                .opacity(row.isRunning ? 1.0 : 0.5)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    MenuBarRootView()
}
