import Foundation
import DoubleDataProxy

public enum ConsentDecision: Int32, Sendable {
    case dismiss = -1
    case decline = 0
    case accept = 1
}

/// SDK-supplied participation copy. Style these fields without replacing their content.
public struct ConsentNotice: Decodable, Sendable {
    public let version: String
    public let title: String?
    public let controller: String
    public let contact: String
    public let purpose: String
    public let privacyURL: URL
    public let text: String

    public var displayTitle: String {
        guard let title, !title.isEmpty else { return "Share your connection" }
        return title
    }
    private enum CodingKeys: String, CodingKey {
        case version, title, controller, contact, purpose, text
        case privacyURL = "privacy_url"
    }
}

public struct ClientStatus: Decodable, Sendable {
    public let state: String
    public let consentState: String
    public let bytesUsed: UInt64
    public let byteLimit: UInt64
    private enum CodingKeys: String, CodingKey {
        case state
        case consentState = "consent_state"
        case bytesUsed = "bytes_used"
        case byteLimit = "byte_limit"
    }
}

public enum DoubleDataError: Error, LocalizedError, Sendable {
    case native(code: Int32, message: String)
    case closed
    case consentPending
    case cancelled
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case let .native(_, message): return message
        case .closed: return "The sharing session is closed."
        case .consentPending: return "A sharing choice is already pending."
        case .cancelled: return "The sharing choice was cancelled."
        case .invalidResponse: return "The SDK returned an unreadable response."
        }
    }
}

private final class DecisionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var decision: ConsentDecision?
    var isPending: Bool {
        condition.lock(); defer { condition.unlock() }
        return decision == nil
    }
    func choose(_ value: ConsentDecision) {
        condition.lock(); defer { condition.unlock() }
        guard decision == nil else { return }
        decision = value
        condition.broadcast()
    }
    func wait() -> ConsentDecision {
        condition.lock(); defer { condition.unlock() }
        while decision == nil { condition.wait() }
        return decision!
    }
}

/// One presentation. Only an explicit user action may choose .accept.
public final class ConsentPrompt: Identifiable, @unchecked Sendable {
    public let id = UUID()
    public let notice: ConsentNotice
    private let gate: DecisionGate
    fileprivate init(notice: ConsentNotice, gate: DecisionGate) {
        self.notice = notice; self.gate = gate
    }
    /// Duplicate or late choices after cancellation have no effect.
    public func choose(_ decision: ConsentDecision) { gate.choose(decision) }
}

public typealias ConsentPresentation = @MainActor @Sendable (ConsentPrompt) -> Void

private final class ConsentSession: @unchecked Sendable {
    let gate = DecisionGate()
    let present: ConsentPresentation
    init(present: @escaping ConsentPresentation) { self.present = present }
    func cancel() { gate.choose(.dismiss) }
    func run(_ json: UnsafePointer<CChar>) -> Int32 {
        guard gate.isPending else { return ConsentDecision.dismiss.rawValue }
        // Copy borrowed C text before dispatching UI or returning the callback.
        let copied = Data(String(cString: json).utf8)
        guard let notice = try? JSONDecoder().decode(ConsentNotice.self, from: copied),
              notice.privacyURL.scheme == "https", notice.privacyURL.host != nil else {
            gate.choose(.dismiss)
            return ConsentDecision.dismiss.rawValue
        }
        let prompt = ConsentPrompt(notice: notice, gate: gate)
        DispatchQueue.main.async { [self] in
            if gate.isPending { present(prompt) }
        }
        return gate.wait().rawValue
    }
}

private let consentCallback: @convention(c)
    (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Int32 = { json, context in
        guard let json, let context else { return ConsentDecision.dismiss.rawValue }
        return Unmanaged<ConsentSession>.fromOpaque(context).takeUnretainedValue().run(json)
    }

private func checkedNative(_ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) throws {
    var error: UnsafeMutablePointer<CChar>?
    let code = body(&error)
    defer { if let error { DoubleDataFreeString(error) } }
    if code != 0 {
        throw DoubleDataError.native(code: code,
            message: error.map { String(cString: $0) } ?? "The sharing operation failed.")
    }
}

/// Owned and accessed only on its serial worker. A failed Destroy retains the handle.
private final class NativeOwner: @unchecked Sendable {
    private var handle: UInt64
    init(handle: UInt64) { self.handle = handle }
    func requireHandle() throws -> UInt64 {
        guard handle != 0 else { throw DoubleDataError.closed }
        return handle
    }
    func destroy() throws {
        guard handle != 0 else { return }
        try checkedNative { DoubleDataDestroy(handle, $0) }
        handle = 0
    }
    func retire(on worker: DispatchQueue) {
        do { try destroy() }
        catch {
            // Keep ownership after a failed join; never discard a live native handle.
            worker.asyncAfter(deadline: .now() + 1) { [self] in retire(on: worker) }
        }
    }
}

private final class ClientState: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var closing = false
    private var pending: ConsentSession?
    func currentEpoch() throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard !closing else { throw DoubleDataError.closed }
        return epoch
    }
    func begin(_ session: ConsentSession) throws -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        guard !closing else { throw DoubleDataError.closed }
        guard pending == nil else { throw DoubleDataError.consentPending }
        pending = session
        return epoch
    }
    func permits(_ expected: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closing && epoch == expected
    }
    func finish(_ session: ConsentSession) {
        lock.lock(); defer { lock.unlock() }
        if pending === session { pending = nil }
    }
    func cancel(_ session: ConsentSession) -> Bool {
        lock.lock()
        let matched = pending === session
        if matched { epoch &+= 1; pending = nil }
        lock.unlock()
        session.cancel()
        return matched
    }
    @discardableResult func invalidate(closing: Bool = false) -> Bool {
        lock.lock()
        epoch &+= 1; self.closing = self.closing || closing
        let old = pending; pending = nil
        lock.unlock()
        old?.cancel()
        return old != nil
    }
}

/// Native calls and joins run on a serial worker; presentation arrives on the main actor.
public final class DoubleDataClient: @unchecked Sendable {
    private let worker = DispatchQueue(label: "io.doubledata.ios.lifecycle")
    private let state = ClientState()
    private let owner: NativeOwner
    private let nativeHandle: UInt64
    private init(handle: UInt64) { nativeHandle = handle; owner = NativeOwner(handle: handle) }

    private func invalidateNativeConsent() {
        // This C export never joins or performs I/O. A destroyed handle is
        // already revoked, so its invalid-handle result needs no recovery.
        try? checkedNative { DoubleDataInvalidateConsent(nativeHandle, $0) }
    }

    /// Configuration validation creates no traffic. Omit consent_notice to use SDK copy.
    public static func create(configurationJSON: String) async throws -> DoubleDataClient {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var handle: UInt64 = 0
                    try configurationJSON.withCString { config in
                        try checkedNative { DoubleDataCreate(config, &handle, $0) }
                    }
                    continuation.resume(returning: DoubleDataClient(handle: handle))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func execute<Value: Sendable>(
        _ operation: @escaping @Sendable (NativeOwner) throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { [owner] in
                do { continuation.resume(returning: try operation(owner)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func requestConsent(present: @escaping ConsentPresentation) async throws {
        try await requestConsent(startAfterAccept: false, present: present)
    }
    public func requestConsentAndStart(present: @escaping ConsentPresentation) async throws {
        try await requestConsent(startAfterAccept: true, present: present)
    }
    private func requestConsent(startAfterAccept: Bool, present: @escaping ConsentPresentation) async throws {
        let session = ConsentSession(present: present)
        let expected = try state.begin(session)
        try await withTaskCancellationHandler {
            try await execute { [state] owner in
                defer { state.finish(session) }
                guard state.permits(expected) else { throw DoubleDataError.cancelled }
                let handle = try owner.requireHandle()
                let retained = Unmanaged.passRetained(session)
                defer { retained.release() }
                try checkedNative { DoubleDataRequestConsent(handle, consentCallback, retained.toOpaque(), $0) }
                guard state.permits(expected) else { throw DoubleDataError.cancelled }
                if startAfterAccept { try checkedNative { DoubleDataStart(handle, $0) } }
            }
        } onCancel: { [state, nativeHandle] in
            if state.cancel(session) {
                try? checkedNative { DoubleDataInvalidateConsent(nativeHandle, $0) }
            }
        }
    }

    /// Immediately revoke native permission and cancel a pending UI without joins.
    /// Follow with withdrawConsent() or close() to join and report the revocation.
    public func cancelPendingConsent() {
        state.invalidate()
        invalidateNativeConsent()
    }

    public func start() async throws {
        let expected = try state.currentEpoch()
        try await execute { [state] owner in
            guard state.permits(expected) else { throw DoubleDataError.cancelled }
            let handle = try owner.requireHandle()
            try checkedNative { DoubleDataStart(handle, $0) }
        }
    }
    public func stop() async throws {
        if state.invalidate() { invalidateNativeConsent() }
        try await execute { owner in
            let handle = try owner.requireHandle()
            try checkedNative { DoubleDataStop(handle, $0) }
        }
    }
    public func withdrawConsent() async throws {
        cancelPendingConsent()
        try await execute { owner in
            let handle = try owner.requireHandle()
            try checkedNative { DoubleDataWithdrawConsent(handle, $0) }
        }
    }
    public func status() async throws -> ClientStatus {
        try await execute { owner in
            let handle = try owner.requireHandle()
            var json: UnsafeMutablePointer<CChar>?
            defer { if let json { DoubleDataFreeString(json) } }
            try checkedNative { DoubleDataStatus(handle, &json, $0) }
            guard let json else { throw DoubleDataError.invalidResponse }
            return try JSONDecoder().decode(ClientStatus.self, from: Data(String(cString: json).utf8))
        }
    }
    /// Await before replacing the client. Retry this method if native joining fails.
    public func close() async throws {
        state.invalidate(closing: true)
        invalidateNativeConsent()
        try await execute { try $0.destroy() }
    }
    deinit {
        state.invalidate(closing: true)
        invalidateNativeConsent()
        let retainedOwner = owner
        let retainedWorker = worker
        retainedWorker.async { retainedOwner.retire(on: retainedWorker) }
    }
}
