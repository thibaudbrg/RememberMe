import Foundation

/// Splits a top-level JSON array (`[ {…}, {…}, … ]`) into the raw byte slices of its
/// depth-1 elements, without building a tree for the whole document. Used by the streaming
/// Takeout decoder so a multi-hundred-MB file can be decoded one record at a time.
///
/// Scanning is structural only: it tracks brace/bracket depth plus in-string and escape state
/// so commas, brackets and braces inside string values don't confuse the boundaries. It does
/// not validate JSON beyond that — each slice is handed to a real `JSONDecoder`.
enum RecordScanner {
    /// Returns one `Data` slice per depth-1 element of the top-level array, or `nil` if the
    /// document's first non-whitespace byte isn't `[` (i.e. not the supported array form).
    static func recordSlices(in data: Data) -> [Data]? {
        let bytes = [UInt8](data)
        var i = 0
        let n = bytes.count

        // Skip leading whitespace; require an opening '['.
        while i < n, isWhitespace(bytes[i]) { i += 1 }
        guard i < n, bytes[i] == UInt8(ascii: "[") else { return nil }
        i += 1

        var slices: [Data] = []
        var depth = 0                 // nesting depth relative to inside the top array
        var inString = false
        var escaped = false
        var elementStart: Int? = nil  // index of first byte of the current depth-1 element

        while i < n {
            let c = bytes[i]

            if inString {
                if escaped {
                    escaped = false
                } else if c == UInt8(ascii: "\\") {
                    escaped = true
                } else if c == UInt8(ascii: "\"") {
                    inString = false
                }
                i += 1
                continue
            }

            switch c {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                if depth == 0, elementStart == nil { elementStart = i }
                depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                if depth == 0 {
                    // Closing ']' of the top-level array. Capture a trailing primitive element.
                    if let start = elementStart {
                        slices.append(trimmedSlice(bytes, start, i, data: data))
                    }
                    return slices
                }
                depth -= 1
                if depth == 0, let start = elementStart {
                    slices.append(Data(bytes[start ... i]))
                    elementStart = nil
                }
            case UInt8(ascii: ","):
                if depth == 0 {
                    // Comma between top-level elements. Capture a primitive element (objects
                    // and arrays are already captured when their closing bracket lands).
                    if let start = elementStart {
                        slices.append(trimmedSlice(bytes, start, i - 1, data: data))
                        elementStart = nil
                    }
                }
            default:
                if depth == 0, elementStart == nil, !isWhitespace(c) {
                    elementStart = i
                }
            }
            i += 1
        }
        // Unterminated array — return what we found so far.
        return slices
    }

    private static func isWhitespace(_ c: UInt8) -> Bool {
        c == UInt8(ascii: " ") || c == UInt8(ascii: "\n") || c == UInt8(ascii: "\r") || c == UInt8(ascii: "\t")
    }

    /// Slice from `start` through `end` inclusive, trimming trailing whitespace so a primitive
    /// element decodes cleanly.
    private static func trimmedSlice(_ bytes: [UInt8], _ start: Int, _ end: Int, data _: Data) -> Data {
        var e = end
        while e > start, isWhitespace(bytes[e]) { e -= 1 }
        return Data(bytes[start ... e])
    }
}
