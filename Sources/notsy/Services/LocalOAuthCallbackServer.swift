import Foundation
import Network

struct OAuthCallbackResult {
    let code: String
    let state: String?
}

enum LocalOAuthCallbackError: Error {
    case invalidPort
    case listenerFailed(String)
    case timeout
    case invalidRequest
    case missingCode
    case stateMismatch
}

final class LocalOAuthCallbackServer: @unchecked Sendable {
    static let shared = LocalOAuthCallbackServer()

    private let queue = DispatchQueue(label: "notsy.oauth.callback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<OAuthCallbackResult, Error>?

    private init() {}

    func waitForCode(port: UInt16, expectedPath: String, timeoutSeconds: TimeInterval = 180) async throws -> OAuthCallbackResult {
        stop()

        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw LocalOAuthCallbackError.invalidPort
        }

        let listener = try NWListener(using: .tcp, on: endpointPort)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                if case .failed(let error) = state {
                    self.finish(with: .failure(LocalOAuthCallbackError.listenerFailed(error.localizedDescription)))
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection, expectedPath: expectedPath)
            }

            listener.start(queue: queue)

            queue.asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                guard let self, self.continuation != nil else { return }
                self.finish(with: .failure(LocalOAuthCallbackError.timeout))
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        continuation = nil
    }

    private func handle(connection: NWConnection, expectedPath: String) {
        connection.start(queue: queue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            guard let data,
                  let requestText = String(data: data, encoding: .utf8),
                  let firstLine = requestText.split(separator: "\n").first else {
                self.respond(connection: connection, status: "400 Bad Request", body: "Invalid request")
                self.finish(with: .failure(LocalOAuthCallbackError.invalidRequest))
                return
            }

            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2 else {
                self.respond(connection: connection, status: "400 Bad Request", body: "Invalid request")
                self.finish(with: .failure(LocalOAuthCallbackError.invalidRequest))
                return
            }

            let pathAndQuery = String(parts[1])
            guard let components = URLComponents(string: "http://localhost\(pathAndQuery)") else {
                self.respond(connection: connection, status: "400 Bad Request", body: "Invalid callback")
                self.finish(with: .failure(LocalOAuthCallbackError.invalidRequest))
                return
            }

            guard components.path == expectedPath else {
                self.respond(connection: connection, status: "404 Not Found", body: "Not found")
                return
            }

            let code = components.queryItems?.first(where: { $0.name == "code" })?.value
            let state = components.queryItems?.first(where: { $0.name == "state" })?.value

            guard let code, !code.isEmpty else {
                self.respond(connection: connection, status: "400 Bad Request", body: "Missing code")
                self.finish(with: .failure(LocalOAuthCallbackError.missingCode))
                return
            }

            let html = """
            <html><body style=\"font-family:-apple-system,system-ui;padding:32px\">
            <h2>Notion Connected</h2>
            <p>You can close this tab and return to Notsy.</p>
            </body></html>
            """

            self.respond(connection: connection, status: "200 OK", body: html, contentType: "text/html")
            self.finish(with: .success(OAuthCallbackResult(code: code, state: state)))
        }
    }

    private func respond(connection: NWConnection, status: String, body: String, contentType: String = "text/plain") {
        let bodyData = body.data(using: .utf8) ?? Data()
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType); charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        let headerData = header.data(using: .utf8) ?? Data()

        connection.send(content: headerData + bodyData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(with result: Result<OAuthCallbackResult, Error>) {
        listener?.cancel()
        listener = nil

        guard let continuation else { return }
        self.continuation = nil

        switch result {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }
}
