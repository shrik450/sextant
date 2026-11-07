import CoreText
import Testing
@testable import SextantCore

/// Lists the fonts installed on the machine running the tests, which on macOS include Menlo,
/// Courier New, Helvetica and Arial Unicode MS.
@Test func listsFixedPitchFamiliesOnly() {
    let families = monospacedFontFamilies()
    #expect(families.contains("Menlo"))
    #expect(families.contains("Courier New"))
    #expect(!families.contains("Helvetica"))
    #expect(!families.contains("Arial Unicode MS"))
    for family in families {
        let regular = CTFontCreateWithName(family as CFString, 12, nil)
        let i = CTFontGetGlyphWithName(regular, "i" as CFString), w = CTFontGetGlyphWithName(regular, "W" as CFString)
        var advances = [CGSize](repeating: .zero, count: 2)
        CTFontGetAdvancesForGlyphs(regular, .horizontal, [i, w], &advances, 2)
        #expect(advances[0].width == advances[1].width, "\(family)")
    }
}
