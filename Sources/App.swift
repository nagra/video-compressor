import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
  }

  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  private let compressor = Compressor()
  private let dropZone = DropZone()
  private var recent: [Compressor.Result] = []
  private weak var progressItem: NSMenuItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let button = statusItem.button {
      button.image = NSImage(systemSymbolName: "film", accessibilityDescription: "Video Compressor")
      button.imagePosition = .imageLeading
      button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
      button.toolTip = "Drop videos here to compress them"
      // The status item's window forwards dragging-destination calls to its delegate.
      button.window?.registerForDraggedTypes([.fileURL])
      button.window?.delegate = self
    }
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu

    compressor.onChange = { [weak self] in self?.refresh() }
    compressor.onFinish = { [weak self] in self?.finished($0) }

    dropZone.isEnabled = UserDefaults.standard.object(forKey: "showsDropZone") as? Bool ?? true
    dropZone.onDrop = { [weak self] in self?.compressor.enqueue($0) }
    dropZone.start()

    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  func applicationWillTerminate(_ notification: Notification) {
    compressor.cancelAll()
  }

  /// Files dropped on the app's icon in Finder, or passed with `open -a`.
  func application(_ application: NSApplication, open urls: [URL]) {
    compressor.enqueue(urls.filter(isVideo))
  }

  private func refresh() {
    statusItem.button?.title = compressor.current == nil ? "" : " \(compressor.shortStatus)"
    progressItem?.title = compressor.detailStatus
  }

  private func finished(_ result: Compressor.Result) {
    recent = Array(([result] + recent).prefix(5))

    let name = result.source.lastPathComponent
    let content = UNMutableNotificationContent()
    switch result.outcome {
    case .compressed: content.title = "Compressed \(name)"
    case .skipped: content.title = "\(name) left as is"
    case .failed: content.title = "Couldn't compress \(name)"
    }
    content.body = result.message
    content.sound = .default
    content.userInfo = ["path": result.revealURL.path]
    UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    )
  }

  @objc private func cancel() {
    compressor.cancelAll()
  }

  @objc private func chooseVideos() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.movie]
    panel.prompt = "Compress"
    NSApp.activate()
    guard panel.runModal() == .OK else { return }
    compressor.enqueue(panel.urls)
  }

  @objc private func reveal(_ sender: NSMenuItem) {
    guard let url = sender.representedObject as? URL else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  @objc private func toggleDropZone() {
    dropZone.isEnabled.toggle()
    UserDefaults.standard.set(dropZone.isEnabled, forKey: "showsDropZone")
  }

  @objc private func toggleLaunchAtLogin() {
    let service = SMAppService.mainApp
    do {
      if service.status == .enabled {
        try service.unregister()
      } else {
        try service.register()
      }
    } catch {
      NSApp.activate()
      NSAlert(error: error).runModal()
    }
  }
}

extension AppDelegate: NSMenuDelegate {
  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()

    if let current = compressor.current {
      menu.addItem(label(current.lastPathComponent))
      let progress = label(compressor.detailStatus)
      progressItem = progress
      menu.addItem(progress)
      menu.addItem(item("Cancel", action: #selector(cancel)))
    } else {
      menu.addItem(label("Drop videos on this icon to compress them"))
    }

    menu.addItem(.separator())
    menu.addItem(item("Compress Videos…", action: #selector(chooseVideos), key: "o"))

    if !recent.isEmpty {
      menu.addItem(.separator())
      menu.addItem(.sectionHeader(title: "Recent"))
      for result in recent {
        let entry = item(result.source.lastPathComponent, action: #selector(reveal(_:)))
        entry.subtitle = result.message
        entry.image = NSImage(systemSymbolName: result.outcome.symbol, accessibilityDescription: nil)
        entry.representedObject = result.revealURL
        menu.addItem(entry)
      }
    }

    menu.addItem(.separator())
    let zone = item("Show Drop Zone While Dragging", action: #selector(toggleDropZone))
    zone.state = dropZone.isEnabled ? .on : .off
    menu.addItem(zone)
    let login = item("Launch at Login", action: #selector(toggleLaunchAtLogin))
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    menu.addItem(login)
    menu.addItem(item("Quit Video Compressor", action: #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
  }

  private func item(_ title: String, action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.target = target ?? self
    return item
  }

  private func label(_ title: String) -> NSMenuItem {
    NSMenuItem(title: title, action: nil, keyEquivalent: "")
  }
}

extension AppDelegate: NSWindowDelegate, NSDraggingDestination {
  func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard !videoURLs(on: sender.draggingPasteboard).isEmpty else { return [] }
    statusItem.button?.highlight(true)
    return .copy
  }

  func draggingExited(_ sender: NSDraggingInfo?) {
    statusItem.button?.highlight(false)
  }

  func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    statusItem.button?.highlight(false)
    let urls = videoURLs(on: sender.draggingPasteboard)
    compressor.enqueue(urls)
    return !urls.isEmpty
  }
}

/// Floats a large drop target at the screen's right edge whenever a video drag starts
/// anywhere, so files don't have to be carried up to the menu bar (where hitting the top
/// edge sets off Mission Control).
@MainActor
final class DropZone {
  var isEnabled = true
  var onDrop: ([URL]) -> Void = { _ in }

  private let state = DropZoneState()
  private lazy var panel = makePanel()
  private var monitor: Any?
  private var lastDragChange = NSPasteboard(name: .drag).changeCount
  private var isShown = false
  private var releaseTask: Task<Void, Never>?

  func start() {
    // Mouse-only global monitors need no Accessibility permission.
    monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
      MainActor.assumeIsolated { self?.mouseDragged() }
    }
  }

  /// A new drag writes to the drag pasteboard, so its change count marks each drag's start.
  private func mouseDragged() {
    let pasteboard = NSPasteboard(name: .drag)
    guard pasteboard.changeCount != lastDragChange else { return }
    lastDragChange = pasteboard.changeCount
    guard isEnabled, !videoURLs(on: pasteboard).isEmpty else { return }
    show()
  }

  private func show() {
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
    else { return }
    let visible = screen.visibleFrame
    let size = NSSize(width: 260, height: 260)
    panel.setFrame(
      NSRect(x: visible.maxX - size.width - 24, y: visible.midY - size.height / 2, width: size.width, height: size.height),
      display: false
    )
    state.isTargeted = false
    isShown = true
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      panel.animator().alphaValue = 1
    }

    releaseTask?.cancel()
    releaseTask = Task { [weak self] in
      while NSEvent.pressedMouseButtons & 1 != 0 {
        try? await Task.sleep(for: .milliseconds(100))
      }
      // The drag ended somewhere else; give an in-flight drop on the panel time to land first.
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      self?.hide()
    }
  }

  private func hide() {
    releaseTask?.cancel()
    isShown = false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.2
      panel.animator().alphaValue = 0
    }
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(200))
      guard let self, !isShown else { return }
      panel.orderOut(nil)
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: true
    )
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false

    let content = NSHostingView(rootView: DropZoneContent(state: state))
    // A plain view on top takes the drag, so SwiftUI never competes for it.
    let target = DropTargetView()
    target.onTargetChange = { [weak self] in self?.state.isTargeted = $0 }
    target.onDrop = { [weak self] urls in
      self?.onDrop(urls)
      self?.hide()
    }
    let container = NSView()
    for view in [content, target] {
      view.frame = container.bounds
      view.autoresizingMask = [.width, .height]
      container.addSubview(view)
    }
    panel.contentView = container
    return panel
  }
}

@MainActor
@Observable
private final class DropZoneState {
  var isTargeted = false
}

private struct DropZoneContent: View {
  let state: DropZoneState

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: state.isTargeted ? "arrow.down.circle.dotted" : "film.stack")
        .font(.system(size: 44, weight: .light))
        .contentTransition(.symbolEffect(.replace))
      Text("Drop to Compress")
        .font(.headline)
      Text("Saves a _compressed copy\nnext to the original")
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .foregroundStyle(state.isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background {
      RoundedRectangle(cornerRadius: 18)
        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        .foregroundStyle(state.isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        .padding(14)
    }
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
    .scaleEffect(state.isTargeted ? 1.04 : 1)
    .animation(.spring(duration: 0.25), value: state.isTargeted)
  }
}

private final class DropTargetView: NSView {
  var onTargetChange: (Bool) -> Void = { _ in }
  var onDrop: ([URL]) -> Void = { _ in }

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard !videoURLs(on: sender.draggingPasteboard).isEmpty else { return [] }
    onTargetChange(true)
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    onTargetChange(false)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let urls = videoURLs(on: sender.draggingPasteboard)
    onTargetChange(false)
    onDrop(urls)
    return !urls.isEmpty
  }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if let path = response.notification.request.content.userInfo["path"] as? String {
      onMain { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
    completionHandler()
  }
}

/// Runs the bundled compress-video script on one file at a time, reporting progress
/// parsed from ffmpeg's `time=` stats.
@MainActor
final class Compressor {
  enum Outcome {
    case compressed, skipped, failed

    var symbol: String {
      switch self {
      case .compressed: "checkmark.circle"
      case .skipped: "minus.circle"
      case .failed: "xmark.circle"
      }
    }
  }

  struct Result {
    let source: URL
    let output: URL
    let outcome: Outcome
    let message: String

    var revealURL: URL { outcome == .compressed ? output : source }
  }

  var onChange: () -> Void = {}
  var onFinish: (Result) -> Void = { _ in }

  private(set) var current: URL?
  private var queue: [URL] = []
  private var process: Process?
  private var output = Data()
  private var reachedEOF = false
  private var exitStatus: Int32?
  private var duration: Double?
  private var encoded: Double = 0
  private var isChecking = false
  private var cancelled = false

  private let script = Bundle.main.url(forResource: "compress-video", withExtension: "command")!

  var shortStatus: String {
    isChecking ? "Checking" : "\(percent)%"
  }

  var detailStatus: String {
    let status = isChecking ? "Checking quality…" : "Encoding \(percent)%"
    return queue.isEmpty ? status : "\(status) · \(queue.count) more queued"
  }

  private var percent: Int {
    guard let duration, duration > 0 else { return 0 }
    return min(99, Int(encoded / duration * 100))
  }

  func enqueue(_ urls: [URL]) {
    let new = urls.filter { $0 != current && !queue.contains($0) }
    guard !new.isEmpty else { return }
    queue += new
    startNext()
    onChange()
  }

  /// Stops the current file and drops anything queued.
  func cancelAll() {
    queue.removeAll()
    guard let process, process.isRunning else { return }
    cancelled = true
    // Kill the script first so it can't start its next step, then the ffmpeg processes it spawned.
    let children = Self.descendants(of: process.processIdentifier)
    process.terminate()
    children.forEach { kill($0, SIGTERM) }
    onChange()
  }

  private func startNext() {
    guard process == nil, !queue.isEmpty else { return }
    let source = queue.removeFirst()
    current = source
    output = Data()
    reachedEOF = false
    exitStatus = nil
    duration = nil
    encoded = 0
    isChecking = false
    cancelled = false

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let seconds = Self.probeDuration(of: source)
      onMain { if self?.current == source { self?.duration = seconds } }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, "-f", source.path]
    process.standardInput = FileHandle.nullDevice
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    // Output chunks and the exit status arrive separately; finish once both have.
    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil }
      onMain { self?.received(data) }
    }
    process.terminationHandler = { [weak self] process in
      let status = process.terminationStatus
      onMain { self?.exited(status) }
    }

    do {
      try process.run()
      self.process = process
    } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      complete(Result(source: source, output: Self.outputURL(for: source), outcome: .failed, message: error.localizedDescription))
    }
  }

  private func received(_ data: Data) {
    guard !data.isEmpty else {
      reachedEOF = true
      finishIfDone()
      return
    }
    output.append(data)
    let text = String(decoding: data, as: UTF8.self)
    if text.contains("Checking quality") {
      isChecking = true
    } else if let match = text.matches(of: #/time=(\d+):(\d+):([\d.]+)/#).last,
      let h = Double(match.1), let m = Double(match.2), let s = Double(match.3)
    {
      encoded = h * 3600 + m * 60 + s
    }
    onChange()
  }

  private func exited(_ status: Int32) {
    exitStatus = status
    finishIfDone()
  }

  private func finishIfDone() {
    guard reachedEOF, let status = exitStatus, let source = current else { return }
    let output = Self.outputURL(for: source)
    let lines = String(decoding: self.output, as: UTF8.self).split(whereSeparator: \.isNewline)
    func message(after prefix: String) -> String? {
      lines.last { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
    }

    let result: Result
    if cancelled {
      try? FileManager.default.removeItem(at: output)
      result = Result(source: source, output: output, outcome: .failed, message: "Cancelled")
    } else if let message = message(after: "✓ ") {
      result = Result(source: source, output: output, outcome: .compressed, message: message)
    } else if let message = message(after: "• ") {
      result = Result(source: source, output: output, outcome: .skipped, message: message)
    } else {
      let message = message(after: "✗ ") ?? lines.last.map(String.init) ?? "The script exited with status \(status)."
      result = Result(source: source, output: output, outcome: .failed, message: message)
    }
    complete(result)
  }

  private func complete(_ result: Result) {
    process = nil
    current = nil
    onFinish(result)
    startNext()
    onChange()
  }

  /// Mirrors the script's `${src:r}_compressed.mp4`.
  private static func outputURL(for source: URL) -> URL {
    URL(fileURLWithPath: source.deletingPathExtension().path + "_compressed.mp4")
  }

  nonisolated private static func probeDuration(of url: URL) -> Double? {
    guard
      let ffprobe = ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
        .first(where: FileManager.default.isExecutableFile(atPath:))
    else { return nil }
    let text = run(ffprobe, ["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", url.path])
    return Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }

  nonisolated private static func descendants(of pid: pid_t) -> [pid_t] {
    let children = run("/usr/bin/pgrep", ["-P", String(pid)]).split(separator: "\n").compactMap { pid_t($0) }
    return children + children.flatMap(descendants)
  }

  nonisolated private static func run(_ path: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }
}

private func videoURLs(on pasteboard: NSPasteboard) -> [URL] {
  pasteboard.readObjects(
    forClasses: [NSURL.self],
    options: [
      .urlReadingFileURLsOnly: true,
      .urlReadingContentsConformToTypes: [UTType.movie.identifier],
    ]
  ) as? [URL] ?? []
}

private func isVideo(_ url: URL) -> Bool {
  (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .movie) == true
}

/// Hops back to the main actor from Foundation callbacks, keeping their order.
private func onMain(_ work: @escaping @Sendable @MainActor () -> Void) {
  DispatchQueue.main.async { MainActor.assumeIsolated(work) }
}
