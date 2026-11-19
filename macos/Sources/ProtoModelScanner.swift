import Foundation

struct ConvModelInfo {
    var stepMap: [Int: String]
    var sortedSteps: [Int]
    var defaultModel: String
    var dbSize: Int64
}

enum ProtoModelScanner {
    private static let needleLsi: [UInt8] = [0x0f] + Array("last_step_index".utf8) + [0x12]
    private static let maxDbBytes: Int64 = 512 * 1024 * 1024
    private static let chunkSize = 8 * 1024 * 1024
    private static let margin = 700
    private static let keep = margin * 2

    static func dbTotalSize(at convDbPath: String) -> Int64 {
        guard !convDbPath.isEmpty else { return 0 }
        let fm = FileManager.default
        var total: Int64 = 0
        for p in [convDbPath, convDbPath + "-wal"] {
            if let attrs = try? fm.attributesOfItem(atPath: p),
               let type = attrs[.type] as? FileAttributeType,
               type == .typeRegular,
               let sz = attrs[.size] as? NSNumber {
                total += sz.int64Value
            }
        }
        return total
    }

    static func extractConvModelMap(convDbPath: String) -> ConvModelInfo {
        guard !convDbPath.isEmpty else {
            return ConvModelInfo(stepMap: [:], sortedSteps: [], defaultModel: "", dbSize: 0)
        }

        var stepMap: [Int: String] = [:]
        var defaultModel = ""
        var dbSize: Int64 = 0
        let fm = FileManager.default

        for filePath in [convDbPath, convDbPath + "-wal"] {
            guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let type = attrs[.type] as? FileAttributeType,
                  type == .typeRegular,
                  let szNum = attrs[.size] as? NSNumber else {
                continue
            }
            let fileSize = szNum.int64Value
            dbSize += fileSize
            if fileSize <= 0 || fileSize > maxDbBytes {
                continue
            }

            guard let fh = FileHandle(forReadingAtPath: filePath) else {
                continue
            }
            defer { try? fh.close() }

            let bufCapacity = fileSize <= Int64(chunkSize) ? Int(fileSize) : (chunkSize + keep)
            var buffer = [UInt8](repeating: 0, count: bufCapacity)
            var filePos: Int64 = 0
            var carryLen = 0

            while filePos < fileSize {
                let maxRead = min(chunkSize, Int(fileSize - filePos), bufCapacity - carryLen)
                if maxRead <= 0 { break }
                let chunkData = fh.readData(ofLength: maxRead)
                let bytesRead = chunkData.count
                if bytesRead <= 0 { break }

                chunkData.copyBytes(to: &buffer[carryLen], count: bytesRead)
                filePos += Int64(bytesRead)

                let totalLen = carryLen + bytesRead
                let isLast = filePos >= fileSize
                let scanEnd = isLast ? totalLen : max(0, totalLen - margin)
                var offset = carryLen > 0 ? max(0, carryLen - margin) : 0
                var prevLsiEnd = offset

                buffer.withUnsafeBufferPointer { ptr in
                    while offset < scanEnd {
                        guard let idx = findSubsequence(needleLsi, in: ptr, start: offset, end: scanEnd) else {
                            break
                        }
                        let pos = idx + needleLsi.count
                        if pos < totalLen {
                            let vlen = Int(ptr[pos])
                            if vlen >= 1 && vlen <= 8 && pos + 1 + vlen <= totalLen {
                                if let stepIdx = parseAsciiDigits(ptr, start: pos + 1, length: vlen) {
                                    var rawInternal = ""
                                    let intStart = max(prevLsiEnd, idx - 650)
                                    if intStart <= idx - 3 {
                                        var k = intStart
                                        while k <= idx - 3 {
                                            if ptr[k] == 0x9a && ptr[k + 1] == 0x01 {
                                                let mlen = Int(ptr[k + 2])
                                                if mlen >= 4 && mlen <= 120 && k + 3 + mlen <= idx {
                                                    if let s = decodeUtf8(ptr, start: k + 3, length: mlen),
                                                       isValidInternalSlug(s),
                                                       !ModelNormalizer.isHexOrUuid(s) {
                                                        rawInternal = s
                                                    }
                                                }
                                            }
                                            k += 1
                                        }
                                    }

                                    var rawDisplay = ""
                                    let nextIdx = findSubsequence(needleLsi, in: ptr, start: pos, end: totalLen) ?? totalLen
                                    let winEnd = min(totalLen, idx + 650, nextIdx)
                                    if pos <= winEnd - 3 {
                                        var k = pos
                                        while k <= winEnd - 3 {
                                            if ptr[k] == 0xaa && ptr[k + 1] == 0x01 {
                                                let dlen = Int(ptr[k + 2])
                                                if dlen >= 4 && dlen <= 120 && k + 3 + dlen <= winEnd {
                                                    if let s = decodeUtf8(ptr, start: k + 3, length: dlen),
                                                       isValidDisplayLabel(s),
                                                       !ModelNormalizer.isHexOrUuid(s) {
                                                        rawDisplay = s
                                                        break
                                                    }
                                                }
                                            }
                                            k += 1
                                        }
                                    }

                                    let norm = ModelNormalizer.normalizeModelName(rawDisplay: rawDisplay, rawInternal: rawInternal)
                                    if !norm.isEmpty {
                                        stepMap[stepIdx] = norm
                                        defaultModel = norm
                                    }
                                }
                            }
                        }
                        prevLsiEnd = pos
                        offset = pos
                    }
                }

                if isLast { break }
                carryLen = min(keep, totalLen)
                if carryLen > 0 {
                    buffer.replaceSubrange(0..<carryLen, with: buffer[(totalLen - carryLen)..<totalLen])
                }
            }
        }

        let sortedSteps = stepMap.keys.sorted()
        return ConvModelInfo(stepMap: stepMap, sortedSteps: sortedSteps, defaultModel: defaultModel, dbSize: dbSize)
    }

    static func resolveStepModel(stepIdx: Int, modelInfo: ConvModelInfo?, fallbackModel: String = "") -> String {
        if let direct = modelInfo?.stepMap[stepIdx] {
            return direct
        }
        if let info = modelInfo, !info.sortedSteps.isEmpty {
            let steps = info.sortedSteps
            if stepIdx < steps[0] {
                return info.stepMap[steps[0]] ?? "其他模型"
            }
            var chosen = steps[0]
            for s in steps.reversed() {
                if s <= stepIdx {
                    chosen = s
                    break
                }
            }
            if let resolved = info.stepMap[chosen] {
                return resolved
            }
        }
        let trimmedFallback = fallbackModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallback.isEmpty {
            let norm = ModelNormalizer.normalizeModelName(rawDisplay: trimmedFallback, rawInternal: "")
            if !norm.isEmpty { return norm }
            return trimmedFallback
        }
        if let def = modelInfo?.defaultModel, !def.isEmpty {
            return def
        }
        return "其他模型"
    }

    // MARK: - Byte Scanning Primitives

    private static func findSubsequence(_ needle: [UInt8], in hay: UnsafeBufferPointer<UInt8>, start: Int, end: Int) -> Int? {
        let nCount = needle.count
        guard nCount > 0, start >= 0, end <= hay.count, end - start >= nCount else { return nil }
        let firstByte = needle[0]
        let limit = end - nCount
        var i = start
        while i <= limit {
            if hay[i] == firstByte {
                var matched = true
                var j = 1
                while j < nCount {
                    if hay[i + j] != needle[j] {
                        matched = false
                        break
                    }
                    j += 1
                }
                if matched { return i }
            }
            i += 1
        }
        return nil
    }

    private static func parseAsciiDigits(_ ptr: UnsafeBufferPointer<UInt8>, start: Int, length: Int) -> Int? {
        guard length > 0, start + length <= ptr.count else { return nil }
        var val = 0
        for i in start..<(start + length) {
            let b = ptr[i]
            guard b >= 0x30 && b <= 0x39 else { return nil }
            let digit = Int(b - 0x30)
            if val > (Int.max - digit) / 10 { return nil }
            val = val * 10 + digit
        }
        return val
    }

    private static func decodeUtf8(_ ptr: UnsafeBufferPointer<UInt8>, start: Int, length: Int) -> String? {
        guard start >= 0, length > 0, start + length <= ptr.count else { return nil }
        let slice = UnsafeBufferPointer(start: ptr.baseAddress!.advanced(by: start), count: length)
        return String(bytes: slice, encoding: .utf8)
    }

    private static func isValidInternalSlug(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first,
              (first.value >= 0x41 && first.value <= 0x5A) || (first.value >= 0x61 && first.value <= 0x7A) else {
            return false
        }
        for u in s.unicodeScalars {
            let v = u.value
            let ok = (v >= 0x41 && v <= 0x5A) ||
                     (v >= 0x61 && v <= 0x7A) ||
                     (v >= 0x30 && v <= 0x39) ||
                     v == 0x2E || v == 0x5F || v == 0x2F || v == 0x40 || v == 0x2D
            if !ok { return false }
        }
        return true
    }

    private static func isValidDisplayLabel(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first,
              (first.value >= 0x41 && first.value <= 0x5A) || (first.value >= 0x61 && first.value <= 0x7A) else {
            return false
        }
        for u in s.unicodeScalars {
            let v = u.value
            let ok = (v >= 0x41 && v <= 0x5A) ||
                     (v >= 0x61 && v <= 0x7A) ||
                     (v >= 0x30 && v <= 0x39) ||
                     v == 0x20 || v == 0x2E || v == 0x5F || v == 0x28 || v == 0x29 ||
                     v == 0x2D || v == 0x2B || v == 0x2F
            if !ok { return false }
        }
        return true
    }
}
