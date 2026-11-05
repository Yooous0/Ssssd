#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <dispatch/dispatch.h>

static uintptr_t g_base = 0;
static UITextView *g_logView = nil;
static UILabel *g_statsLabel = nil;

static uintptr_t OFF_LOCAL_PLAYER_ID = 0x31F17E8;
static uintptr_t g_stamina_addr = 0; // Сюда запишется адрес стамины

static volatile int g_stamina = 0;
static volatile int g_current_id = 0;

static void LogToMenu(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_logView) return;
        NSString *newText = [g_logView.text stringByAppendingFormat:@"\n%@", msg];
        if (newText.length > 3000) newText = [newText substringFromIndex:newText.length - 3000];
        g_logView.text = newText;
        [g_logView scrollRangeToVisible:NSMakeRange(g_logView.text.length - 1, 1)];
    });
}

static uintptr_t find_main_base(void) {
    char path[4096]; uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return 0;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *p = _dyld_get_image_name(i);
        if (p && strcmp(p, path) == 0) return (uintptr_t)_dyld_get_image_header(i);
    }
    return 0;
}

static inline int16_t rd16(uintptr_t a){ return *(volatile int16_t*)a; }
static inline float   rdf32(uintptr_t a){ return *(volatile float*)a; }
static inline void    wrf32(uintptr_t a, float v){ *(volatile float*)a = v; }

// ===== УМНЫЙ ПОИСК СТАМИНЫ РЯДОМ С ID =====
static void find_stamina(void) {
    if (!g_base) return;
    LogToMenu(@"[SCAN] Ищу стамину (float 1-100) рядом с ID...");
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        uintptr_t id_addr = g_base + OFF_LOCAL_PLAYER_ID;
        
        // Сканируем 4 КБ памяти вокруг твоего ID
        for (int offset = -0x1000; offset < 0x1000; offset += 4) {
            uintptr_t check_addr = id_addr + offset;
            @try {
                float val = rdf32(check_addr);
                // Ищем дробное число, похожее на стамину (от 1.0 до 100.0)
                if (val >= 1.0f && val <= 100.0f) {
                    g_stamina_addr = check_addr;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        LogToMenu(@"[SCAN] Найдена стамина: %.1f", val);
                        LogToMenu(@"[SCAN] Включи свитч!");
                    });
                    return;
                }
            } @catch (NSException *e) {}
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            LogToMenu(@"[SCAN] Не нашел. Поищи через VansonLoader.");
        });
    });
}

// ===== ПРОЦЕСС =====
static void process_memory(void) {
    if (!g_base) return;
    @try {
        // Читаем ID (16 бит)
        int16_t id = rd16(g_base + OFF_LOCAL_PLAYER_ID);
        if (id > 0 && id < 2000) g_current_id = id;
        
        // Если свитч включен — замораживаем стамину
        if (g_stamina && g_stamina_addr != 0) {
            wrf32(g_stamina_addr, 100.0f);
        }
    } @catch (NSException *e) {}
}

static void start_ticker(void) {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0));
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 30ull * NSEC_PER_MSEC, 10ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{ process_memory(); });
    dispatch_resume(t);
}

// ===== МЕНЮ (ТЕМНО-БЕЛЫЙ СТИЛЬ) =====
@interface MenuView : UIView
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIButton *floatingBtn;
@property (nonatomic, strong) UISwitch *swStamina;
@property (nonatomic, assign) BOOL menuOpen;
@end

@implementation MenuView
- (instancetype)initWithFrame:(CGRect)frame { self = [super initWithFrame:frame]; if (self) [self setup]; return self; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.floatingBtn && !self.floatingBtn.hidden && [self.floatingBtn pointInside:[self convertPoint:point toView:self.floatingBtn] withEvent:event]) return YES;
    if (self.panel && !self.panel.hidden && [self.panel pointInside:[self convertPoint:point toView:self.panel] withEvent:event]) return YES;
    return NO;
}

- (void)setup {
    self.backgroundColor = [UIColor clearColor];
    
    // Плавающая кнопка
    CGFloat btnSize = 44;
    self.floatingBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingBtn.frame = CGRectMake(20, 100, btnSize, btnSize);
    self.floatingBtn.layer.cornerRadius = btnSize / 2;
    self.floatingBtn.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
    self.floatingBtn.layer.borderWidth = 1.0;
    self.floatingBtn.layer.borderColor = [UIColor colorWithWhite:0.8 alpha:1.0].CGColor;
    [self.floatingBtn setTitle:@"N" forState:UIControlStateNormal];
    [self.floatingBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.floatingBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [self.floatingBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.floatingBtn];
    [self.floatingBtn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanBtn:)]];

    // Панель
    CGFloat panelW = 280, panelH = 250;
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(20, 160, panelW, panelH)];
    self.panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.96];
    self.panel.layer.cornerRadius = 14;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = [UIColor colorWithWhite:0.4 alpha:1.0].CGColor;
    self.panel.hidden = YES;
    [self addSubview:self.panel];
    [self.panel addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanPanel:)]];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, panelW - 32, 22)];
    title.text = @"NOIR CLIENT";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:16];
    [self.panel addSubview:title];

    g_statsLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, panelW - 32, 30)];
    g_statsLabel.text = @"ID: ---";
    g_statsLabel.textColor = [UIColor whiteColor];
    g_statsLabel.font = [UIFont fontWithName:@"Menlo-Bold" size:14] ?: [UIFont boldSystemFontOfSize:14];
    g_statsLabel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    g_statsLabel.textAlignment = NSTextAlignmentCenter;
    g_statsLabel.layer.cornerRadius = 8;
    g_statsLabel.layer.masksToBounds = YES;
    [self.panel addSubview:g_statsLabel];

    self.swStamina = [[UISwitch alloc] initWithFrame:CGRectMake(16, 80, 51, 31)];
    self.swStamina.transform = CGAffineTransformMakeScale(0.8, 0.8);
    self.swStamina.onTintColor = [UIColor whiteColor];
    [self.swStamina addTarget:self action:@selector(toggleStamina:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.swStamina];
    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(70, 85, 140, 24)];
    l1.text = @"НФТ бег";
    l1.textColor = [UIColor whiteColor];
    [self.panel addSubview:l1];

    UIButton *scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    scanBtn.frame = CGRectMake(16, 120, panelW - 32, 36);
    scanBtn.layer.borderWidth = 1;
    scanBtn.layer.borderColor = [UIColor colorWithWhite:0.6 alpha:0.5].CGColor;
    scanBtn.layer.cornerRadius = 8;
    [scanBtn setTitle:@"Найти стамину" forState:UIControlStateNormal];
    [scanBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [scanBtn addTarget:self action:@selector(doScan) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:scanBtn];

    g_logView = [[UITextView alloc] initWithFrame:CGRectMake(12, 165, panelW - 24, panelH - 175)];
    g_logView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.9];
    g_logView.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    g_logView.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    g_logView.editable = NO;
    g_logView.layer.cornerRadius = 6;
    g_logView.text = @"=== LOG ===";
    [self.panel addSubview:g_logView];
}

- (void)doScan { find_stamina(); }
- (void)toggleMenu { self.menuOpen = !self.menuOpen; self.panel.hidden = !self.menuOpen; if (self.menuOpen) { CGRect b = self.floatingBtn.frame; self.panel.frame = CGRectMake(b.origin.x, b.origin.y + b.size.height + 10, 280, 250); } }
- (void)handlePanBtn:(UIPanGestureRecognizer*)g { CGPoint t = [g translationInView:self]; self.floatingBtn.center = CGPointMake(self.floatingBtn.center.x + t.x, self.floatingBtn.center.y + t.y); [g setTranslation:CGPointZero inView:self]; if (self.menuOpen) { CGRect b = self.floatingBtn.frame; self.panel.frame = CGRectMake(b.origin.x, b.origin.y + b.size.height + 10, 280, 250); } }
- (void)handlePanPanel:(UIPanGestureRecognizer*)g { CGPoint t = [g translationInView:self]; self.panel.center = CGPointMake(self.panel.center.x + t.x, self.panel.center.y + t.y); [g setTranslation:CGPointZero inView:self]; }
- (void)toggleStamina:(UISwitch*)s { g_stamina = s.isOn ? 1 : 0; LogToMenu(@"[MENU] НФТ бег %@", s.isOn ? @"ON" : @"OFF"); if(g_stamina) find_stamina(); }
@end

static MenuView *g_menu = nil;
static void attach_menu_to_game(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *gameWindow = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) { if (w.isKeyWindow) { gameWindow = w; break; } }
        if (!gameWindow) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ attach_menu_to_game(); }); return; }
        g_menu = [[MenuView alloc] initWithFrame:gameWindow.bounds];
        g_menu.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [gameWindow addSubview:g_menu];
        [gameWindow bringSubviewToFront:g_menu];
        
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
            if (g_statsLabel) {
                g_statsLabel.text = [NSString stringWithFormat:@"ID: %d", g_current_id];
            }
        }];
    });
}

__attribute__((constructor))
static void init_all(void) {
    g_base = find_main_base();
    start_ticker();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ attach_menu_to_game(); });
}
