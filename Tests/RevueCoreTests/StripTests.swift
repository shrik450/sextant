import Foundation
import Testing
@testable import RevueCore

@Test func stripScrollsOnlyAsFarAsAPaneNeeds() {
    let total: CGFloat = 3 * 600 + 2
    #expect(stripOffset(showing: 0, from: 0, paneWidth: 600, gap: 1, viewport: 900, total: total) == 0)
    #expect(stripOffset(showing: 1, from: 0, paneWidth: 600, gap: 1, viewport: 900, total: total) == 301)
    #expect(stripOffset(showing: 2, from: 301, paneWidth: 600, gap: 1, viewport: 900, total: total) == 902)
    #expect(stripOffset(showing: 1, from: 902, paneWidth: 600, gap: 1, viewport: 900, total: total) == 601)
    #expect(stripOffset(showing: 1, from: 601, paneWidth: 600, gap: 1, viewport: 900, total: total) == 601)
}

@Test func stripNeverScrollsPastItsEnds() {
    #expect(stripOffset(showing: 0, from: 500, paneWidth: 900, gap: 1, viewport: 900, total: 900) == 0)
    #expect(stripOffset(showing: 1, from: 5000, paneWidth: 600, gap: 1, viewport: 900, total: 1201) == 301)
}

@Test func stripCountsTheGapsBetweenPanes() {
    let total: CGFloat = 3 * 600 + 2 * 12
    #expect(stripOffset(showing: 1, from: 0, paneWidth: 600, gap: 12, viewport: 900, total: total) == 312)
    #expect(stripOffset(showing: 2, from: 312, paneWidth: 600, gap: 12, viewport: 900, total: total) == 924)
}
