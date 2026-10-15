import Foundation

public struct BootedSimulator {
    public let name: String
    public let udid: String
    public let isInjected: Bool
    public let runningAppBundle: String?
}

public final class SimulatorManager {
    public static let shared = SimulatorManager()
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "spawn", simUDID, "launchctl", "list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            for line in output.components(separatedBy: "\n") {
                if line.contains("UIKitApplication:") {
                    let parts = line.components(separatedBy: "UIKitApplication:")
                    if parts.count >= 2 {
                        let sub = parts[1]
                        let bundle = sub.components(separatedBy: "[").first ?? sub
                        let trimmed = bundle.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.hasPrefix("com.apple.") {
                            return trimmed
                        }
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }
    
    public static func getBootedSimulators() -> [BootedSimulator] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "booted", "-j"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let devicesDict = json["devices"] as? [String: [[String: Any]]] else {
                return []
            }
            
            var result: [BootedSimulator] = []
            for (_, list) in devicesDict {
                for dev in list {
                    if let state = dev["state"] as? String, state == "Booted",
                       let name = dev["name"] as? String,
                       let udid = dev["udid"] as? String {
                        let injected = injectedSimUDIDs.contains(udid)
                        let runningApp = getRunningApp(simUDID: udid)
                        result.append(BootedSimulator(name: name, udid: udid, isInjected: injected, runningAppBundle: runningApp))
                    }
                }
            }
            return result
        } catch {
            return []
        }
    }
    
    public static func injectDylib(loaderPath: String, intoUDID: String? = nil) {
        let simulators = getBootedSimulators()
        let targets = intoUDID != nil ? simulators.filter { $0.udid == intoUDID } : simulators
        
        for sim in targets {
            // Set DYLD_INSERT_LIBRARIES
            let proc1 = Process()
            proc1.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            proc1.arguments = [
                "simctl", "spawn", sim.udid,
                "launchctl", "setenv", "DYLD_INSERT_LIBRARIES", loaderPath
            ]
            try? proc1.run()
            proc1.waitUntilExit()
            
            // Set __XPC_DYLD_INSERT_LIBRARIES
            let proc2 = Process()
            proc2.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            proc2.arguments = [
                "simctl", "spawn", sim.udid,
                "launchctl", "setenv", "__XPC_DYLD_INSERT_LIBRARIES", loaderPath
            ]
            try? proc2.run()
            proc2.waitUntilExit()
            
            injectedSimUDIDs.insert(sim.udid)
            print("[SimulatorManager] Injected OpenSimCam dylib into \(sim.name) (\(sim.udid))")
        }
    }
    
    public static func relaunchApp(bundleId: String, simUDID: String) {
        let termProc = Process()
        termProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        termProc.arguments = ["simctl", "terminate", simUDID, bundleId]
        try? termProc.run()
        termProc.waitUntilExit()
        
        let launchProc = Process()
        launchProc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        launchProc.arguments = ["simctl", "launch", simUDID, bundleId]
        try? launchProc.run()
        launchProc.waitUntilExit()
    }
    
    public static func startAutoDetection(onUpdate: (([BootedSimulator]) -> Void)? = nil) {
        ensureDylibsInstalled()
        
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 2.0)
        timer.setEventHandler {
            guard let loader = getLoaderPath() else { return }
            let sims = getBootedSimulators()
            let currentUDIDs = Set(sims.map { $0.udid })
            
            // Clean up stopped simulators
            injectedSimUDIDs = injectedSimUDIDs.intersection(currentUDIDs)
            
            // Automatically inject any newly booted simulator with both env vars
            for sim in sims {
                if !injectedSimUDIDs.contains(sim.udid) {
                    injectDylib(loaderPath: loader, intoUDID: sim.udid)
                }
            }
            
            let updatedSims = getBootedSimulators()
            DispatchQueue.main.async {
                onUpdate?(updatedSims)
            }
        }
        timer.resume()
        autoTimer = timer
    }
}
