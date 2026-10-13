#if os(iOS)
import SwiftUI
import InverterCore

/// The iPhone and iPad app: sign-in until there is an account, then three tabs.
public struct PhoneRootView: View {
    @ObservedObject private var store: AppStore
    @State private var tab: PhoneTab = .now
    @State private var showSettings = false
    @AppStorage(rememberKey) private var remember = true

    /// Whether the account stays signed in from one launch to the next ("Remember me" at sign-in).
    static let rememberKey = "rememberSignIn"

    public init(store: AppStore) {
        self.store = store
    }

    public var body: some View {
        Group {
            if store.signInRequired && store.snapshot == nil {
                SignInScreen(store: store).transition(.opacity)
            } else {
                tabs.transition(.opacity)
            }
        }
        .animation(.smooth, value: store.signInRequired)
        .tint(.solarMark)
        .sheet(isPresented: $showSettings) { SettingsView(store: store) }
        .task {
            // Without "Remember me" the last launch's account is dropped before anything is read.
            if !remember { await store.signOut() }
            store.start()
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            screen(.now) { NowScreen(store: store, visible: tab == .now) }
            screen(.today) { TodayScreen(store: store) }
            screen(.history) { HistoryScreen(store: store) }
        }
    }

    private func screen(_ tab: PhoneTab, @ViewBuilder content: () -> some View) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    PhoneHeader(title: tab.title, store: store) { showSettings = true }
                    content()
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .refreshable { await store.refresh(force: true) }
            .toolbar(.hidden, for: .navigationBar)
            // With the bar hidden, cover the status bar in the page colour so the cards scroll under
            // it without a seam at rest.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 0).background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .tabItem { Label(tab.title, systemImage: tab.symbol) }
        .tag(tab)
    }
}

/// The tab's title with the reading's freshness under it, and the settings button beside them.
private struct PhoneHeader: View {
    let title: String
    @ObservedObject var store: AppStore
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                LiveStatus(store: store)
            }
            Spacer(minLength: 8)
            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 4).padding(.top, 8)
    }
}

enum PhoneTab: Hashable {
    case now, today, history

    var title: String {
        switch self {
        case .now: "Now"
        case .today: "Today"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .now: "bolt.fill"
        case .today: "chart.xyaxis.line"
        case .history: "calendar"
        }
    }
}

// MARK: - Shared pieces

/// A titled card on the grouped background.
struct PhoneCard<Content: View>: View {
    var title: String? = nil
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline)
                    Spacer(minLength: 8)
                    if let trailing {
                        Text(trailing).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            content
        }
        .padding(16)
        .phoneCard()
    }
}

/// Green while readings are fresh, orange once the logger has gone quiet, grey before the first one.
struct LiveStatus: View {
    @ObservedObject var store: AppStore

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.color).frame(width: 8, height: 8)
            Text(state.text).lineLimit(1).minimumScaleFactor(0.8)
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .animation(.snappy, value: state.text)
    }

    private var state: (color: Color, text: String) {
        guard let snapshot = store.snapshot else {
            return (.gray, store.errorMessage == nil ? "Connecting…" : "Not connected")
        }
        var parts = ["Updated " + (snapshot.deviceTime ?? snapshot.fetchedAt).formatted(date: .omitted, time: .shortened)]
        if let name = store.selectedDeviceName { parts.append(name) }
        return (store.readingIsStale ? .orange : .green, parts.joined(separator: " · "))
    }
}
#endif
