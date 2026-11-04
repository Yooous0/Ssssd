#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <string.h>
#import <dispatch/dispatch.h>

static uintptr_t g_base = 0;
static UITextView *g_logView = nil;
static UILabel *g_statsLabel = nil;

// Переменные для статистики
static uintptr_t g_id_offset = 0;
static volatile int g_current_id = 0;
static NSTimeInterval g_session_start = 0;

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

static inline int32_t rd32(uintptr_t a){ return *(volatile int32_t*)a; }
static inline int64_t rd64(uintptr_t a){ return *(volatile int64_t*)a; }

// ===== ПАТЧ СТАМИНЫ =====
static void patch_stamina(void) {
    if (!g_base) return;
    uintptr_t patch_addr = g_base + 0x123708;
    vm_protect(mach_task_self(), patch_addr & ~0xFFF, 0x1000, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    *(volatile uint32_t*)patch_addr = 0x52800000; // MOV W0, #1
    vm_protect(mach_task_self(), patch_addr & ~0xFFF, 0x1000, false, VM_PROT_READ | VM_PROT_EXECUTE);
    LogToMenu(@"[PATCH] Стамина включена (0x%lx)", patch_addr);
}

// ===== ПОИСК ID ИГРОКА =====
static void find_player_id(void) {
    if (!g_base) return;
    LogToMenu(@"[SCAN] Ищу ID игрока...");
    
    // Ищем указатель на мир в районе 0x3100000 (где он был у тебя)
    for (uintptr_t offset = 0x3000000; offset < 0x3300000; offset += 8) {
        @try {
            int64_t world_ptr = rd64(g_base + offset);
            if (world_ptr < 0x100000000 || world_ptr > 0x7FFFFFFFFF) continue;
            
            int32_t raw_id = rd32(g_base + offset + 8);
            int32_t id = raw_id % 65536;
            
            // Если ID от 0 до 2000 (адекватный)
            if (id > 0 && id < 2000) {
                // Проверяем, есть ли массив
                uintptr_t test_info = (uintptr_t)world_ptr + (id * 0xF8);
                int64_t test_ped = rd64(test_info);
                if (test_ped > 0x100000000 && test_ped < 0x7FFFFFFFFF) {
                    g_id_offset = offset + 8; // Запоминаем, где лежит именно ID
                    LogToMenu(@"[SCAN] УСПЕХ! ID найден. Оффсет: 0x%lx", g_id_offset);
                    return;
                }
            }
        } @catch (NSException *e) {}
    }
    LogToMenu(@"[SCAN] ID не найден (ищи в игре).");
}

// ===== ОБНОВЛЕНИЕ СТАТИСТИКИ =====
static void update_stats(void) {
    if (!g_base || g_id_offset == 0) return;
    @try {
        int32_t raw = rd32(g_base + g_id_offset);
        if (raw > 0) {
            g_current_id = raw % 65536;
        }
    } @catch (NSException *e) {}
}

static void start_stats_ticker(void) {
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 0), 500ull * NSEC_PER_MSEC, 100ull * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(t, ^{
        update_stats();
        if (g_statsLabel) {
            NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:[NSDate dateWithTimeIntervalSince1970:g_session_start]];
            int mins = (int)elapsed / 60;
            int secs = (int)elapsed % 60;
            g_statsLabel.text = [NSString stringWithFormat:@"ID: %d  |  ВСР: %02d:%02d", g_current_id, mins, secs];
        }
    });
    dispatch_resume(t);
}

// ===== МЕНЮ =====
@interface MenuView : UIView
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIButton *floatingBtn;
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

    CGFloat panelW = 280, panelH = 250;
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(20, 160, panelW, panelH)];
    self.panel.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.10 alpha:0.96];
    self.panel.layer.cornerRadius = 14;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = [UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:0.6].CGColor;
    self.panel.hidden = YES;
    [self addSubview:self.panel];
    [self.panel addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanPanel:)]];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, panelW - 32, 22)];
    title.text = @"NONERAI STATS";
    title.textColor = [UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:1];
    title.font = [UIFont boldSystemFontOfSize:16];
    [self.panel addSubview:title];

    // Плашка со статистикой
    g_statsLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 40, panelW - 32, 30)];
    g_statsLabel.text = @"ID: ---  |  ВСР: 00:00";
    g_statsLabel.textColor = [UIColor whiteColor];
    g_statsLabel.font = [UIFont fontWithName:@"Menlo-Bold" size:14] ?: [UIFont boldSystemFontOfSize:14];
    g_statsLabel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    g_statsLabel.textAlignment = NSTextAlignmentCenter;
    g_statsLabel.layer.cornerRadius = 8;
    g_statsLabel.layer.masksToBounds = YES;
    [self.panel addSubview:g_statsLabel];

    UIButton *patchBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    patchBtn.frame = CGRectMake(16, 80, panelW - 32, 36);
    [patchBtn setTitle:@"Включить НФТ бег" forState:UIControlStateNormal];
    [patchBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
    patchBtn.layer.borderWidth = 1;
    patchBtn.layer.borderColor = [UIColor greenColor].CGColor;
    patchBtn.layer.cornerRadius = 8;
    [patchBtn addTarget:self action:@selector(doPatch) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:patchBtn];

    UIButton *scanBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    scanBtn.frame = CGRectMake(16, 126, panelW - 32, 36);
    [scanBtn setTitle:@"Найти ID" forState:UIControlStateNormal];
    [scanBtn setTitleColor:[UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:1] forState:UIControlStateNormal];
    scanBtn.layer.borderWidth = 1;
    scanBtn.layer.borderColor = [UIColor colorWithRed:1 green:0.39 blue:0.28 alpha:0.5].CGColor;
    scanBtn.layer.cornerRadius = 8;
    [scanBtn addTarget:self action:@selector(doScan) forControlEvents:UIControlEventTouchUpInside];
    [self.panel addSubview:scanBtn];

    g_logView = [[UITextView alloc] initWithFrame:CGRectMake(12, 170, panelW - 24, panelH - 180)];
    g_logView.backgroundColor = [UIColor colorWithRed:0.02 green:0.02 blue:0.04 alpha:0.9];
    g_logView.textColor = [UIColor colorWithRed:0.4 green:1 blue:0.4 alpha:1];
    g_logView.font = [UIFont fontWithName:@"Menlo" size:9] ?: [UIFont systemFontOfSize:9];
    g_logView.editable = NO;
    g_logView.layer.cornerRadius = 6;
    g_logView.text = @"=== LOG ===";
    [self.panel addSubview:g_logView];
}

- (void)doPatch { patch_stamina(); }
- (void)doScan { find_player_id(); }
- (void)toggleMenu { self.menuOpen = !self.menuOpen; self.panel.hidden = !self.menuOpen; if (self.menuOpen) { CGRect b = self.floatingBtn.frame; self.panel.frame = CGRectMake(b.origin.x, b.origin.y + b.size.height + 10, 280, 250); } }
- (void)handlePanBtn:(UIPanGestureRecognizer*)g { CGPoint t = [g translationInView:self]; self.floatingBtn.center = CGPointMake(self.floatingBtn.center.x + t.x, self.floatingBtn.center.y + t.y); [g setTranslation:CGPointZero inView:self]; if (self.menuOpen) { CGRect b = self.floatingBtn.frame; self.panel.frame = CGRectMake(b.origin.x, b.origin.y + b.size.height + 10, 280, 250); } }
- (void)handlePanPanel:(UIPanGestureRecognizer*)g { CGPoint t = [g translationInView:self]; self.panel.center = CGPointMake(self.panel.center.x + t.x, self.panel.center.y + t.y); [g setTranslation:CGPointZero inView:self]; }
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
        g_session_start = [[NSDate date] timeIntervalSince1970];
        LogToMenu(@"[NONERAI] Меню загружено.");
    });
}

__attribute__((constructor))
static void init_all(void) {
    g_base = find_main_base();
    patch_stamina(); // Патчим стамину при старте
    start_stats_ticker();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ attach_menu_to_game(); });
}
