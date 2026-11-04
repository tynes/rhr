import Foundation

/// Bluetooth device names come from radio advertisements, which any nearby device can set to
/// anything. They are cleaned before being shown, stored or exported.
public enum DeviceName {
    public static let maxLength = 64

    /// Removes control and invisible formatting characters (newlines, bidi overrides that can
    /// make text read backwards, zero-width characters), trims whitespace and caps the length.
    /// Returns nil when nothing readable is left.
    public static func sanitize(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var scalars = String.UnicodeScalarView()
        for s in raw.unicodeScalars {
            switch s.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                continue
            default:
                scalars.append(s)
            }
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return cleaned.count > maxLength ? String(cleaned.prefix(maxLength)) : cleaned
    }
}
