//
//  SimilarityScorerTests.swift
//  IinaMagnetTests
//
//  Pure title/year similarity scoring (Issue 09).

import Testing
@testable import IinaMagnet

@Suite("SimilarityScorer")
struct SimilarityScorerTests {

    @Test("exact title (after normalization) scores 1; near-exact scores high")
    func exact() {
        #expect(SimilarityScorer.titleSimilarity("葬送的芙莉莲", "葬送的芙莉莲") == 1)
        #expect(SimilarityScorer.titleSimilarity("SPY FAMILY", "spy  family!") == 1)  // case/space/punct
        // letter 'x' vs '×' (math sign) are genuinely different chars → high but < 1.
        #expect(SimilarityScorer.titleSimilarity("SPY x FAMILY", "spy×family") > 0.85)
    }

    @Test("containment scores high but below exact")
    func containment() {
        let s = SimilarityScorer.titleSimilarity("孤独摇滚", "孤独摇滚！第一季")
        #expect(s > 0.6 && s < 1)
    }

    @Test("typos handled by edit distance")
    func typo() {
        let s = SimilarityScorer.titleSimilarity("Frieren", "Freiren")   // transposition
        #expect(s > 0.6)
    }

    @Test("token reordering / extra words handled by Jaccard")
    func tokens() {
        let s = SimilarityScorer.titleSimilarity("attack on titan", "titan attack")
        #expect(s >= 0.6)
    }

    @Test("unrelated titles score low")
    func unrelated() {
        #expect(SimilarityScorer.titleSimilarity("葬送的芙莉莲", "间谍过家家") < 0.3)
    }

    @Test("year: match boosts, clear disagreement discounts, ±1 neutral")
    func year() {
        // Partial title so the year nudge is observable.
        let base = SimilarityScorer.score(parsedTitle: "孤独摇滚",
                                           parsedYear: nil,
                                           candidateTitle: "孤独摇滚！第一季", candidateYear: nil)
        let matched = SimilarityScorer.score(parsedTitle: "孤独摇滚", parsedYear: 2022,
                                             candidateTitle: "孤独摇滚！第一季", candidateYear: 2022)
        let off = SimilarityScorer.score(parsedTitle: "孤独摇滚", parsedYear: 2021,
                                         candidateTitle: "孤独摇滚！第一季", candidateYear: 2022)
        let disagree = SimilarityScorer.score(parsedTitle: "孤独摇滚", parsedYear: 2010,
                                              candidateTitle: "孤独摇滚！第一季", candidateYear: 2022)
        #expect(matched > base)
        #expect(off == base)               // ±1 neutral
        #expect(disagree < base)
        #expect(matched <= 1)
    }

    @Test("bestMatch picks the closest candidate, exact match ≥ 0.85")
    func bestMatch() {
        let parsed = ParsedMedia(title: "葬送的芙莉莲", year: 2023, kindHint: .tv)
        let cands = [
            MetadataCandidate(providerId: .bangumi, externalId: "1", title: "别的番", year: 2010),
            MetadataCandidate(providerId: .bangumi, externalId: "2", title: "葬送的芙莉莲", year: 2023),
        ]
        let m = SimilarityScorer.bestMatch(parsed, cands)
        #expect(m?.0.externalId == "2")
        #expect((m?.1 ?? 0) >= 0.85)
    }

    @Test("levenshtein basics")
    func lev() {
        #expect(SimilarityScorer.levenshtein(Array("kitten"), Array("sitting")) == 3)
        #expect(SimilarityScorer.levenshtein(Array(""), Array("abc")) == 3)
        #expect(SimilarityScorer.levenshtein(Array("abc"), Array("abc")) == 0)
    }
}
