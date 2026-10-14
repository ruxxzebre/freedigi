import Foundation

/// Owns the bridge and all its HID/SDL state on a dedicated run loop. Virtual
/// reports are forwarded there immediately; the UI receives at most 60 updates/s.
public final class Vader5BridgeWorker: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let ready = NSCondition()
        var runLoop: CFRunLoop?
        var shutdown = false
        // Accessed only on the worker thread after publication of runLoop.
        let bridge = Vader5Bridge()
        var pendingUIState: Vader5State?
        var uiTimer: CFRunLoopTimer?
    }
    private let state = State()
    private let callbacks = NSLock()
    private var stateCallback: (@Sendable (Vader5State) -> Void)?
    private var statusCallback: (@Sendable (Vader5BridgeStatus) -> Void)?
    private var lightingCallback: (@Sendable (Vader5LightingStatus) -> Void)?
    private var configurationCallback: (@Sendable (Vader5LightingConfiguration) -> Void)?

    public var onState: (@Sendable (Vader5State) -> Void)? {
        get { callbacks.withLock { stateCallback } }
        set { callbacks.withLock { stateCallback = newValue } }
    }
    public var onStatus: (@Sendable (Vader5BridgeStatus) -> Void)? {
        get { callbacks.withLock { statusCallback } }
        set { callbacks.withLock { statusCallback = newValue } }
    }
    public var onLightingStatus: (@Sendable (Vader5LightingStatus) -> Void)? {
        get { callbacks.withLock { lightingCallback } }
        set { callbacks.withLock { lightingCallback = newValue } }
    }
    public var onLightingConfiguration: (@Sendable (Vader5LightingConfiguration) -> Void)? {
        get { callbacks.withLock { configurationCallback } }
        set { callbacks.withLock { configurationCallback = newValue } }
    }

    public init() {
        let state = self.state
        let thread = Thread {
            let runLoop = CFRunLoopGetCurrent()!
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 60, 60, 0, 0) { _ in }
            CFRunLoopAddTimer(runLoop, timer, .defaultMode)
            state.ready.lock()
            state.runLoop = runLoop
            state.ready.broadcast()
            state.ready.unlock()
            while !state.ready.withLock({ state.shutdown }) {
                CFRunLoopRunInMode(.defaultMode, 60, false)
            }
            CFRunLoopTimerInvalidate(timer)
        }
        thread.name = "ControlLab HID input"
        thread.qualityOfService = .userInteractive
        thread.start()
        state.ready.lock()
        while state.runLoop == nil { state.ready.wait() }
        state.ready.unlock()
        // Installed before any device is scheduled. Closures do not retain this owner.
        state.bridge.onState = { [weak state] value in
            guard let state else { return }
            state.pendingUIState = value
        }
        state.bridge.onStatus = { [weak self] in self?.onStatus?($0) }
        state.bridge.onLightingStatus = { [weak self] in self?.onLightingStatus?($0) }
        state.bridge.onLightingConfiguration = { [weak self] in self?.onLightingConfiguration?($0) }
        enqueue { [weak self] in
            state.uiTimer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 1.0 / 60, 0, 0) { [weak self] _ in
                guard let value = state.pendingUIState else { return }
                state.pendingUIState = nil
                self?.onState?(value)
            }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), state.uiTimer, .defaultMode)
        }
    }

    private func enqueue(_ action: @escaping @Sendable () -> Void) {
        let loop = state.ready.withLock { state.runLoop! }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue, action)
        CFRunLoopWakeUp(loop)
    }

    private final class ResultBox: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
    }

    private func synchronous(_ action: @escaping @Sendable () throws -> Void) throws {
        if CFEqual(CFRunLoopGetCurrent(), state.ready.withLock { state.runLoop! }) {
            try action()
            return
        }
        let box = ResultBox()
        enqueue {
            box.result = Result { try action() }
            box.done.signal()
        }
        box.done.wait()
        try box.result!.get()
    }

    public func start(mode: Vader5BridgeMode, transport: Vader5Transport) throws {
        let state = self.state
        try synchronous { try state.bridge.start(mode: mode, transport: transport) }
    }

    public func stop() {
        let state = self.state
        try? synchronous { state.bridge.stop() }
    }

    public func setLightingAsync(_ configuration: Vader5LightingConfiguration) async throws {
        let state = self.state
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue {
                do { try state.bridge.setLighting(configuration); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    deinit {
        stop()
        let state = self.state
        enqueue {
            if let timer = state.uiTimer { CFRunLoopTimerInvalidate(timer) }
            state.uiTimer = nil
            state.ready.withLock { state.shutdown = true }
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}
