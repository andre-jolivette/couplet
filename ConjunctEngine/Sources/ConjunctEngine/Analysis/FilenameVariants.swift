import Foundation

/// Detects filename pairs that are export/crop variants of the same photo:
/// a leading numeric prefix ("63-foo.jpg" / "foo.jpg") or a trailing numeric
/// suffix ("foo-2.jpg" / "foo.jpg") added by an export workflow.
///
/// Matching is asymmetric: each name is compared in stripped form against the
/// *raw* other name, not stripped-vs-stripped only. This matters when the base
/// name itself starts with digits (date-prefixed exports like
/// "20250504-_R017085.jpg"): stripping `^\d+-` from both sides removes the
/// date from the unprefixed original but only the copy number from the
/// prefixed copy, so the two normalized names never match. That asymmetric
/// miss is why `sharesBaseName` in PairScorer silently failed for
/// "00-20250504-_R017085.jpg" vs "20250504-_R017085.jpg". See decision #94.
public enum FilenameVariants {

    /// Strips one leading numeric prefix: "63-foo.jpg" → "foo.jpg".
    static func strippingNumericPrefix(_ name: String) -> String {
        name.replacingOccurrences(of: #"^\d+-"#, with: "", options: .regularExpression)
    }

    /// Strips one trailing numeric suffix before the extension:
    /// "foo-2.jpg" → "foo.jpg".
    static func strippingNumericSuffix(_ name: String) -> String {
        name.replacingOccurrences(of: #"-\d+(\.\w+)$"#, with: "$1", options: .regularExpression)
    }

    /// All plausible base forms of a filename (lowercased): the name itself,
    /// prefix-stripped, suffix-stripped, and both.
    static func baseForms(_ name: String) -> Set<String> {
        let l = name.lowercased()
        let p = strippingNumericPrefix(l)
        let s = strippingNumericSuffix(l)
        return [l, p, s, strippingNumericSuffix(p)]
    }

    /// True when two distinct filenames are numeric prefix/suffix variants of
    /// the same base name. Identical filenames return false — two records can
    /// only share a filename when they live in different folders, and that is
    /// not this helper's call to make.
    public static func areVariants(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        let la = a.lowercased(), lb = b.lowercased()
        guard la != lb else { return false }
        return !baseForms(la).isDisjoint(with: baseForms(lb))
    }
}
