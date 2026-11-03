#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <dispatch/dispatch.h>

// ===== ОФФСЕТЫ (iOS, из Lua-скрипта @Alex52525) =====
#define OFF_LOCAL_PLAYER_ID   0x31F17F0
#define OFF_WORLD_PLAYERS     0x31F17E8
#define STRIDE                0xF8
#define OFF_INF_SPRINT        0xE8
#define OFF_PED_INF_SPRINT    0x85F
// ====================================================

static uintptr_t g_base = 0;
static volatile int g_enabled = 0;
static UIWindow *g_overlay = nil;

static inline int32_t rd32(uintptr_t a){ return *(volatile int32_t*)a; }
static inline void   wr32(uintptr_t a, int32_t v){ *(volatile int32_t*)a = v; }

// ===== 1. НАДЁЖНЫЙ ПОИСК БАЗЫ ИГРЫ =====
static uintptr_t find_main_base(void) {
    char exe_path[4096];
    uint32_t size = sizeof(exe_path);
    if (_NSGetExecutablePath(exe_path, &size) != 0) return 0;

    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (p && strcmp(p, exe_path) == 0)
            return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

// ===== 2. ЛОГИКА (точный порт Lua) =====
static void apply_state(void) {
    if (!g_base) return;

    int32_t raw = rd32(g_base + OFF_LOCAL_PLAYER_ID);
    if (!raw) return;

    int32_t id = raw % 65536;
    uintptr_t info = g_base + OFF_WORLD_PLAYERS + (uintptr_t)id * STRIDE;
    int32_t ped = rd32(info);
    int32_t flag = g_enabled ? 1 : 0;

    wr32(info + OFF_INF_SPRINT, flag);
    if (ped) wr32((uintptr_t)ped + OFF_PED_INF_SPRINT, flag);
}

static void infstam_set(int on) {
    g_enabled = on;
    apply_state();
    NSLog(@"[InfinityStamina] %@", on ? @"ON" : @"OFF");
}

// ===== 3. UI-OVERLAY ПОВЕРХ METAL =====
@interface InfstamCtrl : NSObject
- (void)toggle:(UISwitch *)s;
@end

@implementation InfstamCtrl
- (void)toggle:(UISwitch *)s {
    infstam_set(s.isOn ? 1 : 0);
}
@end

static InfstamCtrl *g_ctrl = nil;

static void setup_overlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!UIApplication.sharedApplication) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{ setup_overlay(); });
            return;
        }

        g_ctrl = [InfstamCtrl new];

        g_overlay = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        g_overlay.windowLevel = UIWindowLevelAlert + 1;
        g_overlay.backgroundColor = [UIColor clearColor];
        g_overlay.rootViewController = [UIViewController new];
        g_overlay.hidden = NO;

        UIView *root = g_overlay.rootViewController.view;

        UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(20, 120, 60, 30)];
        [sw addTarget:g_ctrl action:@selector(toggle:)
     forControlEvents:UIControlEventValueChanged];
        [root addSubview:sw];

        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(90, 120, 200, 30)];
        lbl.text = @"Inf Stamina";
        lbl.textColor = [UIColor greenColor];
        lbl.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        lbl.font = [UIFont boldSystemFontOfSize:16];
        [root addSubview:lbl];

        NSLog(@"[InfinityStamina] Overlay OK, base=0x%lx", (unsigned long)g_base);
    });
}

// ===== 4. АВТОПОДДЕРЖКА (0.5 сек) =====
static void start_ticker(void) {
    dispatch_source_t t = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0));
    dispatch_source_set_timer(t,
        dispatch_time(DISPATCH_TIME_NOW, 0),
        500ull * NSEC_PER_MSEC, 100ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        if (g_enabled) apply_state();
    });
    dispatch_resume(t);
}

// ===== 5. СТАРТ =====
__attribute__((constructor))
static void init_infstam(void) {
    g_base = find_main_base();
    NSLog(@"[InfinityStamina] base = 0x%lx", (unsigned long)g_base);

    if (!g_base) {
        NSLog(@"[InfinityStamina] ОШИБКА: база игры не найдена");
        return;
    }

    // Тест оффсета (смотри в Console.app)
    int32_t test = rd32(g_base + OFF_LOCAL_PLAYER_ID);
    NSLog(@"[InfinityStamina] TEST raw = %d (id=%d)", test, test % 65536);

    start_ticker();
    setup_overlay();
}
