import Foundation

struct DeviceLookupResult: Equatable {
    let serial: String
    let ipAddress: String
    let p2pPort: Int
    let httpPort: Int
    let rtspPort: Int
    let deviceType: String
    let manufacturer: String
    let visit: String
    let p2pType: String
    let softwareVersion: String
    let rawJSON: String

    var summary: String {
        """
        SN: \(serial)
        IP: \(ipAddress)
        RTSP: \(rtspPort)  |  P2P: \(p2pPort)  |  HTTP: \(httpPort)
        Type: \(deviceType) (\(manufacturer))
        Mode: \(visit) / \(p2pType)
        Firmware: \(softwareVersion)
        """
    }
}

enum StreamURLBuilder {
    /// Single well-known path for the local dh-p2p tunnel (one PTCP realm).
    static func localTunnelURL(
        port: Int,
        username: String,
        password: String,
        channel: Int,
        subtype: Int
    ) -> URL? {
        candidates(
            ip: "127.0.0.1",
            rtspPort: port,
            username: username,
            password: password,
            channel: channel,
            subtype: subtype
        ).first
    }

    /// Common Dahua / CP Plus live RTSP paths.
    static func candidates(
        ip: String,
        rtspPort: Int,
        username: String,
        password: String,
        channel: Int,
        subtype: Int
    ) -> [URL] {
        let user = percentEncode(username)
        let pass = percentEncode(password)
        let auth = "\(user):\(pass)"
        let host = "\(ip):\(rtspPort)"
        // Primary path first — used exclusively for P2P tunnel (single Bind).
        let paths = [
            "/cam/realmonitor?channel=\(channel)&subtype=\(subtype)",
            "/cam/realmonitor?channel=\(channel)&subtype=\(subtype)&unicast=true&proto=Onvif",
            "/live/ch\(channel)",
            "/live",
            "/Streaming/Channels/\(channel)0\(subtype)",
            "/h264/ch\(channel)/main/av_stream",
            "/h264/ch\(channel)/sub/av_stream"
        ]
        return paths.compactMap { URL(string: "rtsp://\(auth)@\(host)\($0)") }
    }

    private static func percentEncode(_ value: String) -> String {
        // Must encode @ in password (e.g. pass@word → pass%40word) so it
        // is not parsed as userinfo/host separators.
        var allowed = CharacterSet.urlUserAllowed
        allowed.remove(charactersIn: ":@/?#[]")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
