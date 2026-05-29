//
//  AnitomyBridge.h
//  AnitomyBridge
//
//  Minimal Obj-C surface over the vendored Anitomy C++ library (ADR-0006).
//  Only native types cross the boundary; no Anitomy/C++ types are exposed, so
//  Swift sees a plain Obj-C class.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ANTParser : NSObject

/// Parses an anime/video filename into Anitomy element fields.
///
/// Returns a dictionary keyed by Anitomy element names — `anime_title`,
/// `episode_number`, `anime_season`, `anime_year`, `video_resolution`,
/// `release_group`, `episode_title`, `anime_type`, `file_extension` — to their
/// string values. Keys are present only when Anitomy found that element.
/// Returns `nil` when parsing yields no elements at all.
+ (nullable NSDictionary<NSString *, NSString *> *)parse:(NSString *)filename;

@end

NS_ASSUME_NONNULL_END
