import Testing
@testable import SextantCore

private func rgb(_ hex: Int) -> RGB {
    RGB(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
}

@Test func blackOnWhiteIsTwentyOneToOne() {
    #expect(abs(contrastRatio(rgb(0x000000), rgb(0xffffff)) - 21) < 0.01)
}

@Test func keepsAColourThatAlreadyReads() {
    let navy = rgb(0x0a3069)
    #expect(readable(navy, on: rgb(0xf9fafb)) == navy)
}

@Test func darkensTextOnALightHighlightUntilItReads() {
    let highlight = rgb(0xcf222e).over(rgb(0xf9fafb), alpha: 0.25)
    let blue = rgb(0x0466d7)
    #expect(contrastRatio(blue, highlight) < 4.5)
    let fixed = readable(blue, on: highlight)
    #expect(contrastRatio(fixed, highlight) >= 4.5)
    #expect(fixed.luminance < blue.luminance)
    #expect(fixed.blue > fixed.red, "keeps its hue")
}

@Test func lightensTextOnADarkHighlightUntilItReads() {
    let highlight = rgb(0x3fb950).over(rgb(0x13171d), alpha: 0.28)
    let grey = rgb(0x9198a1)
    #expect(contrastRatio(grey, highlight) < 4.5)
    let fixed = readable(grey, on: highlight)
    #expect(contrastRatio(fixed, highlight) >= 4.5)
    #expect(fixed.luminance > grey.luminance)
}

@Test func movesNoFurtherThanItNeeds() {
    let highlight = rgb(0xcf222e).over(rgb(0xf9fafb), alpha: 0.25)
    let fixed = readable(rgb(0x0466d7), on: highlight)
    #expect(contrastRatio(fixed, highlight) < 4.7)
}
