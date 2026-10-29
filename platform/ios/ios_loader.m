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
