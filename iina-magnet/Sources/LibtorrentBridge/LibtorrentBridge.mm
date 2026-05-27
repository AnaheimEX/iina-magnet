//
//  LibtorrentBridge.mm
//  LibtorrentBridge
//
//  Obj-C++ implementation. Includes libtorrent C++ headers and translates
//  to/from the Foundation types declared in LibtorrentBridge.h.
//
//  Memory model:
//    - One libtorrent::session per LMSession instance.
//    - Torrent handles indexed by their info-hash hex string in
//      `_handlesByHash`. Pause/resume/remove/setPieceDeadline take that hex.
//    - Alerts are drained on demand via pumpAlerts; nothing pushed.

#import "LibtorrentBridge.h"

#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/alert.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/info_hash.hpp>
#include <libtorrent/sha1_hash.hpp>
#include <libtorrent/bitfield.hpp>
#include <libtorrent/load_torrent.hpp>
#include <libtorrent/write_resume_data.hpp>

#include <memory>
#include <string>
#include <unordered_map>
#include <vector>

namespace lt = libtorrent;

// MARK: - Hex helpers

namespace {

inline std::string toHexString(const unsigned char *data, std::size_t len) {
    static const char hexchars[] = "0123456789abcdef";
    std::string out(len * 2, '\0');
    for (std::size_t i = 0; i < len; ++i) {
        out[i * 2]     = hexchars[(data[i] >> 4) & 0xf];
        out[i * 2 + 1] = hexchars[data[i] & 0xf];
    }
    return out;
}

inline bool fromHexString(const std::string &hex, unsigned char *out, std::size_t len) {
    if (hex.size() != len * 2) return false;
    auto nibble = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    for (std::size_t i = 0; i < len; ++i) {
        int hi = nibble(hex[i * 2]);
        int lo = nibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return false;
        out[i] = static_cast<unsigned char>((hi << 4) | lo);
    }
    return true;
}

inline NSString *hexStringFromInfoHashes(const lt::info_hash_t &hashes) {
    // Prefer v1 (universal in classic BT); fall back to v2 when v1 absent.
    if (hashes.has_v1()) {
        return [NSString stringWithUTF8String:
                toHexString(reinterpret_cast<const unsigned char*>(hashes.v1.data()), 20).c_str()];
    }
    if (hashes.has_v2()) {
        return [NSString stringWithUTF8String:
                toHexString(reinterpret_cast<const unsigned char*>(hashes.v2.data()), 32).c_str()];
    }
    return nil;
}

} // anonymous namespace

// MARK: - LMSessionSettings

@implementation LMSessionSettings

+ (instancetype)defaultSettings {
    LMSessionSettings *s = [[LMSessionSettings alloc] init];
    s.listenPort = 0;
    s.enableDHT = YES;
    s.enablePEX = YES;
    s.enableLSD = YES;
    s.enableUPnP = NO;   // off by default — user must opt in (PRD US-44)
    s.encryptionPolicy = LMEncryptionPolicyForced;
    s.uploadRateLimit = 0;
    s.downloadRateLimit = 0;
    s.maxConnections = 0;
    return s;
}

@end

// MARK: - LMTorrentStatus

@interface LMTorrentStatus ()
@property (nonatomic, readwrite) NSString *name;
@property (nonatomic, readwrite) NSString *infoHash;
@property (nonatomic, readwrite) int64_t totalSize;
@property (nonatomic, readwrite) int64_t downloadedBytes;
@property (nonatomic, readwrite) int64_t uploadedBytes;
@property (nonatomic, readwrite) int numPeers;
@property (nonatomic, readwrite) int numSeeds;
@property (nonatomic, readwrite) LMTaskState state;
@property (nonatomic, readwrite) int downloadRate;
@property (nonatomic, readwrite) int uploadRate;
@property (nonatomic, readwrite) double progress;
@property (nonatomic, readwrite) NSData *pieces;
@property (nonatomic, readwrite) int numPieces;
@property (nonatomic, readwrite) int pieceLength;
@property (nonatomic, readwrite) BOOL hasMetadata;
@end

@implementation LMTorrentStatus
@end

// MARK: - LMAlert

@interface LMAlert ()
@property (nonatomic, readwrite) LMAlertType type;
@property (nonatomic, readwrite, nullable) NSString *infoHash;
@property (nonatomic, readwrite) NSString *message;
@property (nonatomic, readwrite) NSDate *timestamp;
@property (nonatomic, readwrite) int extraInt;
@end

@implementation LMAlert
@end

// MARK: - LMSession

@implementation LMSession {
    std::unique_ptr<lt::session> _session;
    std::unordered_map<std::string, lt::torrent_handle> _handlesByHash;
}

- (instancetype)initWithSettings:(LMSessionSettings *)settings {
    self = [super init];
    if (!self) return nil;

    lt::settings_pack pack;
    pack.set_str(lt::settings_pack::user_agent, "iina-magnet/0.1.0 libtorrent/2.0");

    // Listen interfaces: bind to all on the requested port (0 = any)
    char buf[64];
    std::snprintf(buf, sizeof(buf), "0.0.0.0:%d,[::]:%d",
                  settings.listenPort, settings.listenPort);
    pack.set_str(lt::settings_pack::listen_interfaces, buf);

    pack.set_bool(lt::settings_pack::enable_dht, settings.enableDHT);
    pack.set_bool(lt::settings_pack::enable_lsd, settings.enableLSD);
    pack.set_bool(lt::settings_pack::enable_upnp, settings.enableUPnP);
    pack.set_bool(lt::settings_pack::enable_natpmp, settings.enableUPnP);

    int outPolicy = lt::settings_pack::pe_forced;
    int inPolicy  = lt::settings_pack::pe_forced;
    int crypto    = lt::settings_pack::pe_both;
    switch (settings.encryptionPolicy) {
        case LMEncryptionPolicyForced:
            outPolicy = inPolicy = lt::settings_pack::pe_forced;
            crypto = lt::settings_pack::pe_rc4;
            break;
        case LMEncryptionPolicyPreferred:
            outPolicy = inPolicy = lt::settings_pack::pe_enabled;
            crypto = lt::settings_pack::pe_both;
            break;
        case LMEncryptionPolicyDisabled:
            outPolicy = inPolicy = lt::settings_pack::pe_disabled;
            crypto = lt::settings_pack::pe_plaintext;
            break;
    }
    pack.set_int(lt::settings_pack::out_enc_policy, outPolicy);
    pack.set_int(lt::settings_pack::in_enc_policy, inPolicy);
    pack.set_int(lt::settings_pack::allowed_enc_level, crypto);

    if (settings.uploadRateLimit > 0)
        pack.set_int(lt::settings_pack::upload_rate_limit, settings.uploadRateLimit);
    if (settings.downloadRateLimit > 0)
        pack.set_int(lt::settings_pack::download_rate_limit, settings.downloadRateLimit);
    if (settings.maxConnections > 0)
        pack.set_int(lt::settings_pack::connections_limit, settings.maxConnections);

    // Alerts: enable categories we'll consume
    pack.set_int(lt::settings_pack::alert_mask,
                 lt::alert_category::status
                 | lt::alert_category::piece_progress
                 | lt::alert_category::file_progress
                 | lt::alert_category::error
                 | lt::alert_category::storage);

    // Do NOT enable PEX through settings_pack (need session_flags); for now PEX is via session extensions.
    _session = std::make_unique<lt::session>(std::move(pack));

    // PEX extension
    if (settings.enablePEX) {
        // PEX is built-in to libtorrent's default extensions in 2.x; nothing to add explicitly.
    }
    return self;
}

- (void)dealloc {
    if (_session) {
        _session->pause();
    }
}

// MARK: Adding torrents

- (nullable NSString *)addMagnet:(NSString *)magnetURI
                        savePath:(NSString *)savePath
                           error:(NSError * _Nullable * _Nullable)error
{
    lt::error_code ec;
    lt::add_torrent_params atp = lt::parse_magnet_uri([magnetURI UTF8String], ec);
    if (ec) {
        if (error) *error = [NSError errorWithDomain:@"LibtorrentBridge"
                                                code:ec.value()
                                            userInfo:@{ NSLocalizedDescriptionKey: @(ec.message().c_str()) }];
        return nil;
    }
    atp.save_path = [savePath UTF8String];
    atp.flags |= lt::torrent_flags::auto_managed;

    lt::torrent_handle handle = _session->add_torrent(std::move(atp), ec);
    if (ec || !handle.is_valid()) {
        if (error) *error = [NSError errorWithDomain:@"LibtorrentBridge"
                                                code:ec ? ec.value() : -1
                                            userInfo:@{ NSLocalizedDescriptionKey: ec ? @(ec.message().c_str()) : @"invalid handle" }];
        return nil;
    }
    NSString *hex = hexStringFromInfoHashes(handle.info_hashes());
    if (hex) {
        _handlesByHash[[hex UTF8String]] = handle;
    }
    return hex;
}

- (nullable NSString *)addTorrentFile:(NSData *)torrentData
                             savePath:(NSString *)savePath
                                error:(NSError * _Nullable * _Nullable)error
{
    lt::error_code ec;
    auto info = std::make_shared<lt::torrent_info>(static_cast<const char*>(torrentData.bytes),
                                                   static_cast<int>(torrentData.length),
                                                   ec);
    if (ec) {
        if (error) *error = [NSError errorWithDomain:@"LibtorrentBridge"
                                                code:ec.value()
                                            userInfo:@{ NSLocalizedDescriptionKey: @(ec.message().c_str()) }];
        return nil;
    }
    lt::add_torrent_params atp;
    atp.ti = info;
    atp.save_path = [savePath UTF8String];
    atp.flags |= lt::torrent_flags::auto_managed;

    lt::torrent_handle handle = _session->add_torrent(std::move(atp), ec);
    if (ec || !handle.is_valid()) {
        if (error) *error = [NSError errorWithDomain:@"LibtorrentBridge"
                                                code:ec ? ec.value() : -1
                                            userInfo:@{ NSLocalizedDescriptionKey: ec ? @(ec.message().c_str()) : @"invalid handle" }];
        return nil;
    }
    NSString *hex = hexStringFromInfoHashes(handle.info_hashes());
    if (hex) {
        _handlesByHash[[hex UTF8String]] = handle;
    }
    return hex;
}

// MARK: Control

- (void)pauseTorrent:(NSString *)infoHash {
    auto it = _handlesByHash.find([infoHash UTF8String]);
    if (it != _handlesByHash.end()) it->second.pause();
}

- (void)resumeTorrent:(NSString *)infoHash {
    auto it = _handlesByHash.find([infoHash UTF8String]);
    if (it != _handlesByHash.end()) it->second.resume();
}

- (void)removeTorrent:(NSString *)infoHash deleteFiles:(BOOL)deleteFiles {
    auto it = _handlesByHash.find([infoHash UTF8String]);
    if (it == _handlesByHash.end()) return;
    _session->remove_torrent(it->second,
                             deleteFiles ? lt::session::delete_files : lt::remove_flags_t{});
    _handlesByHash.erase(it);
}

- (void)setPieceDeadline:(NSString *)infoHash piece:(int)piece deadlineMs:(int)deadlineMs {
    auto it = _handlesByHash.find([infoHash UTF8String]);
    if (it != _handlesByHash.end()) {
        it->second.set_piece_deadline(lt::piece_index_t(piece), deadlineMs);
    }
}

- (void)setSequentialDownload:(NSString *)infoHash enabled:(BOOL)enabled {
    auto it = _handlesByHash.find([infoHash UTF8String]);
    if (it == _handlesByHash.end()) return;
    if (enabled) {
        it->second.set_flags(lt::torrent_flags::sequential_download);
    } else {
        it->second.unset_flags(lt::torrent_flags::sequential_download);
    }
}

// MARK: Status snapshot

static LMTaskState mapState(const lt::torrent_status &st) {
    if ((st.flags & lt::torrent_flags::paused) == lt::torrent_flags::paused) return LMTaskStatePaused;
    switch (st.state) {
        case lt::torrent_status::downloading_metadata:
        case lt::torrent_status::checking_files:
        case lt::torrent_status::checking_resume_data:
            return LMTaskStateResolving;
        case lt::torrent_status::downloading:
            return LMTaskStateDownloading;
        case lt::torrent_status::finished:
            return LMTaskStateCompleted;
        case lt::torrent_status::seeding:
            return LMTaskStateSeeding;
        default:
            return LMTaskStateDownloading;
    }
}

static LMTorrentStatus *makeStatus(const lt::torrent_status &st) {
    LMTorrentStatus *s = [[LMTorrentStatus alloc] init];
    s.name = [NSString stringWithUTF8String:st.name.c_str()];
    s.infoHash = hexStringFromInfoHashes(st.info_hashes) ?: @"";
    s.totalSize = st.total_wanted;
    s.downloadedBytes = st.total_wanted_done;
    s.uploadedBytes = st.total_payload_upload;
    s.numPeers = st.num_peers;
    s.numSeeds = st.num_seeds;
    s.state = mapState(st);
    s.downloadRate = st.download_payload_rate;
    s.uploadRate = st.upload_payload_rate;
    s.progress = st.progress;
    s.hasMetadata = static_cast<bool>(st.has_metadata);

    s.numPieces = st.pieces.size();
    if (st.pieces.size() > 0) {
        NSMutableData *bits = [NSMutableData dataWithLength:st.pieces.size()];
        unsigned char *bytes = static_cast<unsigned char*>(bits.mutableBytes);
        for (int i = 0; i < st.pieces.size(); ++i) {
            bytes[i] = st.pieces.get_bit(lt::piece_index_t(i)) ? 1 : 0;
        }
        s.pieces = bits;
    } else {
        s.pieces = [NSData data];
    }

    // piece_length from torrent_info if available
    if (auto ti = st.torrent_file.lock()) {
        s.pieceLength = ti->piece_length();
    } else {
        s.pieceLength = 0;
    }
    return s;
}

- (nullable LMTorrentStatus *)statusOf:(NSString *)infoHash {
    auto it = _handlesByHash.find([infoHash UTF8String]);
    if (it == _handlesByHash.end()) return nil;
    return makeStatus(it->second.status());
}

- (NSArray<LMTorrentStatus *> *)allStatuses {
    NSMutableArray *arr = [NSMutableArray array];
    for (const auto &kv : _handlesByHash) {
        if (!kv.second.is_valid()) continue;
        [arr addObject:makeStatus(kv.second.status())];
    }
    return arr;
}

// MARK: Alerts

- (NSArray<LMAlert *> *)pumpAlerts {
    std::vector<lt::alert*> pending;
    _session->pop_alerts(&pending);
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:pending.size()];

    for (lt::alert *a : pending) {
        LMAlert *m = [[LMAlert alloc] init];
        m.message = [NSString stringWithUTF8String:a->message().c_str()];
        m.timestamp = [NSDate date];
        m.extraInt = -1;
        m.type = LMAlertTypeOther;

        if (auto *t = lt::alert_cast<lt::metadata_received_alert>(a)) {
            m.type = LMAlertTypeMetadataReceived;
            m.infoHash = hexStringFromInfoHashes(t->handle.info_hashes());
        } else if (auto *p = lt::alert_cast<lt::piece_finished_alert>(a)) {
            m.type = LMAlertTypePieceFinished;
            m.infoHash = hexStringFromInfoHashes(p->handle.info_hashes());
            m.extraInt = static_cast<int>(p->piece_index);
        } else if (auto *f = lt::alert_cast<lt::file_completed_alert>(a)) {
            m.type = LMAlertTypeFileCompleted;
            m.infoHash = hexStringFromInfoHashes(f->handle.info_hashes());
            m.extraInt = static_cast<int>(f->index);
        } else if (auto *finished = lt::alert_cast<lt::torrent_finished_alert>(a)) {
            m.type = LMAlertTypeTorrentFinished;
            m.infoHash = hexStringFromInfoHashes(finished->handle.info_hashes());
        } else if (auto *err = lt::alert_cast<lt::torrent_error_alert>(a)) {
            m.type = LMAlertTypeTorrentError;
            m.infoHash = hexStringFromInfoHashes(err->handle.info_hashes());
        } else if (auto *resume = lt::alert_cast<lt::save_resume_data_alert>(a)) {
            m.type = LMAlertTypeSaveResumeData;
            m.infoHash = hexStringFromInfoHashes(resume->handle.info_hashes());
        }
        [out addObject:m];
    }
    return out;
}

@end
