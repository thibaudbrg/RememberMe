import CryptoKit
import DeviceCheck
import Foundation

/// Apple App Attest client for the route proxy. Proves to the proxy that requests come
/// from a genuine, unmodified build of this app — without sending any identity. The
/// Secure Enclave key is generated once, attested against the proxy's `/v1/attest`
/// endpoint, then every routing request carries an assertion over its body hash.
///
/// The key ID is not a secret (the private key never leaves the Secure Enclave), so it
/// lives in UserDefaults. `invalidate()` clears it; the next request re-attests.
@MainActor
final class AppAttestService {
    private static let keyIDDefaultsKey = "appattest.keyId"
    private static let attestedDefaultsKey = "appattest.attested"

    #if DEBUG
    /// Accepted only by the Worker's dev environment (`DEV_BYPASS=true`); the production
    /// Worker rejects it. Compiled out of Release builds entirely.
    private static let devSecret = "dev-secret-local"
    #endif

    private let workerBase: URL
    private let urlSession: URLSession
    private let service = DCAppAttestService.shared

    init(workerBase: URL, urlSession: URLSession = .shared) {
        self.workerBase = workerBase
        self.urlSession = urlSession
    }

    /// Headers authenticating `body` to the proxy: App Attest assertion headers on a real
    /// device, the dev-bypass header on simulator DEBUG builds.
    func authHeaders(for body: Data) async throws -> [String: String] {
        guard service.isSupported else {
            #if DEBUG
            return ["X-Dev-Secret": Self.devSecret]
            #else
            throw RoutingError.attestationUnavailable
            #endif
        }
        let keyID = try await ensureAttested()
        let bodyHash = Data(SHA256.hash(data: body))
        let assertion: Data
        do {
            assertion = try await service.generateAssertion(keyID, clientDataHash: bodyHash)
        } catch {
            // A rejected/invalidated key throws here; clear it so the next call re-attests.
            invalidate()
            throw RoutingError.attestationUnavailable
        }
        return [
            "X-Attest-Key-Id": keyID,
            "X-Attest-Assertion": assertion.base64EncodedString(),
        ]
    }

    /// Forgets the attested key. The next `authHeaders` call generates and attests a
    /// fresh one — used when the proxy rejects our key (401/403).
    func invalidate() {
        UserDefaults.standard.removeObject(forKey: Self.keyIDDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.attestedDefaultsKey)
    }

    // MARK: - Internals

    /// Returns the attested key ID, running the one-time generate → challenge → attest
    /// flow if needed.
    private func ensureAttested() async throws -> String {
        if let keyID = UserDefaults.standard.string(forKey: Self.keyIDDefaultsKey),
           UserDefaults.standard.bool(forKey: Self.attestedDefaultsKey) {
            return keyID
        }

        let keyID: String
        do {
            keyID = try await service.generateKey()
        } catch {
            throw RoutingError.attestationUnavailable
        }

        let challenge = try await fetchChallenge()
        let challengeHash = Data(SHA256.hash(data: challenge))
        let attestation: Data
        do {
            attestation = try await service.attestKey(keyID, clientDataHash: challengeHash)
        } catch {
            throw RoutingError.attestationUnavailable
        }

        try await submitAttestation(keyID: keyID, attestation: attestation, challenge: challenge)

        UserDefaults.standard.set(keyID, forKey: Self.keyIDDefaultsKey)
        UserDefaults.standard.set(true, forKey: Self.attestedDefaultsKey)
        return keyID
    }

    private func fetchChallenge() async throws -> Data {
        struct ChallengeResponse: Decodable { let challenge: String }
        var request = URLRequest(
            url: workerBase.appending(path: "v1/attest-challenge"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        let (data, response) = try await mapNetworkErrors { [urlSession] in
            try await urlSession.data(for: request)
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(ChallengeResponse.self, from: data),
              let challenge = Data(base64Encoded: decoded.challenge)
        else { throw RoutingError.attestationUnavailable }
        return challenge
    }

    private func submitAttestation(keyID: String, attestation: Data, challenge: Data) async throws {
        let body: [String: String] = [
            "keyId": keyID,
            "attestation": attestation.base64EncodedString(),
            "challenge": challenge.base64EncodedString(),
        ]
        var request = URLRequest(
            url: workerBase.appending(path: "v1/attest"),
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await mapNetworkErrors { [urlSession] in
            try await urlSession.data(for: request)
        }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw RoutingError.attestationUnavailable
        }
    }

    private func mapNetworkErrors(
        _ work: () async throws -> (Data, URLResponse)
    ) async throws -> (Data, URLResponse) {
        do {
            return try await work()
        } catch is CancellationError {
            throw RoutingError.cancelled
        } catch {
            throw RoutingError.network
        }
    }
}
