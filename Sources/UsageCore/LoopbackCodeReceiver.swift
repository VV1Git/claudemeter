import Foundation

/// A one-shot HTTP listener on the loopback interface, so the browser can hand the
/// authorization code straight back to this process.
///
/// This is what makes signing in a single click. Without it the flow falls back to the manual
/// page, which shows the user a `code#state` string to copy into a field — workable, and what
/// `claude setup-token` does, but it is one more thing for the user to do.
///
/// Built on BSD sockets rather than `NWListener`, which was tried first and failed to bind at
/// all on this machine — `EINVAL` from every parameter combination, signed or not, sandboxed or
/// not. Sockets also keep this in `UsageCore` with nothing but Foundation behind it, which is
/// what lets the accept loop be tested against a real connection instead of only its parser.
///
/// Bound to `127.0.0.1` explicitly, never to `INADDR_ANY`: a port that accepts an authorization
/// code should not be reachable from whatever network the machine is on.
///
/// `@unchecked Sendable` because the mutable state is one flag and one descriptor, both only
/// ever touched under `lock`.
public final class LoopbackCodeReceiver: @unchecked Sendable {
    /// Long enough to sign in unhurriedly, including a password and a second factor; short
    /// enough that a sign-in the user abandoned does not hold a port open all day.
    public static let timeout: TimeInterval = 5 * 60

    /// How long a connection that has said nothing is given before it is dropped. A browser
    /// sends its request line immediately; anything that does not is not the browser, and must
    /// not be allowed to hold up the one connection that matters.
    private static let readTimeout: TimeInterval = 5

    private let queue = DispatchQueue(label: "com.claudemeter.oauth-loopback")
    private let lock = NSLock()
    private var descriptor: Int32
    private var isClosed = false

    /// The port the browser should be told to come back to.
    public let port: UInt16

    /// Opens the port. Throws when one cannot be had, which is the caller's cue to fall back to
    /// the manual page rather than to fail the sign-in outright.
    public init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OAuthSignInError.noLoopbackPort }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        // Port 0 asks the kernel for a free one, which is then read back with `getsockname`.
        // Naming a fixed port would collide with whatever else on the machine had claimed it.
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            Darwin.close(fd)
            throw OAuthSignInError.noLoopbackPort
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0, assigned.sin_port != 0 else {
            Darwin.close(fd)
            throw OAuthSignInError.noLoopbackPort
        }

        descriptor = fd
        port = UInt16(bigEndian: assigned.sin_port)
    }

    deinit { closeSocket() }

    /// The code the browser brings back.
    ///
    /// Returns once — the socket is closed whatever the outcome, so this is not restartable and
    /// does not need to be: a failed sign-in starts a fresh one, with a fresh PKCE pair.
    public func code() async throws -> AuthorizationCode {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let result = accepting()
                    closeSocket()
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            // Closing the descriptor is what breaks the poll, so a cancelled sign-in returns
            // now rather than when the five-minute deadline comes round.
            closeSocket()
        }
    }

    /// Stops the listener. Idempotent, because a code and a cancel can arrive together.
    public func closeSocket() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(descriptor)
        descriptor = -1
    }

    private var wasClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    // MARK: - The accept loop

    /// Serves connections until one of them is the callback, or until the deadline.
    ///
    /// A loop rather than a single accept because the browser does not only ask for the
    /// callback: it asks for `/favicon.ico` on the way past, and answering that as though it
    /// were the callback would abandon a sign-in still in progress.
    private func accepting() -> Result<AuthorizationCode, Error> {
        let deadline = Date().addingTimeInterval(Self.timeout)

        while true {
            if wasClosed { return .failure(OAuthSignInError.cancelled) }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return .failure(OAuthSignInError.timedOut) }

            lock.lock()
            let listening = descriptor
            lock.unlock()
            if listening < 0 { return .failure(OAuthSignInError.cancelled) }

            // Capped at a second so a cancel is noticed promptly, rather than only when
            // something happens to connect.
            var descriptors = pollfd(fd: listening, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptors, 1, Int32(min(remaining, 1) * 1000))
            if wasClosed { return .failure(OAuthSignInError.cancelled) }
            if ready < 0 {
                if errno == EINTR { continue }
                return .failure(OAuthSignInError.noLoopbackPort)
            }
            if ready == 0 { continue }

            let connection = accept(listening, nil, nil)
            if connection < 0 {
                if wasClosed { return .failure(OAuthSignInError.cancelled) }
                if errno == EINTR || errno == ECONNABORTED { continue }
                return .failure(OAuthSignInError.noLoopbackPort)
            }
            defer { Darwin.close(connection) }

            guard let request = Self.read(from: connection),
                let target = OAuthSignIn.requestTarget(inRequest: request)
            else {
                Self.respond(on: connection, status: "400 Bad Request", body: Self.failurePage)
                continue
            }

            do {
                let code = try OAuthSignIn.parseCallback(requestTarget: target)
                Self.respond(on: connection, status: "200 OK", body: Self.successPage)
                return .success(code)
            } catch OAuthSignInError.notTheCallback {
                Self.respond(on: connection, status: "404 Not Found", body: "")
            } catch {
                Self.respond(on: connection, status: "200 OK", body: Self.failurePage)
                return .failure(error)
            }
        }
    }

    /// One read. The request line is the first thing on the wire and everything this needs is in
    /// it, so there is no reason to drain the rest of the request.
    private static func read(from connection: Int32) -> Data? {
        var timeout = timeval(
            tv_sec: Int(readTimeout), tv_usec: 0)
        setsockopt(
            connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = recv(connection, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        return Data(buffer.prefix(count))
    }

    private static func respond(on connection: Int32, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
            + body
        let bytes = Array(response.utf8)
        var sent = 0
        while sent < bytes.count {
            // `MSG_NOSIGNAL` has no macOS equivalent here; a browser that closed early would
            // otherwise raise SIGPIPE and take the app down with it. The socket option set on
            // the descriptor is what prevents that.
            var on: Int32 = 1
            setsockopt(
                connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let written = bytes[sent...].withUnsafeBufferPointer {
                send(connection, $0.baseAddress, $0.count, 0)
            }
            guard written > 0 else { return }
            sent += written
        }
    }

    // MARK: - What the browser is left looking at

    private static let successPage = page(
        title: "Signed in",
        message: "ClaudeMeter is signed in. You can close this tab and go back to the menu bar.")

    private static let failurePage = page(
        title: "Sign-in failed",
        message: "ClaudeMeter could not read the authorization code. Go back to the menu bar and "
            + "try again.")

    /// Self-contained on purpose: this is served from a socket that closes a moment later, so
    /// anything it referenced would fail to load.
    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title></head>
        <body style="font: 16px -apple-system, system-ui, sans-serif; margin: 4rem auto; \
        max-width: 28rem; color: #222; background: #fff;">
        <h1 style="font-size: 1.25rem;">\(title)</h1><p>\(message)</p></body></html>
        """
    }
}
