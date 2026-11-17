import AppKit
import Foundation
import Testing
@testable import TerminalApp

@Suite(.serialized) @MainActor enum DownloadOfferTests {
  private final class Request: PaneDownloadRequest {
    let id = UUID()
    var suggestedFilename = "../../remote.txt"
    var byteCount = 3
    var isAvailable = true
    var data = Data([1, 2, 3])
    var takes = 0
    var dismissals = 0
    var deferred = false
    var completion: (@MainActor (Data?) -> Void)?
    func takeData(_ completion: @escaping @MainActor (Data?) -> Void) {
      takes += 1
      isAvailable = false
      if deferred { self.completion = completion } else { completion(data) }
    }
    func dismiss() { dismissals += 1; isAvailable = false; data = Data() }
  }
  private final class Presenter: DownloadSavePresenting {
    var presentations = 0
    var cancellations = 0
    var suggestedName: String?
    var completion: (@MainActor (URL?) -> Void)?
    func present(in window: NSWindow?, suggestedName: String, completion: @escaping @MainActor (URL?) -> Void) {
      presentations += 1
      self.suggestedName = suggestedName
      self.completion = completion
    }
    func cancel() { cancellations += 1 }
    func reply(_ url: URL?) { let callback = completion; completion = nil; callback?(url) }
  }

  @Test static func offeringNeverOpensAPanelOrFetchesBytes() {
    let panel = Presenter()
    var writes = 0
    let controller = DownloadOfferController(admission: DownloadOfferAdmission(), presenter: panel, writer: { _, _, done in writes += 1; done(nil) })
    let first = Request()
    #expect(controller.offer(first, now: 10))
    #expect(panel.presentations == 0 && first.takes == 0 && writes == 0)
    #expect(controller.presentation == .offered(name: "remote.txt", bytes: 3, saving: false))
    let extra = Request()
    #expect(!controller.offer(extra, now: 12))
    #expect(extra.dismissals == 1 && first.dismissals == 0)
    controller.dismiss()
    #expect(first.dismissals == 1 && controller.presentation == nil)
    #expect(first.data.isEmpty && first.takes == 0)
  }

  @Test static func onlyAnAcceptedUserDestinationFetchesAndWrites() {
    let panel = Presenter()
    let candidate = Request()
    let destination = URL(fileURLWithPath: "/user/chosen/renamed.bin")
    var writes: [(Data, URL)] = []
    let controller = DownloadOfferController(admission: DownloadOfferAdmission(), presenter: panel, writer: { bytes, url, done in
      writes.append((bytes, url)); done(nil)
    })
    #expect(controller.offer(candidate, now: 20))
    controller.save(in: nil)
    #expect(panel.presentations == 1 && panel.suggestedName == "remote.txt")
    #expect(candidate.takes == 0 && writes.isEmpty)
    controller.save(in: nil)
    #expect(panel.presentations == 1, "repeated Save must not create another dialog")
    panel.reply(destination)
    #expect(candidate.takes == 1 && candidate.dismissals == 1)
    #expect(writes.count == 1 && writes[0].0 == Data([1, 2, 3]) && writes[0].1 == destination)
    #expect(controller.presentation == nil)
  }

  @Test static func cancelAndCloseInvalidateLatePanelAndDataCallbacks() {
    let panel = Presenter()
    var writes = 0
    let controller = DownloadOfferController(admission: DownloadOfferAdmission(), presenter: panel, writer: { _, _, done in writes += 1; done(nil) })
    let canceled = Request()
    #expect(controller.offer(canceled, now: 30))
    controller.save(in: nil)
    panel.reply(nil)
    #expect(canceled.dismissals == 1 && canceled.takes == 0 && controller.presentation == nil)

    let closed = Request()
    #expect(controller.offer(closed, now: 31))
    controller.save(in: nil)
    controller.dismiss()
    panel.reply(URL(fileURLWithPath: "/unwanted"))
    #expect(closed.dismissals == 1 && closed.takes == 0 && writes == 0)

    let deferred = Request()
    deferred.deferred = true
    #expect(controller.offer(deferred, now: 32))
    controller.save(in: nil)
    panel.reply(URL(fileURLWithPath: "/user-selected"))
    #expect(deferred.takes == 1)
    controller.dismiss()
    deferred.completion?(Data([1, 2, 3]))
    deferred.completion = nil
    #expect(writes == 0 && deferred.dismissals == 1 && controller.presentation == nil)
  }

  @Test static func admissionLimitsAndPayloadMismatchReleaseRequests() {
    let panel = Presenter()
    var writes = 0
    let controller = DownloadOfferController(admission: DownloadOfferAdmission(), presenter: panel, writer: { _, _, done in writes += 1; done(nil) })
    let first = Request()
    #expect(controller.offer(first, now: 100))
    controller.dismiss()
    let burst = Request()
    #expect(!controller.offer(burst, now: 100.1) && burst.dismissals == 1)
    let tooLarge = Request()
    tooLarge.byteCount = DownloadOfferController.maximumBytes + 1
    #expect(!controller.offer(tooLarge, now: 101) && tooLarge.dismissals == 1 && tooLarge.takes == 0)
    let unavailable = Request()
    unavailable.isAvailable = false
    #expect(!controller.offer(unavailable, now: 101) && unavailable.dismissals == 1)
    let mismatch = Request()
    mismatch.byteCount = 4
    #expect(controller.offer(mismatch, now: 101))
    controller.save(in: nil)
    panel.reply(URL(fileURLWithPath: "/user-selected"))
    #expect(writes == 0 && mismatch.dismissals == 1 && controller.presentation == .failed)
    controller.dismiss()
    #expect(controller.presentation == nil)
  }

  @Test static func suggestedNamesCannotCarryPathsOrTextControls() {
    #expect(DownloadFilename.sanitized("../../.profile") == "profile")
    #expect(DownloadFilename.sanitized("C:\\remote\\report.txt") == "report.txt")
    #expect(DownloadFilename.sanitized("bad\u{0}\n\u{202e}name.txt") == "badname.txt")
    #expect(DownloadFilename.sanitized("...") == "Download")
    #expect(DownloadFilename.sanitized("") == "Download")
    let long = DownloadFilename.sanitized(String(repeating: "猫", count: 1000))
    #expect(!long.isEmpty && long.utf8.count <= 180 && !long.contains("/"))
  }
  @Test static func multiplePanesShareOneAdmissionSlot() {
    let admission = DownloadOfferAdmission()
    let first = DownloadOfferController(admission: admission, presenter: Presenter())
    let second = DownloadOfferController(admission: admission, presenter: Presenter())
    let offered = Request()
    let rejected = Request()
    #expect(first.offer(offered, now: 1))
    #expect(!second.offer(rejected, now: 2) && rejected.dismissals == 1)
    first.dismiss()
    let next = Request()
    #expect(second.offer(next, now: 2))
    second.dismiss()
  }
  @Test static func acceptedSaveWritesOnlyTheChosenFile() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("download-offer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let selected = folder.appendingPathComponent("chosen.bin")
    let panel = Presenter()
    let controller = DownloadOfferController(admission: DownloadOfferAdmission(), presenter: panel)
    let candidate = Request()
    #expect(controller.offer(candidate, now: 1))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    controller.save(in: nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    panel.reply(selected)
    #expect(await TestEnvironment.wait { controller.presentation == nil })
    #expect(try Data(contentsOf: selected) == Data([1, 2, 3]))
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["chosen.bin"])
  }
}
