#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <dispatch/dispatch.h>
#import <math.h>

// ===== ОФФСЕТЫ СТАМИНЫ (iOS) =====
#define OFF_LOCAL_PLAYER_ID   0x31F17F0
#define OFF_WORLD_PLAYERS     0x31F17E8
#define STRIDE                0xF8
#define OFF_INF_SPRINT        0xE8
#define OFF_PED_INF_SPRINT    0x85F

// ===== ХИТБОКСЫ =====
#define HB_STEP       0x20
#define HB_COUNT      10
#define HB_MIN        0.05f
#define HB_MAX        0.35f
#define HB_MULT       2.0f

static uintptr_t g_base = 0;
static volatile int g_stamina = 0;
static volatile int g_hitbox  = 0;
static uintptr_t g_hb_table   = 0;
static float     g_hb_orig[HB_COUNT];

static inline int32_t rd32(uintptr_t a){ return *(volatile int32_t*)a; }
static inline void    wr32(uintptr_t a, int32_t v){ *(volatile int32_t*)a = v; }
static inline float   rdf32(uintptr_t a){ return *(volatile float*)a; }
static inline void    wrf32(uintptr_t a, float v){ *(volatile float*)a = v; }

// ===== ЛОГ В МЕНЮ =====
static UITextView *g_logView = nil;

static void LogToMenu(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"%@", msg);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_logView) return;
        NSString *current = g_logView.text;
        NSString *newText = [current stringByAppendingFormat:@"\n%@", msg];
        // Обрезаем до последних 2000 символов
        if (newText.length > 2000) {
            newText = [newText substringFromIndex:newText.length - 2000];
        }
        g_logView.text = newText;
        // Автоскролл вниз
        NSRange range = NSMakeRange(g_logView.text.length - 1, 1);
        [g_logView scrollRangeToVisible:range];
    });
}

// ===== БАЗА =====
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

// ===== СТАМИНА =====
static void apply_stamina(void) {
    if (!g_base) {
        LogToMenu(@"[STAM] base=0, skip");
        return;
    }

    int32_t raw = rd32(g_base + OFF_LOCAL_PLAYER_ID);
    LogToMenu(@"[STAM] raw=%d id=%d", raw, raw % 65536);

    if (!raw || raw < 0) return;

    int32_t id = raw % 65536;
    if (id < 0 || id > 1000) {
        LogToMenu(@"[STAM] id out of range: %d", id);
        return;
    }

    uintptr_t info = g_base + OFF_WORLD_PLAYERS + (uintptr_t)id * STRIDE;
    if (info < g_base || info > g_base + 0x20000000) {
        LogToMenu(@"[STAM] info out of range");
        return;
    }

    int32_t ped = rd32(info);
    LogToMenu(@"[STAM] info=0x%lx ped=0x%x", (unsigned long)info, ped);

    int32_t flag = g_stamina ? 1 : 0;

    @try {
        wr32(info + OFF_INF_SPRINT, flag);
        LogToMenu(@"[STAM] wrote info+0xE8 = %d", flag);

        if (ped && ped > 0x10000000 && ped < 0x7FFFFFFF) {
            wr32((uintptr_t)ped + OFF_PED_INF_SPRINT, flag);
            LogToMenu(@"[STAM] wrote ped+0x85F = %d", flag);
        } else {
            LogToMenu(@"[STAM] ped invalid, skip");
        }
    } @catch (NSException *e) {
        LogToMenu(@"[STAM] EXCEPTION: %@", e);
    }
}

// ===== ХИТБОКСЫ (пока отключены, но код оставлен) =====
static int looks_like_hb(uintptr_t base) {
    for (int i = 0; i < HB_COUNT; i++) {
        float v = rdf32(base + i * HB_STEP);
        if (!(v > HB_MIN && v < HB_MAX)) return 0;
    }
    int diff = 0;
    float first = rdf32(base);
    for (int i = 1; i < HB_COUNT; i++) {
        if (fabsf(rdf32(base + i * HB_STEP) - first) > 0.001f) diff++;
    }
    return diff >= 3;
}

static uintptr_t scan_hitbox_table(void) {
    if (!g_base) return 0;
    LogToMenu(@"[HB] scanning...");
    uintptr_t start = g_base;
    uintptr_t end   = g_base + 0x20000000;
    uintptr_t a = start & ~0xFFF;

    while (a < end) {
        for (uintptr_t p = a; p + HB_COUNT * HB_STEP < a + 0x10000; p += 4) {
            @try {
                if (looks_like_hb(p)) {
                    LogToMenu(@"[HB] candidate 0x%lx", (unsigned long)p);
                    return p;
                }
            } @catch (NSException *e) {}
        }
        a += 0x10000;
    }
    LogToMenu(@"[HB] not found");
    return 0;
}

static void apply_hitbox(int on) {
    if (!g_hb_table) return;
    if (g_hb_table < g_base || g_hb_table > g_base + 0x20000000) return;

    for (int i = 0; i < HB_COUNT; i++) {
        uintptr_t addr = g_hb_table + i * HB_STEP;
        @try {
            if (on) {
                if (g_hb_orig[i] == 0) g_hb_orig[i] = rdf32(addr);
                wrf32(addr, g_hb_orig[i] * HB_MULT);
            } else {
                if (g_hb_orig[i] > 0) wrf32(addr, g_hb_orig[i]);
            }
        } @catch (NSException *e) {}
    }
}

// ===== ТАЙМЕР =====
static void start_ticker(void) {
    dispatch_source_t t = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0));
    dispatch_source_set_timer(t,
        dispatch_time(DISPATCH_TIME_NOW, 0),
        500ull * NSEC_PER_MSEC, 100ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        if (g_stamina) apply_stamina();
    });
    dispatch_resume(t);
}

// ===== МЕНЮ =====
@interface MenuView : UIView
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIButton *floatingBtn;
@property (nonatomic, strong) UISwitch *swStamina;
@property (nonatomic, strong) UISwitch *swHitbox;
@property (nonatomic, assign) BOOL menuOpen;
@end

@implementation MenuView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self setup];
    return self;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.floatingBtn && !self.floatingBtn.hidden) {
        CGPoint p = [self convertPoint:point toView:self.floatingBtn];
        if ([self.floatingBtn pointInside:p withEvent:event]) return YES;
    }
    if (self.panel && !self.panel.hidden) {
        CGPoint p = [self convertPoint:point toView:self.panel];
        if ([self.panel pointInside:p withEvent:event]) return YES;
    }
    return NO;
}

- (void)setup {
    self.backgroundColor = [UIColor clearColor];
    self.menuOpen = NO;

    CGFloat btnSize = 44;
    self.floatingBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingBtn.frame = CGRectMake(20, 100, btnSize, btnSize);
    self.floatingBtn.layer.cornerRadius = btnSize / 2;
    self.floatingBtn.layer.shadowColor = [UIColor blackColor].CGColor;
    self.floatingBtn.layer.shadowOpacity = 0.5;
    self.floatingBtn.layer.shadowRadius = 4;
    self.floatingBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.15 alpha:0.95];
    self.floatingBtn.layer.borderWidth = 1.5;
    self.floatingBtn.layer.borderColor = [UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:1].CGColor;
    [self.floatingBtn setTitle:@"N" forState:UIControlStateNormal];
    [self.floatingBtn setTitleColor:[UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:1] forState:UIControlStateNormal];
    self.floatingBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [self.floatingBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.floatingBtn];

    UIPanGestureRecognizer *panBtn = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanBtn:)];
    [self.floatingBtn addGestureRecognizer:panBtn];

    // Панель (больше, чтобы влез лог)
    CGFloat panelW = 280, panelH = 400;
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(20, 160, panelW, panelH)];
    self.panel.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:0.96];
    self.panel.layer.cornerRadius = 14;
    self.panel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.panel.layer.shadowOpacity = 0.6;
    self.panel.layer.shadowRadius = 10;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = [UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:0.6].CGColor;
    self.panel.hidden = YES;
    [self addSubview:self.panel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, panelW - 32, 22)];
    title.text = @"NONERAI";
    title.textColor = [UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:16];
    [self.panel addSubview:title];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(12, 42, panelW - 24, 1)];
    sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    [self.panel addSubview:sep];

    // Свитч 1: НФТ бег
    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(16, 52, 140, 24)];
    l1.text = @"НФТ бег";
    l1.textColor = [UIColor whiteColor];
    l1.font = [UIFont systemFontOfSize:14];
    [self.panel addSubview:l1];

    self.swStamina = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 70, 48, 51, 31)];
    self.swStamina.transform = CGAffineTransformMakeScale(0.8, 0.8);
    [self.swStamina addTarget:self action:@selector(toggleStamina:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.swStamina];

    // Свитч 2: Хитбоксы
    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(16, 92, 140, 24)];
    l2.text = @"Хитбоксы";
    l2.textColor = [UIColor whiteColor];
    l2.font = [UIFont systemFontOfSize:14];
    [self.panel addSubview:l2];

    self.swHitbox = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 70, 88, 51, 31)];
    self.swHitbox.transform = CGAffineTransformMakeScale(0.8, 0.8);
    [self.swHitbox addTarget:self action:@selector(toggleHitbox:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.swHitbox];

    // Лог
    UILabel *logLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 128, panelW - 32, 16)];
    logLabel.text = @"ЛОГ:";
    logLabel.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    logLabel.font = [UIFont systemFontOfSize:11];
    [self.panel addSubview:logLabel];

    g_logView = [[UITextView alloc] initWithFrame:CGRectMake(12, 146, panelW - 24, panelH - 160)];
    g_logView.backgroundColor = [UIColor colorWithRed:0.02 green:0.02 blue:0.04 alpha:0.9];
    g_logView.textColor = [UIColor colorWithRed:0.4 green:1 blue:0.4 alpha:1];
    g_logView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    g_logView.editable = NO;
    g_logView.layer.cornerRadius = 6;
    g_logView.text = @"=== LOG START ===";
    [self.panel addSubview:g_logView];

    UIPanGestureRecognizer *panPanel = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanPanel:)];
    [self.panel addGestureRecognizer:panPanel];
}

- (void)toggleMenu {
    self.menuOpen = !self.menuOpen;
    self.panel.hidden = !self.menuOpen;
    if (self.menuOpen) {
        CGRect btn = self.floatingBtn.frame;
        self.panel.frame = CGRectMake(btn.origin.x, btn.origin.y + btn.size.height + 10, 280, 400);
    }
}

- (void)handlePanBtn:(UIPanGestureRecognizer*)g {
    CGPoint t = [g translationInView:self];
    self.floatingBtn.center = CGPointMake(self.floatingBtn.center.x + t.x, self.floatingBtn.center.y + t.y);
    [g setTranslation:CGPointZero inView:self];
    if (self.menuOpen) {
        CGRect btn = self.floatingBtn.frame;
        self.panel.frame = CGRectMake(btn.origin.x, btn.origin.y + btn.size.height + 10, 280, 400);
    }
}

- (void)handlePanPanel:(UIPanGestureRecognizer*)g {
    CGPoint t = [g translationInView:self];
    self.panel.center = CGPointMake(self.panel.center.x + t.x, self.panel.center.y + t.y);
    [g setTranslation:CGPointZero inView:self];
}

- (void)toggleStamina:(UISwitch*)s {
    g_stamina = s.isOn ? 1 : 0;
    LogToMenu(@"[MENU] Stamina %@", s.isOn ? @"ON" : @"OFF");
    apply_stamina();
}

- (void)toggleHitbox:(UISwitch*)s {
    g_hitbox = s.isOn ? 1 : 0;
    LogToMenu(@"[MENU] Hitbox %@", s.isOn ? @"ON" : @"OFF");
    if (s.isOn) {
        if (!g_hb_table) {
            g_hb_table = scan_hitbox_table();
            if (g_hb_table) {
                for (int i = 0; i < HB_COUNT; i++) g_hb_orig[i] = 0;
            }
        }
        if (g_hb_table) {
            apply_hitbox(1);
            LogToMenu(@"[HB] ON table=0x%lx", (unsigned long)g_hb_table);
        } else {
            LogToMenu(@"[HB] table not found");
        }
    } else {
        apply_hitbox(0);
    }
}

@end

// ===== ПРИКРЕПЛЕНИЕ =====
static MenuView *g_menu = nil;

static void attach_menu_to_game(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *gameWindow = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { gameWindow = w; break; }
        }
        if (!gameWindow) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{ attach_menu_to_game(); });
            return;
        }
        g_menu = [[MenuView alloc] initWithFrame:gameWindow.bounds];
        g_menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [gameWindow addSubview:g_menu];
        [gameWindow bringSubviewToFront:g_menu];

        LogToMenu(@"[NONERAI] Menu attached");
        LogToMenu(@"[NONERAI] base = 0x%lx", (unsigned long)g_base);
    });
}

__attribute__((constructor))
static void init_all(void) {
    g_base = find_main_base();
    start_ticker();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ attach_menu_to_game(); });
}
