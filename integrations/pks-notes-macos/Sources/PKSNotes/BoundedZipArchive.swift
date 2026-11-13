import Foundation
import zlib

/// Bounded, read-only ZIP entry access shared by native document importers.
/// It never extracts paths to disk; only explicitly requested entries are read.
enum BoundedZipArchive {
    enum Failure: Error { case unsupported, malformed, notFound, tooLarge, failedToRead }

    static func readEntry(_ name: String, from bytes: Data) throws -> Data {
        guard bytes.count <= 64 * 1024 * 1024 else { throw Failure.failedToRead }

        func u16(_ i: Int) -> Int? {
            guard i >= 0, i + 2 <= bytes.count else { return nil }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8
        }
        func u32(_ i: Int) -> Int? {
            guard i >= 0, i + 4 <= bytes.count else { return nil }
            return Int(bytes[i]) | Int(bytes[i + 1]) << 8
                | Int(bytes[i + 2]) << 16 | Int(bytes[i + 3]) << 24
        }
        func validateExtraFields(_ range: Range<Int>) throws {
            guard range.lowerBound >= 0, range.upperBound <= bytes.count else {
                throw Failure.malformed
            }
            var offset = range.lowerBound
            while offset < range.upperBound {
                guard range.upperBound - offset >= 4,
                      let identifier = u16(offset),
                      let length = u16(offset + 2),
                      length <= range.upperBound - offset - 4 else {
                    throw Failure.malformed
                }
                // ZIP64 is unnecessary under the archive and entry bounds below.
                guard identifier != 0x0001 else { throw Failure.unsupported }
                offset += 4 + length
            }
        }

        guard bytes.count >= 22 else { throw Failure.unsupported }
        let searchStart = max(0, bytes.count - 22 - 65_535)
        guard let eocd = stride(from: bytes.count - 22, through: searchStart, by: -1).first(where: { index in
            u32(index) == 0x06054b50 &&
                u16(index + 20).map { length in index + 22 + length == bytes.count } == true
        }), let commentLength = u16(eocd + 20),
              eocd + 22 + commentLength == bytes.count,
              u16(eocd + 4) == 0, u16(eocd + 6) == 0,
              let count = u16(eocd + 10), u16(eocd + 8) == count,
              count <= 10_000,
              let centralSize = u32(eocd + 12),
              let centralOffset = u32(eocd + 16),
              centralOffset + centralSize <= eocd else { throw Failure.unsupported }

        let supportedFlags = 0x0006 | 0x0008 | 0x0800
        var cursor = centralOffset
        let centralEnd = centralOffset + centralSize
        var selection: (
            flags: Int, method: Int, compressed: Int, inflated: Int,
            crc: Int, local: Int, rawName: Data
        )?

        for _ in 0..<count {
            guard cursor + 46 <= centralEnd, u32(cursor) == 0x02014b50,
                  let flags = u16(cursor + 8), let method = u16(cursor + 10),
                  let crc = u32(cursor + 16), let compressed = u32(cursor + 20),
                  let inflated = u32(cursor + 24), let nameLength = u16(cursor + 28),
                  let extras = u16(cursor + 30), let comment = u16(cursor + 32),
                  let local = u32(cursor + 42),
                  cursor + 46 + nameLength + extras + comment <= centralEnd
            else { throw Failure.malformed }

            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            let extraEnd = nameEnd + extras
            try validateExtraFields(nameEnd..<extraEnd)
            let rawName = bytes.subdata(in: nameStart..<nameEnd)

            if String(data: rawName, encoding: .utf8) == name {
                guard selection == nil else { throw Failure.malformed }
                guard flags & ~supportedFlags == 0,
                      method == 0 || method == 8,
                      method == 8 || flags & 0x0006 == 0 else {
                    throw Failure.unsupported
                }
                guard inflated <= 12 * 1024 * 1024 else { throw Failure.tooLarge }
                selection = (flags, method, compressed, inflated, crc, local, rawName)
            }
            cursor += 46 + nameLength + extras + comment
        }

        guard let entry = selection else { throw Failure.notFound }
        guard entry.local <= centralOffset,
              centralOffset - entry.local >= 30,
              u32(entry.local) == 0x04034b50,
              let localFlags = u16(entry.local + 6),
              let localMethod = u16(entry.local + 8),
              let localCRC = u32(entry.local + 14),
              let localCompressed = u32(entry.local + 18),
              let localInflated = u32(entry.local + 22),
              let filenameLength = u16(entry.local + 26),
              let extraLength = u16(entry.local + 28) else {
            throw Failure.malformed
        }

        let localNameStart = entry.local + 30
        let localNameEnd = localNameStart + filenameLength
        let localExtraEnd = localNameEnd + extraLength
        guard localExtraEnd <= centralOffset,
              bytes.subdata(in: localNameStart..<localNameEnd) == entry.rawName,
              localFlags == entry.flags,
              localMethod == entry.method else { throw Failure.malformed }
        try validateExtraFields(localNameEnd..<localExtraEnd)

        if entry.flags & 0x0008 != 0 {
            // Bit 3 means the CRC/sizes may be supplied after the compressed data.
            guard (localCRC == 0 || localCRC == entry.crc),
                  (localCompressed == 0 || localCompressed == entry.compressed),
                  (localInflated == 0 || localInflated == entry.inflated) else {
                throw Failure.malformed
            }
        } else {
            guard localCRC == entry.crc,
                  localCompressed == entry.compressed,
                  localInflated == entry.inflated else { throw Failure.malformed }
        }

        let start = localExtraEnd
        guard start <= centralOffset,
              entry.compressed <= centralOffset - start else { throw Failure.malformed }
        let compressed = bytes.subdata(in: start..<(start + entry.compressed))
        let inflated: Data
        if entry.method == 0 {
            guard entry.compressed == entry.inflated else { throw Failure.malformed }
            inflated = compressed
        } else {
            guard entry.inflated > 0, entry.compressed > 0 else { throw Failure.malformed }
            var result = Data(count: entry.inflated)
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                                Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw Failure.failedToRead
            }
            defer { inflateEnd(&stream) }
            let success = compressed.withUnsafeBytes { input in
                result.withUnsafeMutableBytes { output -> Bool in
                    guard let inputBase = input.bindMemory(to: Bytef.self).baseAddress,
                          let outputBase = output.bindMemory(to: Bytef.self).baseAddress else {
                        return false
                    }
                    stream.next_in = UnsafeMutablePointer(mutating: inputBase)
                    stream.avail_in = uInt(input.count)
                    stream.next_out = outputBase
                    stream.avail_out = uInt(output.count)
                    return inflate(&stream, Z_FINISH) == Z_STREAM_END &&
                        Int(stream.total_in) == entry.compressed &&
                        Int(stream.total_out) == entry.inflated
                }
            }
            guard success else { throw Failure.malformed }
            inflated = result
        }

        let checksum = inflated.withUnsafeBytes { buffer -> uLong in
            guard let baseAddress = buffer.bindMemory(to: Bytef.self).baseAddress else {
                return 0
            }
            return crc32(0, baseAddress, uInt(buffer.count))
        }
        guard checksum == uLong(entry.crc) else { throw Failure.malformed }
        return inflated
    }
}
