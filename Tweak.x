#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <signal.h>
#import <dlfcn.h>
#import <math.h>
#import "CSRingV2.h"

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
    BOOL ringGlow, namePill, snapCircle, chevron;
    int count, namePos, mode, style;
    double radius, tilt, cam, blur, size, off, bubSize;
    double iconSize, centerSize, dim, bgBlur, glowHue;
    double gap, cardCorner, glowAmt, moveBlur, openSpeed;
    BOOL openAnim;
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
    C.namePos = (int)prefDouble(CFSTR("namePos"), 0);
    C.radius = prefDouble(CFSTR("radius"), 120);
    C.tilt = prefDouble(CFSTR("tilt"), 35);
    C.cam = prefDouble(CFSTR("cam"), 22);
    C.blur = prefDouble(CFSTR("blur"), 2);
    C.size = prefDouble(CFSTR("size"), 100);
    C.off = prefDouble(CFSTR("off"), 0);
    C.bubSize = prefDouble(CFSTR("bubSize"), 56);
    C.style = (int)prefDouble(CFSTR("style"), 1);
    if (C.style < 0 || C.style > 3) C.style = 1;
    C.ringGlow = prefBool(CFSTR("ringGlow"), YES);
    C.namePill = prefBool(CFSTR("namePill"), NO);
    C.snapCircle = prefBool(CFSTR("snapCircle"), YES);
    C.chevron = prefBool(CFSTR("chevron"), YES);
    C.iconSize = prefDouble(CFSTR("iconSize"), 100);
    C.centerSize = prefDouble(CFSTR("centerSize"), 100);
    C.dim = prefDouble(CFSTR("dim"), 35);
    C.bgBlur = prefDouble(CFSTR("bgBlur"), 10);
    C.glowHue = prefDouble(CFSTR("glowHue"), 225);
    C.gap = prefDouble(CFSTR("gap"), 100);
    C.cardCorner = prefDouble(CFSTR("cardCorner"), 28);
    C.glowAmt = prefDouble(CFSTR("glowAmt"), 70);
    C.moveBlur = prefDouble(CFSTR("moveBlur"), 3);
    C.openSpeed = prefDouble(CFSTR("openSpeed"), 100);
    C.openAnim = prefBool(CFSTR("openAnim"), YES);
}

static CSRingCfg csCfg(void) {
    CSRingCfg c;
    c.radius = C.radius; c.tilt = C.tilt; c.cam = C.cam; c.size = C.size; c.off = C.off; c.count = C.count;
    c.style = C.style; c.iconSize = C.iconSize; c.centerSize = C.centerSize; c.gap = C.gap;
    return c;
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
    UIFont *f = [UIFont systemFontOfSize:(C.namePill ? 12 : 16) weight:UIFontWeightMedium];
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
@property (nonatomic, assign) BOOL circle, neon;
- (void)configure:(CSItem *)it showIcon:(BOOL)on;
- (void)setBlur:(double)r;
- (void)setGlow:(double)k;
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
    CGFloat bw = self.bounds.size.width;
    CGFloat s = bw * (self.circle ? 0.62 : 0.56);
    self.icon.frame = CGRectMake((bw - s) / 2, (self.bounds.size.height - s) / 2, s, s);
    self.icon2.frame = self.icon.frame;
    CGFloat cr = self.circle ? bw / 2 : (self.neon ? C.cardCorner : 18);
    self.front.layer.cornerRadius = cr; self.back.layer.cornerRadius = cr;
    self.icon.layer.cornerRadius = self.circle ? s * 0.225 : 12;
    self.front.layer.borderWidth = self.circle ? 1.6 : (self.neon ? 2.0 : 0.5);
    UIColor *nb = [UIColor colorWithHue:fmod(C.glowHue, 360.0) / 360.0 saturation:0.45 brightness:1 alpha:0.9];
    self.front.layer.borderColor = (self.neon ? nb : [UIColor colorWithWhite:1 alpha:self.circle ? 0.65 : 0.25]).CGColor;
    if (self.circle) self.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:self.bounds].CGPath;
    else if (self.neon) self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:cr].CGPath;
}
- (void)setGlow:(double)k {
    if ((!self.circle && !self.neon) || !C.ringGlow) { self.layer.shadowOpacity = 0; return; }
    UIColor *g = [UIColor colorWithHue:fmod(C.glowHue, 360.0) / 360.0 saturation:0.55 brightness:1 alpha:1];
    self.layer.shadowColor = g.CGColor; self.layer.shadowOffset = CGSizeZero;
    self.layer.shadowRadius = 8 + 10 * k; self.layer.shadowOpacity = (float)((0.25 + 0.65 * k) * (self.neon ? C.glowAmt / 100.0 : 1.0));
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
@property (nonatomic, strong) UIView *ring, *labelHost, *dotsView, *bubble;
@property (nonatomic, strong) UIImageView *bubbleIcon, *chev;
@property (nonatomic, strong) CAShapeLayer *glowRing;
@property (nonatomic, strong) NSMutableArray<CSCard *> *cards;
@property (nonatomic, strong) NSMutableArray<CSLabel *> *labels;
@property (nonatomic, strong) NSMutableArray<CSItem *> *items;
@property (nonatomic, strong) UIButton *xBtn, *cleanBtn, *exitBtn;
@property (nonatomic, strong) UILabel *emptyLabel, *toastLabel;
@property (nonatomic, assign) double rot, vel, from, to, t, dragY, lastRot;
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
- (void)relayoutRing;
- (void)relayoutCards;
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
        _glowRing = [CAShapeLayer layer];
        _glowRing.fillColor = nil; _glowRing.lineWidth = 5; _glowRing.hidden = YES;
        [self.layer addSublayer:_glowRing];
        _bubble = [UIView new]; _bubble.userInteractionEnabled = NO; _bubble.hidden = YES;
        _bubble.backgroundColor = [UIColor colorWithRed:0.12 green:0.2 blue:0.5 alpha:0.45];
        _bubble.layer.borderWidth = 1.5; _bubble.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.45].CGColor;
        _bubble.layer.shadowColor = [UIColor colorWithRed:0.4 green:0.5 blue:1 alpha:1].CGColor;
        _bubble.layer.shadowOpacity = 0.7; _bubble.layer.shadowRadius = 16; _bubble.layer.shadowOffset = CGSizeZero;
        _bubbleIcon = [UIImageView new]; _bubbleIcon.contentMode = UIViewContentModeScaleAspectFit; _bubbleIcon.clipsToBounds = YES;
        [_bubble addSubview:_bubbleIcon]; [self addSubview:_bubble];
        _chev = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"chevron.compact.up" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightMedium]] imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.75] renderingMode:UIImageRenderingModeAlwaysOriginal]];
        _chev.hidden = YES; _chev.userInteractionEnabled = NO; [self addSubview:_chev];
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
        for (UIButton *gb in @[_xBtn, _cleanBtn]) {
            gb.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
            gb.layer.borderWidth = 1; gb.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        }
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
    if (C.style <= 1) {
        self.xBtn.bounds = CGRectMake(0, 0, 170, 46);   // thanh kinh dang vien thuoc giong anh mau 2
        self.xBtn.center = CGPointMake(W / 2, H - 92);
        self.cleanBtn.center = CGPointMake(W / 2 - 124, H - 92);
    } else {
        self.xBtn.bounds = CGRectMake(0, 0, 46, 46);
        self.xBtn.center = CGPointMake(W / 2, H - 70);
        self.cleanBtn.center = CGPointMake(W / 2 - 80, H - 70);
    }
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
        BOOL circ = C.style <= 1;
        CSCard *c = [[CSCard alloc] initWithFrame:circ ? CGRectMake(0, 0, 100, 100) : CGRectMake(0, 0, 110, 186)];
        c.circle = circ; c.neon = (C.style == 3);
        [c configure:it showIcon:C.icon];
        [self.ring addSubview:c]; [self.cards addObject:c];
        CSLabel *l = [CSLabel new];
        l.backgroundColor = C.namePill ? [UIColor colorWithWhite:0.1 alpha:0.78] : UIColor.clearColor;
        l.layer.cornerRadius = 11; l.layer.masksToBounds = YES;
        if (!C.namePill) { l.layer.shadowColor = UIColor.blackColor.CGColor; l.layer.shadowOpacity = 0.5; l.layer.shadowRadius = 3; l.layer.shadowOffset = CGSizeZero; l.layer.masksToBounds = NO; }
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
    self.dotsView.frame = CGRectMake((W - total) / 2, H - (C.style >= 2 ? 125 : 150), total, 6);
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

- (void)applyBackground {
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:CSClamp(C.dim, 0, 90) / 100.0];
    self.blurBg.hidden = C.bgBlur < 0.5;
    self.blurBg.alpha = CSClamp(C.bgBlur / 10.0, 0, 1);
}

- (void)relayout {
    [self applyBackground];
    BOOL circ = C.style <= 1;
    if (!circ) {
        self.glowRing.hidden = YES; self.bubble.hidden = YES; self.chev.hidden = YES;
        [self relayoutCards];
    } else [self relayoutRing];
}

- (void)relayoutRing {
    NSInteger n = self.items.count;
    if (n != (NSInteger)self.cards.count) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    CGFloat cx = W / 2, cy = H * 0.46;
    self.ring.bounds = CGRectMake(0, 0, 2, 2); self.ring.center = CGPointMake(cx, cy);
    self.ring.layer.sublayerTransform = CATransform3DIdentity;
    double step = [self step];
    CSRingCfg cfg = csCfg();
    // vong sang
    if (C.ringGlow) {
        double gx, gy, rx, ry; CSRingGlowRect(cfg, &gx, &gy, &rx, &ry);
        UIColor *g = [UIColor colorWithHue:fmod(C.glowHue, 360.0) / 360.0 saturation:0.6 brightness:1 alpha:1];
        self.glowRing.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx + gx - rx, cy + gy - ry, rx * 2, ry * 2)].CGPath;
        self.glowRing.strokeColor = [g colorWithAlphaComponent:0.75].CGColor;
        self.glowRing.shadowColor = g.CGColor; self.glowRing.shadowOpacity = 0.9; self.glowRing.shadowRadius = 12; self.glowRing.shadowOffset = CGSizeZero;
        self.glowRing.hidden = NO;
    } else self.glowRing.hidden = YES;
    double best = 1e9; NSInteger front = -1;
    NSMutableArray *order = [NSMutableArray array];
    double selDia = 0, selY = 0;
    for (NSInteger i = 0; i < n; i++) {
        CSCard *card = self.cards[i]; CSLabel *lb = self.labels[i];
        double phi = normDeg(i * step - self.rot);
        CSPose p = CSRingPoseCircle(phi, step, cfg, W);
        double y = p.y;
        if (i == self.front && self.dragY != 0) y += self.dragY;
        if (fabs(card.bounds.size.width - 100) > 0.5 || fabs(card.bounds.size.height - 100) > 0.5) card.bounds = CGRectMake(0, 0, 100, 100);
        double f = p.dia / 100.0;
        card.layer.position = CGPointMake(1 + p.x, 1 + y);
        CATransform3D t = CATransform3DIdentity; t.m34 = -1.0 / p.perspective;
        t = CATransform3DRotate(t, p.yaw, 0, 1, 0);
        t = CATransform3DScale(t, f, f, 1);
        card.layer.transform = t; card.layer.zPosition = p.z + p.k * 2;
        double op = p.opacity;
        if (i == self.front && self.dragY < 0) op *= MAX(0.2, 1 + self.dragY / 220.0);
        card.alpha = op;
        [card setBlur:(C.style == 1 ? C.blur * MIN(1.0, fabs(phi) / 90.0) : 0)];
        [card setGlow:p.k];
        card.front.hidden = NO; card.back.hidden = YES;
        double px = cx + p.x, py = cy + y, rr = p.dia / 2;
        card.hit = CGRectMake(px - rr, py - rr, rr * 2, rr * 2); card.zv = p.z + p.k * 2;
        [order addObject:card];
        if (fabs(phi) < best) { best = fabs(phi); front = i; selDia = p.dia; selY = py; }
        BOOL isFront = fabs(phi) <= step / 2;
        BOOL show = C.namePos != 3 && isFront;
        lb.hidden = !show;
        if (show) {
            double bubR = 59.0 * C.centerSize / 100.0 * C.size / 100.0;
            double ly;
            if (C.style == 0) {
                ly = C.namePos == 0 ? py - rr - 18 : (C.namePos == 1 ? cy + C.off + bubR + 26 : cy + C.off + cfg.radius * 1.25 + selDia / 2 + 28);
                lb.center = CGPointMake(C.namePos == 0 ? px : cx, ly);
            } else {
                ly = C.namePos == 0 ? py - rr - 20 : (C.namePos == 1 ? py : py + rr + 20);
                lb.center = CGPointMake(px, ly);
            }
            lb.transform = CGAffineTransformIdentity;
            lb.alpha = 1;
        }
    }
    [order sortUsingComparator:^NSComparisonResult(CSCard *a, CSCard *b) { return a.zv < b.zv ? NSOrderedAscending : NSOrderedDescending; }];
    for (CSCard *c in order) [self.ring bringSubviewToFront:c];
    // bong bong o giua (anh mau 1) + mui ten
    BOOL flat = C.style == 0 && n > 0;
    self.bubble.hidden = !flat;
    if (flat) {
        double bd = 118.0 * C.centerSize / 100.0 * C.size / 100.0;
        self.bubble.bounds = CGRectMake(0, 0, bd, bd); self.bubble.center = CGPointMake(cx, cy + C.off);
        self.bubble.layer.cornerRadius = bd / 2;
        self.bubbleIcon.frame = CGRectInset(self.bubble.bounds, bd * 0.24, bd * 0.24);
        self.bubbleIcon.layer.cornerRadius = bd * 0.12;
        if (front >= 0 && front < n) self.bubbleIcon.image = self.items[front].icon;
        self.bubbleIcon.hidden = !C.icon;
    }
    self.chev.hidden = !(C.style == 0 && C.chevron && n > 0);
    if (!self.chev.hidden) self.chev.center = CGPointMake(cx, selY - selDia / 2 - (C.namePos == 0 && C.style == 0 ? 52 : 26));
    if (front != self.front) {
        BOOL first = (self.front == -2);
        self.front = front;
        if (!first) [self buzz];
        [self rebuildDots];
    }
}

- (void)relayoutCards {
    NSInteger n = self.items.count;
    if (n != (NSInteger)self.cards.count) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, P = 900;
    CGFloat cx = W / 2, cy = H * 0.46 + C.off;
    self.ring.bounds = CGRectMake(0, 0, 2, 2); self.ring.center = CGPointMake(cx, cy);
    CATransform3D persp = CATransform3DIdentity; persp.m34 = -1.0 / P;
    self.ring.layer.sublayerTransform = persp;
    double step = [self step], e = C.cam * M_PI / 180.0;
    CGFloat w = 110 * C.size / 100.0, h = 186 * C.size / 100.0;
    BOOL neon = C.style == 3;
    double gm = neon ? C.gap / 100.0 : 1.0;
    double spd = fabs(self.rot - self.lastRot); self.lastRot = self.rot;
    double mblur = neon ? C.moveBlur * MIN(1.0, spd / MAX(step * 0.2, 0.5)) : 0;
    double best = 1e9; NSInteger front = -1;
    NSMutableArray *order = [NSMutableArray array];
    for (NSInteger i = 0; i < n; i++) {
        CSCard *card = self.cards[i]; CSLabel *lb = self.labels[i];
        double phi = normDeg(i * step - self.rot), r = phi * gm * M_PI / 180.0;
        double kk = CSClamp(1.0 - fabs(phi) / MAX(step, 1.0), 0, 1), ks = kk * kk * (3.0 - 2.0 * kk);
        double fsc = neon ? 0.80 + 0.30 * ks : 1.0;
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
        if (neon) t = CATransform3DScale(t, fsc, fsc, 1);
        card.layer.transform = t;
        double op = 0.4 + 0.6 * (cos(r) + 1) / 2;
        if (i == self.front && self.dragY < 0) op *= MAX(0.2, 1 + self.dragY / 220.0);
        card.alpha = op;
        double bl = C.blur * MIN(1.0, fabs(phi) / 90.0) + (C.namePos == 1 ? 1.5 : 0) + mblur;
        [card setBlur:bl];
        [card setGlow:ks];
        card.front.hidden = back; card.back.hidden = !back;
        double px = cx + x * s, py = cy + y * s;
        double hw = (w * fsc * s / 2) * MAX(fabs(cos(yaw)), 0.25), hh = h * fsc * s / 2;
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
    if (C.openAnim) {
        double sp = CSClamp(C.openSpeed, 40, 250) / 100.0;
        csOverlay.ring.transform = CGAffineTransformMakeScale(0.35, 0.35);
        csOverlay.labelHost.alpha = 0;
        [UIView animateWithDuration:0.55 / sp delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.6
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ csOverlay.ring.transform = CGAffineTransformIdentity; csOverlay.alpha = 1; } completion:nil];
        [UIView animateWithDuration:0.3 / sp delay:0.12 / sp options:0 animations:^{ csOverlay.labelHost.alpha = 1; } completion:nil];
    } else {
        csOverlay.ring.transform = CGAffineTransformIdentity; csOverlay.labelHost.alpha = 1;
        [UIView animateWithDuration:0.2 animations:^{ csOverlay.alpha = 1; }];
    }
    for (UIView *b in csBubbles) [csRoot.view bringSubviewToFront:b];
    csShownAt = [NSDate date];
    csLog(@"overlay shown (test=%d)", test);
}

static void csHideOverlay(void) {
    if (!csOverlay || !csOverlay.superview) return;
    CSOverlay *o = csOverlay;
    double sp = CSClamp(C.openSpeed, 40, 250) / 100.0;
    [UIView animateWithDuration:0.2 / sp delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        o.alpha = 0; if (C.openAnim) o.ring.transform = CGAffineTransformMakeScale(0.6, 0.6);
    } completion:^(BOOL f) { if (o.alpha == 0) { [o removeFromSuperview]; o.ring.transform = CGAffineTransformIdentity; } }];
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

static UIViewController *csFindVC(UIViewController *v, NSString *cls, int d) {
    if (!v || d > 8) return nil;
    if ([NSStringFromClass(v.class) isEqualToString:cls]) return v;
    for (UIViewController *c in v.childViewControllers) { UIViewController *r = csFindVC(c, cls, d + 1); if (r) return r; }
    UIViewController *p = v.presentedViewController;
    return p ? csFindVC(p, cls, d + 1) : nil;
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
        UIViewController *deck = csFindVC(rvc, @"SBDeckSwitcherViewController", 0);
        if (deck && deck.isViewLoaded) {
            NSMutableString *o2 = [NSMutableString string]; int b2 = 260;
            csWalk(deck.view, 0, 9, o2, &b2);
            csLog(@"DECK VC view tree (%@):\n%@", NSStringFromClass(deck.class), o2);
        } else csLog(@"DECK VC not found under rootVC");
    }
}

static int csPrevVis = -1;

#pragma mark - real switcher (hook SBDeckSwitcherViewController, the stock iPhone switcher)

@interface SBDeckSwitcherViewController : UIViewController
@end

#define CS_MARKER @"/var/mobile/Documents/CircleSwitcher.armed"
static BOOL csTripped, csMarkerOn;
static double csLastApply;
static int csDeckHits, csDeckApplied;
static const void *kMineP = &kMineP, *kMineT = &kMineT, *kSysP = &kSysP, *kSysT = &kSysT, *kSysO = &kSysO, *kApplied = &kApplied;

static BOOL csT3Near(CATransform3D a, CATransform3D b) {
    return fabs(a.m11 - b.m11) < 1e-3 && fabs(a.m12 - b.m12) < 1e-3 && fabs(a.m21 - b.m21) < 1e-3 && fabs(a.m22 - b.m22) < 1e-3 &&
           fabs(a.m34 - b.m34) < 1e-6 && fabs(a.m41 - b.m41) < 0.05 && fabs(a.m42 - b.m42) < 0.05 && fabs(a.m43 - b.m43) < 0.05;
}

// Gom the app that + dong tieu de (ten/icon app) ben trong view cua switcher
static void csCollect(UIView *v, int d, NSMutableArray *cards, NSMutableArray *heads, int *budget) {
    if (--(*budget) < 0 || d > 9) return;
    NSString *n = NSStringFromClass(v.class);
    if ([n rangeOfString:@"Header"].location != NSNotFound || [n rangeOfString:@"IconImageContainer"].location != NSNotFound) {
        [heads addObject:v]; return;
    }
    if ([n rangeOfString:@"ItemContainer"].location != NSNotFound) { [cards addObject:v]; return; }
    for (UIView *x in v.subviews) csCollect(x, d + 1, cards, heads, budget);
}

typedef struct { BOOL ok; CGPoint pos, scr; CATransform3D t; double sc, op; } CSSys;
static const void *kMineO = &kMineO;

// Doc vi tri/ti le/do mo DO HE THONG dat (bo qua gia tri do chinh tweak da ghi)
static CSSys csCapture(UIView *c) {
    CSSys s; memset(&s, 0, sizeof s);
    UIView *sv = c.superview;
    if (!sv || !c.window) return s;
    CALayer *L = c.layer;
    NSValue *mp = objc_getAssociatedObject(c, kMineP), *mt = objc_getAssociatedObject(c, kMineT);
    NSNumber *mo = objc_getAssociatedObject(c, kMineO);
    CGPoint curP = L.position; CATransform3D curT = L.transform;
    BOOL mine = mp && mt && mo && fabs(curP.x - mp.CGPointValue.x) < 0.05 && fabs(curP.y - mp.CGPointValue.y) < 0.05 &&
                csT3Near(curT, mt.CATransform3DValue) && fabs(L.opacity - mo.floatValue) < 0.01;
    if (!mine) {
        objc_setAssociatedObject(c, kSysP, [NSValue valueWithCGPoint:curP], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(c, kSysT, [NSValue valueWithCATransform3D:curT], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(c, kSysO, @(L.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSValue *spv = objc_getAssociatedObject(c, kSysP), *stv = objc_getAssociatedObject(c, kSysT);
    if (!spv || !stv) return s;
    s.pos = spv.CGPointValue; s.t = stv.CATransform3DValue;
    NSNumber *so = objc_getAssociatedObject(c, kSysO);
    s.op = so ? so.doubleValue : 1.0;
    if (!isfinite(s.pos.x) || !isfinite(s.pos.y)) return s;
    CGAffineTransform st = CATransform3DGetAffineTransform(s.t);
    s.sc = hypot(st.a, st.b);
    s.scr = [sv convertPoint:s.pos toView:nil];
    s.ok = YES;
    return s;
}

static const void *kMaskL = &kMaskL, *kHid = &kHid;

static void csSetCircleMask(UIView *c, BOOL on) {
    CALayer *L = c.layer;
    CAShapeLayer *mine = objc_getAssociatedObject(c, kMaskL);
    if (!on) { if (mine && L.mask == mine) L.mask = nil; objc_setAssociatedObject(c, kMaskL, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); return; }
    if (L.mask && L.mask != mine) return; // he thong dang dung mask rieng -> khong dung vao
    CGFloat bw = c.bounds.size.width, bh = c.bounds.size.height;
    if (!mine) { mine = [CAShapeLayer layer]; mine.fillColor = UIColor.blackColor.CGColor; objc_setAssociatedObject(c, kMaskL, mine, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    CGRect r = CGRectMake(0, (bh - bw) / 2, bw, bw);
    mine.frame = c.bounds;
    mine.path = [UIBezierPath bezierPathWithOvalInRect:r].CGPath;
    L.mask = mine;
}

static const void *kNeon = &kNeon;
static void csSetNeon(UIView *c, BOOL on, double k) {
    CALayer *L = c.layer;
    if (!on) {
        if ([objc_getAssociatedObject(c, kNeon) boolValue]) { L.shadowOpacity = 0; objc_setAssociatedObject(c, kNeon, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
        return;
    }
    UIColor *g = [UIColor colorWithHue:fmod(C.glowHue, 360.0) / 360.0 saturation:0.55 brightness:1 alpha:1];
    L.shadowColor = g.CGColor; L.shadowOffset = CGSizeZero;
    L.shadowRadius = 10 + 14 * k; L.shadowOpacity = (float)((0.2 + 0.7 * k) * C.glowAmt / 100.0);
    L.shadowPath = [UIBezierPath bezierPathWithRoundedRect:c.bounds cornerRadius:C.cardCorner].CGPath;
    objc_setAssociatedObject(c, kNeon, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void csHideHead(UIView *h, BOOL hide) {
    BOOL was = [objc_getAssociatedObject(h, kHid) boolValue];
    if (hide && !was) { h.hidden = YES; objc_setAssociatedObject(h, kHid, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    else if (hide) h.hidden = YES;
    else if (was) { h.hidden = NO; objc_setAssociatedObject(h, kHid, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
}

static NSString *csTitleOf(UIView *v, int d) {
    if (d > 5) return nil;
    if ([v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) return ((UILabel *)v).text;
    for (UIView *x in v.subviews) { NSString *t = csTitleOf(x, d + 1); if (t) return t; }
    return nil;
}

static CSLabel *csNameL;
static void csShowName(NSString *t, CGPoint c) {
    if (!t.length || C.namePos == 3) { csNameL.hidden = YES; return; }
    if (!ensureWindow()) return;
    if (!csNameL) {
        csNameL = [CSLabel new]; csNameL.userInteractionEnabled = NO;
        csNameL.textColor = UIColor.whiteColor; csNameL.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        csNameL.layer.shadowColor = UIColor.blackColor.CGColor; csNameL.layer.shadowOpacity = 0.5; csNameL.layer.shadowRadius = 3; csNameL.layer.shadowOffset = CGSizeZero;
        [csRoot.view addSubview:csNameL];
    }
    if (![csNameL.text isEqualToString:t]) { csNameL.text = t; [csNameL sizeToFit]; }
    csNameL.center = c; csNameL.hidden = NO;
}

static void csRestore(UIView *c, CSSys s) {
    if (![objc_getAssociatedObject(c, kApplied) boolValue]) return;
    csSetCircleMask(c, NO);
    csSetNeon(c, NO, 0);
    CALayer *L = c.layer;
    L.position = s.pos; L.transform = s.t; L.opacity = (float)s.op; L.zPosition = 0; L.doubleSided = YES;
    objc_setAssociatedObject(c, kApplied, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kMineP, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kMineT, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kMineO, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void csStamp(UIView *c) {
    CALayer *L = c.layer;
    objc_setAssociatedObject(c, kMineP, [NSValue valueWithCGPoint:L.position], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kMineT, [NSValue valueWithCATransform3D:L.transform], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kMineO, @(L.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(c, kApplied, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// Cache danh sach the/tieu de: khong quet cay view moi khung hinh (nguyen nhan lag cu)
static NSArray *csCards, *csHeads;
static __weak UIView *csCacheRoot;
static NSUInteger csCacheSig;
static double csNextScan;
static int csScanLogs;

static NSUInteger csSigOf(void) {
    UIView *a = csCards.firstObject, *b = csHeads.firstObject;
    return a.superview.subviews.count * 131 + b.superview.subviews.count + csCards.count * 7 + csHeads.count;
}

static BOOL csCacheValid(UIView *root) {
    if (!csCards.count || csCacheRoot != root) return NO;
    for (UIView *c in csCards) if (!c.window) return NO;
    return csSigOf() == csCacheSig;
}

static void csRefresh(UIView *root) {
    if (csCacheValid(root)) return;
    double now = CACurrentMediaTime();
    if (now < csNextScan) return;
    NSMutableArray *cards = [NSMutableArray array], *heads = [NSMutableArray array];
    int budget = 900;
    csCollect(root, 0, cards, heads, &budget);
    csCards = cards; csHeads = heads; csCacheRoot = root; csCacheSig = csSigOf();
    if (!cards.count) csNextScan = now + 0.5;
    if (csScanLogs++ < 6) {
        NSMutableString *hs = [NSMutableString string];
        for (UIView *h in heads) [hs appendFormat:@"%@ ", NSStringFromClass(h.class)];
        csLog(@"scan: cards=%lu headers=%lu [%@] cardClass=%@", (unsigned long)cards.count, (unsigned long)heads.count, hs,
              cards.count ? NSStringFromClass([cards.firstObject class]) : @"-");
    }
}

// Xep CA vong: tinh vi tri tung the theo thu tu that cua chung (do he thong dat) nen cuon/vuot/dong app van khop.
static void csDeckLayout(UIViewController *vc) {
    if (!C.enabled || C.mode != 0 || csTripped || -[csBoot timeIntervalSinceNow] < 12) return;
    static BOOL busy;
    if (busy || !vc.isViewLoaded) return;
    busy = YES;
    @try {
        csRefresh(vc.view);
        NSArray *cards = csCards, *heads = csHeads;
        int n = (int)MIN((NSUInteger)40, cards.count);
        if (n > 0) {
            double W = UIScreen.mainScreen.bounds.size.width;
            CSSys sy[40]; double bw[40], ssc[40], newX[40], newY[40], ratio[40], opf[40], zz[40], kk[40];
            BOOL vis[40], act[40]; int order[40], m = 0;
            for (int i = 0; i < n; i++) {
                UIView *c = cards[i];
                sy[i] = csCapture(c);
                bw[i] = MAX(1, c.bounds.size.width);
                ssc[i] = sy[i].sc * bw[i] / W;
                vis[i] = sy[i].ok && !c.hidden && sy[i].op > 0.01 && ssc[i] > 0.02;
                act[i] = NO; kk[i] = 0;
                if (vis[i]) order[m++] = i;
            }
            for (int a = 1; a < m; a++) { // sap xep theo x he thong (chen)
                int t = order[a], b = a - 1;
                while (b >= 0 && sy[order[b]].scr.x > sy[t].scr.x) { order[b + 1] = order[b]; b--; }
                order[b + 1] = t;
            }
            if (m > 0) {
                int ctr = 0; double best = 1e9;
                for (int j = 0; j < m; j++) { double d = fabs(sy[order[j]].scr.x - W / 2); if (d < best) { best = d; ctr = j; } }
                double sp = 0; int sc = 0;
                if (ctr + 1 < m) { double d = sy[order[ctr + 1]].scr.x - sy[order[ctr]].scr.x; if (d > 1) { sp += d; sc++; } }
                if (ctr > 0) { double d = sy[order[ctr]].scr.x - sy[order[ctr - 1]].scr.x; if (d > 1) { sp += d; sc++; } }
                double spacing = sc ? sp / sc : W * 0.62;
                spacing = clampd(spacing, W * 0.25, W * 1.2);
                double frac = (sy[order[ctr]].scr.x - W / 2) / spacing;
                double step = 360.0 / MAX(3, MAX(C.count, m));
                CSRingCfg cfg = csCfg(); BOOL circ = C.style <= 1; int frontIdx = -1;
                for (int j = 0; j < m; j++) {
                    int i = order[j]; UIView *c = cards[i];
                    double k = clampd((0.85 - ssc[i]) / 0.25, 0, 1);
                    if (k < 0.001) { csRestore(c, sy[i]); continue; }
                    double phi = normDeg(((j - ctr) + frac) * step);
                    CSPose p = circ ? CSRingPoseCircle(phi, step, cfg, W) : (C.style == 3 ? CSRingPoseStrip(phi, step, cfg) : CSRingPose(phi, cfg));
                    double scale = ssc[i] + (p.scale - ssc[i]) * k;
                    double f = scale * W / bw[i];
                    CGPoint scr = CGPointMake(sy[i].scr.x + (W / 2 + p.x - sy[i].scr.x) * k, sy[i].scr.y + p.y * k);
                    CGPoint pos = [c.superview convertPoint:scr fromView:nil];
                    CATransform3D t = CATransform3DIdentity;
                    t.m34 = -1.0 / p.perspective;
                    t = CATransform3DRotate(t, p.yaw * k, 0, 1, 0);
                    t = CATransform3DScale(t, f, f, 1);
                    if (!isfinite(pos.x) || !isfinite(pos.y) || !isfinite(f) || f <= 0.001 || !isfinite(p.z) || !isfinite(p.opacity)) continue;
                    CALayer *L = c.layer;
                    L.position = pos; L.transform = t;
                    L.opacity = (float)(sy[i].op * (1 + (p.opacity - 1) * k));
                    L.zPosition = p.z * k;
                    L.doubleSided = cos(p.yaw * k) >= 0;
                    csSetCircleMask(c, circ && C.snapCircle && k > 0.5);
                    csSetNeon(c, C.style == 3 && C.ringGlow && k > 0.05, p.k * k);
                    csStamp(c);
                    if (j == ctr) frontIdx = i;
                    csLastApply = CACurrentMediaTime(); csDeckApplied++;
                    act[i] = YES; kk[i] = k; newX[i] = scr.x; newY[i] = scr.y;
                    ratio[i] = scale / MAX(0.05, ssc[i]); opf[i] = 1 + (p.opacity - 1) * k; zz[i] = p.z * k;
                }
                BOOL any = NO;
                for (int i = 0; i < n; i++) if (act[i]) any = YES;
                int hn = (int)MIN((NSUInteger)60, heads.count);
                NSString *frontName = nil;
                for (int q = 0; q < hn; q++) {
                    UIView *h = heads[q];
                    if (!any) { csHideHead(h, NO); continue; }
                    csHideHead(h, YES); // tieu de he thong khong the di theo vong -> an, ve ten rieng ben duoi
                    if (frontIdx >= 0 && !frontName && h.window) {
                        CGPoint hc = [h.superview convertPoint:h.center toView:nil];
                        if (fabs(hc.x - sy[frontIdx].scr.x) < MAX(40.0, spacing * 0.6)) frontName = csTitleOf(h, 0);
                    }
                }
                if (any && frontIdx >= 0) {
                    double dia = ratio[frontIdx] * ssc[frontIdx] * W;
                    double hh = circ ? dia : dia * (UIScreen.mainScreen.bounds.size.height / W);
                    double ly = C.namePos == 0 ? newY[frontIdx] - hh / 2 - 22 : (C.namePos == 1 ? newY[frontIdx] : newY[frontIdx] + hh / 2 + 22);
                    csShowName(frontName, CGPointMake(newX[frontIdx], ly));
                } else csNameL.hidden = YES;
            }
        }
    } @catch (NSException *e) { csLog(@"deck layout exception: %@", e); }
    busy = NO;
}

static void csGuardTick(void) {
    double up = -[csBoot timeIntervalSinceNow];
    double now = CACurrentMediaTime();
    BOOL recent = csLastApply > 0 && now - csLastApply < 4;
    BOOL need = up < 20 || recent;
    if (need && !csMarkerOn) { [@"1" writeToFile:CS_MARKER atomically:NO encoding:NSUTF8StringEncoding error:nil]; csMarkerOn = YES; }
    else if (!need && csMarkerOn) { [NSFileManager.defaultManager removeItemAtPath:CS_MARKER error:nil]; csMarkerOn = NO; }
}

static void csTick(void) {
    if (++csTickCount % 12 == 1) loadCfg();
    csGuardTick();
    if (!C.enabled || C.mode != 2) {
        if (csOverlay.superview && !csOverlay.testMode) csHideOverlay();
        if (C.enabled && C.mode == 1 && -[csBoot timeIntervalSinceNow] > 15) {
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

%group DeckHook
%hook SBDeckSwitcherViewController
- (void)viewDidLayoutSubviews {
    %orig;
    csDeckLayout((UIViewController *)self);
}
%end
%end

%group DeckScroll
%hook SBDeckSwitcherViewController
- (void)scrollViewDidScroll:(UIScrollView *)sv {
    %orig;
    csDeckLayout((UIViewController *)self);
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
        int one = 3; CFNumberRef nm = CFNumberCreate(NULL, kCFNumberIntType, &one);
        CFPreferencesSetAppValue(CFSTR("mode"), nm, CS_DOMAIN); CFRelease(nm);
        CFPreferencesAppSynchronize(CS_DOMAIN);
        loadCfg();
        csLog(@"CRASH GUARD: SpringBoard died while the tweak was active -> mode set to 3 (inert), hooks disabled this boot");
        return;
    }
    [@"1" writeToFile:CS_MARKER atomically:NO encoding:NSUTF8StringEncoding error:nil];
    csMarkerOn = YES;
    Class deck = NSClassFromString(@"SBDeckSwitcherViewController");
    if (C.mode == 0 && deck) {
        %init(DeckHook);
        BOOL sc = [deck instancesRespondToSelector:@selector(scrollViewDidScroll:)];
        if (sc) { %init(DeckScroll); }
        csLog(@"real switcher hooks installed on SBDeckSwitcherViewController (scrollViewDidScroll=%d)", sc);
    } else csLog(@"real switcher hooks NOT installed (mode=%d, deck class=%d)", C.mode, deck != nil);
    dispatch_async(dispatch_get_main_queue(), ^{
        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(dc, NULL, csTestNote, CS_TEST_NOTE, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(dc, NULL, csRespringNote, CS_RESPRING_NOTE, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        NSTimer *tm = [NSTimer timerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { csTick(); }];
        [NSRunLoop.mainRunLoop addTimer:tm forMode:NSRunLoopCommonModes];
        csLog(@"timer + darwin observers installed");
    });
}
