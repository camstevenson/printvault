import Foundation
import AppKit
import Darwin

/// Enforces that only a single instance of PrintVault runs at any time (across `.app`, Xcode, and `swift run` launches).
/// Uses a kernel-managed POSIX advisory file lock (`flock`) so crashes never leave stale locks behind.
@MainActor
public final class SingleInstanceGuard {
    public static let shared = SingleInstanceGuard()

    private static let activateNotificationName = Notification.Name("com.printvault.activateExistingInstance")
    private var lockFileDescriptor: Int32 = -1
    private var activationObserver: NSObjectProtocol?

    public init() {}

    deinit {
        if lockFileDescriptor >= 0 {
            flock(lockFileDescriptor, LOCK_UN)
            close(lockFileDescriptor)
        }
    }

    public static var defaultLockFileURL: URL {
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = appSupport.appendingPathComponent("PrintVault", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("instance.lock")
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("printvault-\(getuid()).lock")
    }

    /// Attempts to acquire the exclusive single-instance lock.
    /// Returns `true` if this process is the primary instance, or `false` if another instance already holds the lock.
    @discardableResult
    public func tryAcquireLock(at lockURL: URL = defaultLockFileURL) -> Bool {
        if lockFileDescriptor >= 0 {
            return true
        }

        let dir = lockURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            // If we cannot open the lock path at all, don't block the user from launching
            return true
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }

        // Write our PID into the lock file so a second launch can activate us directly
        let pidString = "\(ProcessInfo.processInfo.processIdentifier)\n"
        ftruncate(fd, 0)
        lseek(fd, 0, SEEK_SET)
        _ = pidString.withCString { ptr in
            write(fd, ptr, strlen(ptr))
        }

        self.lockFileDescriptor = fd
        return true
    }

    /// Releases the held lock (used primarily in unit tests; on normal exit/crash the kernel releases `flock` automatically).
    public func releaseLock() {
        if lockFileDescriptor >= 0 {
            flock(lockFileDescriptor, LOCK_UN)
            close(lockFileDescriptor)
            lockFileDescriptor = -1
        }
    }

    /// Ensures only one PrintVault instance runs. If another instance is already active, focuses it and terminates this process immediately.
    public func enforceSingleInstanceOrTerminate(lockURL: URL = defaultLockFileURL) {
        if tryAcquireLock(at: lockURL) {
            observeActivationRequests()
            return
        }

        activateExistingInstance(lockURL: lockURL)
        // Give the distributed notification a brief moment to flush before exiting
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        Darwin.exit(0)
    }

    /// Reads the PID from the lock file and brings the existing PrintVault instance to the foreground.
    public func activateExistingInstance(lockURL: URL = defaultLockFileURL) {
        let currentPID = ProcessInfo.processInfo.processIdentifier

        // 1. Try activating by PID stored in the lock file (works for both .app and CLI `swift run` launches)
        if let contents = try? String(contentsOf: lockURL, encoding: .utf8),
           let existingPID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)),
           existingPID != currentPID,
           let running = NSRunningApplication(processIdentifier: existingPID) {
            running.unhide()
            running.activate(options: [.activateAllWindows])
        } else {
            // 2. Fallback: look up by bundle identifier
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.printvault.PrintVault")
                .filter { $0.processIdentifier != currentPID }
            if let existing = others.first {
                existing.unhide()
                existing.activate(options: [.activateAllWindows])
            }
        }

        // 3. Notify the running instance to deminiaturize and order its window front
        DistributedNotificationCenter.default().postNotificationName(
            Self.activateNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func observeActivationRequests() {
        guard activationObserver == nil else { return }
        activationObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.activateNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApplication.shared.unhide(nil)
                NSApplication.shared.activate(ignoringOtherApps: true)
                for window in NSApplication.shared.windows where window.canBecomeMain {
                    if window.isMiniaturized {
                        window.deminiaturize(nil)
                    }
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}
