import Foundation

public struct BootedSimulator {
    public let name: String
    public let udid: String
    public let isInjected: Bool
    public let runningAppBundle: String?
}

public final class SimulatorManager {
    public static let shared = SimulatorManager()
    public static let backgroundQueue = DispatchQueue(label: "com.opensimcam.simulator", qos: .utility)
    private static var autoTimer: DispatchSourceTimer?
    private static var injectedSimUDIDs = Set<String>()
    
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
                let runningApp = includeRunningApps ? getRunningApp(simUDID: udid) : nil
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
            let standard = runXcrun([
                "simctl", "spawn", sim.udid,
                "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", loaderPath
            ]).0 == 0
            let xpc = runXcrun([
                "simctl", "spawn", sim.udid,
                "launchctl", "setenv", "__XPC_DYLD_INSERT_LIBRARIES", loaderPath
            ]).0 == 0

            if standard && xpc {
                injectedSimUDIDs.insert(sim.udid)
                print("[SimulatorManager] Injected OpenSimCam dylib into \(sim.name) (\(sim.udid))")
            } else {
                allInjected = false
                injectedSimUDIDs.remove(sim.udid)
                print("[SimulatorManager] Failed to inject OpenSimCam into \(sim.name) (\(sim.udid))")
            }
        }
        return allInjected && !targets.isEmpty
    }

    @discardableResult
    private static func runXcrun(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        do {
            try process.run()
            let timeout = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeout.cancel()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, "")
        }
    }
    
    public static func startAutoDetection(onUpdate: (([BootedSimulator]) -> Void)? = nil) {
        let timer = DispatchSource.makeTimerSource(queue: backgroundQueue)
        timer.schedule(deadline: .now(), repeating: 3.0)
        timer.setEventHandler {
            let devices = getBootedSimulators(includeRunningApps: false)
            let currentUDIDs = Set(devices.map { $0.udid })
            injectedSimUDIDs = injectedSimUDIDs.intersection(currentUDIDs)

            // Publish booted devices before querying app processes or copying
            // the camera loader, so simulator discovery stays responsive.
            DispatchQueue.main.async { onUpdate?(devices) }

            let sims = devices.map { device in
                BootedSimulator(
                    name: device.name,
                    udid: device.udid,
                    isInjected: device.isInjected,
                    runningAppBundle: getRunningApp(simUDID: device.udid)
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
