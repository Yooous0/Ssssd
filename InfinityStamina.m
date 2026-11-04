#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <dispatch/dispatch.h>

static uintptr_t g_base = 0;
static volatile int g_stamina = 0;
static uintptr_t g_id_offset = 0;
static uintptr_t g_world_offset = 0;

#define STRIDE                0xF8
#define OFF_INF_SPRINT        0xE8
#define OFF_PED_INF_SPRINT    0x85F

static UITextView *g_logView = nil;
static inline int32_t rd32(uintptr_t a){ return *(volatile int32_t*)a; }
static inline void    wr32(uintptr_t a, int32_t v){ *(volatile int32_t*)a = v; }

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

// ===== СКАНЕР =====
static void auto_find_offset(void) {
    if (!g_base) return;
    
    uintptr_t start_search = 0x3000000;
    uintptr_t end_search   = 0x3500000;
    
    LogToMenu(@"[SCAN] Ищу связку ID (0-1500) и World...");
    
    for (uintptr_t offset = start_search; offset < end_search; offset += 4) {
        @try {
            int32_t raw_id = rd32(g_base + offset);
            if (raw_id <= 0 || raw_id > 100000000) continue;
            
            int32_t id = raw_id % 65536;
            // ID от 0 до 1500
            if (id <= 0 || id > 1500) continue;
            
            // Проверяем указатель на мир (-8 байт)
            uintptr_t world_ptr = g_base + offset - 8;
            int32_t world_val = rd32(world_ptr);
            
            if (world_val > 0x10000000 && world_val < 0x7FFFFFFF) {
                
                // Проверяем, лежит ли по адресу (world + id*stride) указатель на Ped
                uintptr_t test_info = (uintptr_t)world_val + (id * STRIDE);
                int32_t test_ped = rd32(test_info);
                
                if (test_ped > 0x10000000 && test_ped < 0x7FFFFFFF) {
                    g_id_offset = offset;
                    g_world_offset = world_ptr;
                    
                    LogToMenu(@"[SCAN] УСПЕХ!");
                    LogToMenu(@"[SCAN] ID оффсет: 0x%lx", offset);
                    LogToMenu(@"[SCAN] World ptr: 0x%x", world_val);
                    LogToMenu(@"[SCAN] Найден ID: %d", id);
                    LogToMenu(@"[SCAN] Найден Ped: 0x%x", test_ped);
                    return;
                }
            }
        } @catch (NSException *e) {}
    }
    LogToMenu(@"[SCAN] Не найдено.");
}

// ===== ПРИМЕНЕНИЕ =====
static void apply_stamina(void) {
    if (!g_base || g_id_offset == 0) return;
    
    int32_t raw_id = rd32(g_base + g_id_offset);
    if (raw_id <= 0) return;
    
    int32_t id = raw_id % 65536;
    int32_t world_ptr = rd32(g_base + g_world_offset);
    if (world_ptr <= 0) return;

    uintptr_t info = (uintptr_t)world_ptr + (id * STRIDE);
    int32_t ped = rd32(info);
    int32_t flag = g_stamina ? 1 : 0;
    
    @try {
        wr32(info + OFF_INF_SPRINT, flag);
        if (ped > 0x10000000 && ped < 0x7FFFFFFF) {
            wr32((uintptr_t)ped + OFF_PED_INF_SPRINT, flag);
        }
    } @catch (NSException *e) {}
}

static void start_ticker(void) {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0));
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 500ull * NSEC_PER_MSEC, 100ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{ if (g_stamina) apply_stamina(); });
    dispatch_resume(t);
}

// ===== МЕНЮ =====
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
    CGFloat btnSize = 44;
    self.floatingBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    self.floatingBtn.frame = CGRectMake(20, 100, btnSize, btnSize);
    self.floatingBtn.layer.cornerRadius = btnSize / 2;
    self.floatingBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.15 alpha:0.95];
    self.floatingBtn.layer.borderWidth = 1.5;
    self.floatingBtn.layer.borderColor = [UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:1].CGColor;
    [self.floatingBtn setTitle:@"N" forState:UIControlStateNormal];
    [self.floatingBtn setTitleColor:[UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:1] forState:UIControlStateNormal];
    self.floatingBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
    [self.floatingBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:self.floatingBtn];
    [self.floatingBtn addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanBtn:)]];

    CGFloat panelW = 300, panelH = 400;
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(20, 160, panelW, panelH)];
    self.panel.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:0.96];
    self.panel.layer.cornerRadius = 14;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = [UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:0.6].CGColor;
    self.panel.hidden = YES;
    [self addSubview:self.panel];
    [self.panel addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanPanel:)]];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, panelW - 32, 22)];
    title.text = @"NONERAI AUTO";
    title.textColor = [UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:16];
    [self.panel addSubview:title];

    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(16, 50, 140, 24)];
    l1.text = @"НФТ бег";
    l1.textColor = [UIColor whiteColor];
    [self.panel addSubview:l1];

    self.swStamina = [[UISwitch alloc] initWithFrame:CGRectMake(panelW - 70, 46, 51, 31)];
    self.swStamina.transform = CGAffineTransformMakeScale(0.8, 0.8);
    [self.swStamina addTarget:self action:@selector(toggleStamina:) forControlEvents:UIControlEventValueChanged];
    [self.panel addSubview:self.swStamina];

    UIButton *scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    scanBtn.frame = CGRectMake(16, 90, panelW - 32, 36);
    [scanBtn setTitle:@"Найти оффсет (в игре)" forState:UIControlStateNormal];
    [scanBtn setTitleColor:[UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:1] forState:UIControlStateNormal];
    scanBtn.layer.borderWidth = 1;
    scanBtn.layer.borderColor = [UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:0.5].CGColor;
    scanBtn.layer.cornerRadius = 8;
    [scanBtn addTarget:self action:@selector(doScan) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:scanBtn];

    g_logView = [[UITextView alloc] initWithFrame:CGRectMake(12, 136, panelW - 24, panelH - 150)];
    g_logView.backgroundColor = [UIColor colorWithRed:0.02 green:0.02 blue:0.04 alpha:0.9];
    g_logView.textColor = [UIColor colorWithRed:0.4 green:1 blue:0.4 alpha:1];
    g_logView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
    g_logView.editable = NO;
    g_logView.layer.cornerRadius = 6;
    g_logView.text = @"=== LOG START ===";
    [self.panel addSubview:g_logView];
}

- (void)doScan { auto_find_offset(); }
- (void)toggleMenu { self.menuOpen = !self.menuOpen; self.panel.hidden = !self.menuOpen; if (self.menuOpen) { CGRect b = self.floatingBtn.frame; self.panel.frame = CGRectMake(b.origin.x, b.origin.y + b.size.height + 10, 300, 400); } }
- (void)handlePanBtn:(UIPanGestureRecognizer*)g { CGPoint t = [g translationInView:self]; self.floatingBtn.center = CGPointMake(self.floatingBtn.center.x + t.x, self.floatingBtn.center.y + t.y); [g setTranslation:CGPointZero inView:self]; if (self.menuOpen) { CGRect b = self.floatingBtn.frame; self.panel.frame = CGRectMake(b.origin.x, b.origin.y + b.size.height + 10, 300, 400); } }
- (void)handlePanPanel:(UIPanGestureRecognizer*)g { CGPoint t = [g translationInView:self]; self.panel.center = CGPointMake(self.panel.center.x + t.x, self.panel.center.y + t.y); [g setTranslation:CGPointZero inView:self]; }
- (void)toggleStamina:(UISwitch*)s { g_stamina = s.isOn ? 1 : 0; LogToMenu(@"[MENU] Stamina %@", s.isOn ? @"ON" : @"OFF"); apply_stamina(); }
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
        LogToMenu(@"[NONERAI] Menu OK");
    });
}

__attribute__((constructor))
static void init_all(void) {
    g_base = find_main_base();
    start_ticker();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ attach_menu_to_game(); });
}
