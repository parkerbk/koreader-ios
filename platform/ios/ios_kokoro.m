/* The Kokoro voices for ios_tts.m, which owns the queue of sentences.
 *
 * Sentences are generated one at a time on a queue of their own and played
 * through AVAudioEngine, staying ahead of playback so long ones don't leave a
 * gap. Everything else stays on the main thread. The model is too big to ship
 * in the app, so it's downloaded on request.
 *
 * The engine isn't built for the simulator: the download works there, but the
 * voices fall back to the system one. */

#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <Foundation/Foundation.h>

#include <TargetConditionals.h>
#include <bzlib.h>
#if !TARGET_OS_SIMULATOR
#include "sherpa-onnx/c-api/c-api.h"
#endif

#include "ios_kokoro.h"

typedef enum {
    KO_KOKORO_MISSING = 0,
    KO_KOKORO_DOWNLOADING = 1,
    KO_KOKORO_UNPACKING = 2,
    KO_KOKORO_READY = 3,
    KO_KOKORO_FAILED = 4,
} ko_kokoro_status_t;

static NSString *const KO_KOKORO_URL =
    @"https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-int8-en-v0_19.tar.bz2";
static NSString *const KO_KOKORO_SHA256 = @"c9f0dd393615805b0bab050c340834d5e684e732aec91c0e860cd30e982c08bd";
static NSString *const KO_KOKORO_SESSION = @"com.bparker2003.koreaderios.kokoro";

static const double KO_KOKORO_SAMPLE_RATE = 24000;
/* Long sentences take many seconds to generate, so go well past the next one. */
static const double KO_KOKORO_AHEAD_S = 20;
static const double KO_KOKORO_TICK_S = 0.5;
static const int KO_KOKORO_THREADS = 2;
enum { KO_TAR_BLOCK = 512 };

static dispatch_queue_t g_generate_queue = nil;
static void *g_model = NULL; /* Only touched on g_generate_queue. */

static AVAudioEngine *g_audio = nil;
static AVAudioPlayerNode *g_player = nil;
static AVAudioFormat *g_format = nil;
static bool g_active = false;
static bool g_generating = false;
/* Turns over on every start and stop, so late callbacks can tell they're stale. */
static int g_token = 0;
static int g_voice = 0;
static float g_speed = 1;
static NSUInteger g_sentences_scheduled = 0;
static int64_t g_samples_scheduled = 0;

static volatile ko_kokoro_status_t g_download_status = KO_KOKORO_MISSING;
static volatile float g_download_progress = 0;
static NSURLSession *g_session = nil;

static NSString *ko_kokoro_dir(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)[0];
    return [support stringByAppendingPathComponent:@"kokoro"];
}

bool ko_kokoro_installed(void) {
    return [NSFileManager.defaultManager fileExistsAtPath:ko_kokoro_dir()];
}

#if TARGET_OS_SIMULATOR

static void *ko_kokoro_create_model(void) {
    return NULL;
}

static AVAudioPCMBuffer *ko_kokoro_generate(void *model, NSString *text, int voice, float speed) {
    return nil;
}

static void ko_kokoro_destroy_model(void *model) {}

#else

static void *ko_kokoro_create_model(void) {
    NSString *dir = ko_kokoro_dir();
    SherpaOnnxOfflineTtsConfig config;
    memset(&config, 0, sizeof(config));
    config.model.kokoro.model = [dir stringByAppendingPathComponent:@"model.int8.onnx"].fileSystemRepresentation;
    config.model.kokoro.voices = [dir stringByAppendingPathComponent:@"voices.bin"].fileSystemRepresentation;
    config.model.kokoro.tokens = [dir stringByAppendingPathComponent:@"tokens.txt"].fileSystemRepresentation;
    config.model.kokoro.data_dir = [dir stringByAppendingPathComponent:@"espeak-ng-data"].fileSystemRepresentation;
    config.model.kokoro.length_scale = 1.0f;
    config.model.num_threads = KO_KOKORO_THREADS;
    config.model.provider = "cpu";
    config.max_num_sentences = 1;
    return (void *)SherpaOnnxCreateOfflineTts(&config);
}

/* A sentence can come out empty, and still has to count as played. */
static AVAudioPCMBuffer *ko_kokoro_generate(void *model, NSString *text, int voice, float speed) {
    const SherpaOnnxGeneratedAudio *audio =
        SherpaOnnxOfflineTtsGenerate((const SherpaOnnxOfflineTts *)model, text.UTF8String, voice, speed);
    AVAudioFrameCount frames = audio ? (AVAudioFrameCount)MAX(audio->n, 1) : 1;
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:g_format frameCapacity:frames];
    buffer.frameLength = frames;
    memset(buffer.floatChannelData[0], 0, frames * sizeof(float));
    if (audio) {
        memcpy(buffer.floatChannelData[0], audio->samples, audio->n * sizeof(float));
        SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
    }
    return buffer;
}

static void ko_kokoro_destroy_model(void *model) {
    SherpaOnnxDestroyOfflineTts((const SherpaOnnxOfflineTts *)model);
}

#endif

/* Seconds of audio scheduled and not yet heard. */
static double ko_kokoro_seconds_ahead(void) {
    AVAudioTime *time = g_player.lastRenderTime;
    AVAudioTime *player_time = time ? [g_player playerTimeForNodeTime:time] : nil;
    int64_t played = player_time ? player_time.sampleTime : 0;
    return (g_samples_scheduled - played) / KO_KOKORO_SAMPLE_RATE;
}

static void ko_kokoro_pump(void);

static void ko_kokoro_schedule(AVAudioPCMBuffer *buffer) {
    int token = g_token;
    g_sentences_scheduled++;
    g_samples_scheduled += buffer.frameLength;
    [g_player scheduleBuffer:buffer
        completionCallbackType:AVAudioPlayerNodeCompletionDataPlayedBack
             completionHandler:^(AVAudioPlayerNodeCompletionCallbackType type) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token == g_token) {
                g_sentences_scheduled--;
                ko_tts_kokoro_sentence_done();
                ko_kokoro_pump();
            }
        });
    }];
}

static void ko_kokoro_pump(void) {
    if (!g_active || g_generating || ko_kokoro_seconds_ahead() >= KO_KOKORO_AHEAD_S) {
        return;
    }
    NSString *text = ko_tts_text_at(g_sentences_scheduled);
    if (!text) {
        return;
    }
    g_generating = true;
    int token = g_token;
    int voice = g_voice;
    float speed = g_speed;
    dispatch_async(g_generate_queue, ^{
        if (!g_model) {
            g_model = ko_kokoro_create_model();
        }
        AVAudioPCMBuffer *buffer = g_model ? ko_kokoro_generate(g_model, text, voice, speed) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (token != g_token) {
                return;
            }
            g_generating = false;
            if (buffer) {
                ko_kokoro_schedule(buffer);
                ko_kokoro_pump();
            } else {
                ko_tts_kokoro_failed();
            }
        });
    });
}

static void ko_kokoro_tick(int token) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KO_KOKORO_TICK_S * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token == g_token) {
            ko_kokoro_pump();
            ko_kokoro_tick(token);
        }
    });
}

/* Drops everything scheduled, leaving the engine as it is. */
static void ko_kokoro_halt(void) {
    g_token++;
    g_active = false;
    g_generating = false;
    g_sentences_scheduled = 0;
    g_samples_scheduled = 0;
    [g_player stop];
}

static void ko_kokoro_setup(void) {
    if (g_audio) {
        return;
    }
    g_generate_queue = dispatch_queue_create("koreader.kokoro", DISPATCH_QUEUE_SERIAL);
    g_format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:KO_KOKORO_SAMPLE_RATE channels:1];
    g_audio = [[AVAudioEngine alloc] init];
    g_player = [[AVAudioPlayerNode alloc] init];
    [g_audio attachNode:g_player];
    [g_audio connect:g_player to:g_audio.mainMixerNode format:g_format];
    /* New headphones and the like stop the engine, with nothing else to say so. */
    [NSNotificationCenter.defaultCenter addObserverForName:AVAudioEngineConfigurationChangeNotification
                                                    object:g_audio
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        if (g_active) {
            ko_tts_kokoro_restart();
        }
    }];
}

/* Plays from the current sentence of ios_tts.m's queue. */
void ko_kokoro_start(int voice, float speed) {
    ko_kokoro_setup();
    ko_kokoro_halt();
    g_voice = voice;
    g_speed = speed;
    if (!g_audio.isRunning && ![g_audio startAndReturnError:nil]) {
        ko_tts_kokoro_failed();
        return;
    }
    g_active = true;
    [g_player play];
    ko_kokoro_pump();
    ko_kokoro_tick(g_token);
}

void ko_kokoro_pause(void) {
    [g_player pause];
}

/* False if the engine has stopped since, as it does for a call. */
bool ko_kokoro_resume(void) {
    if (!g_audio.isRunning) {
        return false;
    }
    [g_player play];
    return true;
}

/* Also gives the model's memory back, which is most of what the app is using. */
void ko_kokoro_stop(void) {
    if (!g_audio) {
        return;
    }
    ko_kokoro_halt();
    [g_audio stop];
    dispatch_async(g_generate_queue, ^{
        if (g_model) {
            ko_kokoro_destroy_model(g_model);
            g_model = NULL;
        }
    });
}

static bool ko_kokoro_checksum_matches(NSString *path) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    for (;;) {
        @autoreleasepool {
            NSData *chunk = [file readDataOfLength:1 << 20];
            if (chunk.length == 0) {
                break;
            }
            CC_SHA256_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex isEqualToString:KO_KOKORO_SHA256];
}

static bool ko_bz_read(BZFILE *bz, void *out, size_t length) {
    int error = BZ_OK;
    size_t total = 0;
    while (total < length && error == BZ_OK) {
        total += (size_t)BZ2_bzRead(&error, bz, (char *)out + total, (int)(length - total));
    }
    return total == length;
}

/* Reads one file's data from the tar, writing it out unless out is NULL. */
static bool ko_tar_copy(BZFILE *bz, size_t size, FILE *out) {
    static char chunk[1 << 16];
    size_t padded = (size + KO_TAR_BLOCK - 1) / KO_TAR_BLOCK * KO_TAR_BLOCK;
    size_t left = padded;
    while (left > 0) {
        size_t length = MIN(left, sizeof(chunk));
        if (!ko_bz_read(bz, chunk, length)) {
            return false;
        }
        size_t written = padded - left;
        if (out && written < size && fwrite(chunk, 1, MIN(length, size - written), out) == 0) {
            return false;
        }
        left -= length;
    }
    return true;
}

/* The other languages' dictionaries take up 18 MB, and Kokoro's model is English. */
static bool ko_kokoro_wanted(NSString *name) {
    NSString *file = name.lastPathComponent;
    return ![file hasSuffix:@"_dict"] || [file isEqualToString:@"en_dict"];
}

static bool ko_kokoro_unpack(NSString *archive, NSString *dest) {
    NSFileManager *manager = NSFileManager.defaultManager;
    FILE *file = fopen(archive.fileSystemRepresentation, "rb");
    if (!file) {
        return false;
    }
    int error = BZ_OK;
    BZFILE *bz = BZ2_bzReadOpen(&error, file, 0, 0, NULL, 0);
    bool ok = error == BZ_OK;
    char header[KO_TAR_BLOCK];
    while (ok && ko_bz_read(bz, header, sizeof(header)) && header[0] != 0) {
        @autoreleasepool {
            char name_bytes[101] = {0};
            memcpy(name_bytes, header, 100);
            size_t size = strtoul(header + 124, NULL, 8);
            bool is_file = header[156] == '0' || header[156] == 0;
            /* Every entry is under the archive's one top-level directory. */
            NSArray<NSString *> *parts = [@(name_bytes) pathComponents];
            NSString *name = parts.count > 1
                ? [NSString pathWithComponents:[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]] : @"";
            FILE *out = NULL;
            if (is_file && name.length && ko_kokoro_wanted(name)) {
                NSString *path = [dest stringByAppendingPathComponent:name];
                [manager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                   withIntermediateDirectories:YES attributes:nil error:nil];
                out = fopen(path.fileSystemRepresentation, "wb");
                ok = out != NULL;
            }
            ok = ok && ko_tar_copy(bz, size, out);
            if (out) {
                fclose(out);
            }
        }
    }
    BZ2_bzReadClose(&error, bz);
    fclose(file);
    return ok;
}

static void ko_kokoro_install(NSString *archive) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *dir = ko_kokoro_dir();
    NSString *partial = [dir stringByAppendingString:@".partial"];
    [manager removeItemAtPath:partial error:nil];
    [manager createDirectoryAtPath:partial withIntermediateDirectories:YES attributes:nil error:nil];
    bool ok = ko_kokoro_checksum_matches(archive) && ko_kokoro_unpack(archive, partial);
    [manager removeItemAtPath:archive error:nil];
    /* The rename is what makes it count as installed, so half a copy never does. */
    ok = ok && [manager moveItemAtPath:partial toPath:dir error:nil];
    if (ok) {
        NSURL *url = [NSURL fileURLWithPath:dir];
        [url setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    } else {
        [manager removeItemAtPath:partial error:nil];
    }
    g_download_status = ok ? KO_KOKORO_READY : KO_KOKORO_FAILED;
}

@interface KOKokoroDownload : NSObject <NSURLSessionDownloadDelegate>
@end

@implementation KOKokoroDownload

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)task
                 didWriteData:(int64_t)written
            totalBytesWritten:(int64_t)total
    totalBytesExpectedToWrite:(int64_t)expected {
    if (expected > 0) {
        g_download_progress = (float)total / (float)expected;
    }
}

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)task
    didFinishDownloadingToURL:(NSURL *)location {
    /* The file goes away when this returns. */
    NSString *archive = [ko_kokoro_dir() stringByAppendingString:@".tar.bz2"];
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager createDirectoryAtPath:archive.stringByDeletingLastPathComponent
       withIntermediateDirectories:YES attributes:nil error:nil];
    [manager removeItemAtPath:archive error:nil];
    if (![manager moveItemAtPath:location.path toPath:archive error:nil]) {
        g_download_status = KO_KOKORO_FAILED;
        return;
    }
    g_download_status = KO_KOKORO_UNPACKING;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        ko_kokoro_install(archive);
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        g_download_status = KO_KOKORO_FAILED;
    }
}

@end

void ko_ios_kokoro_download(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_download_status == KO_KOKORO_DOWNLOADING || g_download_status == KO_KOKORO_UNPACKING) {
            return;
        }
        if (!g_session) {
            /* A background session, so locking the phone doesn't lose the download. */
            NSURLSessionConfiguration *config =
                [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:KO_KOKORO_SESSION];
            g_session = [NSURLSession sessionWithConfiguration:config
                                                      delegate:[[KOKokoroDownload alloc] init]
                                                 delegateQueue:nil];
        }
        g_download_status = KO_KOKORO_DOWNLOADING;
        g_download_progress = 0;
        [[g_session downloadTaskWithURL:[NSURL URLWithString:KO_KOKORO_URL]] resume];
    });
}

int ko_ios_kokoro_status(float *progress) {
    *progress = g_download_progress;
    if (g_download_status == KO_KOKORO_MISSING || g_download_status == KO_KOKORO_READY) {
        return ko_kokoro_installed() ? KO_KOKORO_READY : KO_KOKORO_MISSING;
    }
    return g_download_status;
}

void ko_ios_kokoro_delete(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSFileManager.defaultManager removeItemAtPath:ko_kokoro_dir() error:nil];
        g_download_status = KO_KOKORO_MISSING;
    });
}
