#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <dispatch/dispatch.h>

// ===== ОФФСЕТЫ СТАМИНЫ (iOS, из Lua) =====
#define OFF_LOCAL_PLAYER_ID   0x31F17F0
#define OFF_WORLD_PLAYERS     0x31F17E8
#define STRIDE                0xF8
#define OFF_INF_SPRINT        0xE8
#define OFF_PED_INF_SPRINT    0x85F
// =========================================

// ===== ХИТБОКСЫ (универсальный скан) =====
#define HB_STEP       0x20
#define HB_COUNT      10
#define HB_MIN        0.05f
#define HB_MAX        0.35f
#define HB_MULT       6.0f
// =========================================

static uintptr_t g_base = 0;
static volatile int g_stamina = 0;
static volatile int g_hitbox  = 0;
static uintptr_t g_hb_table   = 0;
static UIWindow *g_overlay    = nil;

static inline int32_t rd32(uintptr_t a){ return *(volatile int32_t*)a; }
static inline void    wr32(uintptr_t a, int32_t v){ *(volatile int32_t*)a = v; }
static inline float   rdf32(uintptr_t a){ return *(volatile float*)a; }
static inline void    wrf32(uintptr_t a, float v){ *(volatile float*)a = v; }

// ===== 1. БАЗА ИГРЫ =====
static uintptr_t find_main_base(void) {
    char path[4096];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return 0;

    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (p && strcmp(p, path) == 0)
            return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

// ===== 2. СТАМИНА =====
static void apply_stamina(void) {
    if (!g_base) return;
    int32_t raw = rd32(g_base + OFF_LOCAL_PLAYER_ID);
    if (!raw) return;
    int32_t id = raw % 65536;
    uintptr_t info = g_base + OFF_WORLD_PLAYERS + (uintptr_t)id * STRIDE;
    int32_t ped = rd32(info);
    int32_t flag = g_stamina ? 1 : 0;
    wr32(info + OFF_INF_SPRINT, flag);
    if (ped) wr32((uintptr_t)ped + OFF_PED_INF_SPRINT, flag);
}

// ===== 3. ХИТБОКСЫ — поиск таблицы =====
static int looks_like_hb(uintptr_t base) {
    for (int i = 0; i < HB_COUNT; i++) {
        float v = rdf32(base + i * HB_STEP);
        if (!(v > HB_MIN && v < HB_MAX)) return 0;
    }
    // хотя бы 3 разных значения
    int diff = 0;
    float first = rdf32(base);
    for (int i = 1; i < HB_COUNT; i++) {
        if (fabsf(rdf32(base + i * HB_STEP) - first) > 0.001f) diff++;
    }
    return diff >= 3;
}

static uintptr_t scan_hitbox_table(void) {
    // Ищем в rw-памяти игры (только диапазон модуля игры ± 512MB)
    if (!g_base) return 0;
    uintptr_t start = g_base;
    uintptr_t end   = g_base + 0x20000000; // 512 MB

    uintptr_t a = start & ~0xFFF;
    while (a < end) {
        for (int i = 0; i < HB_COUNT; i++) {
            // пробуем каждые 4 байта (float-выравнивание)
        }
        // простой проход по 4 байта
        for (uintptr_t p = a; p + HB_COUNT * HB_STEP < a + 0x10000; p += 4) {
            if (looks_like_hb(p)) {
                NSLog(@"[HB] candidate at 0x%lx", (unsigned long)p);
                return p;
            }
        }
        a += 0x10000;
    }
    return 0;
}

static void apply_hitbox(void) {
    if (!g_hb_table) return;
    for (int i = 0; i < HB_COUNT; i++) {
        uintptr_t addr = g_hb_table + i * HB_STEP;
        float orig = rdf32(addr);
        // Если ещё не умножено — умножаем
        if (g_hitbox) {
            if (orig > 0.01f && orig < 1.0f) wrf32(addr, orig * HB_MULT);
        }
    }
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
        if (g_stamina) apply_stamina();
        // хитбоксы не перезаписываем каждые 0.5 сек, иначе будем умножать бесконечно
    });
    dispatch_resume(t);
}

// ===== 5. UI =====
@interface Ctrl : NSObject
- (void)toggleStamina:(UISwitch*)s;
- (void)toggleHitbox:(UISwitch*)s;
@end

@implementation Ctrl
- (void)toggleStamina:(UISwitch*)s {
    g_stamina = s.isOn ? 1 : 0;
    apply_stamina();
    NSLog(@"[InfStamina] %@", s.isOn ? @"ON" : @"OFF");
}
- (void)toggleHitbox:(UISwitch*)s {
    g_hitbox = s.isOn ? 1 : 0;
    if (s.isOn) {
        if (!g_hb_table) {
            NSLog(@"[HB] scanning...");
            g_hb_table = scan_hitbox_table();
        }
        if (g_hb_table) {
            apply_hitbox();
            NSLog(@"[HB] ON, table=0x%lx", (unsigned long)g_hb_table);
        } else {
            NSLog(@"[HB] table not found");
        }
    } else {
        NSLog(@"[HB] OFF");
    }
}
@end

static Ctrl *g_ctrl = nil;

static void setup_overlay(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!UIApplication.sharedApplication) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{ setup_overlay(); });
            return;
        }

        g_ctrl = [Ctrl new];

        g_overlay = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        g_overlay.windowLevel = UIWindowLevelAlert + 1;
        g_overlay.backgroundColor = [UIColor clearColor];
        g_overlay.rootViewController = [UIViewController new];
        g_overlay.hidden = NO;

        UIView *root = g_overlay.rootViewController.view;

        // Свитч 1: НФТ бег
        UISwitch *sw1 = [[UISwitch alloc] initWithFrame:CGRectMake(20, 100, 60, 30)];
        [sw1 addTarget:g_ctrl action:@selector(toggleStamina:)
       forControlEvents:UIControlEventValueChanged];
        [root addSubview:sw1];

        UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(90, 100, 220, 30)];
        l1.text = @"НФТ бег";
        l1.textColor = [UIColor greenColor];
        l1.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        [root addSubview:l1];

        // Свитч 2: Хитбоксы
        UISwitch *sw2 = [[UISwitch alloc] initWithFrame:CGRectMake(20, 150, 60, 30)];
        [sw2 addTarget:g_ctrl action:@selector(toggleHitbox:)
       forControlEvents:UIControlEventValueChanged];
        [root addSubview:sw2];

        UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(90, 150, 220, 30)];
        l2.text = @"Хитбоксы";
        l2.textColor = [UIColor yellowColor];
        l2.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        [root addSubview:l2];

        // Индикатор работы dylib
        UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(20, 200, 300, 30)];
        l3.text = [NSString stringWithFormat:@"dylib OK, base=0x%lx", (unsigned long)g_base];
        l3.textColor = [UIColor whiteColor];
        l3.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        l3.font = [UIFont systemFontOfSize:11];
        [root addSubview:l3];

        NSLog(@"[NONERAI] Overlay OK, base=0x%lx", (unsigned long)g_base);
    });
}

// ===== 6. СТАРТ =====
__attribute__((constructor))
static void init_all(void) {
    g_base = find_main_base();
    NSLog(@"[NONERAI] base = 0x%lx", (unsigned long)g_base);

    if (!g_base) {
        NSLog(@"[NONERAI] ОШИБКА: база не найдена");
        return;
    }

    // Тест оффсета стамины
    int32_t test = rd32(g_base + OFF_LOCAL_PLAYER_ID);
    NSLog(@"[NONERAI] stamina TEST raw = %d (id=%d)", test, test % 65536);

    start_ticker();
    setup_overlay();
}
