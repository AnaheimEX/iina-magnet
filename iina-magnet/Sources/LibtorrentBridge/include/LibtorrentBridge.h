//
//  LibtorrentBridge.h
//  LibtorrentBridge
//
//  Obj-C-only public surface of the libtorrent Rasterbar wrapper.
//  Implementations live in LibtorrentBridge.mm (Obj-C++) which includes
//  <libtorrent/...> headers; consumers only see Foundation types here.
//
//  This wrapper is intentionally narrow — only the APIs the TorrentManager
//  Swift actor (Issue 06) needs. New methods land here when a Phase 1
//  feature requires them.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Enums

typedef NS_ENUM(NSInteger, LMEncryptionPolicy) {
    LMEncryptionPolicyForced     = 0,  ///< Refuse plaintext peers
    LMEncryptionPolicyPreferred  = 1,  ///< Prefer encryption but fall back
    LMEncryptionPolicyDisabled   = 2,  ///< Plaintext only
};

typedef NS_ENUM(NSInteger, LMTaskState) {
    LMTaskStateResolving    = 0,  ///< Fetching torrent metadata via magnet
    LMTaskStateDownloading  = 1,
    LMTaskStatePaused       = 2,
    LMTaskStateSeeding      = 3,
    LMTaskStateCompleted    = 4,
    LMTaskStateFailed       = 5,
    LMTaskStateRemoved      = 6,
};

typedef NS_ENUM(NSInteger, LMAlertType) {
    LMAlertTypeMetadataReceived   = 0,  ///< extraInt = -1
    LMAlertTypePieceFinished      = 1,  ///< extraInt = piece index
    LMAlertTypeFileCompleted      = 2,  ///< extraInt = file index
    LMAlertTypeTorrentFinished    = 3,
    LMAlertTypeTorrentError       = 4,
    LMAlertTypeSaveResumeData     = 5,
    LMAlertTypeOther              = 99,
};

// MARK: - Value types

@interface LMSessionSettings : NSObject
@property (nonatomic)               int                  listenPort;        ///< 0 = OS-assigned
@property (nonatomic)               BOOL                 enableDHT;
@property (nonatomic)               BOOL                 enablePEX;
@property (nonatomic)               BOOL                 enableLSD;
@property (nonatomic)               BOOL                 enableUPnP;
@property (nonatomic)               LMEncryptionPolicy   encryptionPolicy;
@property (nonatomic)               int                  uploadRateLimit;   ///< bytes/sec; 0 = unlimited
@property (nonatomic)               int                  downloadRateLimit;
@property (nonatomic)               int                  maxConnections;    ///< 0 = libtorrent default

+ (instancetype)defaultSettings;
@end

@interface LMTorrentStatus : NSObject
@property (nonatomic, readonly)     NSString            *name;
@property (nonatomic, readonly)     NSString            *infoHash;
@property (nonatomic, readonly)     int64_t              totalSize;
@property (nonatomic, readonly)     int64_t              downloadedBytes;
@property (nonatomic, readonly)     int64_t              uploadedBytes;
@property (nonatomic, readonly)     int                  numPeers;
@property (nonatomic, readonly)     int                  numSeeds;
@property (nonatomic, readonly)     LMTaskState          state;
@property (nonatomic, readonly)     int                  downloadRate;     ///< bytes/sec
@property (nonatomic, readonly)     int                  uploadRate;       ///< bytes/sec
@property (nonatomic, readonly)     double               progress;         ///< 0.0 - 1.0
@property (nonatomic, readonly)     NSData              *pieces;           ///< bitfield: 1 byte per piece (0 / 1)
@property (nonatomic, readonly)     int                  numPieces;
@property (nonatomic, readonly)     int                  pieceLength;
@property (nonatomic, readonly)     BOOL                 hasMetadata;      ///< false while resolving magnet
@end

@interface LMAlert : NSObject
@property (nonatomic, readonly)              LMAlertType  type;
@property (nonatomic, readonly, nullable)    NSString    *infoHash;
@property (nonatomic, readonly)              NSString    *message;
@property (nonatomic, readonly)              NSDate      *timestamp;
@property (nonatomic, readonly)              int          extraInt;        ///< see LMAlertType doc-comments
@end

// MARK: - Session

@interface LMSession : NSObject

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithSettings:(LMSessionSettings *)settings NS_DESIGNATED_INITIALIZER;

/// Adds a magnet URI; returns its info-hash hex on success, nil on failure (with NSError if provided).
- (nullable NSString *)addMagnet:(NSString *)magnetURI
                        savePath:(NSString *)savePath
                           error:(NSError * _Nullable * _Nullable)error;

/// Adds a .torrent file (the raw bencoded bytes); returns its info-hash hex.
- (nullable NSString *)addTorrentFile:(NSData *)torrentData
                             savePath:(NSString *)savePath
                                error:(NSError * _Nullable * _Nullable)error;

- (void)pauseTorrent:(NSString *)infoHash;
- (void)resumeTorrent:(NSString *)infoHash;

/// Removes the torrent from the session; if deleteFiles is YES, also wipes the files on disk.
- (void)removeTorrent:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles;

/// Bumps a single piece's download priority. deadlineMs = 0 means "ASAP".
- (void)setPieceDeadline:(NSString *)infoHash piece:(int)piece deadlineMs:(int)deadlineMs;

/// Toggle sequential download (in-order pieces) for streaming.
- (void)setSequentialDownload:(NSString *)infoHash enabled:(BOOL)enabled;

/// Snapshot of a single torrent's status. Returns nil if infoHash is unknown.
- (nullable LMTorrentStatus *)statusOf:(NSString *)infoHash;

/// Snapshot of every torrent currently in the session.
- (NSArray<LMTorrentStatus *> *)allStatuses;

/// Drain pending alerts from libtorrent's internal queue.
/// Call this on a timer (e.g. every 50ms) from the actor that owns this session.
- (NSArray<LMAlert *> *)pumpAlerts;

@end

NS_ASSUME_NONNULL_END
