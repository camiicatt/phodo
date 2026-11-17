import SwiftUI

/// Sign in / sign up with an email code. Same screen for both: new emails
/// get an account automatically. (Sign in with Apple goes here later.)
struct AuthView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Spacer().frame(height: 40)
            Text("phodo").font(PhFont.title(64))
            Text("one pic a day.\njust for your people.").font(PhFont.mono(16)).foregroundStyle(theme.softInk)
                .fixedSize(horizontal: false, vertical: true)
            InkLine().padding(.vertical, 8)

            if !codeSent {
                field("email", text: $email, prompt: "you@school.edu")
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                Button { Task { await send() } } label: {
                    if busy { ProgressView().tint(theme.bg) } else { Text("send me a code") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || !email.contains("@"))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("check your email ✉︎").font(PhFont.bold(22))
                    Text("enter the code we sent to \(email). (tapping the link on this phone works too.)")
                        .font(PhFont.body(17)).fixedSize(horizontal: false, vertical: true)
                }
                field("code", text: $code, prompt: "123456")
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .onChange(of: code) { _, new in
                        let digits = String(new.filter(\.isNumber).prefix(8))
                        if digits != new { code = digits }
                    }
                Button { Task { await verify() } } label: {
                    if busy { ProgressView().tint(theme.bg) } else { Text("let me in") }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || code.filter(\.isNumber).count < 6)
                HStack {
                    Button("different email") { codeSent = false; code = ""; errorText = nil }
                    Spacer()
                    Button("resend") { Task { await send() } }
                }
                .font(PhFont.mono(14)).foregroundStyle(theme.softInk)
            }

            if let errorText {
                Text(errorText).font(PhFont.mono(13))
            }
            Spacer()
            if !store.isLive {
                Text("demo mode: no backend set up, any code works")
                    .font(PhFont.mono(12)).foregroundStyle(theme.softInk)
            }
        }
        .foregroundStyle(theme.ink)
        .phodoPage()
        .onAppear { errorText = store.loadError }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("done") { focused = false }.font(PhFont.bold(17))
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(spacing: 8) {
            FieldLabel(label)
            TextField("", text: text, prompt: Text(prompt).foregroundStyle(theme.softInk.opacity(0.6)))
                .font(PhFont.body(22))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
            InkLine()
        }
    }

    private func send() async {
        busy = true; defer { busy = false }
        do {
            try await store.sendCode(to: email)
            codeSent = true; errorText = nil
        } catch {
            errorText = error.localizedDescription.lowercased()
        }
    }

    private func verify() async {
        busy = true; defer { busy = false }
        do {
            try await store.verify(email: email, code: code)
        } catch {
            errorText = "that code didn't work — check it or resend"
        }
    }
}
