import Foundation

/// Decoder for Google's encoded polyline format (algorithm v1).
/// Spec: https://developers.google.com/maps/documentation/utilities/polylinealgorithm
public enum GooglePolyline {
    /// Decodes an encoded polyline string into a sequence of coordinates. Returns an
    /// empty array on malformed input — the caller's responsibility to reject.
    public static func decode(_ encoded: String) -> [Coordinate] {
        var coordinates: [Coordinate] = []
        var index = encoded.startIndex
        var lat = 0
        var lon = 0

        while index < encoded.endIndex {
            guard let dLat = decodeDelta(in: encoded, index: &index) else { return coordinates }
            lat += dLat
            guard let dLon = decodeDelta(in: encoded, index: &index) else { return coordinates }
            lon += dLon
            coordinates.append(Coordinate(
                latitude: Double(lat) / 1e5,
                longitude: Double(lon) / 1e5
            ))
        }
        return coordinates
    }

    /// Reads one varint-encoded signed integer from `encoded` starting at `index`,
    /// advancing the index past the consumed characters. Returns nil if input is truncated.
    private static func decodeDelta(in encoded: String, index: inout String.Index) -> Int? {
        var result = 0
        var shift = 0
        while true {
            guard index < encoded.endIndex else { return nil }
            let ascii = Int(encoded[index].asciiValue ?? 0)
            index = encoded.index(after: index)
            let chunk = (ascii - 63) & 0x1F
            result |= chunk << shift
            shift += 5
            if (ascii - 63) < 0x20 { break }
            if shift > 30 { return nil } // sanity: guard runaway loops on garbage input
        }
        // Last bit is the sign. The spec stores `(value << 1) ^ (value >> 31)` so we undo it.
        let signed = (result & 1) != 0 ? ~(result >> 1) : (result >> 1)
        return signed
    }
}
