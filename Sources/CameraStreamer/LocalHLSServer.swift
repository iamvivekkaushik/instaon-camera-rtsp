import Foundation
import Network

/// Serves a directory of HLS files over HTTP on 127.0.0.1.
/// AVPlayer refuses `file://…/index.m3u8` (crossed-out play icon); it needs HTTP(S).
final class LocalHLSServer: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(label: "CameraStreamer.LocalHLSServer")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    var playlistHTTPURL: URL {
        URL(string: "http://127.0.0.1:\(port)/index.m3u8")!
    }

    init(directory: URL) {
        // Resolve /var → /private/var so path-prefix checks work on macOS.
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
    }

    func start() throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(integerLiteral: 0)
        )
        let listener = try NWListener(using: params)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        var startError: Error?

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let p = listener.port?.rawValue {
                    self?.port = p
                }
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            case .cancelled:
                break
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        listener.start(queue: queue)
        let wait = ready.wait(timeout: .now() + 3)
        if wait == .timedOut {
            stop()
            throw NSError(
                domain: "CameraStreamer",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: "Local HLS HTTP server failed to bind"]
            )
        }
        if let startError {
            stop()
            throw startError
        }
        guard port > 0 else {
            stop()
            throw NSError(
                domain: "CameraStreamer",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "Local HLS HTTP server has no port"]
            )
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var buf = buffer
            if let data, !data.isEmpty {
                buf.append(data)
            }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: buf.startIndex..<range.lowerBound)
                let request = String(data: headerData, encoding: .utf8) ?? ""
                self.respond(to: request, on: connection)
            } else if isComplete {
                connection.cancel()
            } else if buf.count > 16 * 1024 {
                connection.cancel()
            } else {
                self.receiveRequest(on: connection, buffer: buf)
            }
        }
    }

    private func respond(to request: String, on connection: NWConnection) {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            send(status: 405, contentType: "text/plain", body: Data("Method Not Allowed".utf8), on: connection, headOnly: false)
            return
        }
        let headOnly = parts[0] == "HEAD"
        var path = String(parts[1])
        if let q = path.firstIndex(of: "?") {
            path = String(path[..<q])
        }
        path = path.removingPercentEncoding ?? path
        if path == "/" {
            path = "/index.m3u8"
        }
        guard path.hasPrefix("/"), !path.contains("..") else {
            send(status: 400, contentType: "text/plain", body: Data("Bad Request".utf8), on: connection, headOnly: false)
            return
        }

        let relative = String(path.dropFirst())
        let fileURL = directory.appendingPathComponent(relative)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard fileURL.path.hasPrefix(directory.path + "/") || fileURL.path == directory.path else {
            send(status: 403, contentType: "text/plain", body: Data("Forbidden".utf8), on: connection, headOnly: false)
            return
        }

        guard let body = try? Data(contentsOf: fileURL) else {
            // Live HLS: playlist/segments may be mid-rotation; ask client to retry.
            send(
                status: 404,
                contentType: "text/plain",
                body: Data("Not Found".utf8),
                on: connection,
                headOnly: false,
                extraHeaders: ["Cache-Control: no-cache"]
            )
            return
        }

        let contentType: String
        switch fileURL.pathExtension.lowercased() {
        case "m3u8":
            contentType = "application/vnd.apple.mpegurl"
        case "ts", "m2ts":
            contentType = "video/mp2t"
        case "m4s", "mp4":
            contentType = "video/mp4"
        default:
            contentType = "application/octet-stream"
        }

        send(
            status: 200,
            contentType: contentType,
            body: body,
            on: connection,
            headOnly: headOnly,
            extraHeaders: [
                "Cache-Control: no-cache, no-store, must-revalidate",
                "Access-Control-Allow-Origin: *",
            ]
        )
    }

    private func send(
        status: Int,
        contentType: String,
        body: Data,
        on connection: NWConnection,
        headOnly: Bool,
        extraHeaders: [String] = []
    ) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        default: reason = "Error"
        }
        var header =
            "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n"
        for h in extraHeaders {
            header += h + "\r\n"
        }
        header += "\r\n"
        var payload = Data(header.utf8)
        if !headOnly {
            payload.append(body)
        }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
