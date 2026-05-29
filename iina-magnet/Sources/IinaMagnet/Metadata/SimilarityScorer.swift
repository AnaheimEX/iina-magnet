//
//  SimilarityScorer.swift
//  IinaMagnet
//
//  Pure title/year similarity scorer (Issue 09) used to pick the best metadata
//  candidate and to produce the 0–1 confidence that drives the match state
//  (PRD IM-7: ≥0.85 confirmed, ≥0.65 pending, else unmatched) and the archive
//  page's confidence banner.
//
//  Title similarity is the max of three cheap, deterministic signals so it holds
//  up across the shapes we actually see:
//    • exact (after normalization) → 1.0
//    • containment (one title inside the other, common for "Name" vs
//      "Name: Subtitle") → scaled by length ratio
//    • character edit distance (normalized Levenshtein) → catches typos / minor
//      transliteration differences
//    • token-set Jaccard → catches word reordering / extra words (latin titles)
//  Year then nudges the score up on an exact match and discounts it when the
//  years clearly disagree (a ±1 gap is treated as neutral: air vs release year).

import Foundation

public enum SimilarityScorer {

    /// Best candidate + its 0–1 score, or nil if there are none.
    public static func bestMatch(_ parsed: ParsedMedia,
                                 _ candidates: [MetadataCandidate]) -> (MetadataCandidate, Double)? {
        guard !candidates.isEmpty else { return nil }
        var best: (MetadataCandidate, Double)?
        for c in candidates {
            let s = score(parsedTitle: parsed.title, parsedYear: parsed.year,
                          candidateTitle: c.title, candidateYear: c.year)
            if best == nil || s > best!.1 { best = (c, s) }
        }
        return best
    }

    /// Combined 0–1 confidence for one (parsed, candidate) pair.
    public static func score(parsedTitle: String, parsedYear: Int?,
                             candidateTitle: String, candidateYear: Int?) -> Double {
        let t = titleSimilarity(parsedTitle, candidateTitle)
        guard let py = parsedYear, let cy = candidateYear else { return t }
        if py == cy { return min(1, t + 0.10 * (1 - t)) }   // confidence boost toward 1
        if abs(py - cy) <= 1 { return t }                    // air vs release — neutral
        return t * 0.7                                       // years clearly disagree
    }

    // MARK: - Title similarity

    public static func titleSimilarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a), nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return 0 }
        if na == nb { return 1 }

        var best = 0.0
        if na.contains(nb) || nb.contains(na) {
            let ratio = Double(min(na.count, nb.count)) / Double(max(na.count, nb.count))
            best = 0.6 + 0.4 * ratio
        }
        best = max(best, charSimilarity(na, nb))
        best = max(best, tokenJaccard(a, b))
        return best
    }

    /// Lowercase + strip whitespace and punctuation (handles CJK middle dots etc.).
    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "[\\s\\p{P}\\p{S}]+", with: "",
                                            options: .regularExpression)
    }

    /// 1 − (Levenshtein / maxLen), clamped to 0…1.
    static func charSimilarity(_ a: String, _ b: String) -> Double {
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 0 }
        let dist = levenshtein(Array(a), Array(b))
        return 1 - Double(dist) / Double(maxLen)
    }

    /// Jaccard over whitespace/punctuation-split lowercase tokens. Returns 0 for
    /// single-token (e.g. spaceless CJK) inputs — the other signals cover those.
    static func tokenJaccard(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        guard ta.count > 1 || tb.count > 1 else { return 0 }
        guard !ta.isEmpty, !tb.isEmpty else { return 0 }
        let inter = ta.intersection(tb).count
        let union = ta.union(tb).count
        return union > 0 ? Double(inter) / Double(union) : 0
    }

    private static func tokens(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }

    /// Classic Levenshtein edit distance over character arrays (two-row DP).
    static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1,        // deletion
                             cur[j - 1] + 1,     // insertion
                             prev[j - 1] + cost) // substitution
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
