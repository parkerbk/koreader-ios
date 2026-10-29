/* _exit() override for inline "subprocesses" on iOS.

   iOS forbids fork(), so base/ffi/util.lua's runInSubProcess runs the
   child function inline, in the app process. Plugins (e.g. Readest's sync
   workers) end their child function with ffi.C._exit(0), which then kills
   the whole app on the spot -- without flushing any settings.

   LuaJIT resolves ffi.C symbols with dlsym(RTLD_DEFAULT), which searches
   the main executable before libSystem, so this definition is the one
   ffi.C._exit gets. While frontend/device/sdl/device.lua has flagged an
   inline child as running, it returns instead (the call is the child's
   last statement, so the child function then simply returns). Otherwise
   it forwards to the real _exit. Other images keep binding to libSystem's
   _exit through the two-level namespace.

   Defined under another C name with an asm label: the compiler treats
   anything *named* _exit as noreturn, which this one isn't. */

#define KO_RTLD_NEXT ((void *)-1)

void *dlsym(void *handle, const char *symbol);

static volatile int g_inline_child = 0;

void ko_ios_set_inline_child(int on) {
    g_inline_child = on;
}

void ko_ios_exit(int status) __asm__("__exit");

void ko_ios_exit(int status) {
    if (g_inline_child) {
        return;
    }
    static void (*real_exit)(int) = 0;
    if (!real_exit) {
        real_exit = (void (*)(int))dlsym(KO_RTLD_NEXT, "_exit");
    }
    real_exit(status);
    for (;;) {} /* not reached */
}
