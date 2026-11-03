/* Apple Silicon loader for the recompiled inFAMOUS Second Son: the counterpart of port/src/probe.c
 * without any x86 code. Loads the linked guest image (data only: its code is the recompiled C),
 * relocates it, binds imports to the PS4 runtime, starts the GPU library and runs the game. */
#define _DARWIN_C_SOURCE
#include "x86.h"
#include "recomp_rt.h"
#include "recomp_host.h"
#include "runtime.h"
#include "gpu/tlggpu.h"
#include "iss_native_resolution.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>
#include <pthread.h>
#include <signal.h>
#include <setjmp.h>
#include <dlfcn.h>
#include <unistd.h>
#include <sys/mman.h>
#include <mach-o/getsect.h>
#include <mach-o/ldsyms.h>

uint64_t recomp_image_size;
static const uint64_t PAGE = 16384;
static uint64_t round_page(uint64_t n) { return (n + PAGE - 1) & ~(PAGE - 1); }
static void fail(const char *m) { fprintf(stderr, "ERROR: %s\n", m); exit(1); }

/* ---------------------------------------------------------------- native resolution */
/* iss_native_output / iss_native_percent (tlg.ini): the game's 3D render size. The lifter
 * patched the resolution-independent sites into the recompiled code and reads the six size
 * immediates from the guest image (lifter/iss_native_sites.json), so writing them here
 * takes effect. The US 01.07 sites match the EU 01.07 executable byte for byte; each site is
 * still checked before it is written. Scenes above the original 1080p pixel count would
 * also need the exposure-buffer patches, which are not part of the recompiled build. */
static void apply_native_resolution(unsigned char *image, uint64_t size) {
    const char *path = getenv("TLG_CONFIG");
    FILE *f = path ? fopen(path, "r") : NULL;
    IssNativeConfig c;
    int ok = iss_native_config(f, &c);
    if (f) fclose(f);
    if (!ok) { puts("Native rendering: malformed settings; 1920x1080"); c.output = 0; }
    /* Off: the original 1920x1080, written the same way, so the patched code (always compiled
     * in) runs exactly as the port's native mode does at 1080p and 100%. */
    const int off = !c.output;
    if (off) { c.output = 1; c.percent = 100; }
    IssNativePlan p;
    if (!iss_native_plan(c, &p)) { puts("Native rendering: refused dimensions/scale"); return; }
    if (iss_native_exposure_entries(p.width, p.height) > ISS_EXPOSURE_ORIGINAL_ENTRIES) {
        printf("Native rendering: %ux%u is above the original pixel count, not supported in the "
               "recompiled build; original dimensions\n", p.width, p.height);
        return;
    }
    IssNativeSite sites[ISS_NATIVE_SITE_COUNT];
    iss_native_changes(&p, sites);
    for (unsigned i = 0; i < ISS_NATIVE_SITE_COUNT; i++)
        if (sites[i].offset > size || sites[i].length > size - sites[i].offset ||
            memcmp(image + sites[i].offset, sites[i].before, sites[i].length)) {
            puts("Native rendering: executable differs from 01.07; original dimensions");
            return;
        }
    for (unsigned i = 0; i < ISS_NATIVE_SITE_COUNT; i++)
        memcpy(image + sites[i].offset, sites[i].after, sites[i].length);
    if (off) return;
    runtime_native_publish(1, "Native rendering (recompiled build)", &p);
    printf("Native rendering: scene %ux%u (%d%% of %ux%u), HUD %ux%u\n", p.width, p.height,
           p.percent, p.output_width, p.output_height, p.ui_width, p.ui_height);
}

/* ---------------------------------------------------------------- address space */
/* Apple Silicon layout (all below 1 TiB; [0xfc0000000, 0x7000000000) is the commpage and GPU
 * carveout, and malloc reserves a randomized block below that): */
#define USER_MIN 0x7000000000ULL   /* PS4 user range (runtime_memory.c) */
#define USER_MAX 0xe000000000ULL
#define LOW_MIN 0xe100000000ULL    /* stacks, TLS and other host objects the guest sees */
#define LOW_MAX 0xfc00000000ULL
#define IMAGE_RESERVE 0x40000000ULL /* 1 GiB at IMG */
static int reserved_ok;
static void reserve(uint64_t lo, uint64_t hi, const char *what) {
    void *p = mmap((void *)lo, hi - lo, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (p != (void *)lo) {
        fprintf(stderr, "ERROR: cannot reserve %s [%#llx, %#llx): got %p\n", what, (unsigned long long)lo, (unsigned long long)hi, p);
        if (p != MAP_FAILED) munmap(p, hi - lo);
        reserved_ok = 0;
    }
}
/* Before malloc and the GPU driver claim these ranges. */
__attribute__((constructor(101))) static void reserve_guest_ranges(void) {
    reserved_ok = 1;
    /* macOS 27+: the __TLGUSER placeholder segment (guest_reserve.S) kept malloc out of the
     * user range. It slides with the executable, so its end can reach the guest image: give it
     * back before reserving anything. */
    unsigned long seg_size = 0;
    uint8_t *seg = getsegmentdata(&_mh_execute_header, "__TLGUSER", &seg_size);
    if (seg && seg_size) munmap(seg, seg_size);
    reserve(IMG, IMG + IMAGE_RESERVE, "guest image");
    reserve(LOW_MIN, LOW_MAX, "low guest window");
    reserve(USER_MIN, USER_MAX, "PS4 user range");
}
void *recomp_low_stack(size_t size) { return runtime_low_map(size, PROT_READ | PROT_WRITE); }

/* ---------------------------------------------------------------- faults */
#include "rcpc_fixup.h"
static int gpu_enabled;
static void fault(int sig, siginfo_t *info, void *context) {
    /* guest acquire/release accesses straddling a 16-byte block (x86.h, rcpc_fixup.h) */
    if (sig == SIGBUS && recomp_rcpc_fixup(context)) return;
    if ((sig == SIGSEGV || sig == SIGBUS) && runtime_fault_recover) {
        sigjmp_buf *recover = runtime_fault_recover;
        runtime_fault_recover = NULL;
        sigset_t unblock; sigemptyset(&unblock); sigaddset(&unblock, sig);
        pthread_sigmask(SIG_UNBLOCK, &unblock, NULL);
        siglongjmp(*recover, 1);
    }
    if (gpu_enabled && (sig == SIGSEGV || sig == SIGBUS) && tlggpu_handle_fault(context, info->si_addr)) return;
    ucontext_t *uc = context;
    char where[256];
    recomp_describe_host_pc((uintptr_t)uc->uc_mcontext->__ss.__pc, where, sizeof where);
    fprintf(stderr, "FATAL: signal %d at %s, address %p (guest offset %#llx)\n", sig, where, info->si_addr,
            (unsigned long long)((uintptr_t)info->si_addr - IMG));
    fprintf(stderr, "  lr: "); recomp_describe_host_pc((uintptr_t)uc->uc_mcontext->__ss.__lr, where, sizeof where);
    fprintf(stderr, "%s\n", where);
    /* walk the host frame chain (recompiled guest functions are host frames) */
    uintptr_t fp = (uintptr_t)uc->uc_mcontext->__ss.__fp;
    for (int i = 0; i < 40 && fp; ++i) {
        uintptr_t *f = (uintptr_t *)fp;
        if (!f[1]) break;
        recomp_describe_host_pc(f[1], where, sizeof where);
        fprintf(stderr, "  #%d %s\n", i, where);
        if (f[0] <= fp) break;
        fp = f[0];
    }
    fflush(NULL);
    signal(sig, SIG_DFL);
    _exit(30);
}

/* ---------------------------------------------------------------- boot file */
static uint64_t read64(FILE *f) {
    uint64_t v;
    if (fread(&v, 8, 1, f) != 1) fail("truncated boot file");
    return v;
}
static int sfo_value(const char *path, const char *key, char *text, size_t text_size, uint32_t *number) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    static unsigned char data[65536];
    size_t n = fread(data, 1, sizeof(data), f); fclose(f);
    if (n < 20 || memcmp(data, "\0PSF", 4)) return 0;
    uint32_t keys, values, count;
    memcpy(&keys, data + 8, 4); memcpy(&values, data + 12, 4); memcpy(&count, data + 16, 4);
    for (uint32_t i = 0; i < count && 20 + i * 16 + 16 <= n; ++i) {
        const unsigned char *e = data + 20 + i * 16;
        uint16_t key_offset, format; uint32_t length, offset;
        memcpy(&key_offset, e, 2); memcpy(&format, e + 2, 2); memcpy(&length, e + 4, 4); memcpy(&offset, e + 12, 4);
        if (keys + key_offset >= n || values + offset + length > n || strcmp((const char *)data + keys + key_offset, key)) continue;
        if (format == 0x0404 && number && length >= 4) { memcpy(number, data + values + offset, 4); return 1; }
        if (text && text_size) {
            size_t copy = length < text_size - 1 ? length : text_size - 1;
            memcpy(text, data + values + offset, copy); text[copy] = 0;
        }
        return 1;
    }
    return 0;
}

typedef struct { uint64_t base, size, init, tls_address, tls_memsz, tls_filesz, tls_module; } LinkedModule;
static LinkedModule modules[8];
static uint64_t module_count, entry_offset, procparam, main_tls[4];
static unsigned char *image;

static void guest_exit(void) { puts("Runtime: process finalizer callback reached"); }
static void *guest_main(void *arg) {
    (void)arg;
    enum { MAIN_STACK = 16 * 1024 * 1024 };
    unsigned char *stack = runtime_low_map(MAIN_STACK, PROT_READ | PROT_WRITE);
    if (!stack) fail("cannot allocate guest main stack");
    recomp_thread_begin(stack, MAIN_STACK);
    for (uint64_t m = 0; m < module_count; ++m)
        if (modules[m].tls_module)
            runtime_set_module_tls(modules[m].tls_module, image + modules[m].tls_address, modules[m].tls_filesz, modules[m].tls_memsz);
    runtime_set_main_tls(image + main_tls[0], main_tls[1], main_tls[2], main_tls[3]);
    runtime_thread_attach_main();
    runtime_set_procparam(image + procparam);
    for (uint64_t m = 0; m < module_count; ++m) {
        printf("Starting linked module %" PRIu64 " at image offset 0x%" PRIx64 "\n", m, modules[m].init);
        int result = (int)recomp_guest_call(IMG + modules[m].init, 3, 0, 0, 0, 0, 0, 0);
        printf("Module %" PRIu64 " initializer returned %d\n", m, result);
        if (result) fail("module initializer failed");
    }
    printf("Entering recompiled guest code at guest offset 0x%" PRIx64 "\n", entry_offset);
    static struct { uint64_t argc; const char *argv[2]; } params = {1, {"/app0/eboot.bin", NULL}};
    recomp_guest_call(IMG + entry_offset, 2, (uint64_t)&params, (uint64_t)guest_exit, 0, 0, 0, 0);
    fail("entry unexpectedly returned");
    return NULL;
}

static char **saved_argv;
void runtime_restart(void) {
    fflush(NULL);
    puts("Runtime: restarting");
    for (int fd = 3; fd < 1024; ++fd) close(fd);
    execv(saved_argv[0], saved_argv);
    perror("runtime_restart: exec");
    _exit(1);
}

static int boot_main(int argc, char **argv);
static int boot_argc; static char **boot_argv;
static void *boot_thread(void *arg) { (void)arg; exit(boot_main(boot_argc, boot_argv)); return NULL; }
int main(int argc, char **argv) {
    saved_argv = argv;
    setvbuf(stdout, NULL, _IONBF, 0);
    /* The process main thread belongs to the window (Cocoa); the game boots on another thread. */
    boot_argc = argc; boot_argv = argv;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 64u << 20);
    pthread_t thread;
    if (pthread_create(&thread, &attr, boot_thread, NULL)) fail("cannot start the boot thread");
    tlggpu_main_thread_loop();
    pthread_join(thread, NULL);
    return 0;
}
static int boot_main(int argc, char **argv) {
    if (!reserved_ok) fail("guest address ranges unavailable");
    int cpu_only = 0;
    const char *content_profile = NULL, *app0 = NULL, *user_dir = NULL;
    const char *mounts[8]; int mount_count = 0;
    for (int i = 2; i < argc; ++i) {
        if (!strcmp(argv[i], "--cpu-only")) cpu_only = 1;
        else if (!strcmp(argv[i], "--content-profile") && i + 1 < argc) content_profile = argv[++i];
        else if (!strcmp(argv[i], "--app0") && i + 1 < argc) app0 = argv[++i];
        else if (!strcmp(argv[i], "--user") && i + 1 < argc) user_dir = argv[++i];
        else if (!strcmp(argv[i], "--mount") && i + 1 < argc) mounts[mount_count++ & 7] = argv[++i];
        else if (!strcmp(argv[i], "--timeout") && i + 1 < argc) ++i;
        else if (!strcmp(argv[i], "--patches") && i + 1 < argc) ++i;
        else { fprintf(stderr, "Unknown option: %s\n", argv[i]); return 1; }
    }
    if (argc < 2) { fprintf(stderr, "Usage: %s boot-linked.bin [--app0 dir] [--user dir] [--content-profile file] [--cpu-only]\n", argv[0]); return 1; }
    {
        char path[4096], serial[32] = "?", version[32] = "?";
        snprintf(path, sizeof(path), "%s/sce_sys/param.sfo", app0 ? app0 : ".");
        sfo_value(path, "TITLE_ID", serial, sizeof(serial), NULL);
        sfo_value(path, "APP_VER", version, sizeof(version), NULL);
        printf("Build: iss-recomp (Apple Silicon, recompiled guest; built %s %s); game %s %s\n", __DATE__, __TIME__, serial, version);
    }
    if (content_profile) {
        FILE *profile = fopen(content_profile, "rb");
        unsigned char data[28];
        if (!profile) fail("cannot open content profile");
        if (fread(data, 1, sizeof(data), profile) != sizeof(data) || memcmp(data, "G3CONT01", 8)) fail("invalid content profile");
        fclose(profile);
        uint32_t values[5];
        for (unsigned i = 0; i < 5; ++i) memcpy(&values[i], data + 8 + i * 4, 4);
        runtime_content_configure(values);
    }
    if (app0) {
        runtime_file_configure(app0, user_dir ? user_dir : "user");
        for (int i = 0; i < mount_count && i < 8; ++i) {
            const char *eq = strchr(mounts[i], '=');
            if (!eq) continue;
            char guest[64]; size_t glen = (size_t)(eq - mounts[i]);
            if (glen >= sizeof guest) continue;
            memcpy(guest, mounts[i], glen); guest[glen] = 0;
            runtime_file_mount(guest, eq + 1);
        }
        char sfo[4096], id[16] = "";
        snprintf(sfo, sizeof(sfo), "%s/sce_sys/param.sfo", app0);
        if (sfo_value(sfo, "INSTALL_DIR_SAVEDATA", id, sizeof(id), NULL) || sfo_value(sfo, "TITLE_ID", id, sizeof(id), NULL))
            runtime_savedata_configure(id);
    }
    tlggpu_register_kernel();
    struct sigaction sa = {0};
    /* SA_NODEFER: an emulated straddling access (rcpc_fixup.h) may itself hit a page the GPU
     * library protects, which faults again inside this handler. */
    sa.sa_sigaction = fault; sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, NULL); sigaction(SIGBUS, &sa, NULL); sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL); sigaction(SIGFPE, &sa, NULL);

    FILE *f = fopen(argv[1], "rb");
    if (!f) fail("cannot open boot file");
    char magic[8];
    if (fread(magic, 1, 8, f) != 8 || memcmp(magic, "G3PROBE5", 8)) fail("expected a G3PROBE5 boot file (link_modules.py)");
    uint64_t size = read64(f); entry_offset = read64(f);
    uint64_t ns = read64(f), nr = read64(f), import_count = read64(f), capabilities = read64(f);
    runtime_start(capabilities);
    procparam = read64(f);
    for (int i = 0; i < 4; ++i) main_tls[i] = read64(f);
    module_count = read64(f);
    if (!module_count || module_count > 8) fail("invalid module count");
    for (uint64_t m = 0; m < module_count; ++m) {
        LinkedModule *x = &modules[m];
        x->base = read64(f); x->size = read64(f); x->init = read64(f); x->tls_address = read64(f);
        x->tls_memsz = read64(f); x->tls_filesz = read64(f); x->tls_module = read64(f);
    }
    uint64_t nb = read64(f);
    uint64_t *bindings = calloc(import_count + 1, 8), *binding_kinds = calloc(import_count + 1, 8);
    for (uint64_t i = 0; i < nb; ++i) {
        uint64_t index = read64(f), address = read64(f), kind = read64(f);
        if (index >= import_count) fail("bad binding");
        bindings[index] = address; binding_kinds[index] = kind;
    }
    uint64_t (*segments)[3] = calloc(ns, sizeof(*segments));
    for (uint64_t i = 0; i < ns; ++i) { segments[i][0] = read64(f); segments[i][1] = read64(f); segments[i][2] = read64(f); }
    char (*names)[128] = calloc(import_count + 1, 128);
    if (fread(names, 128, import_count, f) != import_count) fail("truncated import names");
    uint64_t (*relocs)[4] = calloc(nr + 1, sizeof(*relocs));
    for (uint64_t i = 0; i < nr; ++i) for (int k = 0; k < 4; ++k) relocs[i][k] = read64(f);
    if (size > IMAGE_RESERVE) fail("image too large");
    recomp_image_size = round_page(size);
    image = mmap((void *)IMG, recomp_image_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
    if (image != (void *)IMG) fail("cannot map the guest image");
    if (fread(image, 1, size, f) != size) fail("truncated image");
    fclose(f);

    if (!cpu_only) {
        char title[128] = "inFAMOUS Second Son", serial[16] = "UNKNOWN", sfo[4096];
        uint32_t attributes = 0;
        snprintf(sfo, sizeof(sfo), "%s/sce_sys/param.sfo", app0 ? app0 : ".");
        sfo_value(sfo, "TITLE", title, sizeof(title), NULL);
        sfo_value(sfo, "TITLE_ID", serial, sizeof(serial), NULL);
        sfo_value(sfo, "ATTRIBUTE", NULL, 0, &attributes);
        uint64_t sdk = 0;
        if (procparam) memcpy(&sdk, image + procparam + 16, 8);
        TlgGpuConfig gpu = {title, serial, user_dir ? user_dir : "user", (uint32_t)sdk, attributes, 1920, 1080};
        gpu_enabled = 1;
        if (tlggpu_init(&gpu)) fail("GPU initialization failed");
        printf("GPU: window and Vulkan presenter ready; SDK 0x%08x, %u HLE symbols\n", (unsigned)sdk, tlggpu_symbol_count());
    }

    /* imports: every function import is a fake guest address the dispatcher turns into a host call */
    recomp_imports = calloc(1024, sizeof(*recomp_imports));
    recomp_import_count = import_count;
    if (import_count > 900) fail("too many imports for the thunk table");
    const char *trace = getenv("RECOMP_IMPORT_TRACE");
    for (uint64_t i = 0; i < import_count; ++i) {
        recomp_imports[i].name = names[i];
        recomp_imports[i].label = runtime_import_name(names[i]);
        recomp_imports[i].trace = trace && (!strcmp(trace, "1") || strstr(trace, recomp_imports[i].label ? recomp_imports[i].label : "?"));
    }
    unsigned char *data_traps = mmap(NULL, (import_count + 1) * PAGE, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    uint64_t resolved = 0, native = 0, missing = 0;
    for (uint64_t i = 0; i < nr; ++i) {
        uint64_t target = relocs[i][0], kind = relocs[i][1], value = relocs[i][2], addend = relocs[i][3], v;
        if (kind == 0) v = IMG + value;
        else {
            uintptr_t host = runtime_resolve(names[value], kind == 2);
            if (kind == 1) {
                if (host) { recomp_imports[value].fn = (void *)host; v = RECOMP_IMPORT_BASE + 16 * value; ++resolved; }
                else if (bindings[value] && binding_kinds[value] == 1) { v = IMG + bindings[value]; ++native; }
                else { v = RECOMP_IMPORT_BASE + 16 * value; ++missing; }
            } else {
                if (host) v = host + addend;
                else if (bindings[value]) v = IMG + bindings[value] + addend;
                else v = (uint64_t)(data_traps + PAGE * value + addend);
            }
        }
        memcpy(image + target, &v, 8);
    }
    printf("Relocated %" PRIu64 " entries: %" PRIu64 " host imports, %" PRIu64 " native libc bindings, %" PRIu64 " unresolved\n",
           nr, resolved, native, missing);
    apply_native_resolution(image, recomp_image_size);
    for (uint64_t s = 0; s < ns; ++s) {
        unsigned fl = (unsigned)segments[s][2];
        int prot = ((fl & 4) ? PROT_READ : 0) | ((fl & 2) ? PROT_WRITE : 0) | ((fl & 1) ? PROT_READ : 0);
        if (prot) mprotect(image + segments[s][0], round_page(segments[s][1]), prot | PROT_READ);
    }
    recomp_table_init();
    tlggpu_set_guest_image(IMG, recomp_image_size);
    runtime_freeze_start(IMG, recomp_image_size, 0);

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 256u << 20);
    pthread_t thread;
    if (pthread_create(&thread, &attr, guest_main, NULL)) fail("cannot start the guest main thread");
    pthread_join(thread, NULL);
    return 0;
}
