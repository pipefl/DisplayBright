//
//  DDCControl.swift
//  DisplayBright
//
//  Created by Josh Phillips on 4/9/26.
//

import Foundation
@preconcurrency import CoreGraphics
import IOKit
import IOKit.i2c
import IOKit.graphics

// MARK: - DDC/CI Constants

/// VCP (Virtual Control Panel) codes used in DDC/CI protocol
enum VCPCode: UInt8, Sendable {
    case brightness = 0x10
}

// MARK: - DDC Result Types

struct DDCReadResult: Sendable {
    let currentValue: UInt16
    let maxValue: UInt16
}

// MARK: - DDC Control

/// Handles DDC/CI communication with external displays over I2C
enum DDCControl {

    // MARK: - DDC Constants
    private static let sourceAddress: UInt8 = 0x51
    private static let replyAddress: UInt8 = 0x6E
    private static let getCommand: UInt8 = 0x01
    private static let setCommand: UInt8 = 0x03
    private static let getReplyCommand: UInt8 = 0x02
    private static let i2cAddress: UInt32 = 0x37
    private static let replyDelay: UInt32 = 50_000

    // MARK: - Public API

    /// Read a VCP value from an external display
    static func read(displayID: CGDirectDisplayID, code: VCPCode) -> DDCReadResult? {
        guard let service = ioServiceForDisplay(displayID: displayID) else {
            print("[DDC] No I2C service found for display \(displayID)")
            return nil
        }
        defer { IOObjectRelease(service) }

        let length: UInt8 = 0x82
        let payload: [UInt8] = [sourceAddress, length, getCommand, code.rawValue]
        let checksum = computeChecksum(destination: replyAddress, data: payload)
        var sendData = payload + [checksum]
        var replyData = [UInt8](repeating: 0, count: 11)

        let success = sendData.withUnsafeMutableBufferPointer { sendBuf in
            replyData.withUnsafeMutableBufferPointer { replyBuf in
                sendI2C(
                    service: service,
                    sendAddress: i2cAddress,
                    sendBuffer: sendBuf.baseAddress!,
                    sendCount: sendBuf.count,
                    replyAddress: i2cAddress,
                    replyBuffer: replyBuf.baseAddress!,
                    replyCount: replyBuf.count
                )
            }
        }

        guard success else {
            print("[DDC] I2C transaction failed for display \(displayID)")
            return nil
        }

        guard replyData.count >= 11 else { return nil }

        let replyCommand = replyData[2]
        guard replyCommand == getReplyCommand else {
            print("[DDC] Unexpected reply command: \(replyCommand)")
            return nil
        }

        let maxValue = (UInt16(replyData[6]) << 8) | UInt16(replyData[7])
        let currentValue = (UInt16(replyData[8]) << 8) | UInt16(replyData[9])

        return DDCReadResult(currentValue: currentValue, maxValue: maxValue)
    }

    /// Write a VCP value to an external display
    @discardableResult
    static func write(displayID: CGDirectDisplayID, code: VCPCode, value: UInt16) -> Bool {
        guard let service = ioServiceForDisplay(displayID: displayID) else {
            print("[DDC] No I2C service found for display \(displayID)")
            return false
        }
        defer { IOObjectRelease(service) }

        let length: UInt8 = 0x84
        let valueHi = UInt8((value >> 8) & 0xFF)
        let valueLo = UInt8(value & 0xFF)
        let payload: [UInt8] = [sourceAddress, length, setCommand, code.rawValue, valueHi, valueLo]
        let checksum = computeChecksum(destination: replyAddress, data: payload)
        var sendData = payload + [checksum]

        let success = sendData.withUnsafeMutableBufferPointer { sendBuf in
            sendI2C(
                service: service,
                sendAddress: i2cAddress,
                sendBuffer: sendBuf.baseAddress!,
                sendCount: sendBuf.count,
                replyAddress: 0,
                replyBuffer: nil,
                replyCount: 0
            )
        }

        if !success {
            print("[DDC] I2C write failed for display \(displayID)")
        }

        return success
    }

    // MARK: - I2C Communication

    private static func sendI2C(
        service: io_service_t,
        sendAddress: UInt32,
        sendBuffer: UnsafeMutablePointer<UInt8>,
        sendCount: Int,
        replyAddress: UInt32,
        replyBuffer: UnsafeMutablePointer<UInt8>?,
        replyCount: Int
    ) -> Bool {
        var busCount: IOItemCount = 0
        let countResult = IOFBGetI2CInterfaceCount(service, &busCount)
        guard countResult == KERN_SUCCESS, busCount > 0 else {
            print("[DDC] No I2C buses found")
            return false
        }

        for bus: IOOptionBits in 0..<IOOptionBits(busCount) {
            var i2cInterface: io_service_t = IO_OBJECT_NULL
            let interfaceResult = IOFBCopyI2CInterfaceForBus(service, bus, &i2cInterface)
            guard interfaceResult == KERN_SUCCESS, i2cInterface != IO_OBJECT_NULL else {
                continue
            }
            defer { IOObjectRelease(i2cInterface) }

            var connect: IOI2CConnectRef? = nil
            let openResult = IOI2CInterfaceOpen(i2cInterface, 0, &connect)
            guard openResult == KERN_SUCCESS, let connect = connect else {
                continue
            }
            defer { IOI2CInterfaceClose(connect, 0) }

            var request = IOI2CRequest()
            request.sendAddress = sendAddress << 1
            request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
            request.sendBuffer = vm_address_t(Int(bitPattern: sendBuffer))
            request.sendBytes = UInt32(sendCount)

            if let replyBuffer = replyBuffer, replyCount > 0 {
                request.replyAddress = replyAddress << 1
                request.replyTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
                request.replyBuffer = vm_address_t(Int(bitPattern: replyBuffer))
                request.replyBytes = UInt32(replyCount)
                request.minReplyDelay = UInt64(replyDelay) * 1000
            } else {
                request.replyTransactionType = IOOptionBits(kIOI2CNoTransactionType)
            }

            let sendResult = IOI2CSendRequest(connect, 0, &request)
            if sendResult == KERN_SUCCESS && request.result == KERN_SUCCESS {
                return true
            }
        }

        return false
    }

    // MARK: - Display Service Lookup

    private static func ioServiceForDisplay(displayID: CGDirectDisplayID) -> io_service_t? {
        // Strategy 1: Try IOAVService (Apple Silicon Macs)
        if let service = findAVServiceForDisplay(displayID: displayID) {
            return service
        }

        // Strategy 2: Try IOFramebuffer (Intel Macs)
        if let service = findFramebufferServiceForDisplay(displayID: displayID) {
            return service
        }

        print("[DDC] No service found via any strategy for display \(displayID)")
        return nil
    }

    // MARK: - Apple Silicon: IOAVService lookup

    /// On Apple Silicon, DDC goes through IOAVService (or DCPAVServiceProxy)
    private static func findAVServiceForDisplay(displayID: CGDirectDisplayID) -> io_service_t? {
        // Try to find IOAVServiceInterface or DCPAVServiceProxy
        for className in ["IOAVService", "DCPAVServiceProxy"] {
            var iterator: io_iterator_t = 0
            let matching = IOServiceMatching(className)
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            var service = IOIteratorNext(iterator)
            while service != IO_OBJECT_NULL {
                // Check if this service matches our display by looking at the location/EDIDMatch
                if avServiceMatchesDisplay(service: service, displayID: displayID) {
                    return service
                }
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
        }

        return nil
    }

    /// Check if an IOAVService/DCPAVServiceProxy matches a display
    private static func avServiceMatchesDisplay(service: io_service_t, displayID: CGDirectDisplayID) -> Bool {
        // Walk down to find an IODisplay child with matching vendor/product
        var childIterator: io_iterator_t = 0
        if IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &childIterator) == KERN_SUCCESS {
            defer { IOObjectRelease(childIterator) }

            var child = IOIteratorNext(childIterator)
            while child != IO_OBJECT_NULL {
                defer {
                    IOObjectRelease(child)
                    child = IOIteratorNext(childIterator)
                }

                if displayServiceMatchesID(service: child, displayID: displayID) {
                    return true
                }
            }
        }

        // Also check the service itself
        if displayServiceMatchesID(service: service, displayID: displayID) {
            return true
        }

        // Fallback: if there's only one external display, match any service we find
        // (common case — single external monitor)
        return false
    }

    // MARK: - Intel: IOFramebuffer lookup

    private static func findFramebufferServiceForDisplay(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IODisplayConnect")
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service: io_service_t = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            if let framebuffer = findFramebufferParent(of: service) {
                if framebufferMatchesDisplay(framebuffer: framebuffer, displayID: displayID) {
                    IOObjectRelease(service)
                    return framebuffer
                }
                IOObjectRelease(framebuffer)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return nil
    }

    private static func findFramebufferParent(of service: io_service_t) -> io_service_t? {
        var parent: io_service_t = IO_OBJECT_NULL
        var current = service
        IOObjectRetain(current)

        for _ in 0..<8 {
            let kr = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard kr == KERN_SUCCESS else { return nil }

            if IOObjectConformsTo(parent, "IOFramebuffer") != 0 {
                return parent
            }
            current = parent
        }

        IOObjectRelease(current)
        return nil
    }

    private static func framebufferMatchesDisplay(framebuffer: io_service_t, displayID: CGDirectDisplayID) -> Bool {
        var childIterator: io_iterator_t = 0
        let kr = IORegistryEntryGetChildIterator(framebuffer, kIOServicePlane, &childIterator)
        guard kr == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(childIterator) }

        var child: io_service_t = IOIteratorNext(childIterator)
        while child != IO_OBJECT_NULL {
            defer {
                IOObjectRelease(child)
                child = IOIteratorNext(childIterator)
            }

            if displayServiceMatchesID(service: child, displayID: displayID) {
                return true
            }
        }

        return false
    }

    // MARK: - Common display matching

    /// Check if an IOKit service matches a CGDirectDisplayID by vendor/product/serial
    private static func displayServiceMatchesID(service: io_service_t, displayID: CGDirectDisplayID) -> Bool {
        guard let info = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayOnlyPreferredName))?.takeRetainedValue() as? [String: Any] else {
            return false
        }

        guard let vendorID = info[kDisplayVendorID] as? UInt32,
              let productID = info[kDisplayProductID] as? UInt32 else {
            return false
        }

        let cgVendor = CGDisplayVendorNumber(displayID)
        let cgModel = CGDisplayModelNumber(displayID)

        guard vendorID == cgVendor && productID == cgModel else {
            return false
        }

        // If serial is available, use it for disambiguation
        let cgSerial = CGDisplaySerialNumber(displayID)
        if let serialNum = info[kDisplaySerialNumber] as? UInt32 {
            return serialNum == cgSerial
        }

        return true
    }

    // MARK: - Checksum

    private static func computeChecksum(destination: UInt8, data: [UInt8]) -> UInt8 {
        var checksum = destination
        for byte in data {
            checksum ^= byte
        }
        return checksum
    }
}
