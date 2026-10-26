import AppKit
import Testing
import Defaults
@testable import Maccy

extension SharedStateTests {
  @MainActor
  final class ScreenshotWatcherTests {
    let watcher = ScreenshotWatcher.shared
    let folder: URL
    let png: Data

    let savedEnabledTypes = Defaults[.enabledPasteboardTypes]

    init() throws {
      folder = FileManager.default.temporaryDirectory.appending(path: "maccy-screenshots-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

      let image = try #require(NSImage(named: "NSInfo"))
      let tiff = try #require(image.tiffRepresentation)
      let bitmap = try #require(NSBitmapImageRep(data: tiff))
      png = try #require(bitmap.representation(using: .png, properties: [:]))
    }

    deinit {
      Defaults[.enabledPasteboardTypes] = savedEnabledTypes
      try? FileManager.default.removeItem(at: folder)
    }

    @Test("Screenshot is stored as image")
    func screenshotIsStoredAsImage() throws {
      let url = try write(png, to: "Screenshot.png", screenCapture: true)
      let content = try #require(watcher.screenshotContent(at: url))
      #expect(content.type == NSPasteboard.PasteboardType.png.rawValue)
      #expect(content.value == png)
    }

    @Test("Image that is not a screenshot is skipped")
    func imageThatIsNotScreenshotIsSkipped() throws {
      let url = try write(png, to: "Photo.png", screenCapture: false)
      #expect(watcher.screenshotContent(at: url) == nil)
    }

    @Test("Hidden file being written is skipped")
    func hiddenFileIsSkipped() throws {
      let url = try write(png, to: ".Screenshot.png", screenCapture: true)
      #expect(watcher.screenshotContent(at: url) == nil)
    }

    @Test("Screenshot is skipped when images are disabled")
    func screenshotIsSkippedWhenImagesAreDisabled() throws {
      Defaults[.enabledPasteboardTypes] = Set(StorageType.text.types)
      let url = try write(png, to: "Screenshot.png", screenCapture: true)
      #expect(watcher.screenshotContent(at: url) == nil)
    }

    private func write(_ data: Data, to name: String, screenCapture: Bool) throws -> URL {
      let url = folder.appending(path: name)
      try data.write(to: url)
      if screenCapture {
        let value = Data("1".utf8)
        let result = value.withUnsafeBytes { bytes in
          setxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", bytes.baseAddress, value.count, 0, 0)
        }
        #expect(result == 0)
      }
      return url
    }
  }
}
