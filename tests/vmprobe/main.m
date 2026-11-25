// VM probe: what the port's memory layout needs from iOS, checked on the device.
// The port keeps the game's 32-bit memory in a 4 GiB window at COLO_BASE (1 TiB on the Mac) and maps MEM1
// (24 MiB) again at mirror addresses inside it. This tries each candidate base and the ways of mirroring.
#import <UIKit/UIKit.h>
#include <sys/mman.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <os/proc.h>

static NSMutableString *out;
static void say(NSString *f, ...) NS_FORMAT_FUNCTION(1, 2);
static void say(NSString *f, ...) { va_list a; va_start(a, f); [out appendString:[[NSString alloc] initWithFormat:f arguments:a]]; [out appendString:@"\n"]; va_end(a); }

static const uint64_t GiB = 1ull << 30;

static void probe(void) {
    out = [NSMutableString string];
    uintptr_t exe = (uintptr_t)_dyld_get_image_header(0);
    say(@"app code at 0x%lx (%.2f GiB)", (unsigned long)exe, exe / (double)GiB);
    say(@"memory limit: %.0f MB available", os_proc_available_memory() / 1e6);

    // 1. Reserve a 4 GiB window at each candidate base (a hint, never MAP_FIXED over something).
    uint64_t bases[] = { 8 * GiB, 16 * GiB, 32 * GiB, 48 * GiB, 64 * GiB, 128 * GiB, 256 * GiB, 512 * GiB, 1024 * GiB };
    say(@"\n4 GiB window at:");
    uint64_t good = 0;
    for (unsigned i = 0; i < sizeof bases / sizeof *bases; i++) {
        void *p = mmap((void *)bases[i], 4 * GiB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        BOOL ok = p == (void *)bases[i];
        int64_t dist = (int64_t)(bases[i] + 0x80000000ull) - (int64_t)exe;
        say(@"  %4llu GiB: %@  (MEM1 %.1f GiB from code)", bases[i] / GiB,
            ok ? @"OK" : p == MAP_FAILED ? [NSString stringWithFormat:@"failed (%s)", strerror(errno)]
                                         : [NSString stringWithFormat:@"moved to %.1f GiB", (uint64_t)p / (double)GiB],
            dist / (double)GiB);
        if (p != MAP_FAILED) munmap(p, 4 * GiB);
        if (ok && !good) good = bases[i];
    }

    // 2. Anywhere 4 GiB aligned (what the system gives when asked for 8 GiB and trimmed).
    void *any = mmap(NULL, 8 * GiB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    say(@"\nany 8 GiB: %@", any == MAP_FAILED ? [NSString stringWithFormat:@"failed (%s)", strerror(errno)]
                                              : [NSString stringWithFormat:@"at %.1f GiB", (uint64_t)any / (double)GiB]);
    if (any != MAP_FAILED) munmap(any, 8 * GiB);
    if (!good) { say(@"\nno fixed window worked"); return; }

    // 3. MEM1 (24 MiB) committed at window+0x80000000 and mirrored at +0xC0000000 and +0x00000000.
    uint8_t *win = mmap((void *)good, 4 * GiB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    uint8_t *mem1 = win + 0x80000000ull;
    size_t sz = 24 << 20;
    void *m = mmap(mem1, sz, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_SHARED | MAP_ANON, -1, 0);
    say(@"\nMEM1 at %llu GiB + 0x80000000: %@", good / GiB, m == mem1 ? @"OK" : @"failed");
    // mirror with vm_remap (shared, not copied)
    vm_address_t dst = (vm_address_t)(win + 0xC0000000ull);
    vm_prot_t cur, max;
    kern_return_t kr = vm_remap(mach_task_self(), &dst, sz, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                                (vm_address_t)mem1, FALSE, &cur, &max, VM_INHERIT_NONE);
    BOOL mirrored = kr == KERN_SUCCESS;
    if (mirrored) { mem1[100] = 0x5A; mirrored = ((uint8_t *)dst)[100] == 0x5A; }
    say(@"mirror by vm_remap: %@", kr ? [NSString stringWithFormat:@"failed (%d)", kr] : mirrored ? @"OK, shared" : @"mapped but not shared");
    // shared memory object, as the Mac build does
    int fd = shm_open("/colo.probe", O_RDWR | O_CREAT, 0600);
    say(@"shm_open: %@", fd < 0 ? [NSString stringWithFormat:@"failed (%s)", strerror(errno)] : @"OK");
    if (fd >= 0) { close(fd); shm_unlink("/colo.probe"); }
    munmap(win, 4 * GiB);
    say(@"\nfirst good base: %llu GiB", good / GiB);
}

@interface App : UIResponder <UIApplicationDelegate>
@property (strong) UIWindow *window;
@end
@implementation App
- (BOOL)application:(UIApplication *)a didFinishLaunchingWithOptions:(NSDictionary *)o {
    probe();
    NSLog(@"%@", out);
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    UITextView *t = [[UITextView alloc] initWithFrame:vc.view.bounds];
    t.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    t.editable = NO;
    t.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    t.textContainerInset = UIEdgeInsetsMake(60, 16, 40, 16);
    t.text = out;
    [vc.view addSubview:t];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    UIPasteboard.generalPasteboard.string = out;   // so it can be pasted back
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); }
}
