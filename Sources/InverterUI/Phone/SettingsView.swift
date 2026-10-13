#if os(iOS)
import SwiftUI
import InverterCore

/// The account, which inverter to show, how it looks, and signing out, laid out like the Settings app.
struct SettingsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PhoneRootView.rememberKey) private var remember = true
    @State private var confirmSignOut = false
    @State private var user: String?

    var body: some View {
        NavigationStack {
            Form {
                Section { account }

                if store.devices.count > 1 {
                    Section("Inverter") {
                        Picker("Inverter", selection: Binding(
                            get: { store.devices.first(where: \.isSelected)?.id ?? "" },
                            set: { id in Task { await store.selectDevice(id) } })) {
                            ForEach(store.devices) { Text($0.name).tag($0.id) }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    }
                }

                Section {
                    Picker(selection: $store.heroStyle) {
                        ForEach(HeroStyle.selectable) { Text($0.title).tag($0) }
                    } label: {
                        SettingsRow(title: "Illustration", symbol: "photo", color: .orange)
                    }
                    .pickerStyle(.navigationLink)
                    Toggle(isOn: $remember) {
                        SettingsRow(title: "Remember Me", symbol: "key.fill", color: .gray)
                    }
                } footer: {
                    Text("With Remember Me off, you sign in again each time the app is opened.")
                }

                Section {
                    LabeledContent {
                        Text(Self.version)
                    } label: {
                        SettingsRow(title: "Version", symbol: "info", color: .blue)
                    }
                } footer: {
                    Text("Inverterly only reads your inverter. It cannot change any setting.")
                }

                Section {
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        Text("Sign Out").frame(maxWidth: .infinity)
                    }
                    .confirmationDialog("Sign out of this account?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                        Button("Sign Out", role: .destructive) {
                            Task { await store.signOut() }
                            dismiss()
                        }
                    } message: {
                        Text("Your saved login and history on this iPhone are removed.")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(.solarMark)
        .task { user = (try? InverterConfig.load())?.user }
    }

    /// The signed-in username under a round initial, and the inverter's rating.
    private var account: some View {
        HStack(spacing: 14) {
            Text(String((user ?? "?").prefix(1)).uppercased())
                .font(.title2.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(LinearGradient(colors: [.orange, .yellow.opacity(0.9)], startPoint: .bottomLeading, endPoint: .topTrailing),
                            in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(user ?? "Signed in").font(.title3.weight(.semibold)).lineLimit(1)
                Text(accountDetail).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var accountDetail: String {
        var parts = ["Inverter cloud account"]
        if let rated = store.snapshot?.ratedPowerW, rated > 0 { parts = [PowerFormat.kilowatts(rated) + " inverter"] }
        if let name = store.selectedDeviceName { parts.insert(name, at: 0) }
        return parts.joined(separator: " · ")
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

/// A Settings-style row: a white symbol on a small coloured square, then the title.
private struct SettingsRow: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(color, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Text(title)
        }
    }
}
#endif
