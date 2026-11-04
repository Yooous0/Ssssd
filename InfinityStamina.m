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
#define HB_MULT       6.0f

static uintptr_t g_base = 0;
static volatile int g_stamina = 0;
static volatile int g_hitbox  = 0;
static uintptr_t g_hb_table   = 0;
static UIView *g_menuContainer = nil;

static inline int32_t rd32(uintptr_t a){ return *(volatile int32_t*)a; }
static inline void    wr32(uintptr_t a, int32_t v){ *(volatile int32_t*)a = v; }
static inline float   rdf32(uintptr_t a){ return *(volatile float*)a; }
static inline void    wrf32(uintptr_t a, float v){ *(volatile float*)a = v; }

// ===== БАЗА ИГРЫ =====
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

// ===== ХИТБОКСЫ (СКАН) =====
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
    uintptr_t start = g_base;
    uintptr_t end   = g_base + 0x20000000;
    uintptr_t a = start & ~0xFFF;
    while (a < end) {
        for (uintptr_t p = a; p + HB_COUNT * HB_STEP < a + 0x10000; p += 4) {
            @try {
                if (looks_like_hb(p)) {
                    NSLog(@"[HB] candidate at 0x%lx", (unsigned long)p);
                    return p;
                }
            } @catch (NSException *e) {}
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
        if (g_hitbox) {
            if (orig > 0.01f && orig < 1.0f) wrf32(addr, orig * HB_MULT);
        }
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

// ===== КАСТОМНОЕ МЕНЮ (ВНУТРИ ОКНА ИГРЫ) =====
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

- (void)setup {
    self.backgroundColor = [UIColor clearColor];
    self.menuOpen = NO;

    // Плавающая кнопка
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

    // Панель
    CGFloat panelW = 240;
    CGFloat panelH = 180;
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

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(16, 32, panelW - 32, 16)];
    sub.text = @"iOS mod menu";
    sub.textColor = [UIColor colorWithWhite:0.6 alpha:1];
    sub.font = [UIFont systemFontOfSize:11];
    [self.panel addSubview:sub];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(12, 56, panelW - 24, 1)];
    sep.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    [self.panel addSubview:sep];

    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(16, 72, 140, 24)];
    l1.text = @"НФТ бег";
    l1.textColor = [UIColor whiteColor];
    l1.font = [UIFont systemFontOfSize:14];
    [self.panel addSubview:l1];

    self.swStamina = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 70, 68, 51, 31)];
    self.swStamina.transform = CGAffineTransformMakeScale(0.8, 0.8);
    [self.swStamina addTarget:self action:@selector(toggleStamina:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.swStamina];

    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(16, 112, 140, 24)];
    l2.text = @"Хитбоксы";
    l2.textColor = [UIColor whiteColor];
    l2.font = [UIFont systemFontOfSize:14];
    [self.panel addSubview:l2];

    self.swHitbox = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 70, 108, 51, 31)];
    self.swHitbox.transform = CGAffineTransformMakeScale(0.8, 0.8);
    [self.swHitbox addTarget:self action:@selector(toggleHitbox:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.swHitbox];

    UILabel *status = [[UILabel alloc] initWithFrame:CGRectMake(16, panelH - 26, panelW - 32, 16)];
    status.text = [NSString stringWithFormat:@"base: 0x%lx", (unsigned long)g_base];
    status.textColor = [UIColor colorWithWhite:0.5 alpha:1];
    status.font = [UIFont systemFontOfSize:10];
    [self.panel addSubview:status];

    UIPanGestureRecognizer *panPanel = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanPanel:)];
    [self.panel addGestureRecognizer:panPanel];
}

- (void)toggleMenu {
    self.menuOpen = !self.menuOpen;
    self.panel.hidden = !self.menuOpen;
    if (self.menuOpen) {
        CGRect btn = self.floatingBtn.frame;
        self.panel.frame = CGRectMake(btn.origin.x, btn.origin.y + btn.size.height + 10, 240, 180);
    }
}

- (void)handlePanBtn:(UIPanGestureRecognizer*)g {
    CGPoint t = [g translationInView:self];
    self.floatingBtn.center = CGPointMake(self.floatingBtn.center.x + t.x, self.floatingBtn.center.y + t.y);
    [g setTranslation:CGPointZero inView:self];
    if (self.menuOpen) {
        CGRect btn = self.floatingBtn.frame;
        self.panel.frame = CGRectMake(btn.origin.x, btn.origin.y + btn.size.height + 10, 240, 180);
    }
}

- (void)handlePanPanel:(UIPanGestureRecognizer*)g {
    CGPoint t = [g translationInView:self];
    self.panel.center = CGPointMake(self.panel.center.x + t.x, self.panel.center.y + t.y);
    [g setTranslation:CGPointZero inView:self];
}

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

// ===== УСТАНОВКА МЕНЮ В ОКНО ИГРЫ =====
static MenuView *g_menu = nil;

static void attach_menu_to_game(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // Ищем keyWindow игры
        UIWindow *gameWindow = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isKeyWindow) { gameWindow = w; break; }
        }
        
        if (!gameWindow) {
            // Ждём дальше
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{ attach_menu_to_game(); });
            return;
        }

        // Создаём меню и добавляем ПРЯМО в окно игры
        g_menu = [[MenuView alloc] initWithFrame:gameWindow.bounds];
        g_menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [gameWindow addSubview:g_menu];
        
        // Поднимаем на самый верх
        [gameWindow bringSubviewToFront:g_menu];

        NSLog(@"[NONERAI] Menu attached to game window, base=0x%lx", (unsigned long)g_base);
    });
}

// ===== СТАРТ =====
__attribute__((constructor))
static void init_all(void) {
    g_base = find_main_base();
    NSLog(@"[NONERAI] base = 0x%lx", (unsigned long)g_base);
    if (!g_base) { NSLog(@"[NONERAI] base not found"); return; }

    start_ticker();

    // Пытаемся прикрепить меню через 3 секунды (когда игра загрузится)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{ attach_menu_to_game(); });
}
