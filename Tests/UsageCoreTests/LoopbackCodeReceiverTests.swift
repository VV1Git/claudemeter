import Foundation
import Testing

import UsageCore

// These tests open a real listening socket on the loopback interface and connect to it, because
// the failure that mattered here was not in any parsing: `NWListener` refused to bind at all,
// and only an attempt to bind could have shown that. Nothing reaches the network — every
// connection is to 127.0.0.1, on a port the kernel just handed out.

private func get(_ path: String, port: UInt16) async {
    let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
    _ = try? await URLSession.shared.data(from: url)
}

@Test func aReceiverBindsAndReportsItsPort() throws {
    let receiver = try LoopbackCodeReceiver()
    defer { receiver.closeSocket() }
    #expect(receiver.port > 0)
}

@Test func twoReceiversTakeDifferentPorts() throws {
    let first = try LoopbackCodeReceiver()
    defer { first.closeSocket() }
    let second = try LoopbackCodeReceiver()
    defer { second.closeSocket() }
    #expect(first.port != second.port)
}

@Test func theCallbackRequestDeliversItsCode() async throws {
    let receiver = try LoopbackCodeReceiver()
    let port = receiver.port

    async let delivered = receiver.code()
    await get("/callback?code=the%2Bcode&state=the-state", port: port)

    let code = try await delivered
    // Percent-decoded, so a code carrying `+` or `/` survives the round trip intact.
    #expect(code.code == "the+code")
    #expect(code.state == "the-state")
}

@Test func aDriveByRequestDoesNotEndTheWait() async throws {
    // The real sequence a browser produces: it asks for the favicon before, or alongside, the
    // callback. Answering that as though it were the callback would fail the sign-in.
    let receiver = try LoopbackCodeReceiver()
    let port = receiver.port

    async let delivered = receiver.code()
    await get("/favicon.ico", port: port)
    await get("/callback?code=survived&state=s", port: port)

    let code = try await delivered
    #expect(code.code == "survived")
}

@Test func aRefusalInTheCallbackIsReported() async throws {
    let receiver = try LoopbackCodeReceiver()
    let port = receiver.port

    let delivered = Task { try await receiver.code() }
    await get("/callback?error=access_denied", port: port)

    await #expect(throws: OAuthSignInError.denied("access_denied")) { try await delivered.value }
}

@Test func closingTheReceiverEndsTheWait() async throws {
    let receiver = try LoopbackCodeReceiver()

    let delivered = Task { try await receiver.code() }
    // Long enough for the accept loop to be inside its poll, so this exercises the descriptor
    // being closed underneath it rather than the flag being read before the loop starts.
    try await Task.sleep(nanoseconds: 200_000_000)
    receiver.closeSocket()

    await #expect(throws: OAuthSignInError.cancelled) { try await delivered.value }
}

@Test func cancellingTheTaskEndsTheWait() async throws {
    let receiver = try LoopbackCodeReceiver()

    let waiting = Task { try await receiver.code() }
    try await Task.sleep(nanoseconds: 200_000_000)
    waiting.cancel()

    await #expect(throws: OAuthSignInError.cancelled) { try await waiting.value }
}

@Test func aClosedReceiverReleasesItsPort() async throws {
    // The port has to come back, or a user who cancels and retries a few times leaves a trail of
    // held ports behind them.
    let receiver = try LoopbackCodeReceiver()
    let port = receiver.port
    receiver.closeSocket()

    // Nothing is listening any more, so the connection is refused rather than answered.
    let url = URL(string: "http://127.0.0.1:\(port)/callback?code=x")!
    var configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: configuration)
    await #expect(throws: (any Error).self) { try await session.data(from: url) }
}
