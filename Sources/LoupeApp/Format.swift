import Foundation

/// One byte formatter for every display site so units and rounding agree.
func formattedBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
}
