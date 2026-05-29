//
//  AnitomyBridge.mm
//  AnitomyBridge
//
//  Obj-C++ implementation of ANTParser over the vendored classic Anitomy
//  (C++14, string_t = std::wstring). See ADR-0006.

#import "AnitomyBridge.h"

#import "anitomy/anitomy.h"

#include <string>

namespace {

/// macOS `wchar_t` is 4 bytes == one UTF-32 code unit, so Anitomy's
/// `std::wstring` maps cleanly to NSString via UTF-32 (little-endian, native).

std::wstring toWString(NSString *s) {
    if (s.length == 0) {
        return std::wstring();
    }
    NSData *data = [s dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    if (data.length == 0) {
        return std::wstring();
    }
    return std::wstring(reinterpret_cast<const wchar_t *>(data.bytes),
                        data.length / sizeof(wchar_t));
}

NSString *fromWString(const anitomy::string_t &ws) {
    if (ws.empty()) {
        return @"";
    }
    return [[NSString alloc] initWithBytes:ws.data()
                                    length:ws.size() * sizeof(wchar_t)
                                  encoding:NSUTF32LittleEndianStringEncoding];
}

/// Stable string key for the subset of Anitomy categories we map to Swift.
/// Names mirror the classic Anitomy element vocabulary (ADR-0006). Categories
/// outside this set are intentionally dropped.
NSString *_Nullable keyForCategory(anitomy::ElementCategory category) {
    switch (category) {
        case anitomy::kElementAnimeTitle:      return @"anime_title";
        case anitomy::kElementEpisodeNumber:   return @"episode_number";
        case anitomy::kElementAnimeSeason:     return @"anime_season";
        case anitomy::kElementAnimeYear:       return @"anime_year";
        case anitomy::kElementVideoResolution: return @"video_resolution";
        case anitomy::kElementReleaseGroup:    return @"release_group";
        case anitomy::kElementEpisodeTitle:    return @"episode_title";
        case anitomy::kElementAnimeType:       return @"anime_type";
        case anitomy::kElementFileExtension:   return @"file_extension";
        default:                               return nil;
    }
}

}  // namespace

@implementation ANTParser

+ (nullable NSDictionary<NSString *, NSString *> *)parse:(NSString *)filename {
    anitomy::Anitomy parser;
    // Ignore the bool result: even when Parse() bails (e.g. the tokenizer/parser
    // can't fully resolve a CJK-titled bracketed name) it still populates the
    // elements it did recognize. Harvest whatever is there; Swift's
    // FilenameParser (Issue 03) decides how to fall back.
    parser.Parse(toWString(filename));

    const anitomy::Elements &elements = parser.elements();
    if (elements.empty()) {
        return nil;
    }

    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    // Iterate in element order; keep the first value seen per key (episode
    // ranges etc. can emit a category more than once).
    for (const auto &pair : elements) {
        NSString *key = keyForCategory(pair.first);
        if (key == nil || result[key] != nil) {
            continue;
        }
        result[key] = fromWString(pair.second);
    }

    return result.count > 0 ? [result copy] : nil;
}

@end
