import Foundation

enum InstaOnClientError: LocalizedError {
    case invalidSerial
    case badStatus(Int)
    case emptyBody
    case parseFailed(String)
    case deviceOffline(String)

    var errorDescription: String? {
        switch self {
        case .invalidSerial:
            return "Enter a valid InstaOn / device serial."
        case .badStatus(let code):
            return "InstaOn server returned HTTP \(code)."
        case .emptyBody:
            return "Empty response from InstaOn."
        case .parseFailed(let detail):
            return "Could not parse device lookup: \(detail)"
        case .deviceOffline(let detail):
            return "Device not reachable via InstaOn: \(detail)"
        }
    }
}

struct InstaOnClient {
    /// Public InstaOn SOAP endpoint (same service used by gCMOB / NameSolution).
    var endpoint = URL(string: "http://www.instaon.com/webservice/GetDeviceInterface?wsdl")!

    func lookupDevice(serial: String) async throws -> DeviceLookupResult {
        let sn = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sn.isEmpty else { throw InstaOnClientError.invalidSerial }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("text/xml;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("mobile-p2p-query", forHTTPHeaderField: "User-Agent")
        request.setValue("\"\"", forHTTPHeaderField: "SOAPAction")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.httpBody = soapBody(devSequence: sn).data(using: .utf8)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw InstaOnClientError.badStatus(status)
        }
        guard let xml = String(data: data, encoding: .utf8), !xml.isEmpty else {
            throw InstaOnClientError.emptyBody
        }

        return try parseLookupResponse(xml: xml, fallbackSerial: sn)
    }

    private func soapBody(devSequence: String) -> String {
        let escaped = xmlEscape(devSequence)
        return """
        <v:Envelope xmlns:i="http://www.w3.org/2001/XMLSchema-instance" xmlns:d="http://www.w3.org/2001/XMLSchema" xmlns:c="http://schemas.xmlsoap.org/soap/encoding/" xmlns:v="http://schemas.xmlsoap.org/soap/envelope/"><v:Header /><v:Body><n0:getDeviceByDevSequence id="o0" c:root="1" xmlns:n0="http://webservice.ddns.dahua.com/"><devSequence i:type="d:string">\(escaped)</devSequence><userName i:null="true" /></n0:getDeviceByDevSequence></v:Body></v:Envelope>
        """
    }

    private func parseLookupResponse(xml: String, fallbackSerial: String) throws -> DeviceLookupResult {
        guard let returnPayload = firstMatch(pattern: "<return[^>]*>([\\s\\S]*?)</return>", in: xml) else {
            throw InstaOnClientError.parseFailed("missing <return>")
        }

        let unescaped = htmlUnescape(returnPayload).trimmingCharacters(in: .whitespacesAndNewlines)
        if unescaped.isEmpty || unescaped.lowercased() == "null" {
            throw InstaOnClientError.deviceOffline("empty device record")
        }

        guard let jsonData = unescaped.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw InstaOnClientError.parseFailed(unescaped)
        }

        let ip = stringValue(obj["ipAddress"]) ?? ""
        if ip.isEmpty {
            throw InstaOnClientError.deviceOffline(unescaped)
        }

        return DeviceLookupResult(
            serial: stringValue(obj["devSequence"]) ?? fallbackSerial,
            ipAddress: ip,
            p2pPort: intValue(obj["port"]) ?? 25001,
            httpPort: intValue(obj["httpport"]) ?? 80,
            rtspPort: intValue(obj["rtspport"]) ?? 554,
            deviceType: stringValue(obj["devicetype"]) ?? "unknown",
            manufacturer: stringValue(obj["manufacturer"]) ?? "unknown",
            visit: stringValue(obj["visit"]) ?? "unknown",
            p2pType: stringValue(obj["p2ptype"]) ?? "unknown",
            softwareVersion: stringValue(obj["swver"]) ?? "",
            rawJSON: unescaped
        )
    }

    private func firstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[swiftRange])
    }

    private func htmlUnescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String { return Int(s) }
        return nil
    }
}
