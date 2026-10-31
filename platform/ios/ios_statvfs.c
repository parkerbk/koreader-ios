/* statvfs() in the layout KOReader expects.
 *
 * base/ffi declares struct statvfs the Linux way, with 64-bit block counts, so
 * reading Darwin's layout through it gives nonsense: free space came out in
 * the trillions of gigabytes. LuaJIT resolves ffi.C symbols with
 * dlsym(RTLD_DEFAULT), which searches the main executable first (as ios_exit.c
 * relies on), so this translates for Lua while other images keep libSystem's. */

#include <stddef.h>
#include <sys/statvfs.h>

#define KO_RTLD_NEXT ((void *)-1)

void *dlsym(void *handle, const char *symbol);

/* base/ffi/posix_types_64b_h.lua */
struct ko_linux_statvfs {
    unsigned long f_bsize;
    unsigned long f_frsize;
    unsigned long f_blocks;
    unsigned long f_bfree;
    unsigned long f_bavail;
    unsigned long f_files;
    unsigned long f_ffree;
    unsigned long f_favail;
    unsigned long f_fsid;
    unsigned long f_flag;
    unsigned long f_namemax;
    int __f_spare[6];
};

int ko_ios_statvfs(const char *path, struct ko_linux_statvfs *out) __asm__("_statvfs");

int ko_ios_statvfs(const char *path, struct ko_linux_statvfs *out) {
    static int (*real_statvfs)(const char *, struct statvfs *) = NULL;
    if (!real_statvfs) {
        real_statvfs = (int (*)(const char *, struct statvfs *))dlsym(KO_RTLD_NEXT, "statvfs");
    }
    struct statvfs st;
    int result = real_statvfs(path, &st);
    if (result != 0) {
        return result;
    }
    /* Block counts are in f_frsize units, which Linux callers take f_bsize to be. */
    out->f_bsize = st.f_frsize;
    out->f_frsize = st.f_frsize;
    out->f_blocks = st.f_blocks;
    out->f_bfree = st.f_bfree;
    out->f_bavail = st.f_bavail;
    out->f_files = st.f_files;
    out->f_ffree = st.f_ffree;
    out->f_favail = st.f_favail;
    out->f_fsid = st.f_fsid;
    out->f_flag = st.f_flag;
    out->f_namemax = st.f_namemax;
    return 0;
}
