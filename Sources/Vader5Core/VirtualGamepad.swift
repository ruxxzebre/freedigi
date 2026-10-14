import Foundation
import IOKit.hid
import Vader5CoreC
import ControllerProtocol

final class VirtualGamepad {
    private var device: UnsafeMutableRawPointer?
    private var started = false
    private let xboxCompatible: Bool
    private let dryRun: Bool
    private let traceID = UUID()
    private let diagnostics = NativeGamepadDiagnostics.shared

    init(xboxCompatible: Bool = false, dryRun: Bool = false) {
        self.xboxCompatible = xboxCompatible
        self.dryRun = dryRun
    }

    private static let descriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x85, 0x01,
        0x05, 0x09, 0x19, 0x01, 0x29, 0x14, 0x15, 0x00,
        0x25, 0x01, 0x75, 0x01, 0x95, 0x14, 0x81, 0x02,
        0x75, 0x01, 0x95, 0x04, 0x81, 0x03,
        0x05, 0x01, 0x09, 0x39, 0x15, 0x00, 0x25, 0x07,
        0x35, 0x00, 0x46, 0x3B, 0x01, 0x65, 0x14, 0x75,
        0x04, 0x95, 0x01, 0x81, 0x42, 0x75, 0x04, 0x95,
        0x01, 0x81, 0x03, 0x09, 0x30, 0x09, 0x31, 0x09,
        0x33, 0x09, 0x34, 0x16, 0x01, 0x80, 0x26, 0xFF,
        0x7F, 0x75, 0x10, 0x95, 0x04, 0x81, 0x02, 0x09,
        0x32, 0x09, 0x35, 0x15, 0x00, 0x26, 0xFF, 0x00,
        0x75, 0x08, 0x95, 0x02, 0x81, 0x02, 0xC0,
    ]

    func start() throws {
        started = true
        diagnostics.begin(profile: xboxCompatible ? "Xbox-compatible · 045e:02fd" : "Generic HID · 37d7:2401", dryRun: dryRun)
        ControllerDiagnostics.shared.record("Native gamepad", mode: dryRun ? .dryRun : .live,
            stage: "starting", message: "\(diagnostics.snapshot().profile). \(NativeGamepadDiagnostics.signingStatus).", operationID: traceID)
        if dryRun {
            try send(.neutral)
            return
        }
        let properties: [String: Any] = [
            kIOHIDReportDescriptorKey: Data(xboxCompatible ? XboxCompatibleReport.descriptor : Self.descriptor),
            kIOHIDTransportKey: xboxCompatible ? "Bluetooth" : "Virtual",
            kIOHIDManufacturerKey: "ControlLab",
            kIOHIDProductKey: xboxCompatible ? "Xbox Wireless Controller" : "Vader 5 Pro Virtual Gamepad",
            kIOHIDVendorIDKey: xboxCompatible ? XboxCompatibleReport.vendorID : Vader5Protocol.vendorID,
            kIOHIDProductIDKey: xboxCompatible ? XboxCompatibleReport.productID : Vader5Protocol.productID,
            kIOHIDPrimaryUsagePageKey: 1,
            kIOHIDPrimaryUsageKey: 5,
            kIOHIDVersionNumberKey: 1,
            kIOHIDSerialNumberKey: "VADER5-MACOS",
        ]
        device = V5VirtualHIDCreate(properties as CFDictionary)
        guard device != nil else {
            diagnostics.failed(Vader5Error.virtualDeviceCreation.description)
            ControllerDiagnostics.shared.record("Native gamepad", stage: "failed", message: Vader5Error.virtualDeviceCreation.description, operationID: traceID)
            throw Vader5Error.virtualDeviceCreation
        }
        diagnostics.created()
        try send(.neutral)
        ControllerDiagnostics.shared.record("Native gamepad", stage: "created",
            message: "Virtual HID device created and neutral report accepted. GameController/SDL/game recognition still needs checking.", operationID: traceID)
    }

    func send(_ state: Vader5State) throws {
        let report: [UInt8]
        if xboxCompatible {
            var input = ControllerMappingInput()
            _ = input.update(buttonBits: state.buttons.rawValue, dpad: state.dpad,
                             leftTrigger: state.leftTrigger, rightTrigger: state.rightTrigger)
            report = XboxCompatibleReport.encode(leftX: state.leftX, leftY: state.leftY,
                rightX: state.rightX, rightY: state.rightY, leftTrigger: state.leftTrigger,
                rightTrigger: state.rightTrigger, dpad: state.dpad, buttons: input.held)
        } else {
            report = Vader5Protocol.virtualReport(for: state)
        }
        if dryRun { diagnostics.preview(); return }
        guard let device else { throw Vader5Error.virtualDeviceCreation }
        let result = report.withUnsafeBufferPointer {
            V5VirtualHIDHandleReport(device, $0.baseAddress!, $0.count)
        }
        guard result == 0 else {
            let error = Vader5Error.virtualReport(result)
            diagnostics.failed(error.description, report: true)
            ControllerDiagnostics.shared.record("Native gamepad", stage: "failed", message: error.description, operationID: traceID)
            throw error
        }
        diagnostics.accepted()
    }

    func stop() {
        guard started else { return }
        started = false
        if device != nil { try? send(.neutral) }
        if let device { V5VirtualHIDRelease(device) }
        device = nil
        diagnostics.stopped()
        let state = diagnostics.snapshot()
        ControllerDiagnostics.shared.record("Native gamepad", mode: dryRun ? .dryRun : .live, stage: "stopped",
            message: "Accepted \(state.acceptedReports), rejected \(state.rejectedReports), previewed \(state.previewedReports) reports. Virtual device released.", operationID: traceID)
    }

    deinit { stop() }
}
