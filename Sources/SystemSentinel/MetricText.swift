import SwiftUI

extension Text {
    /// The sentence with every figure in bold ("Frees about **7.0 GB**", "up **9 days**",
    /// "**83°C**"), so the numbers stand out when skimming a paragraph.
    init(metrics s: String) {
        let ns = s as NSString
        var out = Text("")
        var at = 0
        for m in Text.metricPattern.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > at { out = out + Text(verbatim: ns.substring(with: NSRange(location: at, length: m.range.location - at))) }
            // A no-break space keeps "6.6 GB" together on one line.
            out = out + Text(verbatim: ns.substring(with: m.range).replacingOccurrences(of: " ", with: "\u{00A0}")).bold()
            at = m.range.location + m.range.length
        }
        if at < ns.length { out = out + Text(verbatim: ns.substring(from: at)) }
        self = out
    }

    /// A number not inside a word (so "sg_console.py" and "v2" stay plain), with its unit
    /// and, for durations such as "2h 5m", the parts after it.
    static let metricPattern: NSRegularExpression = {
        let unit = #"(?:\s?(?:%|°C|TB|GB|MB|KB|kB|bytes|Wh|W|mAh|ms|Gbps|Mbps|kbps|GB/s|MB/s|KB/s|cores?|processes|apps?|days?|hours?|minutes?|seconds?|weeks?|months?|years?|d|h|m|s|x|×)(?![\p{L}\d]))"#
        let one = #"[-–+]?\$?\d[\d,]*(?:\.\d+)?"# + unit + "?"
        return try! NSRegularExpression(pattern: #"(?<![\p{L}\d_./])"# + one + #"(?:\s\d+(?:\.\d+)?\s?(?:h|m|s|min)(?![\p{L}\d]))*"#)
    }()
}
