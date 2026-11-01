/* What ios_tts.m and ios_kokoro.m call in each other. All of it main thread. */

#import <Foundation/Foundation.h>

/* ios_kokoro.m */
bool ko_kokoro_installed(void);
void ko_kokoro_start(int voice, float speed);
void ko_kokoro_pause(void);
bool ko_kokoro_resume(void);
void ko_kokoro_stop(void);

/* ios_tts.m */
NSString *ko_tts_text_at(NSUInteger offset);
void ko_tts_kokoro_sentence_done(void);
void ko_tts_kokoro_restart(void);
void ko_tts_kokoro_failed(void);
