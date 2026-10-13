#if os(iOS)
import SwiftUI

/// The first screen: the account from the inverter's phone app. The password goes to the Keychain.
struct SignInScreen: View {
    @ObservedObject var store: AppStore
    @State private var user = ""
    @State private var password = ""
    @State private var working = false
    @AppStorage(PhoneRootView.rememberKey) private var remember = true
    @FocusState private var focus: Field?

    private enum Field { case user, password }

    private var ready: Bool { !user.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !working }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image("Logo")
                    .resizable()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
                    .padding(.top, 56)

                Text("Inverterly")
                    .font(.largeTitle.weight(.bold))
                    .padding(.top, 24)
                Text("Your solar inverter, live: panels, battery, grid and load.")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)

                fields.padding(.top, 40)

                Text("Use the same username and password as your inverter's monitoring app.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.top, 8)

                if let error = store.signInError, !working {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .padding(.top, 16)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) { footer }
        .animation(.snappy, value: store.signInError)
    }

    private var fields: some View {
        VStack(spacing: 0) {
            row("person") {
                TextField("Username", text: $user)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .user)
                    .onSubmit { focus = .password }
            }
            Divider().padding(.leading, 52)
            row("lock") {
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focus, equals: .password)
                    .onSubmit(submit)
            }
            Divider().padding(.leading, 52)
            row("checkmark.shield") {
                Toggle("Remember me", isOn: $remember)
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(working)
    }

    private func row(_ symbol: String, @ViewBuilder field: () -> some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 24)
            field()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Button(action: submit) {
                HStack(spacing: 8) {
                    if working { ProgressView().tint(.white) }
                    Text(working ? "Signing In…" : "Sign In").fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!ready)

            Label("Read-only. It can't change your inverter's settings.", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 440)
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func submit() {
        guard ready else { return }
        focus = nil
        working = true
        let account = user.trimmingCharacters(in: .whitespaces)
        Task {
            await store.signIn(user: account, password: password, inKeychain: true)
            working = false
            if store.signInRequired { focus = .password }
            password = ""
        }
    }
}
#endif
