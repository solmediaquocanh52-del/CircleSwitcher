#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>
#import <dlfcn.h>
#import <math.h>

#define CS_DOMAIN CFSTR("com.vn.circleswitcher")
#define CS_LOGFILE @"/var/mobile/Documents/CircleSwitcher.log"
#define CS_TEST_NOTE CFSTR("com.vn.circleswitcher/test")
#define CS_RESPRING_NOTE CFSTR("com.vn.circleswitcher/respring")

#pragma mark - prefs

static BOOL prefBool(CFStringRef key, BOOL def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, CS_DOMAIN);
    if (!v) return def;
    BOOL r = def;
    if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue(v);
    else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int n = 0; CFNumberGetValue(v, kCFNumberIntType, &n); r = (n != 0); }
    CFRelease(v);
    return r;
}

static double prefDouble(CFStringRef key, double def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, CS_DOMAIN);
    if (!v) return def;
    double r = def;
    if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberDoubleType, &r);
    CFRelease(v);
    return r;
}

typedef struct {
    BOOL enabled, icon, onlyFront, nameIcon, ram, inertia, haptic, dots, bubOn, keepPinned, debug;
    int count, namePos, mode;
    double radius, tilt, cam, blur, size, off, bubSize;
} CSCfg;
static CSCfg C;

static void loadCfg(void) {
    CFPreferencesAppSynchronize(CS_DOMAIN);
    C.enabled = prefBool(CFSTR("enabled"), YES);
    C.mode = (int)prefDouble(CFSTR("mode"), 2);
    C.icon = prefBool(CFSTR("icon"), YES);
    C.onlyFront = prefBool(CFSTR("onlyFront"), NO);
    C.nameIcon = prefBool(CFSTR("nameIcon"), YES);
    C.ram = prefBool(CFSTR("ram"), NO);
    C.inertia = prefBool(CFSTR("inertia"), YES);
    C.haptic = prefBool(CFSTR("haptic"), YES);
    C.dots = prefBool(CFSTR("dots"), YES);
    C.bubOn = prefBool(CFSTR("bubOn"), YES);
    C.keepPinned = prefBool(CFSTR("keepPinned"), YES);
    C.debug = prefBool(CFSTR("debug"), YES);
    C.count = (int)lround(prefDouble(CFSTR("count"), 8));
    if (C.count < 3) C.count = 3;
    if (C.count > 12) C.count = 12;
    C.namePos = (int)prefDouble(CFSTR("namePos"), 2);
    C.radius = prefDouble(CFSTR("radius"), 130);
    C.tilt = prefDouble(CFSTR("tilt"), 50);
    C.cam = prefDouble(CFSTR("cam"), 10);
    C.blur = prefDouble(CFSTR("blur"), 2);
    C.size = prefDouble(CFSTR("size"), 100);
    C.off = prefDouble(CFSTR("off"), 0);
    C.bubSize = prefDouble(CFSTR("bubSize"), 56);
}

static NSArray<NSString *> *pinList(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("pins"), CS_DOMAIN);
    NSArray *a = (__bridge_transfer NSArray *)v;
    return [a isKindOfClass:NSArray.class] ? a : @[];
}
static void setPinList(NSArray<NSString *> *a) {
    CFPreferencesSetAppValue(CFSTR("pins"), (__bridge CFPropertyListRef)a, CS_DOMAIN);
    CFPreferencesAppSynchronize(CS_DOMAIN);
}

#pragma mark - log

static NSMutableArray<NSString *> *csLines;

static void csLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void csLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[CircleSwitcher] %@", m);
    if (!C.debug) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], m];
    @synchronized (csLines) {
        [csLines addObject:line];
        if (csLines.count > 400) [csLines removeObjectsInRange:NSMakeRange(0, 100)];
    }
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:CS_LOGFILE]) [fm createFileAtPath:CS_LOGFILE contents:nil attributes:nil];
        if ([[fm attributesOfItemAtPath:CS_LOGFILE error:nil] fileSize] > 400 * 1024) [@"" writeToFile:CS_LOGFILE atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:CS_LOGFILE];
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    } @catch (NSException *e) {}
}

#pragma mark - runtime helpers

static id send0(id o, NSString *s) {
    SEL sel = NSSelectorFromString(s);
    if (o && [o respondsToSelector:sel]) return ((id (*)(id, SEL))objc_msgSend)(o, sel);
    return nil;
}
static id send1(id o, NSString *s, id a) {
    SEL sel = NSSelectorFromString(s);
    if (o && [o respondsToSelector:sel]) return ((id (*)(id, SEL, id))objc_msgSend)(o, sel, a);
    return nil;
}
static double clampd(double v, double a, double b) { return v < a ? a : (v > b ? b : v); }
static double normDeg(double a) { a = fmod(a + 180.0, 360.0); if (a < 0) a += 360.0; return a - 180.0; }

#pragma mark - app info

@interface CSItem : NSObject
@property (nonatomic, copy) NSString *bid, *name;
@property (nonatomic, strong) UIImage *icon;
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, assign) int pid;
@property (nonatomic, assign) double ram;
@property (nonatomic, assign) BOOL pinned;
@end
@implementation CSItem
@end

static id mainSwitcher(void) {
    return send0((id)NSClassFromString(@"SBMainSwitcherViewController"), @"sharedInstance");
}

static id sbApp(NSString *bid) {
    id ac = send0((id)NSClassFromString(@"SBApplicationController"), @"sharedInstance");
    return send1(ac, @"applicationWithBundleIdentifier:", bid);
}

static NSString *appName(NSString *bid) {
    NSString *n = send0(sbApp(bid), @"displayName");
    if ([n isKindOfClass:NSString.class] && n.length) return n;
    id px = send1((id)NSClassFromString(@"LSApplicationProxy"), @"applicationProxyForIdentifier:", bid);
    n = send0(px, @"localizedName");
    if ([n isKindOfClass:NSString.class] && n.length) return n;
    return bid.pathExtension.length ? bid.pathExtension : bid;
}

static UIImage *appIcon(NSString *bid) {
    Class k = UIImage.class;
    SEL s = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    if ([k respondsToSelector:s]) {
        @try { return ((id (*)(id, SEL, id, int, double))objc_msgSend)(k, s, bid, 2, UIScreen.mainScreen.scale); } @catch (NSException *e) {}
    }
    return nil;
}

static int appPid(NSString *bid) {
    id a = sbApp(bid);
    @try { id p = [a valueForKeyPath:@"processState.pid"]; if (p) return [p intValue]; } @catch (NSException *e) {}
    @try { id p = [a valueForKey:@"pid"]; if (p) return [p intValue]; } @catch (NSException *e) {}
    return 0;
}

extern int proc_pid_rusage(int pid, int flavor, void *buffer);
static double ramMB(int pid) {
    if (pid <= 1) return 0;
    uint64_t buf[64];
    memset(buf, 0, sizeof(buf));
    if (proc_pid_rusage(pid, 2, buf) != 0) return 0;
    // rusage_info_v2: 16-byte uuid, then uint64 fields; ri_phys_footprint is the 8th (index 7)
    uint64_t fp = buf[2 + 7];
    return (double)fp / (1024.0 * 1024.0);
}

static UIColor *shade(UIColor *c, CGFloat f) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) return c;
    return [UIColor colorWithRed:MIN(1, r * f) green:MIN(1, g * f) blue:MIN(1, b * f) alpha:1];
}

static UIColor *avgColor(UIImage *img) {
    if (!img.CGImage) return nil;
    uint8_t px[4] = {0, 0, 0, 0};
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px, 1, 1, 8, 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (!c) { CGColorSpaceRelease(cs); return nil; }
    CGContextSetInterpolationQuality(c, kCGInterpolationMedium);
    CGContextDrawImage(c, CGRectMake(0, 0, 1, 1), img.CGImage);
    CGContextRelease(c); CGColorSpaceRelease(cs);
    return [UIColor colorWithRed:px[0] / 255.0 green:px[1] / 255.0 blue:px[2] / 255.0 alpha:1];
}

static UIColor *hashColor(NSString *s) {
    NSUInteger h = 5381;
    for (NSUInteger i = 0; i < s.length; i++) h = h * 33 + [s characterAtIndex:i];
    return [UIColor colorWithHue:(h % 360) / 360.0 saturation:0.55 brightness:0.62 alpha:1];
}

static NSMutableDictionary<NSString *, CSItem *> *itemCache;

static CSItem *itemFor(NSString *bid) {
    CSItem *it = itemCache[bid];
    if (!it) {
        it = [CSItem new];
        it.bid = bid;
        it.name = appName(bid);
        it.icon = appIcon(bid);
        UIColor *c = avgColor(it.icon);
        it.color = c ?: hashColor(bid);
        itemCache[bid] = it;
    }
    it.pid = appPid(bid);
    it.ram = C.ram ? ramMB(it.pid) : 0;
    return it;
}

static BOOL csIsUserFacing(NSString *b) {
    if (!b.length) return NO;
    for (NSString *bad in @[@"PosterBoard", @"Spotlight", @"ViewService", @"Service", @"Extension", @"springboard", @"SpringBoard", @"Siri", @"CarPlay", @"InCall", @"AccessibilityUIServer", @"PreBoard", @"ShareSheet", @"RemoteViewService", @"WebContent"])
        if ([b rangeOfString:bad].location != NSNotFound) return NO;
    return YES;
}

static NSArray<NSString *> *recentBundleIDs(void) {
    NSMutableArray *out = [NSMutableArray array];
    @try {
        id ms = mainSwitcher();
        NSArray *layouts = send0(ms, @"recentAppLayouts");
        if (![layouts isKindOfClass:NSArray.class] || !layouts.count) layouts = send0(send0((id)NSClassFromString(@"SBRecentAppLayouts"), @"sharedInstance"), @"recents");
        if (![layouts isKindOfClass:NSArray.class] || !layouts.count) layouts = send0(ms, @"appLayouts");
        if (![layouts isKindOfClass:NSArray.class] || !layouts.count) {
            @try {
                for (UIViewController *cvc in [(UIViewController *)ms childViewControllers]) {
                    NSArray *al = send0(cvc, @"appLayouts");
                    if ([al isKindOfClass:NSArray.class] && al.count) { layouts = al; break; }
                }
            } @catch (NSException *e) {}
        }
        if ([layouts isKindOfClass:NSArray.class]) {
            for (id lay in layouts) {
                NSArray *items = send0(lay, @"allItems");
                if (![items isKindOfClass:NSArray.class]) continue;
                for (id it in items) {
                    NSString *b = send0(it, @"bundleIdentifier");
                    if ([b isKindOfClass:NSString.class] && b.length && ![out containsObject:b]) [out addObject:b];
                }
            }
        }
        if (!out.count) {
            id ac = send0((id)NSClassFromString(@"SBApplicationController"), @"sharedInstance");
            NSArray *run = send0(ac, @"runningApplications");
            if ([run isKindOfClass:NSArray.class]) {
                for (id app in run) {
                    NSString *b = send0(app, @"bundleIdentifier");
                    if ([b isKindOfClass:NSString.class] && b.length && ![out containsObject:b]) [out addObject:b];
                }
            }
            csLog(@"recents: fallback to runningApplications (%lu)", (unsigned long)out.count);
        }
    } @catch (NSException *e) { csLog(@"recents exception: %@", e); }
    [out removeObject:@"com.apple.springboard"];
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *b in out) if (csIsUserFacing(b)) [clean addObject:b];
    return clean;
}

static BOOL killApp(NSString *bid) {
    int pid = appPid(bid);
    if (pid > 1) { int r = kill(pid, SIGKILL); csLog(@"kill %@ pid=%d -> %d", bid, pid, r); return r == 0; }
    csLog(@"kill %@: no pid", bid);
    return NO;
}

static void openApp(NSString *bid) {
    csLog(@"open %@", bid);
    @try {
        id ws = send0((id)NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
        SEL s = NSSelectorFromString(@"openApplicationWithBundleID:");
        if (ws && [ws respondsToSelector:s]) { ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, s, bid); return; }
        id sb = UIApplication.sharedApplication;
        SEL l = NSSelectorFromString(@"launchApplicationWithIdentifier:suspended:");
        if ([sb respondsToSelector:l]) ((BOOL (*)(id, SEL, id, BOOL))objc_msgSend)(sb, l, bid, NO);
    } @catch (NSException *e) { csLog(@"open exception: %@", e); }
    id ms = mainSwitcher();
    for (NSString *n in @[@"dismissSwitcherNoninteractively", @"dismissSwitcherNoninteractivelyWithSource:"]) {
        SEL s = NSSelectorFromString(n);
        if ([ms respondsToSelector:s]) {
            @try { if ([n hasSuffix:@":"]) ((void (*)(id, SEL, long long))objc_msgSend)(ms, s, 0); else ((void (*)(id, SEL))objc_msgSend)(ms, s); } @catch (NSException *e) {}
            break;
        }
    }
}

#pragma mark - card and label views

@interface CSLabel : UILabel
@end
@implementation CSLabel
- (void)drawTextInRect:(CGRect)r { [super drawTextInRect:UIEdgeInsetsInsetRect(r, UIEdgeInsetsMake(2, 9, 2, 9))]; }
- (CGSize)sizeThatFits:(CGSize)size { CGSize s = [super sizeThatFits:size]; return CGSizeMake(s.width + 18, s.height + 4); }
@end

static NSAttributedString *labelFor(CSItem *it) {
    NSMutableAttributedString *as = [NSMutableAttributedString new];
    UIFont *f = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    NSDictionary *at = @{NSFontAttributeName: f, NSForegroundColorAttributeName: UIColor.whiteColor};
    if (C.nameIcon && it.icon) {
        NSTextAttachment *ta = [NSTextAttachment new];
        ta.image = it.icon; ta.bounds = CGRectMake(0, -3, 14, 14);
        [as appendAttributedString:[NSAttributedString attributedStringWithAttachment:ta]];
        [as appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:at]];
    }
    [as appendAttributedString:[[NSAttributedString alloc] initWithString:(it.name ?: it.bid) attributes:at]];
    if (it.pinned) {
        UIImage *pin = [[UIImage systemImageNamed:@"pin.fill"] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (pin) {
            NSTextAttachment *ta = [NSTextAttachment new];
            ta.image = pin; ta.bounds = CGRectMake(0, -1, 10, 11);
            [as appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:at]];
            [as appendAttributedString:[NSAttributedString attributedStringWithAttachment:ta]];
        }
    }
    if (C.ram && it.ram > 0) {
        [as appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %d MB", (int)it.ram]
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:11], NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.65]}]];
    }
    return as;
}

@interface CSCard : UIView
@property (nonatomic, strong) UIView *front, *back;
@property (nonatomic, strong) CAGradientLayer *grad;
@property (nonatomic, strong) UIImageView *icon, *icon2;
@property (nonatomic, strong) id blurFilter;
@property (nonatomic, assign) CGRect hit;
@property (nonatomic, assign) CGFloat zv;
- (void)configure:(CSItem *)it showIcon:(BOOL)on;
- (void)setBlur:(double)r;
@end

@implementation CSCard
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _front = [UIView new];
        _front.layer.cornerRadius = 18; _front.layer.masksToBounds = YES;
        _front.layer.borderWidth = 0.5; _front.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
        _grad = [CAGradientLayer layer];
        [_front.layer addSublayer:_grad];
        _icon = [UIImageView new]; _icon.contentMode = UIViewContentModeScaleAspectFit; _icon.layer.cornerRadius = 12; _icon.clipsToBounds = YES;
        [_front addSubview:_icon];
        _back = [UIView new];
        _back.backgroundColor = [UIColor colorWithWhite:0.14 alpha:1];
        _back.layer.cornerRadius = 18; _back.layer.masksToBounds = YES;
        _back.layer.borderWidth = 0.5; _back.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
        _icon2 = [UIImageView new]; _icon2.contentMode = UIViewContentModeScaleAspectFit; _icon2.alpha = 0.35;
        [_back addSubview:_icon2];
        [self addSubview:_front]; [self addSubview:_back];
        _back.hidden = YES;
    }
    return self;
}
- (void)configure:(CSItem *)it showIcon:(BOOL)on {
    UIColor *c = it.color ?: [UIColor darkGrayColor];
    self.grad.colors = @[(id)shade(c, 1.15).CGColor, (id)shade(c, 0.55).CGColor];
    self.grad.startPoint = CGPointMake(0.5, 0); self.grad.endPoint = CGPointMake(0.5, 1);
    self.icon.image = it.icon; self.icon.hidden = !(on && it.icon);
    self.icon2.image = it.icon; self.icon2.hidden = !(on && it.icon);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.front.frame = self.bounds; self.back.frame = self.bounds;
    self.grad.frame = self.bounds;
    CGFloat s = self.bounds.size.width * 0.56;
    self.icon.frame = CGRectMake((self.bounds.size.width - s) / 2, (self.bounds.size.height - s) / 2, s, s);
    self.icon2.frame = self.icon.frame;
}
- (void)setBlur:(double)r {
    @try {
        if (r < 0.05) { if (self.layer.filters) self.layer.filters = nil; return; }
        if (!self.blurFilter) self.blurFilter = send1((id)NSClassFromString(@"CAFilter"), @"filterWithType:", @"gaussianBlur");
        if (!self.blurFilter) return;
        [self.blurFilter setValue:@(r) forKey:@"inputRadius"];
        self.layer.filters = @[self.blurFilter];
    } @catch (NSException *e) {}
}
@end

#pragma mark - bubbles and window

@class CSOverlay;
static CSOverlay *csOverlay;
static UIWindow *csWin;
static UIViewController *csRoot;
static NSMutableArray *csBubbles;

@interface CSPassWindow : UIWindow
@end
@implementation CSPassWindow
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    UIView *v = [super hitTest:p withEvent:e];
    if (v == self || v == self.rootViewController.view) return nil;
    return v;
}
@end

static UIWindow *ensureWindow(void) {
    if (csWin) return csWin;
    @try {
        UIWindowScene *sc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) { sc = (UIWindowScene *)s; break; }
        }
        csWin = sc ? [[CSPassWindow alloc] initWithWindowScene:sc] : [[CSPassWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
        csWin.frame = UIScreen.mainScreen.bounds;
        csWin.windowLevel = 100000;
        csWin.backgroundColor = UIColor.clearColor;
        csRoot = [UIViewController new];
        csRoot.view.backgroundColor = UIColor.clearColor;
        csWin.rootViewController = csRoot;
        csWin.hidden = NO;
        csLog(@"window created (scene=%d)", sc != nil);
    } @catch (NSException *e) { csLog(@"window exception: %@", e); csWin = nil; }
    return csWin;
}

@interface CSBubble : UIView
@property (nonatomic, strong) CSItem *item;
@end
static UIView *csTrash;
static void csRemoveBubble(CSBubble *b);

@implementation CSBubble
- (instancetype)initWithItem:(CSItem *)it {
    CGFloat s = C.bubSize;
    if ((self = [super initWithFrame:CGRectMake(0, 0, s, s)])) {
        _item = it;
        self.backgroundColor = it.color ?: UIColor.darkGrayColor;
        self.layer.cornerRadius = s / 2;
        self.layer.borderWidth = 1.5; self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor; self.layer.shadowOpacity = 0.35; self.layer.shadowRadius = 6; self.layer.shadowOffset = CGSizeMake(0, 3);
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectInset(self.bounds, s * 0.2, s * 0.2)];
        iv.contentMode = UIViewContentModeScaleAspectFit; iv.layer.cornerRadius = 8; iv.clipsToBounds = YES;
        iv.image = it.icon;
        if (!it.icon || !C.icon) {
            UILabel *l = [[UILabel alloc] initWithFrame:self.bounds];
            l.text = [(it.name ?: @"?") substringToIndex:1]; l.textAlignment = NSTextAlignmentCenter;
            l.textColor = UIColor.whiteColor; l.font = [UIFont boldSystemFontOfSize:s * 0.45];
            [self addSubview:l];
        } else [self addSubview:iv];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)]];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)]];
    }
    return self;
}
- (void)onTap:(UITapGestureRecognizer *)g {
    NSString *bid = self.item.bid;
    csRemoveBubble(self);
    openApp(bid);
}
- (void)onPan:(UIPanGestureRecognizer *)g {
    UIView *host = self.superview;
    if (!host) return;
    CGSize sz = host.bounds.size;
    if (g.state == UIGestureRecognizerStateBegan) {
        if (!csTrash) {
            csTrash = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
            csTrash.layer.cornerRadius = 32; csTrash.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.8];
            UIImageView *x = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"xmark"] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal]];
            x.frame = CGRectMake(20, 20, 24, 24); x.contentMode = UIViewContentModeScaleAspectFit; [csTrash addSubview:x];
        }
        csTrash.center = CGPointMake(sz.width / 2, sz.height - 90); csTrash.alpha = 0;
        [host addSubview:csTrash]; [host bringSubviewToFront:self];
        [UIView animateWithDuration:0.2 animations:^{ csTrash.alpha = 1; }];
    }
    CGPoint t = [g translationInView:host];
    self.center = CGPointMake(self.center.x + t.x, self.center.y + t.y);
    [g setTranslation:CGPointZero inView:host];
    BOOL near = hypot(self.center.x - csTrash.center.x, self.center.y - csTrash.center.y) < 60;
    csTrash.transform = near ? CGAffineTransformMakeScale(1.25, 1.25) : CGAffineTransformIdentity;
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [csTrash removeFromSuperview]; csTrash.transform = CGAffineTransformIdentity;
        if (near) { csRemoveBubble(self); return; }
        CGFloat s = C.bubSize;
        CGFloat x = self.center.x < sz.width / 2 ? s / 2 + 8 : sz.width - s / 2 - 8;
        CGFloat y = clampd(self.center.y, 80, sz.height - 160);
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0 options:0 animations:^{ self.center = CGPointMake(x, y); } completion:nil];
    }
}
@end

static void csRemoveBubble(CSBubble *b) {
    [csBubbles removeObject:b];
    [UIView animateWithDuration:0.2 animations:^{ b.alpha = 0; b.transform = CGAffineTransformMakeScale(0.3, 0.3); } completion:^(BOOL f) { [b removeFromSuperview]; }];
}

static NSSet<NSString *> *csBubbleIDs(void) {
    NSMutableSet *s = [NSMutableSet set];
    for (CSBubble *b in csBubbles) if (b.item.bid) [s addObject:b.item.bid];
    return s;
}

static void csAddBubble(CSItem *it, CGPoint from) {
    if (!ensureWindow()) return;
    if (!csBubbles) csBubbles = [NSMutableArray array];
    CSBubble *b = [[CSBubble alloc] initWithItem:it];
    b.center = from; b.transform = CGAffineTransformMakeScale(0.6, 0.6);
    [csRoot.view addSubview:b];
    [csBubbles addObject:b];
    CGSize sz = csRoot.view.bounds.size;
    CGFloat y = 130 + (csBubbles.count - 1) * (C.bubSize + 12);
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0 options:0 animations:^{
        b.transform = CGAffineTransformIdentity; b.center = CGPointMake(sz.width - C.bubSize / 2 - 8, y);
    } completion:nil];
    csLog(@"bubble added: %@", it.bid);
}

#pragma mark - overlay

@interface CSOverlay : UIView <UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIVisualEffectView *blurBg;
@property (nonatomic, strong) UIView *ring, *labelHost, *dotsView;
@property (nonatomic, strong) NSMutableArray<CSCard *> *cards;
@property (nonatomic, strong) NSMutableArray<CSLabel *> *labels;
@property (nonatomic, strong) NSMutableArray<CSItem *> *items;
@property (nonatomic, strong) UIButton *xBtn, *cleanBtn, *exitBtn;
@property (nonatomic, strong) UILabel *emptyLabel, *toastLabel;
@property (nonatomic, assign) double rot, vel, from, to, t, dragY;
@property (nonatomic, assign) int anim;
@property (nonatomic, assign) NSInteger front, panMode;
@property (nonatomic, copy) NSString *prevBID, *startBID;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) NSDate *armX, *armClean, *lastBgTap, *lastTouch;
@property (nonatomic, assign) BOOL testMode;
@property (nonatomic, assign) CGPoint panStart, panAccum;
@property (nonatomic, strong) UIImpactFeedbackGenerator *hapticGen;
- (void)reloadItems;
- (void)relayout;
- (BOOL)userRecentlyTouched:(NSTimeInterval)sec;
@end

static void csHideOverlay(void);
static BOOL csForceHidden;

@implementation CSOverlay

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _cards = [NSMutableArray array]; _labels = [NSMutableArray array]; _items = [NSMutableArray array];
        _front = -2; _lastTouch = [NSDate date];
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _blurBg = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
        _blurBg.frame = self.bounds; _blurBg.autoresizingMask = self.autoresizingMask;
        [self addSubview:_blurBg];
        _ring = [UIView new]; _ring.userInteractionEnabled = NO; [self addSubview:_ring];
        _labelHost = [UIView new]; _labelHost.userInteractionEnabled = NO; _labelHost.frame = self.bounds; _labelHost.autoresizingMask = self.autoresizingMask;
        [self addSubview:_labelHost];
        _dotsView = [UIView new]; _dotsView.userInteractionEnabled = NO; [self addSubview:_dotsView];

        _emptyLabel = [UILabel new]; _emptyLabel.text = @"Không có app nào đang mở";
        _emptyLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7]; _emptyLabel.font = [UIFont systemFontOfSize:15];
        _emptyLabel.textAlignment = NSTextAlignmentCenter; _emptyLabel.hidden = YES; [self addSubview:_emptyLabel];

        _toastLabel = [CSLabel new]; _toastLabel.font = [UIFont systemFontOfSize:13]; _toastLabel.textColor = UIColor.whiteColor;
        _toastLabel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9]; _toastLabel.layer.cornerRadius = 13; _toastLabel.layer.masksToBounds = YES;
        _toastLabel.alpha = 0; [self addSubview:_toastLabel];

        _xBtn = [self roundButton:@"xmark" action:@selector(onCloseAll)];
        _cleanBtn = [self roundButton:@"memorychip" action:@selector(onClean)];
        _exitBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [_exitBtn setTitle:@"Thoát thử" forState:UIControlStateNormal];
        _exitBtn.tintColor = UIColor.whiteColor; _exitBtn.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9];
        _exitBtn.layer.cornerRadius = 15; _exitBtn.hidden = YES;
        [_exitBtn addTarget:self action:@selector(onExit) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_exitBtn];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
        pan.delegate = self; [self addGestureRecognizer:pan];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
        tap.delegate = self; [self addGestureRecognizer:tap];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onLong:)];
        lp.minimumPressDuration = 0.45; lp.delegate = self; [self addGestureRecognizer:lp];
        UILongPressGestureRecognizer *esc = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onEscape:)];
        esc.minimumPressDuration = 1.6; esc.allowableMovement = 30; esc.delegate = self; [self addGestureRecognizer:esc];
    }
    return self;
}

- (UIButton *)roundButton:(NSString *)sym action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.frame = CGRectMake(0, 0, 46, 46); b.layer.cornerRadius = 23;
    b.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9]; b.tintColor = UIColor.whiteColor;
    UIImage *im = [UIImage systemImageNamed:sym withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20]];
    if (im) [b setImage:im forState:UIControlStateNormal]; else [b setTitle:@"X" forState:UIControlStateNormal];
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:b];
    return b;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t { return ![t.view isKindOfClass:UIControl.class]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }

- (void)touchedNow { self.lastTouch = [NSDate date]; }
- (BOOL)userRecentlyTouched:(NSTimeInterval)sec { return -[self.lastTouch timeIntervalSinceNow] < sec; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    self.xBtn.center = CGPointMake(W / 2, H - 70);
    self.cleanBtn.center = CGPointMake(W / 2 - 80, H - 70);
    self.emptyLabel.frame = CGRectMake(0, H * 0.44, W, 24);
    self.exitBtn.frame = CGRectMake(16, 56, 92, 30);
    [self relayout];
}

#pragma mark helpers

- (double)step { return self.items.count ? 360.0 / self.items.count : 360.0; }
- (NSString *)frontBID { return (self.front >= 0 && self.front < (NSInteger)self.items.count) ? self.items[self.front].bid : nil; }

- (void)toast:(NSString *)t {
    self.toastLabel.text = t; [self.toastLabel sizeToFit];
    CGRect f = self.toastLabel.frame; f.size.height = 26;
    self.toastLabel.frame = f; self.toastLabel.center = CGPointMake(self.bounds.size.width / 2, 70);
    self.toastLabel.alpha = 1;
    [UIView animateWithDuration:0.3 delay:1.6 options:0 animations:^{ self.toastLabel.alpha = 0; } completion:nil];
}

- (void)buzz {
    if (!C.haptic) return;
    @try {
        if (!self.hapticGen) self.hapticGen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [self.hapticGen impactOccurred];
    } @catch (NSException *e) { AudioServicesPlaySystemSound(1519); }
}

#pragma mark data

- (void)reloadItems {
    NSArray *ids = recentBundleIDs();
    NSSet *bub = csBubbleIDs();
    NSArray *pins = pinList();
    NSMutableArray<NSString *> *use = [NSMutableArray array];
    for (NSString *b in ids) { if (![bub containsObject:b]) [use addObject:b]; if ((int)use.count >= C.count) break; }
    NSString *current = use.firstObject;
    self.prevBID = use.count > 1 ? use[1] : nil;
    NSMutableArray<CSItem *> *pinned = [NSMutableArray array], *rest = [NSMutableArray array];
    for (NSString *b in use) {
        CSItem *it = itemFor(b);
        it.pinned = [pins containsObject:b];
        [(it.pinned ? pinned : rest) addObject:it];
    }
    self.items = [NSMutableArray arrayWithArray:pinned];
    [self.items addObjectsFromArray:rest];
    csLog(@"items: %@", [use componentsJoinedByString:@", "]);
    [self rebuildViews];
    NSInteger idx = 0;
    for (NSUInteger i = 0; i < self.items.count; i++) if ([self.items[i].bid isEqualToString:current]) { idx = (NSInteger)i; break; }
    self.rot = idx * [self step]; self.dragY = 0; self.anim = 0; self.front = -2;
    [self relayout];
}

- (void)rebuildViews {
    for (UIView *v in self.cards) [v removeFromSuperview];
    for (UIView *v in self.labels) [v removeFromSuperview];
    [self.cards removeAllObjects]; [self.labels removeAllObjects];
    for (CSItem *it in self.items) {
        CSCard *c = [[CSCard alloc] initWithFrame:CGRectMake(0, 0, 110, 186)];
        [c configure:it showIcon:C.icon];
        [self.ring addSubview:c]; [self.cards addObject:c];
        CSLabel *l = [CSLabel new];
        l.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.78];
        l.layer.cornerRadius = 11; l.layer.masksToBounds = YES;
        l.attributedText = labelFor(it); [l sizeToFit];
        [self.labelHost addSubview:l]; [self.labels addObject:l];
    }
    self.emptyLabel.hidden = self.items.count > 0;
}

- (void)rebuildDots {
    for (UIView *v in self.dotsView.subviews) [v removeFromSuperview];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    NSUInteger n = self.items.count;
    CGFloat total = n * 10 - 4;
    self.dotsView.frame = CGRectMake((W - total) / 2, H - 125, total, 6);
    self.dotsView.hidden = !C.dots || n == 0;
    for (NSUInteger i = 0; i < n; i++) {
        UIView *d = [[UIView alloc] initWithFrame:CGRectMake(i * 10, 0, 6, 6)];
        d.layer.cornerRadius = 3;
        BOOL on = ((NSInteger)i == self.front);
        d.backgroundColor = on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.35];
        d.transform = on ? CGAffineTransformMakeScale(1.4, 1.4) : CGAffineTransformIdentity;
        [self.dotsView addSubview:d];
    }
}

#pragma mark layout

- (void)relayout {
    NSInteger n = self.items.count;
    if (n != (NSInteger)self.cards.count) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, P = 900;
    CGFloat cx = W / 2, cy = H * 0.46 + C.off;
    self.ring.bounds = CGRectMake(0, 0, 2, 2); self.ring.center = CGPointMake(cx, cy);
    CATransform3D persp = CATransform3DIdentity; persp.m34 = -1.0 / P;
    self.ring.layer.sublayerTransform = persp;
    double step = [self step], e = C.cam * M_PI / 180.0;
    CGFloat w = 110 * C.size / 100.0, h = 186 * C.size / 100.0;
    double best = 1e9; NSInteger front = -1;
    NSMutableArray *order = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
        CSCard *card = self.cards[i]; CSLabel *lb = self.labels[i];
        double phi = normDeg(i * step - self.rot), r = phi * M_PI / 180.0;
        double x = C.radius * sin(r), depth = C.radius * cos(r) - C.radius;
        double z = depth * cos(e), y = depth * sin(e);
        if (i == self.front && self.dragY != 0) y += self.dragY;
        double yaw = -C.tilt * clampd(phi / 45.0, -1, 1) * M_PI / 180.0;
        BOOL back = cos(yaw) < 0;
        double s = 1.0 / (1.0 - z / P);
        if (fabs(card.bounds.size.width - w) > 0.5 || fabs(card.bounds.size.height - h) > 0.5) card.bounds = CGRectMake(0, 0, w, h);
        card.center = CGPointMake(1, 1);
        CATransform3D t = CATransform3DIdentity;
        t = CATransform3DTranslate(t, x, y, z);
        t = CATransform3DRotate(t, yaw, 0, 1, 0);
        card.layer.transform = t;
        double op = 0.4 + 0.6 * (cos(r) + 1) / 2;
        if (i == self.front && self.dragY < 0) op *= MAX(0.2, 1 + self.dragY / 220.0);
        card.alpha = op;
        double bl = C.blur * MIN(1.0, fabs(phi) / 90.0) + (C.namePos == 1 ? 1.5 : 0);
        [card setBlur:bl];
        card.front.hidden = back; card.back.hidden = !back;
        double px = cx + x * s, py = cy + y * s;
        double hw = (w * s / 2) * MAX(fabs(cos(yaw)), 0.25), hh = h * s / 2;
        card.hit = CGRectMake(px - hw, py - hh, hw * 2, hh * 2); card.zv = z;
        [order addObject:card];
        BOOL show = C.namePos != 3 && !(C.onlyFront && fabs(phi) > 20);
        lb.hidden = !show;
        if (show) {
            double ly = C.namePos == 0 ? py - hh - 16 : (C.namePos == 2 ? py + hh + 16 : py);
            lb.center = CGPointMake(px, ly);
            lb.transform = CGAffineTransformMakeScale(s, s);
            lb.alpha = op;
        }
        if (fabs(phi) < best) { best = fabs(phi); front = i; }
    }
    [order sortUsingComparator:^NSComparisonResult(CSCard *a, CSCard *b) { return a.zv < b.zv ? NSOrderedAscending : NSOrderedDescending; }];
    for (CSCard *c in order) [self.ring bringSubviewToFront:c];
    if (front != self.front) {
        BOOL first = (self.front == -2);
        self.front = front;
        if (!first) [self buzz];
        [self rebuildDots];
    }
}

#pragma mark animation

- (void)startLink {
    if (!self.link) { self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)]; [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes]; }
    self.link.paused = NO;
}

- (void)onFrame:(CADisplayLink *)l {
    double dt = MAX(0.001, l.targetTimestamp - l.timestamp);
    if (self.anim == 1) {
        self.t += dt;
        double p = MIN(1.0, self.t / 0.28), k = 1 - pow(1 - p, 3);
        self.rot = self.from + (self.to - self.from) * k;
        if (p >= 1) { self.anim = 0; l.paused = YES; }
    } else if (self.anim == 2) {
        self.rot += self.vel * dt;
        self.vel *= pow(0.94, dt * 60);
        if (fabs(self.vel) < 25) { [self snap]; }
    } else if (self.anim == 3) {
        self.dragY *= pow(0.75, dt * 60);
        if (fabs(self.dragY) < 0.5) { self.dragY = 0; self.anim = 0; l.paused = YES; }
    } else { l.paused = YES; }
    [self relayout];
}

- (void)tweenTo:(double)to { self.from = self.rot; self.to = to; self.t = 0; self.anim = 1; [self startLink]; }
- (void)snap { double st = [self step]; [self tweenTo:round(self.rot / st) * st]; }
- (void)rotateToIndex:(NSInteger)i { [self tweenTo:self.rot + normDeg(i * [self step] - self.rot)]; }

#pragma mark card hit

- (CSCard *)cardAt:(CGPoint)p {
    CSCard *best = nil;
    for (CSCard *c in self.cards) {
        if (CGRectContainsPoint(c.hit, p) && (!best || c.zv > best.zv)) best = c;
    }
    return best;
}

#pragma mark gestures

- (void)onPan:(UIPanGestureRecognizer *)g {
    [self touchedNow];
    CGPoint t = [g translationInView:self];
    double step = [self step];
    if (g.state == UIGestureRecognizerStateBegan) {
        self.anim = 0; self.panMode = 0; self.panAccum = CGPointZero; self.startBID = [self frontBID];
        CGPoint cur = [g locationInView:self]; self.panStart = CGPointMake(cur.x - t.x, cur.y - t.y);
    }
    if (g.state == UIGestureRecognizerStateChanged || g.state == UIGestureRecognizerStateBegan) {
        self.panAccum = CGPointMake(self.panAccum.x + t.x, self.panAccum.y + t.y);
        [g setTranslation:CGPointZero inView:self];
        if (self.panMode == 0 && hypot(self.panAccum.x, self.panAccum.y) > 8) {
            CSCard *c = [self cardAt:self.panStart];
            BOOL onFront = c && [self.cards indexOfObject:c] == self.front;
            self.panMode = (fabs(self.panAccum.y) > fabs(self.panAccum.x) && onFront) ? 2 : 1;
            if (self.panMode == 1) self.rot -= self.panAccum.x * (step / 110.0);
        } else if (self.panMode == 1) {
            self.rot -= t.x * (step / 110.0);
        } else if (self.panMode == 2) {
            self.dragY = clampd(self.panAccum.y, -300, 60);
        }
        [self relayout];
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled || g.state == UIGestureRecognizerStateFailed) {
        if (self.panMode == 1) {
            NSString *fb = [self frontBID];
            if (fb && self.startBID && ![fb isEqualToString:self.startBID]) self.prevBID = self.startBID;
            double v = -[g velocityInView:self].x * (step / 110.0);
            if (C.inertia && fabs(v) > 60) { self.vel = v; self.anim = 2; [self startLink]; } else [self snap];
        } else if (self.panMode == 2) {
            if (self.dragY < -90) { [self closeFront]; }
            else if (self.dragY > 45) { [self togglePinFront]; }
            self.anim = 3; [self startLink];
        } else { [self snap]; }
        self.panMode = 0;
    }
}

- (void)onTap:(UITapGestureRecognizer *)g {
    [self touchedNow];
    CGPoint p = [g locationInView:self];
    CSCard *c = [self cardAt:p];
    if (c) {
        NSInteger i = [self.cards indexOfObject:c];
        if (i == self.front) { [self openFront]; }
        else { self.prevBID = [self frontBID]; [self rotateToIndex:i]; }
        return;
    }
    NSDate *now = [NSDate date];
    if (self.lastBgTap && [now timeIntervalSinceDate:self.lastBgTap] < 0.32) { self.lastBgTap = nil; [self goBack]; }
    else self.lastBgTap = now;
}

- (void)onLong:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self touchedNow];
    if (!C.bubOn) return;
    CSCard *c = [self cardAt:[g locationInView:self]];
    if (!c || [self.cards indexOfObject:c] != self.front) return;
    [self bubbleFront];
}

- (void)onEscape:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    csLog(@"escape long-press: force hide");
    csForceHidden = YES; csHideOverlay();
}

- (void)onExit {
    CFPreferencesSetAppValue(CFSTR("testShow"), kCFBooleanFalse, CS_DOMAIN);
    CFPreferencesAppSynchronize(CS_DOMAIN);
    csHideOverlay();
}

#pragma mark actions

- (void)openFront {
    NSString *b = [self frontBID];
    if (!b) return;
    [self buzz];
    csForceHidden = YES;
    csHideOverlay();
    openApp(b);
}

- (void)goBack {
    if (!self.prevBID) return;
    for (NSUInteger i = 0; i < self.items.count; i++) {
        if ([self.items[i].bid isEqualToString:self.prevBID]) {
            self.prevBID = [self frontBID];
            [self rotateToIndex:(NSInteger)i];
            [self toast:[NSString stringWithFormat:@"Quay lại %@", self.items[i].name]];
            return;
        }
    }
}

- (void)removeItemAt:(NSInteger)k {
    if (k < 0 || k >= (NSInteger)self.items.count) return;
    [self.items removeObjectAtIndex:k];
    [self rebuildViews];
    double st = [self step];
    NSInteger nk = MIN(k, MAX((NSInteger)self.items.count - 1, 0));
    self.rot = nk * st; self.front = -2; self.dragY = 0;
    [self relayout];
}

- (void)closeFront {
    NSInteger k = self.front;
    if (k < 0 || k >= (NSInteger)self.items.count) return;
    CSItem *it = self.items[k];
    killApp(it.bid); [self buzz];
    [self toast:[NSString stringWithFormat:@"Đã đóng %@", it.name]];
    self.dragY = 0; [self removeItemAt:k];
}

- (void)bubbleFront {
    NSInteger k = self.front;
    if (k < 0 || k >= (NSInteger)self.items.count) return;
    CSItem *it = self.items[k];
    CGPoint from = [self convertPoint:CGPointMake(self.bounds.size.width / 2, self.bounds.size.height * 0.46 + C.off) toView:csRoot.view];
    csAddBubble(it, from); [self buzz];
    [self removeItemAt:k];
    [self toast:@"Đã tạo bong bóng"];
}

- (void)togglePinFront {
    NSInteger k = self.front;
    if (k < 0 || k >= (NSInteger)self.items.count) return;
    CSItem *it = self.items[k];
    NSMutableArray *pins = [pinList() mutableCopy];
    if ([pins containsObject:it.bid]) [pins removeObject:it.bid]; else [pins addObject:it.bid];
    setPinList(pins); [self buzz];
    it.pinned = [pins containsObject:it.bid];
    [self toast:[NSString stringWithFormat:@"%@ %@", it.pinned ? @"Đã ghim" : @"Đã bỏ ghim", it.name]];
    NSMutableArray *pinned = [NSMutableArray array], *rest = [NSMutableArray array];
    for (CSItem *x in self.items) [(x.pinned ? pinned : rest) addObject:x];
    [pinned addObjectsFromArray:rest]; self.items = pinned;
    [self rebuildViews];
    NSUInteger idx = [self.items indexOfObject:it];
    self.rot = idx * [self step]; self.front = -2; self.dragY = 0;
    [self relayout];
}

- (void)runKill:(BOOL)all {
    NSArray *pins = pinList();
    NSString *keep = [self frontBID];
    int n = 0;
    for (CSItem *it in [self.items copy]) {
        if (!all && [it.bid isEqualToString:keep]) continue;
        if (C.keepPinned && [pins containsObject:it.bid]) continue;
        if (killApp(it.bid)) n++;
    }
    [self buzz];
    [self toast:[NSString stringWithFormat:@"Đã đóng %d app", n]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self reloadItems]; });
}

- (void)onCloseAll {
    [self touchedNow];
    if (self.armX && -[self.armX timeIntervalSinceNow] < 3) { self.armX = nil; [self runKill:YES]; }
    else { self.armX = [NSDate date]; [self toast:@"Chạm X lần nữa để đóng tất cả"]; }
}

- (void)onClean {
    [self touchedNow];
    if (self.armClean && -[self.armClean timeIntervalSinceNow] < 3) { self.armClean = nil; [self runKill:NO]; }
    else { self.armClean = [NSDate date]; [self toast:@"Chạm lần nữa để dọn RAM (đóng app nền)"]; }
}
@end

#pragma mark - show / hide / detection

static NSDate *csBoot;
static NSDate *csShownAt;
static int csTickCount;
static NSString *csLastSig;

static void csShowOverlay(BOOL test) {
    loadCfg();
    if (!ensureWindow()) return;
    if (!csOverlay) csOverlay = [[CSOverlay alloc] initWithFrame:csRoot.view.bounds];
    csOverlay.testMode = test; csOverlay.exitBtn.hidden = !test;
    if (csOverlay.superview != csRoot.view) {
        csOverlay.frame = csRoot.view.bounds;
        csOverlay.alpha = 0;
        [csRoot.view addSubview:csOverlay];
    }
    [csOverlay reloadItems];
    [UIView animateWithDuration:0.2 animations:^{ csOverlay.alpha = 1; }];
    for (UIView *b in csBubbles) [csRoot.view bringSubviewToFront:b];
    csShownAt = [NSDate date];
    csLog(@"overlay shown (test=%d)", test);
}

static void csHideOverlay(void) {
    if (!csOverlay || !csOverlay.superview) return;
    CSOverlay *o = csOverlay;
    [UIView animateWithDuration:0.18 animations:^{ o.alpha = 0; } completion:^(BOOL f) { if (o.alpha == 0) [o removeFromSuperview]; }];
    csLog(@"overlay hidden");
}

// Trang thai switcher theo hook vong doi VC (du phong khi khong co selector nao)
static int csHookVis = -1;

// Tra ve danh sach selector BOOL, khong tham so, ten co visible/showing/presented tren class (gom ca superclass)
static NSArray<NSString *> *csProbeNames(Class cls) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary new];
    NSString *key = NSStringFromClass(cls);
    NSArray *hit = cache[key];
    if (hit) return hit;
    NSMutableArray *out = [NSMutableArray array];
    for (Class k = cls; k && k != NSObject.class && k != UIViewController.class && k != UIResponder.class && k != UIView.class; k = class_getSuperclass(k)) {
        unsigned n = 0;
        Method *ms = class_copyMethodList(k, &n);
        for (unsigned i = 0; i < n; i++) {
            NSString *name = NSStringFromSelector(method_getName(ms[i]));
            if ([name containsString:@":"]) continue;
            char *rt = method_copyReturnType(ms[i]);
            BOOL isBool = rt && (rt[0] == 'B' || rt[0] == 'c');
            free(rt);
            if (!isBool) continue;
            NSString *l = name.lowercaseString;
            if ([l containsString:@"visible"] || [l containsString:@"showing"] || [l containsString:@"presented"]) {
                if (![out containsObject:name]) [out addObject:name];
            }
        }
        free(ms);
    }
    cache[key] = out;
    csLog(@"probe %@ -> %@", key, [out componentsJoinedByString:@", "]);
    return out;
}

static int csDetectVisible(void) {
    id ms = mainSwitcher();
    NSMutableArray *objs = [NSMutableArray array];
    id coord = send0((id)NSClassFromString(@"SBMainSwitcherControllerCoordinator"), @"sharedInstance");
    if (coord) [objs addObject:coord];
    if (ms) {
        [objs addObject:ms];
        @try { for (id c in [(UIViewController *)ms childViewControllers]) { if ([NSStringFromClass([c class]) rangeOfString:@"Switcher"].location != NSNotFound) [objs addObject:c]; } } @catch (NSException *e) {}
    }
    if (!objs.count) return csHookVis;

    // Uu tien cac ten da biet, sau do toi cac ten tim thay bang runtime co chu "switcher"
    NSArray *known = @[@"isAnySwitcherVisible", @"isMainSwitcherVisible", @"isSwitcherVisible", @"isSwitcherShowing", @"isVisible"];
    NSMutableString *sig = [NSMutableString string];
    int result = -1;
    for (id o in objs) {
        NSString *cn = NSStringFromClass([o class]);
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *k in known) if ([o respondsToSelector:NSSelectorFromString(k)]) [names addObject:k];
        for (NSString *k in csProbeNames([o class])) {
            if (![names containsObject:k] && [k.lowercaseString containsString:@"switcher"]) [names addObject:k];
        }
        for (NSString *n in names) {
            BOOL b = NO;
            @try { b = ((BOOL (*)(id, SEL))objc_msgSend)(o, NSSelectorFromString(n)); } @catch (NSException *e) { continue; }
            [sig appendFormat:@"%@.%@=%d ", cn, n, b];
            if (result == -1) result = b ? 1 : 0;
        }
    }
    if (result == -1 && csHookVis != -1) { result = csHookVis; [sig appendFormat:@"hookVis=%d ", csHookVis]; }
    if (sig.length == 0) [sig appendString:@"(no visibility selector found)"];
    if (![sig isEqualToString:csLastSig]) { csLastSig = [sig copy]; csLog(@"switcher signals: %@", sig); }
    return result;
}

static void csDiscoverOnce(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    csLog(@"iOS %@ | SBMainSwitcherViewController=%d Coordinator=%d SBRecentAppLayouts=%d SBFluidSwitcherViewController=%d",
          UIDevice.currentDevice.systemVersion,
          NSClassFromString(@"SBMainSwitcherViewController") != nil,
          NSClassFromString(@"SBMainSwitcherControllerCoordinator") != nil,
          NSClassFromString(@"SBRecentAppLayouts") != nil,
          NSClassFromString(@"SBFluidSwitcherViewController") != nil);
    id ms = mainSwitcher();
    csLog(@"mainSwitcher=%@ children=%@", ms ? NSStringFromClass([ms class]) : @"nil", ms ? [(UIViewController *)ms childViewControllers] : @[]);
    for (NSString *n in @[@"SBMainSwitcherViewController", @"SBMainSwitcherControllerCoordinator", @"SBFluidSwitcherViewController"]) {
        Class k = NSClassFromString(n);
        if (k) csProbeNames(k);
    }
}

#pragma mark - real switcher (hook the stock cards)

@interface SBFluidSwitcherItemContainer : UIView
@end
@interface SBFluidSwitcherViewController : UIViewController
@end

static const void *kSysC = &kSysC, *kSysT = &kSysT, *kSysA = &kSysA, *kApplied = &kApplied;
static __weak UIViewController *csFluid;
static int csCnt[6]; // setCenter, setTransform, setAlpha, setFrame, layoutSubviews, applied
#define CS_MARKER @"/var/mobile/Documents/CircleSwitcher.armed"
static BOOL csTripped, csMarkerOn;
static double csLastApply;

// Dat the app that thanh vong 3D, dua tren vi tri he thong dat (de tu khop voi cuon/vuot/dong app).
static void csApplyRingInner(UIView *c) {
    if (!C.enabled || C.mode != 0) return;
    NSValue *vc = objc_getAssociatedObject(c, kSysC);
    UIView *sv = c.superview;
    if (!vc || !sv || !c.window) return;
    if (csTripped || -[csBoot timeIntervalSinceNow] < 12) return;
    CGPoint sys = vc.CGPointValue;
    if (!isfinite(sys.x) || !isfinite(sys.y)) return;
    NSValue *vt = objc_getAssociatedObject(c, kSysT);
    CGAffineTransform st = vt ? vt.CGAffineTransformValue : CGAffineTransformIdentity;
    NSNumber *na = objc_getAssociatedObject(c, kSysA);
    double sa = na ? na.doubleValue : 1.0;
    CGFloat W = UIScreen.mainScreen.bounds.size.width;
    CGFloat bw = MAX(1, c.bounds.size.width);
    double sysScale = hypot(st.a, st.b) * bw / W;
    CGPoint sysScr = [sv convertPoint:sys toView:nil];
    // k = muc do dang o che do switcher (the nho). Dang o full man hinh (app) thi k = 0 de khong dung vao hieu ung mo/dong app.
    double k = clampd((0.85 - sysScale) / 0.25, 0, 1);
    BOOL applied = [objc_getAssociatedObject(c, kApplied) boolValue];
    CALayer *L = c.layer;
    if (k < 0.001) {
        if (applied) {
            L.position = sys; L.transform = CATransform3DMakeAffineTransform(st); L.opacity = (float)sa; L.zPosition = 0; L.doubleSided = YES;
            objc_setAssociatedObject(c, kApplied, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return;
    }
    NSInteger n = 8, idx = NSNotFound;
    NSArray *ls = send0(csFluid, @"appLayouts");
    if (![ls isKindOfClass:NSArray.class]) ls = send0(send0(c, @"delegate"), @"appLayouts");
    id lay = send0(c, @"appLayout");
    if ([ls isKindOfClass:NSArray.class]) { n = (NSInteger)ls.count; if (lay) idx = (NSInteger)[ls indexOfObject:lay]; }
    n = MAX(3, MIN(n, (NSInteger)C.count));
    double step = 360.0 / n;
    double spacing = W * 0.62;
    double phi = normDeg((sysScr.x - W / 2) / spacing * step);
    double r = phi * M_PI / 180.0, e = C.cam * M_PI / 180.0, R = C.radius * 1.8, P = 900;
    double x = R * sin(r), depth = R * cos(r) - R, z = depth * cos(e), y = depth * sin(e);
    double s = 1.0 / (1.0 - z / P);
    double yaw = -C.tilt * clampd(phi / 45.0, -1, 1) * M_PI / 180.0;
    double ringScale = 0.46 * C.size / 100.0 * s;
    double scale = sysScale + (ringScale - sysScale) * k;
    double f = scale * W / bw;
    CGPoint ringScr = CGPointMake(W / 2 + x * s, sysScr.y + C.off + y * s);
    CGPoint scr = CGPointMake(sysScr.x + (ringScr.x - sysScr.x) * k, sysScr.y + (ringScr.y - sysScr.y) * k);
    CGPoint pos = [sv convertPoint:scr fromView:nil];
    CATransform3D t = CATransform3DIdentity;
    t.m34 = -1.0 / P;
    t = CATransform3DRotate(t, yaw * k, 0, 1, 0);
    t = CATransform3DScale(t, f, f, 1);
    double op = 0.4 + 0.6 * (cos(r) + 1) / 2;
    double hide = (idx != NSNotFound && idx >= C.count) ? 0 : 1;
    if (!isfinite(pos.x) || !isfinite(pos.y) || !isfinite(f) || f <= 0.001 || !isfinite(z) || !isfinite(op)) return;
    csLastApply = CACurrentMediaTime();
    L.position = pos;
    L.transform = t;
    L.opacity = (float)(sa * (1 + (op * hide - 1) * k));
    L.zPosition = z * k;
    L.doubleSided = cos(yaw * k) >= 0;
    objc_setAssociatedObject(c, kApplied, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    csCnt[5]++;
}

static void csApplyRing(UIView *c) {
    static BOOL busy;
    if (busy) return;
    busy = YES;
    @try { csApplyRingInner(c); } @catch (NSException *e) { csLog(@"apply exception: %@", e); }
    busy = NO;
}

// ---- Cac ham DO (chi doc, khong hook, khong thay doi gi) ----
static NSString *csChain(Class k) {
    NSMutableArray *a = [NSMutableArray array];
    for (; k; k = class_getSuperclass(k)) [a addObject:NSStringFromClass(k)];
    return [a componentsJoinedByString:@" < "];
}

static void csProbeArrayCall(id o, NSString *tag, NSArray<NSString *> *sels) {
    for (NSString *n in sels) {
        SEL sl = NSSelectorFromString(n);
        if (!o || [n hasPrefix:@"_"] || ![o respondsToSelector:sl]) continue;
        Method mt = class_getInstanceMethod([o class], sl);
        if (!mt) { csLog(@"  %@.%@ skipped (no method)", tag, n); continue; }
        char *rt = method_copyReturnType(mt);
        BOOL isObj = rt && rt[0] == '@';
        free(rt);
        if (!isObj) { csLog(@"  %@.%@ skipped (returns non-object)", tag, n); continue; }
        csLog(@"  calling %@.%@", tag, n);
        id r = nil;
        @try { r = ((id (*)(id, SEL))objc_msgSend)(o, sl); } @catch (NSException *e) { continue; }
        NSString *d = r ? NSStringFromClass([r class]) : @"nil";
        if ([r isKindOfClass:NSArray.class]) {
            NSArray *a = r; NSString *first = @"-";
            if (a.count) {
                id f = a[0]; NSArray *it = send0(f, @"allItems");
                NSString *b = ([it isKindOfClass:NSArray.class] && it.count) ? send0(it[0], @"bundleIdentifier") : @"?";
                first = [NSString stringWithFormat:@"%@ allItems=%lu b0=%@", NSStringFromClass([f class]), (unsigned long)([it isKindOfClass:NSArray.class] ? it.count : 0), b];
            }
            d = [NSString stringWithFormat:@"NSArray count=%lu first=%@", (unsigned long)a.count, first];
        }
        csLog(@"  %@.%@ -> %@", tag, n, d);
    }
}

static void csStaticDump(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    csLog(@"=== STATIC DUMP iOS %@ arch=%s", UIDevice.currentDevice.systemVersion,
#if __arm64e__
          "arm64e"
#else
          "arm64"
#endif
    );
    NSArray *names = @[@"SBSwitcherViewController", @"SBDeckSwitcherViewController", @"SBFluidSwitcherViewController",
                       @"SBDeckSwitcherItemContainer", @"SBFluidSwitcherItemContainer", @"SBRecentAppLayouts",
                       @"SBMainSwitcherControllerCoordinator", @"SBDeckSwitcherPersonality", @"SBAppLayout"];
    for (NSString *cn in names) {
        Class k = NSClassFromString(cn);
        if (!k) { csLog(@"class %@ = nil", cn); continue; }
        unsigned n = 0; Method *ms = class_copyMethodList(k, &n);
        NSMutableArray *mn = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) [mn addObject:NSStringFromSelector(method_getName(ms[i]))];
        free(ms);
        NSString *joined = [mn componentsJoinedByString:@" "];
        if (joined.length > 6000) joined = [joined substringToIndex:6000];
        csLog(@"class %@ chain: %@ | methods(%u): %@", cn, csChain(k), n, joined);
    }
    unsigned cnt = 0; Class *all = objc_copyClassList(&cnt);
    NSMutableArray *mods = [NSMutableArray array];
    for (unsigned i = 0; i < cnt; i++) {
        const char *nm = class_getName(all[i]);
        if (strncmp(nm, "SB", 2) == 0 && (strstr(nm, "Switcher") || strstr(nm, "AppLayout"))) [mods addObject:@(nm)];
    }
    free(all);
    csLog(@"switcher-ish classes (%lu): %@", (unsigned long)mods.count, [mods componentsJoinedByString:@" "]);
    NSArray *cands = @[@"recents", @"recentAppLayouts", @"appLayouts", @"allAppLayouts"];
    id ral = send0((id)NSClassFromString(@"SBRecentAppLayouts"), @"sharedInstance");
    csLog(@"SBRecentAppLayouts sharedInstance=%@", ral ? NSStringFromClass([ral class]) : @"nil");
    csProbeArrayCall(ral, @"SBRecentAppLayouts", cands);
    id coord = send0((id)NSClassFromString(@"SBMainSwitcherControllerCoordinator"), @"sharedInstance");
    csLog(@"Coordinator sharedInstance=%@", coord ? NSStringFromClass([coord class]) : @"nil");
    csProbeArrayCall(coord, @"Coordinator", cands);
}

static int csSafeVisible(void) {
    id coord = send0((id)NSClassFromString(@"SBMainSwitcherControllerCoordinator"), @"sharedInstance");
    SEL s = NSSelectorFromString(@"isMainSwitcherVisible");
    if (!coord || ![coord respondsToSelector:s]) return -1;
    return ((BOOL (*)(id, SEL))objc_msgSend)(coord, s) ? 1 : 0;
}

static BOOL csHasSwitcher(UIView *v, int d, int *budget) {
    if (--(*budget) < 0 || d > 12) return NO;
    if ([NSStringFromClass(v.class) rangeOfString:@"Switcher"].location != NSNotFound) return YES;
    for (UIView *x in v.subviews) if (csHasSwitcher(x, d + 1, budget)) return YES;
    return NO;
}

static void csWalk(UIView *v, int d, int maxD, NSMutableString *out, int *budget) {
    if (*budget <= 0 || d > maxD) return;
    (*budget)--;
    NSString *ind = [@"" stringByPaddingToLength:(NSUInteger)(d * 2) withString:@" " startingAtIndex:0];
    CGAffineTransform t = v.transform;
    [out appendFormat:@"%@%@ f=%@ a=%.2f hid=%d sub=%lu t=%@\n", ind, NSStringFromClass(v.class), NSStringFromCGRect(v.frame), v.alpha, v.hidden,
     (unsigned long)v.subviews.count, CGAffineTransformIsIdentity(t) ? @"I" : [NSString stringWithFormat:@"a%.2f d%.2f", t.a, t.d]];
    for (UIView *x in v.subviews) csWalk(x, d + 1, maxD, out, budget);
}

static void csViewDump(void) {
    static int dumps;
    if (++dumps > 4) return;
    csLog(@"=== VIEW DUMP #%d", dumps);
    NSMutableArray *wins = [NSMutableArray array];
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes)
        if ([sc isKindOfClass:UIWindowScene.class]) [wins addObjectsFromArray:((UIWindowScene *)sc).windows];
    for (UIWindow *w in wins) {
        int b = 4000;
        if (!csHasSwitcher(w, 0, &b)) continue;
        UIViewController *rvc = w.rootViewController;
        NSMutableString *vcs = [NSMutableString string];
        UIViewController *x = rvc; int n = 0;
        while (x && n++ < 4) { [vcs appendFormat:@"%@ > ", NSStringFromClass(x.class)]; x = x.childViewControllers.firstObject; }
        csLog(@"window %@ level=%.0f rootVC chain: %@", NSStringFromClass(w.class), w.windowLevel, vcs);
        // tim view dau tien co ten chua "Switcher" o do sau nong nhat, in cay tu do
        __block UIView *hit = nil;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:w];
        int guard = 0;
        while (queue.count && !hit && guard++ < 4000) {
            UIView *v = queue.firstObject; [queue removeObjectAtIndex:0];
            if ([NSStringFromClass(v.class) rangeOfString:@"Switcher"].location != NSNotFound) { hit = v; break; }
            [queue addObjectsFromArray:v.subviews];
        }
        if (hit) {
            NSMutableString *out = [NSMutableString string]; int budget = 120;
            csWalk(hit, 0, 7, out, &budget);
            csLog(@"tree from %@ (superview=%@):\n%@", NSStringFromClass(hit.class), NSStringFromClass(hit.superview.class), out);
        }
    }
}

static int csPrevVis = -1;

static void csDumpSwitcher(void) {
    static int dumps;
    if (++dumps > 6) return;
    UIViewController *fl = csFluid;
    csLog(@"=== DUMP #%d fluid=%@ hooks: center=%d transform=%d alpha=%d frame=%d layout=%d applied=%d", dumps,
          fl ? NSStringFromClass(fl.class) : @"nil", csCnt[0], csCnt[1], csCnt[2], csCnt[3], csCnt[4], csCnt[5]);
    NSArray *ls = send0(fl, @"appLayouts");
    if (![ls isKindOfClass:NSArray.class]) { csLog(@"dump: no appLayouts on fluid VC"); }
    else for (NSUInteger i = 0; i < MIN(ls.count, 12); i++) {
        id lay = ls[i];
        NSArray *items = send0(lay, @"allItems");
        NSString *b = ([items isKindOfClass:NSArray.class] && items.count) ? send0(items.firstObject, @"bundleIdentifier") : @"?";
        UIView *c = send1(fl, @"_itemContainerForAppLayoutIfExists:", lay);
        if (![c isKindOfClass:UIView.class]) { csLog(@"[%lu] %@ container=nil", (unsigned long)i, b); continue; }
        NSValue *sc = objc_getAssociatedObject(c, kSysC);
        csLog(@"[%lu] %@ %@ center=%@ sysCenter=%@ bounds=%@ alpha=%.2f superview=%@ win=%d",
              (unsigned long)i, b, NSStringFromClass(c.class), NSStringFromCGPoint(c.center),
              sc ? NSStringFromCGPoint(sc.CGPointValue) : @"(no hook hit)", NSStringFromCGRect(c.bounds), c.alpha,
              c.superview ? NSStringFromClass(c.superview.class) : @"nil", c.window != nil);
    }
    for (NSString *cn in @[@"SBFluidSwitcherViewController", @"SBFluidSwitcherItemContainer", @"SBDeckSwitcherPersonality"]) {
        Class k = NSClassFromString(cn);
        if (!k) { csLog(@"class %@ = nil", cn); continue; }
        unsigned n = 0; Method *ms = class_copyMethodList(k, &n);
        NSMutableArray *names = [NSMutableArray array];
        for (unsigned i = 0; i < n; i++) [names addObject:NSStringFromSelector(method_getName(ms[i]))];
        free(ms);
        NSString *joined = [names componentsJoinedByString:@" "];
        if (joined.length > 3500) joined = [joined substringToIndex:3500];
        csLog(@"methods %@ (%u): %@", cn, n, joined);
    }
    if (dumps == 1) {
        unsigned cnt = 0; Class *all = objc_copyClassList(&cnt);
        NSMutableArray *mods = [NSMutableArray array];
        for (unsigned i = 0; i < cnt; i++) {
            const char *nm = class_getName(all[i]);
            if (strncmp(nm, "SB", 2) == 0 && (strstr(nm, "SwitcherModifier") || strstr(nm, "SwitcherPersonality") || strstr(nm, "SwitcherItem"))) [mods addObject:@(nm)];
        }
        free(all);
        csLog(@"switcher classes (%lu): %@", (unsigned long)mods.count, [mods componentsJoinedByString:@" "]);
    }
}

static void csGuardTick(void) {
    double up = -[csBoot timeIntervalSinceNow];
    double now = CACurrentMediaTime();
    BOOL recent = csLastApply > 0 && now - csLastApply < 4;
    BOOL need = up < 20 || recent;
    if (need && !csMarkerOn) { [@"1" writeToFile:CS_MARKER atomically:NO encoding:NSUTF8StringEncoding error:nil]; csMarkerOn = YES; }
    else if (!need && csMarkerOn) { [NSFileManager.defaultManager removeItemAtPath:CS_MARKER error:nil]; csMarkerOn = NO; }
    static BOOL dumped;
    if (recent && !dumped) { dumped = YES; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ csDumpSwitcher(); }); }
    if (!recent && csLastApply > 0) dumped = NO;
}

static void csTick(void) {
    if (++csTickCount % 12 == 1) loadCfg();
    csGuardTick();
    if (!C.enabled || C.mode != 2) {
        if (csOverlay.superview && !csOverlay.testMode) csHideOverlay();
        if (C.enabled && prefBool(CFSTR("probe"), NO) && -[csBoot timeIntervalSinceNow] > 15) {
            csStaticDump();
            int v = csSafeVisible();
            if (v == 1 && csPrevVis != 1) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ csViewDump(); });
            csPrevVis = v;
        }
        return;
    }
    if (-[csBoot timeIntervalSinceNow] < 8) return;
    csDiscoverOnce();
    if (csOverlay.superview && csOverlay.testMode) return;
    int vis = csDetectVisible();
    BOOL shown = csOverlay.superview != nil;
    if (vis == 1 && !shown && !csForceHidden) csShowOverlay(NO);
    else if (vis == 0) { csForceHidden = NO; if (shown) csHideOverlay(); }
    else if (vis == 1 && shown && csShownAt && -[csShownAt timeIntervalSinceNow] > 90 && ![csOverlay userRecentlyTouched:90]) {
        csLog(@"stuck guard: hiding overlay"); csForceHidden = YES; csHideOverlay();
    }
    if (shown) for (UIView *b in csBubbles) [csRoot.view bringSubviewToFront:b];
}

static void csTestNote(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CFPreferencesAppSynchronize(CS_DOMAIN);
        if (prefBool(CFSTR("testShow"), NO)) csShowOverlay(YES); else csHideOverlay();
    });
}

static void csRespringNote(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef ui) {
    dispatch_async(dispatch_get_main_queue(), ^{
        csLog(@"respring requested");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id svc = send0((id)NSClassFromString(@"FBSystemService"), @"sharedInstance");
            SEL s = NSSelectorFromString(@"exitAndRelaunch:");
            if (svc && [svc respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(svc, s, YES);
            else exit(0);
        });
    });
}

%group RealSwitcher

%hook SBFluidSwitcherViewController
- (void)viewDidLoad {
    %orig;
    csFluid = (UIViewController *)self;
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    csFluid = (UIViewController *)self;
}
%end

%hook SBFluidSwitcherItemContainer
- (void)setCenter:(CGPoint)p {
    %orig;
    csCnt[0]++;
    objc_setAssociatedObject(self, kSysC, [NSValue valueWithCGPoint:p], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    csApplyRing((UIView *)self);
}
- (void)setFrame:(CGRect)f {
    %orig;
    csCnt[3]++;
    NSValue *vt = objc_getAssociatedObject(self, kSysT);
    if (!vt || CGAffineTransformIsIdentity(vt.CGAffineTransformValue)) {
        objc_setAssociatedObject(self, kSysC, [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(f), CGRectGetMidY(f))], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        csApplyRing((UIView *)self);
    }
}
- (void)setTransform:(CGAffineTransform)t {
    %orig;
    csCnt[1]++;
    objc_setAssociatedObject(self, kSysT, [NSValue valueWithCGAffineTransform:t], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    csApplyRing((UIView *)self);
}
- (void)setAlpha:(CGFloat)a {
    %orig;
    csCnt[2]++;
    objc_setAssociatedObject(self, kSysA, @(a), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    csApplyRing((UIView *)self);
}
- (void)layoutSubviews {
    %orig;
    csCnt[4]++;
    csApplyRing((UIView *)self);
}
%end

%end

%ctor {
    // Thoat ngay o moi tien trinh khac SpringBoard, truoc khi lam bat cu viec gi
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    csLines = [NSMutableArray new];
    itemCache = [NSMutableDictionary new];
    csBubbles = [NSMutableArray new];
    csBoot = [NSDate date];
    loadCfg();
    csLog(@"CircleSwitcher loaded in %@", NSBundle.mainBundle.bundleIdentifier);
    if (prefDouble(CFSTR("modeVer"), 0) < 3) {
        // ban cu luu mode=0 (Lop phu). Tu v1.1 so 0 la "Thay that" -> dat lai an toan mot lan
        int m = 2, ver = 3;
        CFNumberRef a = CFNumberCreate(NULL, kCFNumberIntType, &m), b = CFNumberCreate(NULL, kCFNumberIntType, &ver);
        CFPreferencesSetAppValue(CFSTR("mode"), a, CS_DOMAIN); CFPreferencesSetAppValue(CFSTR("modeVer"), b, CS_DOMAIN);
        CFRelease(a); CFRelease(b);
        CFPreferencesAppSynchronize(CS_DOMAIN);
        loadCfg();
        csLog(@"migrated: mode reset to 2 (overlay, stable), modeVer=3");
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:CS_MARKER]) {
        csTripped = YES;
        [NSFileManager.defaultManager removeItemAtPath:CS_MARKER error:nil];
        int one = 1; CFNumberRef nm = CFNumberCreate(NULL, kCFNumberIntType, &one);
        CFPreferencesSetAppValue(CFSTR("mode"), nm, CS_DOMAIN); CFRelease(nm);
        CFPreferencesAppSynchronize(CS_DOMAIN);
        loadCfg();
        csLog(@"CRASH GUARD: SpringBoard died while the tweak was active -> mode set to 1 (log only), hooks disabled this boot");
        return;
    }
    [@"1" writeToFile:CS_MARKER atomically:NO encoding:NSUTF8StringEncoding error:nil];
    csMarkerOn = YES;
    if (C.mode == 0 && NSClassFromString(@"SBFluidSwitcherItemContainer")) { %init(RealSwitcher); csLog(@"real switcher hooks installed"); }
    else csLog(@"real switcher hooks NOT installed (mode=%d, class=%d)", C.mode, NSClassFromString(@"SBFluidSwitcherItemContainer") != nil);
    dispatch_async(dispatch_get_main_queue(), ^{
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, csTestNote, CS_TEST_NOTE, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, csRespringNote, CS_RESPRING_NOTE, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        NSTimer *tm = [NSTimer timerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { csTick(); }];
        [NSRunLoop.mainRunLoop addTimer:tm forMode:NSRunLoopCommonModes];
        csLog(@"timer + darwin observers installed");
    });
}
