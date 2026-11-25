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
    say(@"built with iOS SDK %s", IOS_SDK);
    say(@"app code at 0x%lx (%.2f GiB)", (unsigned long)exe, exe / (double)GiB);
    say(@"memory limit: %.0f MB available", os_proc_available_memory() / 1e6);

    // 1. Where iOS puts a 4 GiB window when asked (it ignores a plain hint).
    uint64_t placed[4] = {0};
    say(@"\n4 GiB window, system's choice:");
    for (int i = 0; i < 4; i++) {
        void *p = mmap(NULL, 4 * GiB, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
        placed[i] = p == MAP_FAILED ? 0 : (uint64_t)p;
        say(@"  try %d: %@", i + 1, p == MAP_FAILED ? [NSString stringWithFormat:@"failed (%s)", strerror(errno)]
                                                  : [NSString stringWithFormat:@"%.2f GiB%@", (uint64_t)p / (double)GiB,
                                                     ((uint64_t)p & (4 * GiB - 1)) ? @"" : @" (4 GiB aligned)"]);
        if (p != MAP_FAILED) munmap(p, 4 * GiB);
    }

    // 2. Fixed addresses (MAP_FIXED), only where nothing is mapped: checked first with a hint-free probe.
    uint64_t fixed[] = { 64 * GiB, 128 * GiB, 256 * GiB, 384 * GiB, 448 * GiB, 456 * GiB, 480 * GiB, 504 * GiB };
    uint64_t good = 0;
    say(@"\nFixed 4 GiB window at:");
    for (unsigned i = 0; i < sizeof fixed / sizeof *fixed; i++) {
        // never over something already mapped: is the range free?
        vm_address_t a = fixed[i]; vm_size_t sz = 0; uint32_t depth = 0;
        vm_region_submap_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        kern_return_t kr = vm_region_recurse_64(mach_task_self(), &a, &sz, &depth, (vm_region_recurse_info_t)&info, &cnt);
        BOOL busy = kr == KERN_SUCCESS && a < fixed[i] + 4 * GiB;
        if (busy) { say(@"  %4llu GiB: something already there", fixed[i] / GiB); continue; }
        void *p = mmap((void *)fixed[i], 4 * GiB, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
        BOOL ok = p == (void *)fixed[i];
        say(@"  %4llu GiB: %@", fixed[i] / GiB, ok ? @"OK" : [NSString stringWithFormat:@"failed (%s)", strerror(errno)]);
        if (ok) { munmap(p, 4 * GiB); if (!good) good = fixed[i]; }
    }
    if (!good) for (int i = 0; i < 4 && !good; i++) if (placed[i] && !(placed[i] & (4 * GiB - 1))) good = placed[i];
    if (!good) { say(@"\nno usable window"); return; }

    // 3. MEM1 (24 MiB) committed at window+0x80000000 and mirrored at +0xC0000000 and +0x00000000.
    uint8_t *win = mmap((void *)good, 4 * GiB, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0);
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
    // 4. The rest of the port's layout around the window: MEM1 mirrored just outside it
    // (base - 2 GiB, base - 1 GiB, base + 4 GiB) and at the physical view (window + 64 KiB).
    struct { const char *name; uint64_t at; } spots[] = {
        { "base - 2 GiB", good - 2 * GiB }, { "base - 1 GiB", good - 1 * GiB }, { "base + 4 GiB", good + 4 * GiB },
        { "window + 0xC0000000", good + 0xC0000000ull }, { "window + 0x10000", good + 0x10000ull } };
    say(@"\nMEM1 mirrors:");
    for (unsigned i = 0; i < sizeof spots / sizeof *spots; i++) {
        uint64_t at = spots[i].at;
        BOOL inside = at >= good && at < good + 4 * GiB;
        if (!inside) {
            vm_address_t q = at; vm_size_t qs = 0; uint32_t d = 0;
            vm_region_submap_info_data_64_t qi; mach_msg_type_number_t qc = VM_REGION_SUBMAP_INFO_COUNT_64;
            if (vm_region_recurse_64(mach_task_self(), &q, &qs, &d, (vm_region_recurse_info_t)&qi, &qc) == KERN_SUCCESS && q < at + sz) {
                say(@"  %s: something already there", spots[i].name); continue;
            }
        }
        vm_address_t to = at;
        kern_return_t k = vm_remap(mach_task_self(), &to, sz, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(),
                                   (vm_address_t)mem1, FALSE, &cur, &max, VM_INHERIT_NONE);
        BOOL same = k == KERN_SUCCESS && ((uint8_t *)to)[100] == 0x5A;
        say(@"  %s: %@", spots[i].name, k ? [NSString stringWithFormat:@"failed (%d)", k] : same ? @"OK" : @"not shared");
        if (k == KERN_SUCCESS && !inside) munmap((void *)to, sz);
    }
    // 5. The free stretch of address space around the window.
    vm_address_t lo = good, hi = good + 4 * GiB;
    { vm_address_t q = 0; vm_size_t qs = 0; uint32_t d = 0; vm_address_t lastend = 0;
      vm_region_submap_info_data_64_t qi; mach_msg_type_number_t qc;
      for (;;) { qc = VM_REGION_SUBMAP_INFO_COUNT_64; d = 0;
          if (vm_region_recurse_64(mach_task_self(), &q, &qs, &d, (vm_region_recurse_info_t)&qi, &qc) != KERN_SUCCESS) break;
          if (q + qs <= good) lastend = q + qs;
          else if (q >= good + 4 * GiB) { hi = q; break; }
          q += qs; }
      lo = lastend; if (hi == good + 4 * GiB) hi = 0; }
    say(@"free from %.3f GiB to %@", lo / (double)GiB, hi ? [NSString stringWithFormat:@"%.3f GiB", hi / (double)GiB] : @"the end");
    munmap(win, 4 * GiB);
    say(@"\nused base: %llu GiB", good / GiB);
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
