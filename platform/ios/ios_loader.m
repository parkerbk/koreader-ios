/* iOS launcher for KOReader.

   Counterpart of base/osx_loader.c. SDL3's iOS support replaces
   `main` with a wrapper that calls UIApplicationMain first; once
   the runloop is up, it invokes our `SDL_main` (this file's main),
   which then boots Lua and hands off to reader.lua.

   Differences vs. macOS:
   - iOS apps have a flat bundle (no Contents/), and the working
     directory at launch is opaque, so we resolve paths via NSBundle.
   - `_NSGetExecutablePath` + `chdir(dirname/../koreader)` would land
     somewhere unrelated to the bundle.
*/

#import <Foundation/Foundation.h>

#include <SDL3/SDL_main.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/syslimits.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

#define LOGNAME "iOS loader"
#define LANGUAGE "en_US.UTF-8"
#define LUA_ERROR "failed to run lua chunk: %s\n"

/* iOS moves the app's data container to a new UUID path on reinstall
 * (…/Containers/Data/Application/<UUID>/Documents), but KOReader saves
 * absolute paths in its settings: extra_plugin_paths, lastdir, history,
 * collections, cover cache paths... Once stale, those silently stop
 * working (e.g. Documents/plugins is no longer scanned, so Storefront
 * and everything it installed disappears). Before Lua starts, rewrite any
 * other container UUID in the Lua data files under Documents to the
 * current one. A marker file records the container we last fixed up for,
 * so the scan only runs after the container actually changed. */
static void relocate_saved_paths(NSString *documentsDir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *uuid = [[documentsDir stringByDeletingLastPathComponent] lastPathComponent];
    NSString *marker = [documentsDir stringByAppendingPathComponent:@".ko_container"];
    NSString *lastUUID = [NSString stringWithContentsOfFile:marker
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if ([lastUUID isEqualToString:uuid]) return;

    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"/Containers/Data/Application/[0-9A-Fa-f-]{36}"
                             options:0
                               error:nil];
    NSString *replacement = [@"/Containers/Data/Application/" stringByAppendingString:uuid];

    NSDirectoryEnumerator *it = [fm enumeratorAtPath:documentsDir];
    for (NSString *rel in it) {
        /* Plugin and font files are code/data we didn't write; leave them. */
        if ([rel isEqualToString:@"plugins"] || [rel isEqualToString:@"fonts"]) {
            [it skipDescendants];
            continue;
        }
        if (![[rel pathExtension] isEqualToString:@"lua"]) continue;
        NSString *path = [documentsDir stringByAppendingPathComponent:rel];
        NSString *text = [NSString stringWithContentsOfFile:path
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
        if (!text || ![text containsString:@"/Containers/Data/Application/"]) continue;
        NSString *fixed = [re stringByReplacingMatchesInString:text
                                                       options:0
                                                         range:NSMakeRange(0, text.length)
                                                  withTemplate:replacement];
        if ([fixed isEqualToString:text]) continue;
        NSError *writeErr = nil;
        if (![fixed writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeErr]) {
            fprintf(stderr, "[%s]: could not update paths in %s: %s\n", LOGNAME,
                    [path fileSystemRepresentation],
                    [[writeErr localizedDescription] UTF8String]);
        } else {
            fprintf(stderr, "[%s]: updated saved paths in %s\n", LOGNAME,
                    [rel fileSystemRepresentation]);
        }
    }
    [uuid writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
        if (!resourcePath) {
            fprintf(stderr, "[%s]: NSBundle resourcePath is nil\n", LOGNAME);
            return EXIT_FAILURE;
        }

        // The asset directory is `app/` rather than `koreader/` because the
        // launcher exec is named `KOReader` and APFS is case-insensitive by
        // default — `KOReader.app/KOReader` (file) and `KOReader.app/koreader/`
        // (dir) would collide.
        NSString *koreaderDir = [resourcePath stringByAppendingPathComponent:@"app"];
        if (chdir([koreaderDir fileSystemRepresentation]) != 0) {
            fprintf(stderr, "[%s]: chdir(%s) failed\n", LOGNAME,
                    [koreaderDir fileSystemRepresentation]);
            return EXIT_FAILURE;
        }

        if (setenv("LC_ALL", LANGUAGE, 1) != 0) {
            fprintf(stderr, "[%s]: setenv LC_ALL failed\n", LOGNAME);
            return EXIT_FAILURE;
        }

        /* On iOS the SDL window must match the display, otherwise the
         * default 600x800 emulator window leaves touches outside its
         * bounds doing nothing. Triggering the SDL_FULLSCREEN code path
         * makes SDL query SDL_GetCurrentDisplayMode and size to the
         * actual screen. */
        setenv("SDL_FULLSCREEN", "1", 1);

        /* Without this SDL can limit rotation to the window's current shape,
         * leaving the app stuck in landscape after a fold or a turn. SDL and
         * Info.plist still rule out what a device doesn't allow. */
        setenv("SDL_ORIENTATIONS", "Portrait PortraitUpsideDown LandscapeLeft LandscapeRight", 1);

        /* Disable SDL's synthesis of mouse events from touches. On iOS
         * SDL3 fires both a FINGER_DOWN and a synthetic MOUSE_BUTTON_DOWN
         * for every tap, and the synthesized event isn't reliably tagged
         * with SDL_TOUCH_MOUSEID — so KOReader's input filter accepts
         * both and registers each tap twice. We have the real finger
         * events; we don't need fake mouse ones. */
        setenv("SDL_TOUCH_MOUSE_EVENTS", "0", 1);

        /* Tell Lua plugins (e.g. iosfilepicker.koplugin) we're on iOS.
         * KOReader still self-identifies as the SDL emulator otherwise. */
        setenv("KO_IOS", "1", 1);

        /* iOS sandbox: use the per-app Documents dir for user data. */
        NSArray<NSString *> *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES);
        if (docs.count > 0) {
            setenv("KO_HOME", [docs[0] fileSystemRepresentation], 1);
            relocate_saved_paths(docs[0]);

            /* PluginLoader auto-registers <data dir>/plugins as an extra
             * plugin path without checking that it exists, then calls
             * lfs.dir() on it -- which raises if the directory is missing.
             * The Documents dir starts out empty on a fresh install, so
             * create it here. It doubles as the drop point for user-added
             * plugins: UIFileSharingEnabled exposes Documents in the Files
             * app, so this folder shows up under On My iPhone -> KOReader. */
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *pluginsDir = [docs[0] stringByAppendingPathComponent:@"plugins"];
            /* User fonts (Files app drops, Storefront installs). The iOS
             * branch of ui/elements/font_settings.lua points KOReader at
             * this folder. */
            NSString *fontsDir = [docs[0] stringByAppendingPathComponent:@"fonts"];
            for (NSString *dir in @[pluginsDir, fontsDir]) {
                NSError *mkdirErr = nil;
                if (![fm createDirectoryAtPath:dir
                   withIntermediateDirectories:YES
                                    attributes:nil
                                         error:&mkdirErr]) {
                    fprintf(stderr, "[%s]: could not create %s: %s\n", LOGNAME,
                            [dir fileSystemRepresentation],
                            [[mkdirErr localizedDescription] UTF8String]);
                }
            }

            /* Seed plugins that must stay writable (Storefront updates
             * itself, and installs into this same folder). They ship under
             * app/seed/plugins rather than app/plugins and are copied over
             * only when missing, so an installed copy -- possibly newer
             * than the seed, or deliberately deleted and re-added by the
             * user -- is never clobbered by an app update. */
            NSString *seedDir = [koreaderDir stringByAppendingPathComponent:@"seed/plugins"];
            for (NSString *entry in [fm contentsOfDirectoryAtPath:seedDir error:nil]) {
                if (![entry hasSuffix:@".koplugin"]) continue;
                NSString *dst = [pluginsDir stringByAppendingPathComponent:entry];
                if ([fm fileExistsAtPath:dst]) continue;
                NSError *copyErr = nil;
                if (![fm copyItemAtPath:[seedDir stringByAppendingPathComponent:entry]
                                 toPath:dst
                                  error:&copyErr]) {
                    fprintf(stderr, "[%s]: could not seed %s: %s\n", LOGNAME,
                            [dst fileSystemRepresentation],
                            [[copyErr localizedDescription] UTF8String]);
                }
            }
        }

        lua_State *L = luaL_newstate();
        luaL_openlibs(L);

        int retval = luaL_dostring(L, "arg = {}");
        if (retval) {
            fprintf(stderr, LUA_ERROR, lua_tostring(L, -1));
            goto quit;
        }

        char buffer[PATH_MAX];
        for (int i = 1; i < argc; ++i) {
            if (snprintf(buffer, PATH_MAX, "table.insert(arg, '%s')", argv[i]) >= 0) {
                retval = luaL_dostring(L, buffer);
                if (retval) {
                    fprintf(stderr, LUA_ERROR, lua_tostring(L, -1));
                    goto quit;
                }
            }
        }

        retval = luaL_dofile(L, "reader.lua");
        if (retval) {
            fprintf(stderr, LUA_ERROR, lua_tostring(L, -1));
        }

quit:
        lua_close(L);
        unsetenv("LC_ALL");
        unsetenv("KO_HOME");
        unsetenv("SDL_FULLSCREEN");
        unsetenv("SDL_TOUCH_MOUSE_EVENTS");
        unsetenv("KO_IOS");
        return retval;
    }
}
