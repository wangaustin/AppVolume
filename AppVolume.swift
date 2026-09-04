import AppKit
import CoreAudio
import Foundation

// MARK: - Model

final class AudioApp: NSObject {
    let processObjectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage?
    var volume: Float = 1.0
    var pipeline: AppAudioPipeline?

    init(processObjectID: AudioObjectID,
         pid: pid_t,
         bundleID: String,
         name: String,
         icon: NSImage?) {
        self.processObjectID = processObjectID
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.icon = icon
    }
}

// MARK: - Core Audio helpers

enum AudioError: Error, CustomStringConvertible {
    case status(OSStatus, String)
    case noOutputDevice
    case noOutputUID
    case aggregateNotAlive

    var description: String {
        switch self {
        case let .status(code, operation):
            return "\(operation) failed (OSStatus \(code))"
        case .noOutputDevice:
            return "No default output device."
        case .noOutputUID:
            return "Could not read the default output device UID."
        case .aggregateNotAlive:
            return "Aggregate audio device did not become ready."
        }
    }
}

@inline(__always)
func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioError.status(status, operation) }
}

func deviceUID(_ deviceID: AudioObjectID) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)

    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
    }
    try check(status, "Read output device UID")
    return value as String
}

func waitUntilAlive(_ deviceID: AudioObjectID) throws {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsAlive,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    for _ in 0..<30 {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &size, &alive
        )
        if status == noErr && alive != 0 { return }
        Thread.sleep(forTimeInterval: 0.1)
    }

    throw AudioError.aggregateNotAlive
}

// MARK: - One tapped app

final class AppAudioPipeline {
    private let processObjectID: AudioObjectID

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    // Intentionally allocated once and read directly by the RT callback.
    // On Apple Silicon, aligned 32-bit reads/writes are atomic.
    private let gain = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    init(processObjectID: AudioObjectID, initialGain: Float) {
        self.processObjectID = processObjectID
        gain.initialize(to: initialGain)
    }

    deinit {
        stop()
        gain.deinitialize(count: 1)
        gain.deallocate()
    }

    func setGain(_ value: Float) {
        gain.pointee = max(0, min(value, 1))
    }

    func start() throws {
        guard tapID == kAudioObjectUnknown else { return }

        let system = AudioHardwareSystem.shared
        guard let output = try system.defaultOutputDevice else {
            throw AudioError.noOutputDevice
        }

        let outputID = output.id
        let outputUID = try deviceUID(outputID)

        // Capture only this process, using the output device's first stream format.
        let tapDescription = CATapDescription(
            processes: [processObjectID],
            deviceUID: outputUID,
            stream: 0
        )
        tapDescription.name = "AppVolume Tap \(processObjectID)"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(tapDescription, &newTapID),
            "Create process tap"
        )
        tapID = newTapID

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppVolume \(processObjectID)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceClockDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: false
                ]
            ]
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &newAggregateID
                ),
                "Create aggregate device"
            )
            aggregateID = newAggregateID
            try waitUntilAlive(aggregateID)

            let gainPtr = gain

            var newIOProcID: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(
                &newIOProcID,
                aggregateID,
                nil
            ) { _, inputData, _, outputData, _ in
                let inputs = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: inputData)
                )
                let outputs = UnsafeMutableAudioBufferListPointer(outputData)

                guard !inputs.isEmpty, !outputs.isEmpty else { return }

                let g = gainPtr.pointee

                // For the simple single-output aggregate used here, the tap is
                // normally the last matching input buffer. Pick a buffer whose
                // channel count matches each output buffer.
                for outIndex in 0..<outputs.count {
                    let outBuffer = outputs[outIndex]
                    guard let outData = outBuffer.mData else { continue }

                    var selected: AudioBuffer?
                    for inIndex in stride(from: inputs.count - 1, through: 0, by: -1) {
                        let candidate = inputs[inIndex]
                        if candidate.mNumberChannels == outBuffer.mNumberChannels &&
                           candidate.mDataByteSize > 0 &&
                           candidate.mData != nil {
                            selected = candidate
                            break
                        }
                    }

                    guard let inBuffer = selected,
                          let inData = inBuffer.mData else {
                        memset(outData, 0, Int(outBuffer.mDataByteSize))
                        continue
                    }

                    let bytes = min(Int(inBuffer.mDataByteSize),
                                    Int(outBuffer.mDataByteSize))
                    let sampleCount = bytes / MemoryLayout<Float>.size

                    let src = inData.assumingMemoryBound(to: Float.self)
                    let dst = outData.assumingMemoryBound(to: Float.self)

                    if g == 1 {
                        memcpy(dst, src, bytes)
                    } else if g == 0 {
                        memset(dst, 0, bytes)
                    } else {
                        for i in 0..<sampleCount {
                            dst[i] = src[i] * g
                        }
                    }

                    if bytes < Int(outBuffer.mDataByteSize) {
                        memset(
                            outData.advanced(by: bytes),
                            0,
                            Int(outBuffer.mDataByteSize) - bytes
                        )
                    }
                }
            }

            try check(status, "Create IOProc")
            ioProcID = newIOProcID

            guard let ioProcID else {
                throw AudioError.status(-1, "Create IOProc")
            }

            try check(
                AudioDeviceStart(aggregateID, ioProcID),
                "Start aggregate device"
            )
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }

        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }
}


// MARK: - UI

final class AppRowView: NSView {
    private let app: AudioApp
    private let onChange: (AudioApp, Float) -> Void

    init(app: AudioApp, onChange: @escaping (AudioApp, Float) -> Void) {
        self.app = app
        self.onChange = onChange
        super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 62))

        let icon = NSImageView(frame: NSRect(x: 10, y: 17, width: 28, height: 28))
        icon.image = app.icon
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)

        let name = NSTextField(labelWithString: app.name)
        name.frame = NSRect(x: 50, y: 35, width: 245, height: 18)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        addSubview(name)

        let slider = NSSlider(
            value: Double(app.volume),
            minValue: 0,
            maxValue: 1,
            target: self,
            action: #selector(changed(_:))
        )
        slider.frame = NSRect(x: 50, y: 8, width: 260, height: 22)
        slider.isContinuous = true
        addSubview(slider)

        let pct = NSTextField(labelWithString: "\(Int(app.volume * 100))%")
        pct.frame = NSRect(x: 320, y: 10, width: 55, height: 18)
        pct.alignment = .right
        pct.tag = 99
        addSubview(pct)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed(_ sender: NSSlider) {
        let v = Float(sender.doubleValue)
        app.volume = v
        if let pct = viewWithTag(99) as? NSTextField {
            pct.stringValue = "\(Int(v * 100))%"
        }
        onChange(app, v)
    }
}


final class MixerController: NSViewController {
    weak var owner: AppDelegate?
    private let scroll = NSScrollView()
    private var document = NSView()

    init(owner: AppDelegate) {
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 460))

        let title = NSTextField(labelWithString: "AppVolume")
        title.font = .systemFont(ofSize: 22, weight: .bold)
        title.frame = NSRect(x: 18, y: 414, width: 220, height: 28)
        view.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Individual app volume")
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 20, y: 393, width: 220, height: 18)
        view.addSubview(subtitle)

        let refresh = NSButton(title: "Rescan", target: self, action: #selector(refreshPressed))
        refresh.frame = NSRect(x: 320, y: 409, width: 82, height: 28)
        view.addSubview(refresh)

        scroll.frame = NSRect(x: 12, y: 18, width: 396, height: 360)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view.addSubview(scroll)

        reload()
    }

    @objc private func refreshPressed() {
        owner?.refresh()
        reload()
    }

    func reload() {
        guard let owner else { return }

        // Rebuild the document view from scratch each time.
        // This avoids NSStackView sizing/autolayout races during refresh.
        let rowHeight: CGFloat = 64
        let width: CGFloat = 390

        if owner.apps.isEmpty {
            document = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 360))

            let empty = NSTextField(wrappingLabelWithString:
                "No apps are currently outputting audio.\n\nStart playing audio in Music, Spotify, Chrome, etc. The list updates automatically."
            )
            empty.frame = NSRect(x: 16, y: 250, width: 350, height: 80)
            empty.textColor = .secondaryLabelColor
            document.addSubview(empty)

            scroll.documentView = document
            return
        }

        let contentHeight = max(
            scroll.contentSize.height,
            CGFloat(owner.apps.count) * rowHeight
        )

        document = NSView(
            frame: NSRect(x: 0, y: 0, width: width, height: contentHeight)
        )

        // NSScrollView's document coordinate system is bottom-left.
        // Place rows from top to bottom explicitly.
        for (index, app) in owner.apps.enumerated() {
            let y = contentHeight - CGFloat(index + 1) * rowHeight

            let row = AppRowView(app: app) { [weak owner] app, volume in
                owner?.setVolume(app, volume)
            }
            row.frame = NSRect(
                x: 0,
                y: y,
                width: width,
                height: rowHeight
            )

            // A light separator helps visually distinguish rows.
            if index < owner.apps.count - 1 {
                let separator = NSBox(
                    frame: NSRect(
                        x: 48,
                        y: 0,
                        width: width - 60,
                        height: 1
                    )
                )
                separator.boxType = .separator
                row.addSubview(separator)
            }

            document.addSubview(row)
        }

        scroll.documentView = document

        // Scroll to the top after refresh so newly added apps are visible.
        if let clip = scroll.contentView as NSClipView? {
            let topY = max(0, contentHeight - scroll.contentSize.height)
            clip.scroll(to: NSPoint(x: 0, y: topY))
            scroll.reflectScrolledClipView(clip)
        }
    }
}


final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var apps: [AudioApp] = []

    private var window: NSWindow!
    private var mixer: MixerController!
    private var scanTimer: Timer?

    // Remember the user's chosen volume even if an app temporarily stops
    // producing sound and later comes back.
    private var savedVolumes: [String: Float] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("AppVolume: applicationDidFinishLaunching")

        NSApp.setActivationPolicy(.regular)

        _ = syncApps()

        mixer = MixerController(owner: self)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AppVolume"
        window.contentViewController = mixer
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        // Poll Core Audio once per second. This is intentionally simple and
        // robust: it notices newly-audible apps, apps that stop producing
        // audio, and apps that quit/restart without requiring manual refresh.
        scanTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(scanAudioApps),
            userInfo: nil,
            repeats: true
        )

        print("AppVolume: window opened; automatic audio-source detection enabled")
    }

    func applicationWillTerminate(_ notification: Notification) {
        scanTimer?.invalidate()
        scanTimer = nil

        for app in apps {
            app.pipeline?.stop()
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    @objc private func scanAudioApps() {
        if syncApps() {
            mixer?.reload()
        }
    }

    // Kept for the optional Rescan button.
    func refresh() {
        if syncApps(forceReload: true) {
            mixer?.reload()
        } else {
            mixer?.reload()
        }
    }

    @discardableResult
    private func syncApps(forceReload: Bool = false) -> Bool {
        do {
            let processes = try AudioHardwareSystem.shared.processes

            struct Candidate {
                let processObjectID: AudioObjectID
                let pid: pid_t
                let bundleID: String
                let name: String
                let icon: NSImage?
            }

            var candidates: [Candidate] = []
            var seenBundles = Set<String>()

            for process in processes {
                guard (try? process.isRunningOutput) == true else { continue }

                guard let bundleID = try? process.bundleID,
                      !bundleID.isEmpty,
                      bundleID != Bundle.main.bundleIdentifier else {
                    continue
                }

                let pid = (try? process.pid) ?? 0
                guard pid > 0 else { continue }

                // Keep one row per application bundle.
                guard !seenBundles.contains(bundleID) else { continue }
                seenBundles.insert(bundleID)

                let running = NSRunningApplication(processIdentifier: pid)

                candidates.append(
                    Candidate(
                        processObjectID: process.id,
                        pid: pid,
                        bundleID: bundleID,
                        name: running?.localizedName ?? bundleID,
                        icon: running?.icon
                    )
                )
            }

            let oldByBundle = Dictionary(
                uniqueKeysWithValues: apps.map { ($0.bundleID, $0) }
            )

            let candidateBundles = Set(candidates.map(\.bundleID))
            let oldBundles = Set(apps.map(\.bundleID))

            var changed = forceReload || candidateBundles != oldBundles

            var newApps: [AudioApp] = []

            for candidate in candidates {
                if let existing = oldByBundle[candidate.bundleID],
                   existing.processObjectID == candidate.processObjectID,
                   existing.pid == candidate.pid {
                    // Same live Core Audio process: keep the object and its
                    // active pipeline so changing the app list doesn't interrupt sound.
                    newApps.append(existing)
                    continue
                }

                // Same bundle but a different process ID means the app restarted
                // or Core Audio created a new process object. Tear the old tap down.
                if let old = oldByBundle[candidate.bundleID] {
                    savedVolumes[old.bundleID] = old.volume
                    old.pipeline?.stop()
                    old.pipeline = nil
                    changed = true
                }

                let app = AudioApp(
                    processObjectID: candidate.processObjectID,
                    pid: candidate.pid,
                    bundleID: candidate.bundleID,
                    name: candidate.name,
                    icon: candidate.icon
                )

                app.volume = savedVolumes[candidate.bundleID] ?? 1.0
                newApps.append(app)
                changed = true

                // If this app previously had a reduced volume, restore that
                // setting automatically when its new audio process appears.
                if app.volume < 0.999 {
                    let pipeline = AppAudioPipeline(
                        processObjectID: app.processObjectID,
                        initialGain: app.volume
                    )
                    app.pipeline = pipeline
                    do {
                        try pipeline.start()
                    } catch {
                        app.pipeline = nil
                        print("AppVolume: failed to restore \(app.name): \(error)")
                    }
                }
            }

            // Clean up apps that are no longer producing audio.
            for old in apps where !candidateBundles.contains(old.bundleID) {
                savedVolumes[old.bundleID] = old.volume
                old.pipeline?.stop()
                old.pipeline = nil
                changed = true
            }

            newApps.sort {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            // Detect ordering/name changes too.
            if newApps.map(\.bundleID) != apps.map(\.bundleID) {
                changed = true
            }

            apps = newApps
            return changed

        } catch {
            showError(error)
            return false
        }
    }

    func setVolume(_ app: AudioApp, _ volume: Float) {
        savedVolumes[app.bundleID] = volume

        if volume >= 0.999 {
            app.pipeline?.stop()
            app.pipeline = nil
            return
        }

        if let pipeline = app.pipeline {
            pipeline.setGain(volume)
            return
        }

        let pipeline = AppAudioPipeline(
            processObjectID: app.processObjectID,
            initialGain: volume
        )
        app.pipeline = pipeline

        do {
            try pipeline.start()
        } catch {
            app.pipeline = nil
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "AppVolume"
            alert.informativeText = "\(error)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
