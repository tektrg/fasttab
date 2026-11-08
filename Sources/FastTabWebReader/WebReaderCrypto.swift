import CryptoKit
import Foundation
import IndieSharing

/// One device's copy of a blob's content key (contract: `wraps:[{deviceId, enc, wrappedKey}]`,
/// base64url without padding).
public struct WebKeyWrap: Codable, Equatable, Sendable {
    public var deviceId: String
    public var enc: String
    public var wrappedKey: String
}

/// A sealed blob: the content key wrapped for each recipient device + the ciphertext.
public struct WebSealedBlob: Equatable, Sendable {
    public var suite: String
    public var wraps: [WebKeyWrap]
    /// ChaCha20-Poly1305 combined: 12-byte nonce ‖ ciphertext ‖ 16-byte tag.
    public var ciphertext: Data
}

/// What a blob is, bound into both the key wrap and the ciphertext so a blob never opens as
/// another (a snapshot replayed as an article, one article swapped for another).
public enum WebBlobKind: Equatable, Sendable {
    case snapshot
    case article(id: String)
    case highlight(id: String)

    var label: String {
        switch self {
        case .snapshot: return "snapshot"
        case .article(let id): return "article:" + id
        case .highlight(let id): return "highlight:" + id
        }
    }
}

/// The web reader's encryption: the existing IndieSharing suite (`hpke-x25519-sha256-chachapoly`).
///
/// Binding (contract v1.1; reference theindieapp_website `src/fasttab-web/crypto.ts`):
/// - fresh random 32-byte content key per blob, label `theindie.fasttab.web.v1`;
/// - content: ChaCha20-Poly1305 combined, AAD = `label|content|<objectId>`;
/// - key wrap: HPKE base mode X25519/HKDF-SHA256/ChaChaPoly, info = label,
///   AAD = `label|key|<objectId>|<deviceId lowercase>`;
/// - objectId = `snapshot` | `article:<articleId>` | `highlight:<uuid>`.
public enum WebReaderCrypto {
    public static let suite = ShareWireFormat.suite
    static let ciphersuite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let label = "theindie.fasttab.web.v1"
    static let info = Data(label.utf8)

    public enum Failure: Error, Equatable {
        case noRecipients
        case unsupportedSuite(String)
        case notForThisDevice
        case badKey
        case tampered
    }

    public struct Recipient: Sendable, Equatable {
        public var deviceID: String
        public var publicKey: DevicePublicKey
        public init(deviceID: String, publicKey: DevicePublicKey) {
            self.deviceID = deviceID.lowercased()
            self.publicKey = publicKey
        }
    }

    static func contentAAD(_ kind: WebBlobKind) -> Data { Data([label, "content", kind.label].joined(separator: "|").utf8) }
    static func wrapAAD(_ kind: WebBlobKind, deviceID: String) -> Data {
        Data([label, "key", kind.label, deviceID.lowercased()].joined(separator: "|").utf8)
    }

    public static func seal(_ plaintext: Data, kind: WebBlobKind, for recipients: [Recipient]) throws -> WebSealedBlob {
        guard !recipients.isEmpty else { throw Failure.noRecipients }
        let key = SymmetricKey(size: .bits256)
        let box = try ChaChaPoly.seal(plaintext, using: key, authenticating: contentAAD(kind))
        let keyBytes = key.withUnsafeBytes { Data($0) }
        var wraps: [WebKeyWrap] = []
        for recipient in recipients {
            var sender = try HPKE.Sender(
                recipientKey: try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipient.publicKey.rawRepresentation), ciphersuite: ciphersuite, info: info)
            let wrapped = try sender.seal(keyBytes, authenticating: wrapAAD(kind, deviceID: recipient.deviceID))
            wraps.append(WebKeyWrap(
                deviceId: recipient.deviceID,
                enc: Base64URL.encode(sender.encapsulatedKey),
                wrappedKey: Base64URL.encode(wrapped)))
        }
        return WebSealedBlob(suite: suite, wraps: wraps, ciphertext: box.combined)
    }

    /// Opens a blob addressed to `deviceID` with this device's key pair.
    public static func open(_ blob: WebSealedBlob, kind: WebBlobKind, deviceID: String, keyPair: DeviceKeyPair) throws -> Data {
        guard blob.suite == suite else { throw Failure.unsupportedSuite(blob.suite) }
        let deviceID = deviceID.lowercased()
        guard let wrap = blob.wraps.first(where: { $0.deviceId.lowercased() == deviceID }) else {
            throw Failure.notForThisDevice
        }
        let keyBytes: Data
        do {
            let enc = try Base64URL.decode(wrap.enc)
            let wrapped = try Base64URL.decode(wrap.wrappedKey)
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: keyPair.privateKeyRawRepresentation)
            var receiver = try HPKE.Recipient(
                privateKey: privateKey, ciphersuite: ciphersuite, info: info, encapsulatedKey: enc)
            keyBytes = try receiver.open(wrapped, authenticating: wrapAAD(kind, deviceID: deviceID))
        } catch {
            throw Failure.badKey
        }
        guard keyBytes.count == 32 else { throw Failure.badKey }
        do {
            let box = try ChaChaPoly.SealedBox(combined: blob.ciphertext)
            return try ChaChaPoly.open(box, using: SymmetricKey(data: keyBytes), authenticating: contentAAD(kind))
        } catch {
            throw Failure.tampered
        }
    }
}
