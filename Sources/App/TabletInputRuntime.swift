#if APP
import Foundation
import CoreFoundation

// The unchecked boundary is deliberately confined here: session state is owned by
// one run loop. Commands execute synchronously there; only copied values return.
// No input callback may synchronously dispatch to the main thread.
final class TabletInputRuntime: @unchecked Sendable {
    let dedicated: Bool
    private var session: TabletSession!
    private var loop: CFRunLoop!
    private var thread: Thread?
    private let finished = DispatchSemaphore(value: 0)
    private var closed = false

    init(dedicated: Bool) {
        precondition(Thread.isMainThread)
        self.dedicated = dedicated
        if dedicated {
            let ready = DispatchSemaphore(value: 0)
            let thread = Thread { [self] in
                autoreleasepool {
                    loop = CFRunLoopGetCurrent()
                    session = TabletSession(logging: false)
                    var context = CFRunLoopSourceContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil,
                        equal: nil, hash: nil, schedule: nil, cancel: nil, perform: { _ in })
                    let source = CFRunLoopSourceCreate(nil, 0, &context)!
                    CFRunLoopAddSource(loop, source, .defaultMode)
                    ready.signal()
                    CFRunLoopRun()
                    CFRunLoopRemoveSource(loop, source, .defaultMode)
                    session = nil
                    finished.signal()
                }
            }
            thread.name = "WaccomDrive input"
            thread.qualityOfService = .userInteractive
            self.thread = thread
            thread.start()
            ready.wait()
        } else {
            loop = CFRunLoopGetMain()
            session = TabletSession(logging: false)
        }
    }

    // Body must not return session-owned reference types or perform UI/file I/O.
    func perform<T>(_ body: @Sendable (TabletSession) -> T) -> T {
        precondition(Thread.isMainThread && !closed)
        guard dedicated else { return body(session) }
        return withoutActuallyEscaping(body) { body in
            let command = InputCommand { [self] in body(session) }
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { command.run() }
            CFRunLoopWakeUp(loop)
            return command.wait()
        }
    }
    func close() {
        guard !closed else { return }
        perform { $0.stop() }
        if dedicated {
            let ownerLoop = loop!
            CFRunLoopPerformBlock(ownerLoop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(ownerLoop) }
            CFRunLoopWakeUp(ownerLoop)
            finished.wait()
            thread = nil
        }
        closed = true
    }
}

// Semaphore handoff supplies the happens-before boundary for the result. The
// closure cannot outlive perform(), and the session never leaves its owner loop.
private final class InputCommand<T>: @unchecked Sendable {
    private var body: (() -> T)?
    private var result: T?
    private let done = DispatchSemaphore(value: 0)
    init(_ body: @escaping () -> T) { self.body = body }
    func run() {
        result = body!()
        // Release the borrowed closure before waking the caller's escaping check.
        body = nil
        done.signal()
    }
    func wait() -> T { done.wait(); return result! }
}
#endif
