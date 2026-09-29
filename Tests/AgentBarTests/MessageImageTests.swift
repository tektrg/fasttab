import AppKit
import Foundation
import Testing
@testable import AgentBar

/// Image attachments on the message card: sizing, the card's rules, upload-then-send, and the wire.
/// Nothing here reaches a real dashboard (fake source / scripted transport).
@MainActor
struct MessageImageTests {
    typealias F = AgentListFixtures

    /// Clean pane, scripted uploads, every send recorded (never pending).
    private final class ImageFakeSource: AgentStatusSource, @unchecked Sendable {
        struct Sent: Equatable { let text: String; let attachments: [String] }
        let updates = AsyncStream<StatusSnapshot> { _ in }
        var uploads: [MessageImage] = []
        var sent: [Sent] = []
        var uploadReply: (Int) -> Result<String, ImageUploadFailure> = { .success("id\($0)") }

        func focus(paneId: String) async -> FocusResult { .success }
        func paneScreen(paneId: String) async -> PaneScreenResult {
            .screen(lines: ["⏺ Done.", "", "❯ "], readAt: Date(timeIntervalSince1970: 0))
        }
        func answer(paneId: String, choice: AnswerChoice, question: QuestionIdentity) async -> AnswerResult { .failed("unused") }
        func perform(_ kind: SessionActionKind, rowId: String, confirmed: Bool) async -> SessionActionOutcome { .failed("unused") }
        func uploadImage(_ image: MessageImage) async -> Result<String, ImageUploadFailure> {
            uploads.append(image)
            return uploadReply(uploads.count)
        }
        func sendMessage(rowId: String, text: String, confirmed: Bool, attachments: [String]) async -> MessageSendOutcome {
            sent.append(Sent(text: text, attachments: attachments))
            return .sent(queued: false)
        }
    }

    private static func image(width: Int, height: Int, noise: Bool = false) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        if noise, let pixels = rep.bitmapData {
            var seed: UInt32 = 12345
            for i in 0..<(rep.bytesPerRow * height) {
                seed = seed &* 1_103_515_245 &+ 12345
                pixels[i] = UInt8(truncatingIfNeeded: seed >> 16)
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    private func sample() -> MessageImage { MessageImage.prepare(Self.image(width: 40, height: 20))! }

    private func openCard(_ source: ImageFakeSource) -> MessageCardModel {
        let model = MessageCardModel(loadSessionContext: { _ in .empty })
        model.statusSource = source
        #expect(model.open(F.agent("a", label: "agent a", project: "p", section: .working)))
        return model
    }

    // MARK: - Sizing

    @Test func aLargeImageIsDownscaledTo2048OnItsLongEdge() throws {
        let prepared = try #require(MessageImage.prepare(Self.image(width: 4000, height: 1000)))
        let rep = try #require(NSBitmapImageRep(data: prepared.data))
        #expect(rep.pixelsWide == 2048)
        #expect(rep.pixelsHigh == 512)
        #expect(prepared.contentType == "image/png")
        #expect(prepared.data.count <= MessageImage.maxBytes)
        #expect(!prepared.thumbnail.isEmpty)
    }

    @Test func anImageThatStaysOver5MBAsPngFallsBackToJpeg() throws {
        let prepared = try #require(MessageImage.prepare(Self.image(width: 2048, height: 2048, noise: true)))
        #expect(prepared.contentType == "image/jpeg")
        #expect(prepared.data.count <= MessageImage.maxBytes)
    }

    // MARK: - Card rules

    @Test func imagesAloneMakeTheCardSendableAndAtMostFourAreKept() {
        let model = openCard(ImageFakeSource())
        #expect(model.card?.canSend == false)
        model.addImages([Self.image(width: 10, height: 10)])
        #expect(model.card?.canSend == true)
        #expect(model.card?.sendableText == "")
        model.addImages((0..<4).map { _ in Self.image(width: 10, height: 10) })
        #expect(model.card?.images.count == 4)
        #expect(model.card?.draftHint == MessageCard.tooManyImagesHint)
        model.setDraft("hi")
        #expect(model.card?.draftHint == nil)
        let first = model.card!.images[0].id
        model.removeImage(first)
        #expect(model.card?.images.count == 3)
        #expect(model.card?.images.contains { $0.id == first } == false)
    }

    @Test func aSlashCommandIsStillRefusedWithImages() {
        let model = openCard(ImageFakeSource())
        model.addImages([Self.image(width: 10, height: 10)])
        model.setDraft("/model opus")
        #expect(model.card?.canSend == false)
    }

    // MARK: - Upload, then send

    @Test func imagesAreUploadedThenTheirIdsGoWithTheText() async {
        let source = ImageFakeSource()
        let model = openCard(source)
        model.setDraft("look at this")
        model.addImages([Self.image(width: 10, height: 10), Self.image(width: 12, height: 12)])
        model.pressSend()
        await waitUntil { !source.sent.isEmpty }
        #expect(source.uploads.count == 2)
        #expect(source.sent == [.init(text: "look at this", attachments: ["id1", "id2"])])
    }

    @Test func aFailedUploadSendsNothingAndSaysWhy() async {
        let source = ImageFakeSource()
        source.uploadReply = { _ in .failure(ImageUploadFailure(reason: "too big.")) }
        let model = openCard(source)
        model.addImages([Self.image(width: 10, height: 10)])
        model.pressSend()
        await waitUntil { model.card?.phase == .editing }
        #expect(source.sent.isEmpty)
        #expect(model.card?.errorText?.contains("too big.") == true)
        #expect(model.card?.images.count == 1)   // kept for a retry
    }

    // MARK: - Wire

    @Test func theUploadIsARawPostWithTheImageTypeAndTheMessageCarriesIds() throws {
        let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!)
        let image = sample()
        let upload = endpoint.imageUploadRequest(image)
        #expect(upload.httpMethod == "POST")
        #expect(upload.url?.path == "/api/attachments/image")
        #expect(upload.value(forHTTPHeaderField: "Content-Type") == "image/png")
        #expect(upload.httpBody == image.data)
        let message = endpoint.messageRequest(rowId: "r", text: "t", confirmed: false, attachments: ["abc"])
        let json = try #require(JSONSerialization.jsonObject(with: message.httpBody!) as? [String: Any])
        #expect(json["attachments"] as? [String] == ["abc"])
        let plain = endpoint.messageRequest(rowId: "r", text: "t", confirmed: false)
        let plainJSON = try #require(JSONSerialization.jsonObject(with: plain.httpBody!) as? [String: Any])
        #expect(plainJSON["attachments"] == nil)
    }

    @Test func theUploadReplyDecodesToAnIdOrTheDashboardsReason() async {
        let endpoint = DashboardEndpoint(baseURL: URL(string: "http://127.0.0.1:4799")!)
        let ok = DashboardStatusSource(endpoint: endpoint, transport: ScriptedDashboardTransport { _ in
            .body(Data(#"{"ok": true, "id": "0123"}"#.utf8))
        })
        #expect(await ok.uploadImage(sample()) == .success("0123"))
        let refused = DashboardStatusSource(endpoint: endpoint, transport: ScriptedDashboardTransport { _ in
            .body(Data(#"{"ok": false, "error": "not an image"}"#.utf8), statusCode: 415)
        })
        #expect(await refused.uploadImage(sample()) == .failure(ImageUploadFailure(reason: "not an image")))
        let old = DashboardStatusSource(endpoint: endpoint, transport: ScriptedDashboardTransport { _ in
            .body(Data(#"{"error": "not found"}"#.utf8), statusCode: 404)
        })
        if case .failure(let failure) = await old.uploadImage(sample()) {
            #expect(failure.reason.contains("restart"))
        } else {
            Issue.record("a 404 must fail")
        }
    }
}
