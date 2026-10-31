/* Reads the book aloud for plugins/readaloud.koplugin.
 *
 * Lua walks the book and queues sentences here ahead of time, because it can't
 * be relied on to run while the app is in the background. Everything from then
 * on happens in native code, and Lua polls for the current sentence when it can.
 * As with the other bridges, callbacks never touch Lua. */

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>

typedef enum {
    KO_TTS_IDLE = 0,
    KO_TTS_SPEAKING = 1,
    KO_TTS_PAUSED = 2,
} ko_tts_state_t;

static NSString *const KOTTSBookKey = @"KOTTSBook";
static NSString *const KOTTSPositionKey = @"KOTTSPosition";

@interface KOSpeechItem : NSObject
@property(nonatomic) int itemId;
@property(nonatomic, copy) NSString *text;
@property(nonatomic, copy) NSString *position;
@end

@implementation KOSpeechItem
@end

static volatile ko_tts_state_t g_state = KO_TTS_IDLE;
static volatile int g_current_id = 0;
static volatile bool g_foreground = true;

static AVSpeechSynthesizer *g_synth = nil;
static id g_tts_delegate = nil;
static AVSpeechUtterance *g_utterance = nil;
static NSMutableArray<KOSpeechItem *> *g_queue = nil;
static NSUInteger g_index = 0;
static bool g_queue_complete = false;
static bool g_waiting_for_text = false;
static bool g_resume_after_interruption = false;
static float g_rate = 0.5f;
static NSString *g_voice_id = nil;
static AVSpeechSynthesisVoice *g_voice = nil;
static NSString *g_language = nil;
static NSString *g_book = nil;
static NSString *g_title = nil;
static NSString *g_author = nil;

static void ko_tts_speak_current(void);
static void ko_tts_stop(void);

/* iOS's own pick for a language is usually its basic voice, even with a better
 * one installed, so rank them: quality first, then the closest language. */
static AVSpeechSynthesisVoice *ko_tts_best_voice(void) {
    NSString *system_language = AVSpeechSynthesisVoice.currentLanguageCode;
    NSString *language = g_language.length ? g_language : system_language;
    NSString *prefix = [language substringToIndex:MIN((NSUInteger)2, language.length)].lowercaseString;
    AVSpeechSynthesisVoice *best = nil;
    NSInteger best_score = -1;
    for (AVSpeechSynthesisVoice *voice in AVSpeechSynthesisVoice.speechVoices) {
        /* The older identifiers are the novelty voices, such as Bubbles. */
        if ([voice.identifier containsString:@"speech.synthesis.voice"]
            || ![voice.language.lowercaseString hasPrefix:prefix]) {
            continue;
        }
        NSInteger score = voice.quality * 4;
        if ([voice.language isEqualToString:language]) {
            score += 2;
        }
        if ([voice.language isEqualToString:system_language]) {
            score += 1;
        }
        if (score > best_score) {
            best = voice;
            best_score = score;
        }
    }
    return best;
}

static AVSpeechSynthesisVoice *ko_tts_voice(void) {
    if (!g_voice) {
        if (g_voice_id.length) {
            g_voice = [AVSpeechSynthesisVoice voiceWithIdentifier:g_voice_id];
        }
        if (!g_voice) {
            g_voice = ko_tts_best_voice();
        }
    }
    return g_voice;
}

static void ko_tts_update_now_playing(void) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    if (g_title.length) {
        info[MPMediaItemPropertyTitle] = g_title;
    }
    if (g_author.length) {
        info[MPMediaItemPropertyArtist] = g_author;
    }
    info[MPNowPlayingInfoPropertyPlaybackRate] = @(g_state == KO_TTS_SPEAKING ? 1.0 : 0.0);
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = info;
}

static void ko_tts_set_state(ko_tts_state_t state) {
    g_state = state;
    ko_tts_update_now_playing();
}

static void ko_tts_save_position(KOSpeechItem *item) {
    /* Written as each sentence starts, so a kill in the background loses little. */
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:g_book forKey:KOTTSBookKey];
    [defaults setObject:item.position forKey:KOTTSPositionKey];
}

static void ko_tts_speak_current(void) {
    if (g_index >= g_queue.count) {
        if (g_queue_complete) {
            ko_tts_stop();
        } else {
            g_waiting_for_text = true;
        }
        return;
    }
    g_waiting_for_text = false;
    KOSpeechItem *item = g_queue[g_index];
    g_current_id = item.itemId;
    ko_tts_save_position(item);
    AVSpeechUtterance *utterance = [AVSpeechUtterance speechUtteranceWithString:item.text];
    utterance.rate = g_rate;
    utterance.voice = ko_tts_voice();
    g_utterance = utterance;
    [g_synth speakUtterance:utterance];
}

/* Starts the current sentence over, which also applies a new rate or voice. */
static void ko_tts_restart_current(void) {
    g_utterance = nil;
    [g_synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    ko_tts_speak_current();
}

static void ko_tts_pause(void) {
    if (g_state == KO_TTS_SPEAKING) {
        [g_synth pauseSpeakingAtBoundary:AVSpeechBoundaryImmediate];
        ko_tts_set_state(KO_TTS_PAUSED);
    }
}

static void ko_tts_resume(void) {
    if (g_state != KO_TTS_PAUSED) {
        return;
    }
    [AVAudioSession.sharedInstance setActive:YES error:nil];
    ko_tts_set_state(KO_TTS_SPEAKING);
    if (g_synth.paused) {
        [g_synth continueSpeaking];
    } else {
        ko_tts_restart_current();
    }
}

static void ko_tts_seek(NSInteger delta) {
    if (g_state == KO_TTS_IDLE || g_queue.count == 0) {
        return;
    }
    NSInteger index = (NSInteger)g_index + delta;
    g_index = (NSUInteger)MAX(0, MIN(index, (NSInteger)g_queue.count - 1));
    ko_tts_set_state(KO_TTS_SPEAKING);
    ko_tts_restart_current();
}

static void ko_tts_stop(void) {
    g_utterance = nil;
    [g_synth stopSpeakingAtBoundary:AVSpeechBoundaryImmediate];
    [g_queue removeAllObjects];
    g_index = 0;
    g_current_id = 0;
    g_queue_complete = false;
    g_waiting_for_text = false;
    g_resume_after_interruption = false;
    g_state = KO_TTS_IDLE;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = nil;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults removeObjectForKey:KOTTSBookKey];
    [defaults removeObjectForKey:KOTTSPositionKey];
    [AVAudioSession.sharedInstance setActive:NO
                                 withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                       error:nil];
}

@interface KOTTSDelegate : NSObject <AVSpeechSynthesizerDelegate>
@end

@implementation KOTTSDelegate

- (void)speechSynthesizer:(AVSpeechSynthesizer *)synthesizer didFinishSpeechUtterance:(AVSpeechUtterance *)utterance {
    if (utterance != g_utterance) {
        return;
    }
    g_index++;
    ko_tts_speak_current();
}

- (void)interrupted:(NSNotification *)note {
    NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if (type == AVAudioSessionInterruptionTypeBegan) {
        g_resume_after_interruption = g_state == KO_TTS_SPEAKING;
        ko_tts_pause();
    } else if (g_resume_after_interruption) {
        g_resume_after_interruption = false;
        NSUInteger options = [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
        if (options & AVAudioSessionInterruptionOptionShouldResume) {
            ko_tts_resume();
        }
    }
}

- (void)routeChanged:(NSNotification *)note {
    /* Headphones came out: don't carry on over the speaker. */
    NSUInteger reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
        ko_tts_pause();
    }
}

- (void)didBecomeActive:(NSNotification *)note {
    g_foreground = true;
}

- (void)didEnterBackground:(NSNotification *)note {
    g_foreground = false;
}

@end

static void ko_tts_add_remote_command(MPRemoteCommand *command, void (^action)(void)) {
    [command addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
        if (g_state == KO_TTS_IDLE) {
            return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
        }
        action();
        return MPRemoteCommandHandlerStatusSuccess;
    }];
}

static void ko_tts_setup(void) {
    if (g_synth) {
        return;
    }
    g_queue = [NSMutableArray array];
    g_synth = [[AVSpeechSynthesizer alloc] init];
    g_tts_delegate = [[KOTTSDelegate alloc] init];
    g_synth.delegate = g_tts_delegate;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [center addObserver:g_tts_delegate selector:@selector(interrupted:)
                   name:AVAudioSessionInterruptionNotification object:session];
    [center addObserver:g_tts_delegate selector:@selector(routeChanged:)
                   name:AVAudioSessionRouteChangeNotification object:session];
    [center addObserver:g_tts_delegate selector:@selector(didBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:g_tts_delegate selector:@selector(didEnterBackground:)
                   name:UIApplicationDidEnterBackgroundNotification object:nil];

    MPRemoteCommandCenter *commands = MPRemoteCommandCenter.sharedCommandCenter;
    ko_tts_add_remote_command(commands.playCommand, ^{ ko_tts_resume(); });
    ko_tts_add_remote_command(commands.pauseCommand, ^{ ko_tts_pause(); });
    ko_tts_add_remote_command(commands.togglePlayPauseCommand, ^{
        if (g_state == KO_TTS_PAUSED) {
            ko_tts_resume();
        } else {
            ko_tts_pause();
        }
    });
    ko_tts_add_remote_command(commands.nextTrackCommand, ^{ ko_tts_seek(1); });
    ko_tts_add_remote_command(commands.previousTrackCommand, ^{ ko_tts_seek(-1); });
}

static NSString *ko_tts_string(const char *text) {
    return text ? [NSString stringWithUTF8String:text] : nil;
}

void ko_ios_tts_configure(const char *book, const char *title, const char *author) {
    NSString *book_string = ko_tts_string(book);
    NSString *title_string = ko_tts_string(title);
    NSString *author_string = ko_tts_string(author);
    dispatch_async(dispatch_get_main_queue(), ^{
        g_book = book_string;
        g_title = title_string;
        g_author = author_string;
    });
}

void ko_ios_tts_set_voice(const char *voice_id, const char *language) {
    NSString *voice_string = ko_tts_string(voice_id);
    NSString *language_string = ko_tts_string(language);
    dispatch_async(dispatch_get_main_queue(), ^{
        g_voice_id = voice_string;
        g_language = language_string;
        g_voice = nil;
        if (g_state == KO_TTS_SPEAKING) {
            ko_tts_restart_current();
        }
    });
}

void ko_ios_tts_set_rate(float rate) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_rate = rate;
        if (g_state == KO_TTS_SPEAKING) {
            ko_tts_restart_current();
        }
    });
}

void ko_ios_tts_enqueue(int item_id, const char *text, const char *position) {
    NSString *text_string = ko_tts_string(text);
    NSString *position_string = ko_tts_string(position);
    dispatch_async(dispatch_get_main_queue(), ^{
        KOSpeechItem *item = [[KOSpeechItem alloc] init];
        item.itemId = item_id;
        item.text = text_string;
        item.position = position_string;
        ko_tts_setup();
        [g_queue addObject:item];
        if (g_waiting_for_text) {
            ko_tts_speak_current();
        }
    });
}

/* There's no more text to come: finish once what's queued has been spoken. */
void ko_ios_tts_queue_complete(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_queue_complete = true;
        if (g_waiting_for_text) {
            ko_tts_speak_current();
        }
    });
}

void ko_ios_tts_start(void) {
    /* Set here rather than on the main queue, so the first poll sees it. */
    g_state = KO_TTS_SPEAKING;
    dispatch_async(dispatch_get_main_queue(), ^{
        ko_tts_setup();
        AVAudioSession *session = AVAudioSession.sharedInstance;
        [session setCategory:AVAudioSessionCategoryPlayback
                        mode:AVAudioSessionModeSpokenAudio
                     options:0
                       error:nil];
        [session setActive:YES error:nil];
        ko_tts_update_now_playing();
        ko_tts_speak_current();
    });
}

void ko_ios_tts_pause(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ ko_tts_pause(); });
}

void ko_ios_tts_resume(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ ko_tts_resume(); });
}

void ko_ios_tts_seek(int delta) {
    dispatch_async(dispatch_get_main_queue(), ^{ ko_tts_seek(delta); });
}

void ko_ios_tts_stop(void) {
    g_state = KO_TTS_IDLE;
    dispatch_async(dispatch_get_main_queue(), ^{ ko_tts_stop(); });
}

int ko_ios_tts_poll(int *current_id) {
    *current_id = g_current_id;
    return g_state;
}

int ko_ios_tts_is_foreground(void) {
    return g_foreground;
}

/* The voices as a JSON array of {id, name, language, quality}. */
void ko_ios_tts_list_voices(char *out, size_t cap) {
    void (^collect)(void) = ^{
        NSMutableArray *voices = [NSMutableArray array];
        for (AVSpeechSynthesisVoice *voice in AVSpeechSynthesisVoice.speechVoices) {
            [voices addObject:@{
                @"id": voice.identifier,
                @"name": voice.name,
                @"language": voice.language,
                @"quality": @(voice.quality),
            }];
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:voices options:0 error:nil];
        size_t length = MIN((size_t)json.length, cap - 1);
        memcpy(out, json.bytes, length);
        out[length] = 0;
    };
    if ([NSThread isMainThread]) {
        collect();
    } else {
        dispatch_sync(dispatch_get_main_queue(), collect);
    }
}

/* Where speech had got to for this book, if the app died while reading it. */
void ko_ios_tts_saved_position(const char *book, char *out, size_t cap) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *position = [defaults stringForKey:KOTTSPositionKey];
    out[0] = 0;
    if (position && [[defaults stringForKey:KOTTSBookKey] isEqualToString:ko_tts_string(book)]) {
        [position getCString:out maxLength:cap encoding:NSUTF8StringEncoding];
    }
}
