import Foundation

/// A colour in sRGB, each channel from 0 to 1.
public struct RGB: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The colour's relative luminance, as WCAG defines it.
    public var luminance: Double {
        0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Returns this colour laid at `alpha` over `below`.
    public func over(_ below: RGB, alpha: Double) -> RGB {
        RGB(red: alpha * red + (1 - alpha) * below.red,
            green: alpha * green + (1 - alpha) * below.green,
            blue: alpha * blue + (1 - alpha) * below.blue)
    }
}

/// Returns the WCAG contrast ratio between two colours, from 1 to 21.
public func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
    let x = a.luminance, y = b.luminance
    return (max(x, y) + 0.05) / (min(x, y) + 0.05)
}

/// Returns the colour closest to `color` in lightness, with its hue, that reaches `minimum`
/// contrast on `background`, or `color` itself when it already does.
///
/// The colour moves away from the background: darker on a light one, lighter on a dark one. Its
/// chroma shrinks only where the lighter or darker colour would fall outside sRGB, so text keeps
/// its hue as it's pushed to stand out.
public func readable(_ color: RGB, on background: RGB, minimum: Double = 4.5) -> RGB {
    guard contrastRatio(color, background) < minimum else { return color }
    let (l, c, h) = oklch(color)
    let step = background.luminance > color.luminance ? -0.004 : 0.004
    var lightness = l
    while (0...1).contains(lightness + step) {
        lightness += step
        var chroma = c
        while chroma > 0, srgb(lightness, chroma, h) == nil { chroma = max(0, chroma - 0.004) }
        if let candidate = srgb(lightness, chroma, h), contrastRatio(candidate, background) >= minimum { return candidate }
    }
    return step < 0 ? RGB(red: 0, green: 0, blue: 0) : RGB(red: 1, green: 1, blue: 1)
}

private func linear(_ v: Double) -> Double {
    v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
}

private func gamma(_ v: Double) -> Double {
    v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
}

/// Returns a colour's OKLCH lightness, chroma and hue angle.
private func oklch(_ c: RGB) -> (Double, Double, Double) {
    let r = linear(c.red), g = linear(c.green), b = linear(c.blue)
    let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    let lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return (lightness, hypot(a, bb), atan2(bb, a))
}

/// Returns the sRGB colour for an OKLCH one, or nil if it falls outside sRGB.
private func srgb(_ lightness: Double, _ chroma: Double, _ hue: Double) -> RGB? {
    let a = chroma * cos(hue), b = chroma * sin(hue)
    let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
    let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
    let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
    let channels = [4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                    -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                    -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s]
    guard channels.allSatisfy({ $0 >= -0.0001 && $0 <= 1.0001 }) else { return nil }
    let v = channels.map { gamma(min(1, max(0, $0))) }
    return RGB(red: v[0], green: v[1], blue: v[2])
}
