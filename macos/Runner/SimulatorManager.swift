import Foundation

public struct BootedSimulator {
    public let name: String
    public let udid: String
    public let isInjected: Bool
    public let runningAppBundle: String?
}

public final class SimulatorManager {
    public static let shared = SimulatorManager()
    public static let backgroundQueue = DispatchQueue(label: "com.opensc.simulator", qos: .utility)
    private static var autoTimer: DispatchSourceTimer?
    private static var injectedSimUDIDs = Set<String>()
    private static let runningAppsLock = NSLock()
    private static var runningAppsCache: [String: String] = [:]
    private static var runningAppsLastChecked: [String: Date] = [:]

    /// A real plugin handshake proves the loader is already running in this
    /// simulator, so treat it as ready without waiting for another launchctl
    /// verification pass.
    public static func recordSuccessfulHandshake(simUDID: String) {
        backgroundQueue.async {
            injectedSimUDIDs.insert(simUDID)
        }
    }
    
    public static func getLoaderPath() -> String? {
        ensureDylibsInstalled()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/Library/Application Support/com.swmansion.SimCam/libSimCamLoader.dylib",
            "\(home)/Library/Application Support/OpenSimCam/libOpenSimCamLoader.dylib",
            Bundle.main.path(forResource: "libOpenSimCamLoader", ofType: "dylib"),
        ].compactMap { $0 }
        
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
    
    public static func ensureDylibsInstalled() {
        let appSupport = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OpenSimCam")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        
        let loaderDest = appSupport.appendingPathComponent("libOpenSimCamLoader.dylib")
        let coreDest = appSupport.appendingPathComponent("libOpenSimCamCore.dylib")
        
        let fallbackDirs = [
            Bundle.main.resourceURL,
            URL(fileURLWithPath: "/Users/intersamrt/Documents/Flutter-Projects/opensimcam/build"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.swmansion.SimCam")
        ].compactMap { $0 }
        
        for dir in fallbackDirs {
            let loaderSrc = dir.appendingPathComponent("libSimCamLoader.dylib")
            let coreSrc = dir.appendingPathComponent("libSimCamCore.dylib")
            let altLoaderSrc = dir.appendingPathComponent("libOpenSimCamLoader.dylib")
            let altCoreSrc = dir.appendingPathComponent("libOpenSimCamCore.dylib")
            
            let finalLoader = FileManager.default.fileExists(atPath: loaderSrc.path) ? loaderSrc : altLoaderSrc
            let finalCore = FileManager.default.fileExists(atPath: coreSrc.path) ? coreSrc : altCoreSrc
            
            if FileManager.default.fileExists(atPath: finalLoader.path) && !FileManager.default.fileExists(atPath: loaderDest.path) {
                try? FileManager.default.copyItem(at: finalLoader, to: loaderDest)
            }
            if FileManager.default.fileExists(atPath: finalCore.path) && !FileManager.default.fileExists(atPath: coreDest.path) {
                try? FileManager.default.copyItem(at: finalCore, to: coreDest)
            }
        }
    }
    
    public static func getRunningApp(simUDID: String) -> String? {
        let (status, output) = runXcrun(["simctl", "spawn", simUDID, "launchctl", "list"])
        guard status == 0 else { return nil }

        // launchctl output has changed formatting across simulator runtimes.
        // Read the UIKitApplication label rather than relying on fixed columns.
        let pattern = #"UIKitApplication:([^\[\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        return matches.reversed().compactMap { match -> String? in
            guard match.numberOfRanges > 1 else { return nil }
            let bundle = nsOutput.substring(with: match.range(at: 1))
            return bundle.hasPrefix("com.apple.") ? nil : bundle
        }.first
    }

    public static func getBundleID(forPID pid: Int, simUDID: String) -> String? {
        let (status, output) = runXcrun(["simctl", "spawn", simUDID, "launchctl", "list"])
        guard status == 0 else { return nil }
        let lines = output.components(separatedBy: "\n")
        for line in lines {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 3, let linePid = Int(parts[0]), linePid == pid {
                let label = String(parts[2])
                if let range = label.range(of: "UIKitApplication:") {
                    let sub = String(label[range.upperBound...])
                    let bundle = sub.components(separatedBy: "[").first ?? sub
                    if !bundle.hasPrefix("com.apple.") {
                        runningAppsLock.lock()
                        runningAppsCache[simUDID] = bundle
                        runningAppsLastChecked[simUDID] = Date()
                        runningAppsLock.unlock()
                        return bundle
                    }
                }
            }
        }
        return nil
    }

    public static func getCachedRunningApp(simUDID: String) -> String? {
        runningAppsLock.lock()
        if let checkedAt = runningAppsLastChecked[simUDID],
           Date().timeIntervalSince(checkedAt) < 2 {
            let cached = runningAppsCache[simUDID]
            runningAppsLock.unlock()
            return cached
        }
        runningAppsLock.unlock()

        let runningApp = getRunningApp(simUDID: simUDID)
        runningAppsLock.lock()
        runningAppsLastChecked[simUDID] = Date()
        if let runningApp {
            runningAppsCache[simUDID] = runningApp
        } else {
            runningAppsCache.removeValue(forKey: simUDID)
        }
        runningAppsLock.unlock()
        return runningApp
    }
    
    public static func getBootedSimulators(includeRunningApps: Bool = true) -> [BootedSimulator] {
        let (status, output) = runXcrun(["simctl", "list", "devices", "booted", "-j"])
        guard status == 0, let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devicesDict = json["devices"] as? [String: [[String: Any]]] else {
            return []
        }

        var result: [BootedSimulator] = []
        for (_, list) in devicesDict {
            for dev in list {
                guard let state = dev["state"] as? String, state == "Booted",
                      let name = dev["name"] as? String,
                      let udid = dev["udid"] as? String else { continue }
                let injected = injectedSimUDIDs.contains(udid)
                let runningApp = includeRunningApps ? getCachedRunningApp(simUDID: udid) : nil
                result.append(BootedSimulator(
                    name: name,
                    udid: udid,
                    isInjected: injected,
                    runningAppBundle: runningApp
                ))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    public static func injectDylib(loaderPath: String, intoUDID: String? = nil) -> Bool {
        let targets: [BootedSimulator]
        if let udid = intoUDID {
            targets = [BootedSimulator(name: udid, udid: udid, isInjected: false, runningAppBundle: nil)]
        } else {
            targets = getBootedSimulators()
        }

        var allInjected = true
        for sim in targets {
            let standardVariable = "DYLD_INSERT_LIBRARIES"
            let xpcVariable = "__XPC_DYLD_INSERT_LIBRARIES"
            var standardReady = getLaunchdEnvironment(standardVariable, simUDID: sim.udid) == loaderPath
            var xpcReady = getLaunchdEnvironment(xpcVariable, simUDID: sim.udid) == loaderPath

            // Avoid re-running launchctl setenv on every refresh when the
            // simulator already has the selected loader configured.
            if !standardReady {
                let result = runXcrun([
                    "simctl", "spawn", sim.udid,
                    "launchctl", "setenv", standardVariable, loaderPath
                ])
                standardReady = result.0 == 0 ||
                    getLaunchdEnvironment(standardVariable, simUDID: sim.udid) == loaderPath
            }
            if !xpcReady {
                let result = runXcrun([
                    "simctl", "spawn", sim.udid,
                    "launchctl", "setenv", xpcVariable, loaderPath
                ])
                xpcReady = result.0 == 0 ||
                    getLaunchdEnvironment(xpcVariable, simUDID: sim.udid) == loaderPath
            }

            if standardReady && xpcReady {
                injectedSimUDIDs.insert(sim.udid)
                print("[SimulatorManager] Injected OpenSC camera loader into \(sim.name) (\(sim.udid))")
            } else {
                allInjected = false
                injectedSimUDIDs.remove(sim.udid)
                print("[SimulatorManager] Loader verification failed for \(sim.name) (\(sim.udid)); DYLD=\(standardReady), XPC_DYLD=\(xpcReady)")
            }
        }
        return allInjected && !targets.isEmpty
    }

    private static func getLaunchdEnvironment(_ key: String, simUDID: String) -> String? {
        let (status, value) = runXcrun([
            "simctl", "spawn", simUDID, "launchctl", "getenv", key
        ])
        guard status == 0 else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private static func runXcrun(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            try process.run()
            let outputGroup = DispatchGroup()
            var outputData = Data()
            var errorData = Data()
            outputGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                outputGroup.leave()
            }
            outputGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                outputGroup.leave()
            }

            let timeoutLock = NSLock()
            var didTimeout = false
            let timeout = DispatchWorkItem {
                guard process.isRunning else { return }
                timeoutLock.lock()
                didTimeout = true
                timeoutLock.unlock()
                process.terminate()
            }
            // Simulator launch services can be busy while booting. Five
            // seconds caused healthy setenv calls to be terminated and left
            // setup reporting stale failures.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: timeout)
            process.waitUntilExit()
            timeout.cancel()
            outputGroup.wait()

            timeoutLock.lock()
            let timedOut = didTimeout
            timeoutLock.unlock()
            let stdout = String(data: outputData, encoding: .utf8) ?? ""
            let stderr = String(data: errorData, encoding: .utf8) ?? ""
            if timedOut {
                print("[SimulatorManager] xcrun timed out: \(arguments.joined(separator: " "))")
                return (-1, stdout + stderr)
            }
            return (process.terminationStatus, process.terminationStatus == 0 ? stdout : stdout + stderr)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
    
    public static func startAutoDetection(onUpdate: (([BootedSimulator]) -> Void)? = nil) {
        let timer = DispatchSource.makeTimerSource(queue: backgroundQueue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler {
            let devices = getBootedSimulators(includeRunningApps: false)
            let currentUDIDs = Set(devices.map { $0.udid })
            injectedSimUDIDs = injectedSimUDIDs.intersection(currentUDIDs)
            runningAppsLock.lock()
            runningAppsLastChecked = runningAppsLastChecked.filter { currentUDIDs.contains($0.key) }
            runningAppsCache = runningAppsCache.filter { currentUDIDs.contains($0.key) }
            runningAppsLock.unlock()

            // Proactively connect to any active camera sockets immediately
            FrameHandshakeServer.shared.scanExistingProcessSockets()

            // Publish booted devices before querying app processes or copying
            // the camera loader, so simulator discovery stays responsive.
            DispatchQueue.main.async { onUpdate?(devices) }

            let sims = devices.map { device in
                BootedSimulator(
                    name: device.name,
                    udid: device.udid,
                    isInjected: device.isInjected,
                    runningAppBundle: getCachedRunningApp(simUDID: device.udid)
                )
            }
            DispatchQueue.main.async { onUpdate?(sims) }

            guard let loader = getLoaderPath() else { return }
            for sim in sims {
                if !injectedSimUDIDs.contains(sim.udid) {
                    injectDylib(loaderPath: loader, intoUDID: sim.udid)
                }
            }

            let updatedSims = sims.map { sim in
                BootedSimulator(
                    name: sim.name,
                    udid: sim.udid,
                    isInjected: injectedSimUDIDs.contains(sim.udid),
                    runningAppBundle: sim.runningAppBundle
                )
            }
            DispatchQueue.main.async {
                onUpdate?(updatedSims)
            }
        }
        timer.resume()
        autoTimer = timer
    }
}
