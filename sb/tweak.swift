
// This file is licensed under the BSD-3 Clause License
// Copyright 2022 © ElleKit Team

import Foundation
import ObjectiveC
import UIKit
import os.log

var orig: UnsafeMutableRawPointer? = nil // for SpringBoard applicationDidFinishLaunching
var orig2: UnsafeMutableRawPointer? = nil // for UIStatusBarWindow initWithFrame
var orig3: UnsafeMutableRawPointer? = nil // for _UIStatusBar layoutSubviews

// Thanks to Amy While (@elihwyma) for this piece of code
extension UIViewController {
    var top: UIViewController? {
        if let controller = self as? UINavigationController {
            return controller.topViewController?.top
        }
        if let controller = self as? UISplitViewController {
            return controller.viewControllers.last?.top
        }
        if let controller = self as? UITabBarController {
            return controller.selectedViewController?.top
        }
        if let controller = presentedViewController {
            return controller.top
        }
        return self
    }
}

var alert: UIAlertController? = nil

func showSafeModeAlert() {
    if alert != nil {
        DispatchQueue.main.async(execute: {
            alert!.dismiss(animated: true, completion: {
                alert = nil
                _showSafeModeAlert()
            })
        })
    } else {
        _showSafeModeAlert()
    }
}

func _showSafeModeAlert() {
    let title = "Safe Mode"
    let message = "You've entered Safe Mode. SpringBoard tweaks will not be injected until you exit Safe Mode.\n\nYou can select Dismiss to safely remove any broken tweaks.\n\nTap the status bar from the home screen to show this alert again."
    DispatchQueue.main.async(execute: {
        guard let alertWindow = UIApplication.shared.keyWindow else { return }
        
        alertWindow.rootViewController = alertWindow.rootViewController?.top
    
        alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        guard alert != nil else { return }
        
        let exitAction = UIAlertAction(title: "Exit Safe Mode", style: .default, handler: { action in
            alert = nil
            try? FileManager.default.removeItem(atPath: "\(safeModeFlagPath)")
            exit(0)
        })

        let dismissAction = UIAlertAction(title: "Dismiss", style: .cancel, handler: { action in
            alert = nil            
        })
        
        alert!.addAction(exitAction)
        alert!.addAction(dismissAction)
    
        alertWindow.makeKeyAndVisible()
    
        alertWindow.rootViewController?.present(alert!, animated: true, completion: nil)
    })
}

@objc class SpringBoard: NSObject {
    @objc func applicationDidFinishLaunching(_ application: UIApplication) {
        let block = unsafeBitCast(orig, to: (@convention (c) (NSObject, Selector, UIApplication) -> Void).self)
        block(self, #selector(UIApplicationDelegate.applicationDidFinishLaunching(_:)), application)
        
        showSafeModeAlert()
    }
}

@objc class UIStatusBarWindow: NSObject {
    @objc func initWithFrame(_ frame: CGRect) -> AnyObject? {
        let block = unsafeBitCast(orig2, to: (@convention (c) (NSObject, Selector, CGRect) -> AnyObject?).self)
        let result = block(self, #selector(UIStatusBarWindow.initWithFrame(_:)), frame)
        if result != nil {
            result?.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleMobileSafetyTrigger(_:))))
        }

        return result
    }

    @objc func handleMobileSafetyTrigger(_ sender: UITapGestureRecognizer) {
        showSafeModeAlert()
    }
}


@objc class _UIStatusBar: UIView {
    @objc func layoutSubviews2() {
        let block = unsafeBitCast(orig3, to: (@convention (c) (NSObject, Selector) -> Void).self)
        block(self, #selector(UIView.layoutSubviews))

        self.backgroundColor = UIColor.systemRed
    }
}

func performHooks() {
    guard let springboard_class = NSClassFromString("SpringBoard") else { return }
    let replacement = class_getMethodImplementation(
        SpringBoard.self,
        #selector(SpringBoard.applicationDidFinishLaunching(_:))
    )!
    messageHook(
        springboard_class, #selector(UIApplicationDelegate.applicationDidFinishLaunching(_:)),
        replacement, &orig
    )

    guard let statusbar_class = NSClassFromString("UIStatusBarWindow") else { return }
    let replacement2 = class_getMethodImplementation(
        UIStatusBarWindow.self,
        #selector(UIStatusBarWindow.initWithFrame(_:))
    )!
    messageHook(
        statusbar_class, NSSelectorFromString("initWithFrame:"),
        replacement2, &orig2
    )

    let handleMobileSafetyTrigger = class_getInstanceMethod(
        UIStatusBarWindow.self,
        #selector(UIStatusBarWindow.handleMobileSafetyTrigger(_:))
    )!
    class_addMethod(
        statusbar_class,
        NSSelectorFromString("handleMobileSafetyTrigger:"),
        method_getImplementation(handleMobileSafetyTrigger),
        method_getTypeEncoding(handleMobileSafetyTrigger)
    )

    guard let statusbar_class2 = NSClassFromString("_UIStatusBar") else { return }
    let replacement3 = class_getMethodImplementation(
        _UIStatusBar.self,
        #selector(_UIStatusBar.layoutSubviews2)
    )!
    messageHook(
        statusbar_class2, #selector(UIView.layoutSubviews),
        replacement3, &orig3
    )
}

let crashSignals = [
    SIGQUIT,
    SIGILL,
    SIGTRAP,
    SIGABRT,
    SIGEMT,
    SIGFPE,
    SIGBUS,
    SIGSEGV,
    SIGSYS
]

let exitSafeModeSignals = [
    SIGINT,
    SIGTERM
]

let safeModeFlagPath: StaticString = "/var/mobile/.eksafemode"

private extension StaticString {
    var cString: UnsafePointer<CChar> {
        UnsafeRawPointer(utf8Start).assumingMemoryBound(to: CChar.self)
    }
}

var crashSignalMask = sigset_t()
var exitSafeModeSignalMask = sigset_t()

func trap(signals: [Int32], action: @escaping @convention(c) (Int32) -> Void) -> sigset_t {
    var signalAction = sigaction()
    signalAction.__sigaction_u.__sa_handler = action
    signalAction.sa_flags = SA_NODEFER | SA_RESETHAND // a nested fault must kill us, not spin on a blocked SIGTRAP
    sigemptyset(&signalAction.sa_mask)

    var mask = sigset_t()
    for sig in signals {
        sigaction(sig, &signalAction, nil)
        mask |= sigset_t(1) << sigset_t(sig - 1)
    }
    return mask
}

func enterSafeMode(_ reason: String, at time: Date = Date()) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss xxx"
    formatter.timeZone = TimeZone.current
    let date = formatter.string(from: time)
    FileManager.default.createFile(atPath: "\(safeModeFlagPath)", contents: "[\(date)] \(reason)".data(using: .utf8))
}

func finishSafeModeReason() {
    guard let raw = try? String(contentsOfFile: "\(safeModeFlagPath)", encoding: .utf8),
          raw.hasPrefix("@"),
          let space = raw.firstIndex(of: " "),
          let time = TimeInterval(raw[raw.index(after: raw.startIndex)..<space]) else { return }
    enterSafeMode(String(raw[raw.index(after: space)...]), at: Date(timeIntervalSince1970: time))
}

// Signal handlers: async-signal-safe calls only, they may run with libobjc/malloc locks held

private func resetToDefault(_ mask: sigset_t) {
    var sig: Int32 = 1
    while sig < NSIG {
        if mask & (sigset_t(1) << sigset_t(sig - 1)) != 0 {
            signal(sig, SIG_DFL)
        }
        sig += 1
    }
}

private func writeStatic(_ fd: Int32, _ string: StaticString) {
    _ = write(fd, string.utf8Start, string.utf8CodeUnitCount)
}

private func writeDecimal(_ fd: Int32, _ value: UInt64) {
    var divisor: UInt64 = 1
    while value / divisor >= 10 {
        divisor *= 10
    }
    repeat {
        var digit = 0x30 /* "0" */ + UInt8(truncatingIfNeeded: value / divisor % 10)
        _ = write(fd, &digit, 1)
        divisor /= 10
    } while divisor > 0
}

func handleExitSafeModeRequest(currentSig: Int32) {
    resetToDefault(exitSafeModeSignalMask)
    unlink(safeModeFlagPath.cString)
    raise(currentSig)
}

// The date can't be formatted here, so leave "@<unix time> <reason>" for finishSafeModeReason()
func handleSBCrash(currentSig: Int32) {
    resetToDefault(crashSignalMask)

    let fd = open(safeModeFlagPath.cString, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if fd >= 0 {
        let now = time(nil)
        writeStatic(fd, "@")
        writeDecimal(fd, now > 0 ? UInt64(now) : 0)
        writeStatic(fd, " SB crash occured: signal ")
        writeDecimal(fd, UInt64(UInt32(bitPattern: currentSig)))
        close(fd)
    }

    raise(currentSig)
}

@_cdecl("tweak_entry")
public func tweak_entry() {
        
    NSLog("Hello world, SpringBoard!")
                
    if FileManager.default.fileExists(atPath: "\(safeModeFlagPath)") {
        finishSafeModeReason()
        performHooks()
    } else if checkVolumeUp() {
        tprint("Volume up!!!")
        enterSafeMode("Volume up detected")
        exit(0)
    }
        
    exitSafeModeSignalMask = trap(signals: exitSafeModeSignals, action: handleExitSafeModeRequest)
    crashSignalMask = trap(signals: crashSignals, action: handleSBCrash)
}
