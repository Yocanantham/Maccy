import AppKit
import Defaults
import UniformTypeIdentifiers

// Adds screenshots saved to the chosen folder to history
// without having to copy them.
// Maccy is sandboxed, so the folder has to be chosen by user once
// and the access is kept in a security-scoped bookmark.
class ScreenshotWatcher {
  static let shared = ScreenshotWatcher()

  private static let screenCaptureAttribute = "com.apple.metadata:kMDItemIsScreenCapture"
  private static let screenshotApplication = "com.apple.screenshot.launcher"
  private static let maxImageSize = 50_000_000

  private var folder: URL?
  private var eventSource: (any DispatchSourceFileSystemObject)?
  private var knownFiles: Set<String> = []

  var folderName: String? { resolveFolder()?.url.lastPathComponent }

  func restart() {
    stop()

    guard Defaults[.addScreenshots], let folder = resolveFolder() else {
      return
    }

    start(folder.url, isStale: folder.isStale)
  }

  func chooseFolder() -> Bool {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.directoryURL = resolveFolder()?.url ?? Self.desktop
    panel.message = NSLocalizedString("ChooseFolderMessage", tableName: "StorageSettings", comment: "")

    NSApp.activate(ignoringOtherApps: true)
    guard panel.runModal() == .OK,
          let url = panel.url,
          let bookmark = try? url.bookmarkData(options: .withSecurityScope) else {
      return false
    }

    Defaults[.screenshotsFolder] = bookmark
    return true
  }

  func screenshotContent(at url: URL) -> HistoryItemContent? {
    let imageTypes = StorageType.images.types
    guard !Defaults[.enabledPasteboardTypes].isDisjoint(with: imageTypes),
          !url.lastPathComponent.hasPrefix("."),
          getxattr(url.path, Self.screenCaptureAttribute, nil, 0, 0, 0) >= 0,
          let type = UTType(filenameExtension: url.pathExtension),
          type.conforms(to: .image),
          let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size <= Self.maxImageSize,
          let data = try? Data(contentsOf: url),
          let image = NSImage(data: data) else {
      return nil
    }

    let pasteboardType = NSPasteboard.PasteboardType(type.identifier)
    if imageTypes.contains(pasteboardType) {
      return HistoryItemContent(type: pasteboardType.rawValue, value: data)
    }

    guard let tiff = image.tiffRepresentation else {
      return nil
    }

    return HistoryItemContent(type: NSPasteboard.PasteboardType.tiff.rawValue, value: tiff)
  }

  // FileManager points to the app container in sandbox.
  private static var desktop: URL {
    let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
    return URL(fileURLWithPath: home).appending(path: "Desktop")
  }

  private func resolveFolder() -> (url: URL, isStale: Bool)? {
    guard let bookmark = Defaults[.screenshotsFolder] else {
      return nil
    }

    var isStale = false
    guard let url = try? URL(
      resolvingBookmarkData: bookmark,
      options: .withSecurityScope,
      bookmarkDataIsStale: &isStale
    ) else {
      return nil
    }

    return (url, isStale)
  }

  private func start(_ url: URL, isStale: Bool) {
    guard url.startAccessingSecurityScopedResource() else {
      return
    }
    self.folder = url

    if isStale, let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
      Defaults[.screenshotsFolder] = bookmark
    }

    let descriptor = open(url.path, O_EVTONLY)
    guard descriptor >= 0 else {
      stop()
      return
    }

    knownFiles = files(in: url)

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: .write,
      queue: .main
    )
    eventSource = source
    source.setEventHandler {
      Task {
        // Screenshots are moved into the folder once written,
        // give the system a moment to finish.
        try? await Task.sleep(for: .milliseconds(500))
        self.checkForNewScreenshots()
      }
    }
    source.setCancelHandler {
      close(descriptor)
    }
    source.resume()
  }

  private func stop() {
    eventSource?.cancel()
    eventSource = nil
    folder?.stopAccessingSecurityScopedResource()
    folder = nil
    knownFiles = []
  }

  private func checkForNewScreenshots() {
    guard let folder else {
      return
    }

    let currentFiles = files(in: folder)
    let newFiles = currentFiles.subtracting(knownFiles)
    knownFiles = currentFiles

    guard !Defaults[.ignoreEvents] else {
      return
    }

    for name in newFiles.sorted() {
      guard let content = screenshotContent(at: folder.appending(path: name)) else {
        continue
      }

      let historyItem = HistoryItem(contents: [content])

      if #unavailable(macOS 15.0) {
        // On macOS 14 the history item needs to be inserted into storage directly after creating it.
        try? History.shared.insertIntoStorage(historyItem)
      }

      historyItem.application = Self.screenshotApplication
      historyItem.title = historyItem.generateTitle()

      History.shared.add(historyItem)
    }
  }

  private func files(in folder: URL) -> Set<String> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return Set(names)
  }
}
