import SwiftUI

/// Add this file and DoubleDataClient.swift to an iOS 15+ SwiftUI app target.
@available(iOS 15.0, *)
@MainActor
final class SharingModel: ObservableObject {
    @Published var prompt: ConsentPrompt?
    @Published private(set) var status = "Sharing is off. Review your options to choose whether to participate."
    @Published private(set) var isBusy = false
    private var activePrompt: ConsentPrompt?
    private var client: DoubleDataClient?
    private var retiring: DoubleDataClient?
    private var consentTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var generation = 0
    private var isActive = false

    func setActive(_ active: Bool) {
        isActive = active
        if !active { withdraw() }
    }

    func review() {
        guard isActive, !isBusy, prompt == nil else { return }
        let expected = generation
        isBusy = true
        consentTask = Task { [weak self] in
            guard let self else { return }
            do {
                if let old = retiring {
                    try await old.close()
                    retiring = nil
                }
                guard expected == generation, isActive else { return }
                if client == nil {
                    guard let url = Bundle.main.url(forResource: "application-sdk", withExtension: "json") else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let json = try String(contentsOf: url, encoding: .utf8)
                    let created = try await DoubleDataClient.create(configurationJSON: json)
                    guard expected == generation, isActive else {
                        try await created.close()
                        return
                    }
                    client = created
                }
                guard let current = client else { return }
                try await current.requestConsentAndStart { [weak self] incoming in
                    guard let self, self.isActive, self.generation == expected else {
                        incoming.choose(.dismiss)
                        return
                    }
                    self.activePrompt = incoming
                    self.prompt = incoming
                    self.isBusy = false
                }
                guard expected == generation else { return }
                status = "Sharing is on. Stop or withdraw whenever you choose."
                pollStatus(expected: expected)
            } catch {
                if expected == generation {
                    status = "Sharing is off. You can review your options again when you're ready."
                }
            }
            if expected == generation { isBusy = false; consentTask = nil }
        }
    }

    func choose(_ decision: ConsentDecision) {
        // Clear the active prompt before sheet dismissal so onDismiss cannot
        // turn the person's explicit choice into another pending interaction.
        let current = activePrompt
        activePrompt = nil
        prompt = nil
        current?.choose(decision)
    }

    func dismissedNotice() {
        activePrompt?.choose(.dismiss)
        activePrompt = nil
        prompt = nil
    }

    private func cancelPresentation(revokeConsent: Bool = true) {
        generation += 1
        activePrompt?.choose(.dismiss)
        activePrompt = nil
        prompt = nil
        if revokeConsent { client?.cancelPendingConsent() }
        consentTask?.cancel()
        consentTask = nil
        statusTask?.cancel()
        statusTask = nil
    }

    func stop() {
        cancelPresentation(revokeConsent: false)
        let expected = generation
        let current = client
        isBusy = true
        Task {
            do {
                try await current?.stop()
                if expected == generation { status = "Sharing is paused." }
            } catch {
                if expected == generation { status = "Sharing could not finish stopping. Try again." }
            }
            if expected == generation { isBusy = false }
        }
    }

    /// Backgrounding ends permission, even if an acceptance is still pending.
    func withdraw() {
        cancelPresentation()
        let expected = generation
        let current = client
        isBusy = true
        Task {
            do {
                try await current?.withdrawConsent()
                if expected == generation { status = "Sharing is off. Your permission has been withdrawn." }
            } catch {
                if expected == generation { status = "Sharing is stopping. Try withdrawing again." }
            }
            if expected == generation { isBusy = false }
        }
    }

    /// Keep a failed close available for retry; do not create a replacement early.
    func close() {
        cancelPresentation()
        let expected = generation
        let old = client ?? retiring
        client = nil
        retiring = old
        isBusy = true
        Task {
            do {
                try await old?.close()
                if expected == generation { retiring = nil; status = "Sharing is off." }
            } catch {
                if expected == generation { status = "Sharing is stopping. The session will be closed before you continue." }
            }
            if expected == generation { isBusy = false }
        }
    }

    private func pollStatus(expected: Int) {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == expected, let current = self.client else { return }
                do {
                    let snapshot = try await current.status()
                    guard self.generation == expected else { return }
                    if snapshot.consentState == "expired" {
                        self.status = "Sharing is off. Review your options to participate again."
                    } else if snapshot.consentState == "withdrawn" {
                        self.status = "Sharing is off. Your permission has been withdrawn."
                    } else if snapshot.state == "running" {
                        self.status = "Sharing is on. Stop or withdraw whenever you choose."
                    } else if snapshot.state == "retrying" {
                        self.status = "Connection interrupted. Trying again…"
                    } else if snapshot.state == "stopped" {
                        self.status = "Sharing is paused."
                    } else {
                        self.status = "Connecting to share…"
                    }
                } catch { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

@available(iOS 15.0, *)
@MainActor
struct SharingView: View {
    @ObservedObject var model: SharingModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Connection sharing").font(.largeTitle.bold())
            Text(model.status)
            Button("Review sharing options") { model.review() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.prompt != nil || scenePhase != .active)
            Button("Stop sharing") { model.stop() }.disabled(model.isBusy)
            Button("Withdraw consent") { model.withdraw() }.disabled(model.isBusy)
        }
        .padding(24)
        .sheet(item: $model.prompt, onDismiss: model.dismissedNotice) { prompt in
            ConsentSheet(prompt: prompt, choose: model.choose)
        }
        .onAppear { model.setActive(scenePhase == .active) }
        .onChange(of: scenePhase) { model.setActive($0 == .active) }
        .onDisappear { model.close() }
    }
}

@available(iOS 15.0, *)
@MainActor
private struct ConsentSheet: View {
    let prompt: ConsentPrompt
    let choose: (ConsentDecision) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(verbatim: prompt.notice.displayTitle).font(.title2.bold())
                    Text(verbatim: prompt.notice.purpose).font(.headline)
                    Text(verbatim: prompt.notice.text)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Controller").font(.caption).foregroundColor(.secondary)
                        Text(verbatim: prompt.notice.controller)
                        Text("Contact").font(.caption).foregroundColor(.secondary)
                        Text(verbatim: prompt.notice.contact)
                    }
                    Link("Privacy policy", destination: prompt.notice.privacyURL)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(24)
            }
            Divider()
            HStack {
                Button("Decline") { choose(.decline) }
                Spacer()
                Button("Enable sharing") { choose(.accept) }.buttonStyle(.borderedProminent)
            }
            .padding(24)
        }
    }
}

@available(iOS 15.0, *)
@main
@MainActor
struct SharingDemoApp: App {
    @StateObject private var model = SharingModel()
    var body: some Scene {
        WindowGroup { SharingView(model: model) }
    }
}
