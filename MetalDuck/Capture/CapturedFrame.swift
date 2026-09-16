//
//  CapturedFrame.swift
//  MetalDuck
//
//  Value type for captured screen content, replacing the CaptureDelegate protocol.
//

import Foundation
import CoreMedia
import CoreVideo
import Darwin
import IOSurface
import ScreenCaptureKit

struct CapturedFrame: @unchecked Sendable {
    let surface: IOSurface
    let pixelBuffer: CVPixelBuffer
    let presentationTimestamp: CMTime
    let frameRateTimestamp: TimeInterval
    let changedAreaRatio: Double?
    let contentRect: CGRect
    let contentScale: CGFloat
    let scaleFactor: CGFloat

    var size: CGSize { contentRect.size }
}

@available(macOS 12.3, *)
extension CapturedFrame {
    /// Creates a CapturedFrame from a CMSampleBuffer produced by SCStream.
    /// Returns nil if the frame status is not `.complete` or required data is missing.
    nonisolated static func from(sampleBuffer: CMSampleBuffer) -> CapturedFrame? {
        guard sampleBuffer.isValid else { return nil }

        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first
        else { return nil }

        guard let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete
        else { return nil }

        guard let pixelBuffer = sampleBuffer.imageBuffer else { return nil }

        guard let surfaceRef = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return nil }
        let surface = unsafeBitCast(surfaceRef, to: IOSurface.self)

        guard let contentRectDict = attachments[.contentRect],
              let contentRect = CGRect(dictionaryRepresentation: contentRectDict as! CFDictionary),
              let contentScale = attachments[.contentScale] as? CGFloat,
              let scaleFactor = attachments[.scaleFactor] as? CGFloat
        else { return nil }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let frameRateTimestamp = Self.frameRateTimestamp(
            displayTime: attachments[.displayTime],
            fallbackTimestamp: timestamp
        )
        let dirtyRects = Self.dirtyRects(from: attachments[.dirtyRects])
        let changedAreaRatio = dirtyRects.map {
            Self.changedAreaRatio(dirtyRects: $0, contentRect: contentRect, scaleFactor: scaleFactor)
        }

        return CapturedFrame(
            surface: surface,
            pixelBuffer: pixelBuffer,
            presentationTimestamp: timestamp,
            frameRateTimestamp: frameRateTimestamp,
            changedAreaRatio: changedAreaRatio,
            contentRect: contentRect,
            contentScale: contentScale,
            scaleFactor: scaleFactor
        )
    }

    private nonisolated static func frameRateTimestamp(displayTime: Any?, fallbackTimestamp: CMTime) -> TimeInterval {
        if let displayTime = displayTime as? UInt64 {
            return seconds(fromMachAbsoluteTime: displayTime)
        }

        if let displayTime = displayTime as? NSNumber {
            return seconds(fromMachAbsoluteTime: displayTime.uint64Value)
        }

        return CMTimeGetSeconds(fallbackTimestamp)
    }

    private nonisolated static func seconds(fromMachAbsoluteTime value: UInt64) -> TimeInterval {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)

        guard timebase.denom != 0 else { return 0 }

        let nanoseconds = Double(value) * Double(timebase.numer) / Double(timebase.denom)
        return nanoseconds / 1_000_000_000
    }

    private nonisolated static func dirtyRects(from value: Any?) -> [CGRect]? {
        if let rects = value as? [CGRect] {
            return rects
        }

        if let values = value as? [NSValue] {
            return values.map(\.rectValue)
        }

        if let array = value as? NSArray {
            return array.compactMap { item -> CGRect? in
                if let value = item as? NSValue {
                    return value.rectValue
                }
                if let dictionary = item as? NSDictionary {
                    return CGRect(dictionaryRepresentation: dictionary)
                }
                return nil
            }
        }

        return nil
    }

    private nonisolated static func changedAreaRatio(
        dirtyRects: [CGRect],
        contentRect: CGRect,
        scaleFactor: CGFloat
    ) -> Double {
        guard dirtyRects.isEmpty == false else { return 0 }

        let contentWidth = max(1, contentRect.width * scaleFactor)
        let contentHeight = max(1, contentRect.height * scaleFactor)
        let contentArea = contentWidth * contentHeight

        let changedArea = dirtyRects.reduce(CGFloat.zero) { total, rect in
            total + max(0, rect.width) * max(0, rect.height)
        }

        return min(1, Double(changedArea / contentArea))
    }
}
