// THROWAWAY HARNESS - Phase 2 will rebuild this properly.
//
// Phase 1 smoke-test AppDelegate.
//
// Responsibilities:
//   1. Configure AVAudioSession with the locked decisions:
//        category = .playAndRecord
//        mode     = .measurement                 // disables AGC
//        options  = [.mixWithOthers, .allowBluetooth]
//      No .duckOthers — passive recorder must not lower other audio.
//   2. Subscribe to AVAudioSession.interruptionNotification and
//      AVAudioSession.routeChangeNotification, and forward to Dart on the
//      `app.didisnorelastnight.smoke/audio` MethodChannel.
//   3. On every session activation, log the active input route to Dart so
//      the AirPods Pro A2DP-only state is visible.
//
// After running bootstrap.sh, copy this file over the generated
// ios/Runner/AppDelegate.swift.

import AVFoundation
import Flutter
import UIKit

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
    private let channelName = "app.didisnorelastnight.smoke/audio"
    private var channel: FlutterMethodChannel?
    private var lastInterruptionStartMs: Int64 = 0

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        if let controller = window?.rootViewController as? FlutterViewController {
            let ch = FlutterMethodChannel(name: channelName, binaryMessenger: controller.binaryMessenger)
            channel = ch
            ch.setMethodCallHandler { [weak self] call, result in
                guard let self = self else { result(nil); return }
                switch call.method {
                case "reportCurrentRoute":
                    self.reportCurrentRoute()
                    result(nil)
                default:
                    result(FlutterMethodNotImplemented)
                }
            }
        }

        configureAudioSession()
        registerAudioObservers()
        // Report initial route once observers and channel are wired.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reportCurrentRoute()
        }

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.mixWithOthers, .allowBluetooth]
            )
            try session.setActive(true)
        } catch {
            NSLog("AVAudioSession configure failed: \(error)")
        }
    }

    private func registerAudioObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(
            self,
            selector: #selector(onInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        nc.addObserver(
            self,
            selector: #selector(onRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func onInterruption(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw)
        else { return }

        switch type {
        case .began:
            lastInterruptionStartMs = nowMs()
            channel?.invokeMethod("interruptionBegan", arguments: nil)
        case .ended:
            var shouldResume = false
            if let optsRaw = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
                shouldResume = opts.contains(.shouldResume)
            }
            if shouldResume {
                // Re-activate the session before telling Dart to resume.
                do {
                    try AVAudioSession.sharedInstance().setActive(true)
                    reportCurrentRoute()
                } catch {
                    NSLog("AVAudioSession re-activate failed: \(error)")
                }
            }
            channel?.invokeMethod(
                "interruptionEnded",
                arguments: ["shouldResume": shouldResume]
            )
        @unknown default:
            break
        }
    }

    @objc private func onRouteChange(_ note: Notification) {
        let start = nowMs()
        // Re-activate to pick up the new route. iOS does this for us most of
        // the time, but explicit setActive(true) is cheap and removes a class
        // of bugs.
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            NSLog("AVAudioSession re-activate on route change failed: \(error)")
        }
        let end = nowMs()
        channel?.invokeMethod(
            "routeChangedAt",
            arguments: ["startEpochMs": start, "endEpochMs": end]
        )
        reportCurrentRoute()
    }

    private func reportCurrentRoute() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let input = route.inputs.first
        let payload: [String: Any] = [
            "portType": input?.portType.rawValue ?? "none",
            "portName": input?.portName ?? "none",
            "sampleRate": session.sampleRate,
            "channels": session.inputNumberOfChannels,
        ]
        channel?.invokeMethod("routeActivated", arguments: payload)
    }

    private func nowMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000.0)
    }
}
