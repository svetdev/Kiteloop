import SwiftUI

/// First run: scan the pairing QR the Mac shows under Settings → Control API
/// → "Pair a phone" — it carries the URL and a one-time code the phone trades
/// for a token of its own, so connecting is one scan. Manual entry stays as the fallback (the simulator
/// has no camera). Pairing adds a Mac; one already saved under the same
/// address gets the new token instead.
struct ConnectView: View {
    @Bindable var connection: ConnectionStore
    /// Set when shown to add another Mac: called once the new one is paired.
    var onPaired: (() -> Void)?
    @State private var url: String = ""
    @State private var token: String = ""
    @State private var scanning = false
    @State private var scanProblem: String?
    @State private var claiming = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan pairing code from the Mac", systemImage: "qrcode.viewfinder")
                    }
                    if claiming {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Pairing with the Mac…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let problem = scanProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    if let problem = connection.tokenStoreProblem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                    Text("On the Mac: Settings → Control API → Pair a phone.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Pair")
                }
                Section("Or by hand") {
                    TextField("http://100.x.y.z:4517", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("token from ~/.kiteloop/control-token", text: $token)
                    Button("Connect") {
                        connection.pair(baseURL: url, token: token)
                        onPaired?()
                    }
                    .disabled(url.isEmpty || token.isEmpty)
                }
            }
            .navigationTitle("Connect to Kiteloop")
            .onAppear { if onPaired == nil { url = connection.baseURL } }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    ScannerView(onCode: { code in
                        scanning = false
                        apply(code)
                    }, onFailure: { message in
                        scanning = false
                        scanProblem = message
                    })
                    .ignoresSafeArea()
                    .navigationTitle("Scan the Mac's QR")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("Cancel") { scanning = false } }
                    }
                }
            }
        }
    }

    /// A scanned code: paired straight away when it carries a token, else
    /// once the Mac has traded its one-time code for one.
    private func apply(_ code: String) {
        guard let link = PairingLink(code) else {
            scanProblem = "That QR is not a Kiteloop pairing code."
            return
        }
        scanProblem = nil
        switch link.credential {
        case .token(let token): finish(link, token: token)
        case .code(let pairingCode): Task { await claim(link, code: pairingCode) }
        }
    }

    private func claim(_ link: PairingLink, code: String) async {
        claiming = true
        defer { claiming = false }
        do {
            let token = try await ControlClient(baseURL: link.base, token: "")
                .claimPairing(code: code, name: UIDevice.current.name)
            finish(link, token: token)
        } catch {
            scanProblem = "The Mac did not pair — \(NowViewModel.refusalText(error))"
        }
    }

    private func finish(_ link: PairingLink, token: String) {
        connection.pair(baseURL: link.base, token: token, name: link.name)
        onPaired?()
    }
}

/// What a pairing QR says, `kiteloop://connect?base=…&code=…[&name=…]`: where
/// the Mac is, what it is called, and the one-time code to trade for a token —
/// or `token=…`, the token itself, from a Mac that keeps no paired phones.
/// Anything else is not a pairing code.
struct PairingLink: Equatable {
    enum Credential: Equatable {
        case code(String)
        case token(String)
    }

    let base: String
    let name: String?
    let credential: Credential

    init?(_ text: String) {
        guard let components = URLComponents(string: text),
              components.scheme == "kiteloop", components.host == "connect" else { return nil }
        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let base = value("base") else { return nil }
        if let code = value("code") {
            credential = .code(code)
        } else if let token = value("token") {
            credential = .token(token)
        } else {
            return nil
        }
        self.base = base
        name = value("name")
    }
}
