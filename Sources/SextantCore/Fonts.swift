import CoreText
import Foundation

/// Returns the installed font families with fixed-pitch faces, as CoreText's monospace trait
/// says, sorted by name, without the system's hidden families.
public func monospacedFontFamilies() -> [String] {
    let monospaced = [kCTFontTraitsAttribute: [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitMonoSpace.rawValue]] as CFDictionary
    let matching = Set([kCTFontTraitsAttribute as String]) as CFSet
    let faces = CTFontDescriptorCreateMatchingFontDescriptors(CTFontDescriptorCreateWithAttributes(monospaced), matching) as? [CTFontDescriptor] ?? []
    let families = Set(faces.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String })
    return families.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
}
