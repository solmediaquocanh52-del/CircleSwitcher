#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>
#import "../CSRing.h"

#define CS_DOMAIN CFSTR("com.vn.circleswitcher")

static double csPref(NSString *key, double def, NSDictionary *over) {
    id o = over[key];
    if ([o isKindOfClass:NSNumber.class]) return [o doubleValue];
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CS_DOMAIN);
    double r = def;
    if (v) {
        if (CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberDoubleType, &r);
        CFRelease(v);
    }
    return r;
}

#pragma mark - Khung xem truoc (dung cung ham CSRingPose voi switcher that)

@interface CSPreviewView : UIView
@property (nonatomic, strong) NSArray<UIView *> *cards;
@property (nonatomic, strong) NSArray<UILabel *> *names;
@property (nonatomic, strong) UIView *screen;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) double phase;     // phan le cua vong (giong frac trong switcher that)
@property (nonatomic) double t0;
@property (nonatomic) BOOL touching;
@property (nonatomic) CSRingCfg cfg;
@property (nonatomic) int namePos;
@property (nonatomic) BOOL glowOn;
@property (nonatomic, strong) CAShapeLayer *glowRing;
- (void)reloadWith:(NSDictionary *)over;
@end

@implementation CSPreviewView

static const double kScreenW = 390.0, kScreenH = 844.0, kU = 0.30; // ti le thu nho man hinh that

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.backgroundColor = UIColor.clearColor;
        UIView *s = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kScreenW * kU, kScreenH * kU)];
        s.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
        s.layer.cornerRadius = 22 * kU * 1.6;
        s.layer.borderWidth = 2; s.layer.borderColor = [UIColor colorWithWhite:0.5 alpha:1].CGColor;
        s.clipsToBounds = YES;
        [self addSubview:s]; self.screen = s;
        NSMutableArray *cs = [NSMutableArray array], *ns = [NSMutableArray array];
        NSArray *nm = @[@"Safari", @"Tin nhắn", @"Ảnh", @"Bản đồ", @"Ghi chú", @"Cài đặt", @"Máy ảnh", @"Nhạc", @"Thời tiết", @"Lịch", @"Mail", @"Lời nhắc"];
        for (int i = 0; i < 12; i++) {
            UIView *c = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100 * kU, 100 * kU)];
            c.backgroundColor = [UIColor colorWithHue:fmod(i * 0.083 + 0.55, 1.0) saturation:0.45 brightness:0.9 alpha:1];
            c.layer.cornerRadius = 40 * kU; c.clipsToBounds = NO;
            c.layer.masksToBounds = NO;
            UIView *ic = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 80 * kU, 80 * kU)];
            ic.center = CGPointMake(c.bounds.size.width / 2, c.bounds.size.height / 2);
            ic.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            ic.backgroundColor = [UIColor colorWithWhite:1 alpha:0.85]; ic.layer.cornerRadius = 18 * kU;
            [c addSubview:ic];
            UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(20 * kU, 60 * kU, c.bounds.size.width - 40 * kU, 14 * kU)];
            bar.backgroundColor = [UIColor colorWithWhite:1 alpha:0.5]; bar.layer.cornerRadius = 7 * kU; bar.tag = 77;
            [c addSubview:bar];
            c.layer.shadowOpacity = 0.35; c.layer.shadowRadius = 4; c.layer.shadowOffset = CGSizeMake(0, 2);
            [s addSubview:c]; [cs addObject:c];
            UILabel *l = [[UILabel alloc] init];
            l.text = nm[i]; l.textColor = UIColor.whiteColor; l.font = [UIFont systemFontOfSize:9 weight:UIFontWeightSemibold];
            l.textAlignment = NSTextAlignmentCenter; l.frame = CGRectMake(0, 0, 70, 12);
            [s addSubview:l]; [ns addObject:l];
        }
        self.cards = cs; self.names = ns;
        CAShapeLayer *gr = [CAShapeLayer layer]; gr.fillColor = nil; gr.lineWidth = 1.5; gr.hidden = YES;
        [s.layer insertSublayer:gr atIndex:0]; self.glowRing = gr;
        self.t0 = CACurrentMediaTime();
        UIPanGestureRecognizer *pg = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
        [self addGestureRecognizer:pg];
        self.cfg = CSRingDefaults(); self.namePos = 0;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.screen.center = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2);
    [self relayout];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && !self.link) {
        self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else if (!self.window) { [self.link invalidate]; self.link = nil; }
}

- (void)pan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) self.touching = YES;
    CGPoint tr = [g translationInView:self]; [g setTranslation:CGPointZero inView:self];
    self.phase -= tr.x / (kScreenW * kU * 0.62);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        self.touching = NO; self.t0 = CACurrentMediaTime() - 0; // quay tiep tu vi tri hien tai
    }
    [self relayout];
}

- (void)tick:(CADisplayLink *)l {
    if (self.touching) return;
    self.phase += 0.006; // tu xoay cham de thay duoc vong 3D
    [self relayout];
}

- (void)reloadWith:(NSDictionary *)over {
    CSRingCfg d = CSRingDefaults(), c;
    c.radius = csPref(@"radius", d.radius, over);
    c.tilt = csPref(@"tilt", d.tilt, over);
    c.cam = csPref(@"cam", d.cam, over);
    c.size = csPref(@"size", d.size, over);
    c.off = csPref(@"off", d.off, over);
    c.count = (int)lround(csPref(@"count", d.count, over));
    c.style = (int)csPref(@"style", d.style, over);
    if (c.style < 0 || c.style > 2) c.style = 1;
    c.iconSize = csPref(@"iconSize", d.iconSize, over);
    c.centerSize = csPref(@"centerSize", d.centerSize, over);
    self.glowOn = csPref(@"ringGlow", 1, over) != 0;
    if (c.count < 3) c.count = 3; if (c.count > 12) c.count = 12;
    self.cfg = c;
    self.namePos = (int)csPref(@"namePos", 0, over);
    [self relayout];
}

// Giong het phan xep vong trong Tweak.x: phi = ((j - ctr) + frac) * step, pose = CSRingPose
- (void)relayout {
    int N = 7, ctr = 3;
    BOOL circ = self.cfg.style != 2;
    double step = 360.0 / MAX(3, MAX(self.cfg.count, N));
    double frac = fmod(self.phase, 1.0); if (frac < 0) frac += 1.0; if (frac > 0.5) frac -= 1.0;
    int shift = (int)floor(self.phase + 0.5);
    double W = kScreenW, cx = W * kU / 2, cy = kScreenH * kU / 2;
    for (int j = 0; j < 12; j++) {
        UIView *c = self.cards[j]; UILabel *lb = self.names[j];
        if (j >= N) { c.hidden = YES; lb.hidden = YES; continue; }
        int rank = ((j + shift) % N + N) % N; // vong tron: the nao di het mot vong thi quay lai
        double rel = rank - ctr;
        double phi = fmod(((rel) + frac) * step + 540.0, 360.0) - 180.0;
        CSRingCfg cfg = self.cfg; if (cfg.count < N) cfg.count = N;
        CSPose p = circ ? CSRingPoseCircle(phi, step, cfg, kScreenW) : CSRingPose(phi, cfg);
        c.hidden = NO;
        double bw = circ ? 100 * kU : kScreenW * kU, bh = circ ? 100 * kU : kScreenH * kU;
        c.bounds = CGRectMake(0, 0, bw, bh);
        c.layer.cornerRadius = circ ? bw / 2 : 40 * kU;
        c.layer.masksToBounds = circ;
        [c viewWithTag:77].hidden = circ;
        double sc = circ ? p.dia / 100.0 : p.scale;
        c.layer.position = CGPointMake(cx + p.x * kU, cy + p.y * kU);
        CATransform3D t = CATransform3DIdentity;
        t.m34 = -1.0 / (p.perspective * kU);
        t = CATransform3DRotate(t, p.yaw, 0, 1, 0);
        t = CATransform3DScale(t, sc, sc, 1);
        c.layer.transform = t;
        c.layer.zPosition = p.z * kU;
        c.layer.opacity = (float)p.opacity;
        c.layer.doubleSided = cos(p.yaw) >= 0;
        BOOL showName = self.namePos != 3 && (!circ || fabs(phi) <= step / 2);
        lb.hidden = !showName;
        if (j == 0) {
            self.glowRing.hidden = !(circ && self.glowOn);
            if (!self.glowRing.hidden) {
                double gx, gy, rx, ry; CSRingGlowRect(self.cfg, &gx, &gy, &rx, &ry);
                self.glowRing.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(cx + (gx - rx) * kU, cy + (gy - ry) * kU, rx * 2 * kU, ry * 2 * kU)].CGPath;
                self.glowRing.strokeColor = [UIColor colorWithRed:0.45 green:0.55 blue:1 alpha:0.8].CGColor;
            }
        }
        if (showName) {
            double ch = circ ? 100 * kU * sc : kScreenH * kU * p.scale;
            double ly = cy + p.y * kU - ch / 2 - 9;
            if (self.namePos == 1) ly = cy + p.y * kU;
            if (self.namePos == 2) ly = cy + p.y * kU + ch / 2 + 9;
            lb.center = CGPointMake(cx + p.x * kU, ly);
            lb.alpha = p.opacity;
            lb.layer.zPosition = p.z * kU + 1;
        }
    }
}

@end

#pragma mark - Man hinh cai dat

@interface CSRootListController : PSListController
@property (nonatomic, strong) CSPreviewView *preview;
@end

@implementation CSRootListController

static const CGFloat kPreviewH = 270;

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UITableView *tv = self.table;
    if (!tv) return;
    if (!self.preview) {
        self.preview = [[CSPreviewView alloc] initWithFrame:CGRectMake(0, 0, tv.bounds.size.width, kPreviewH)];
        self.preview.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        UIColor *bg = tv.backgroundColor ?: UIColor.systemGroupedBackgroundColor;
        self.preview.backgroundColor = bg;
        self.preview.layer.zPosition = 1000;
        [tv addSubview:self.preview];
        UIEdgeInsets i = tv.contentInset; i.top += kPreviewH; tv.contentInset = i;
        UIEdgeInsets si = tv.scrollIndicatorInsets; si.top += kPreviewH; tv.scrollIndicatorInsets = si;
        CGPoint off = tv.contentOffset; off.y -= kPreviewH; tv.contentOffset = off;
    }
    [self.preview reloadWith:nil];
    [self stickPreview];
}

- (void)stickPreview {
    UITableView *tv = self.table;
    if (!tv || !self.preview) return;
    CGFloat top = tv.adjustedContentInset.top - kPreviewH; // vung an toan (thanh dieu huong)
    self.preview.frame = CGRectMake(0, tv.contentOffset.y + top, tv.bounds.size.width, kPreviewH);
    [tv bringSubviewToFront:self.preview];
}

- (void)scrollViewDidScroll:(UIScrollView *)sv {
    if ([PSListController instancesRespondToSelector:@selector(scrollViewDidScroll:)]) {
        IMP imp = class_getMethodImplementation([PSListController class], @selector(scrollViewDidScroll:));
        ((void (*)(id, SEL, id))imp)(self, _cmd, sv);
    }
    [self stickPreview];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    [super setPreferenceValue:value specifier:spec];
    NSString *k = [spec propertyForKey:@"key"];
    [self.preview reloadWith:(k && value) ? @{k: value} : nil];
}

- (void)resetDefaults {
    CSRingCfg d = CSRingDefaults();
    NSDictionary *vals = @{@"radius": @(d.radius), @"tilt": @(d.tilt), @"cam": @(d.cam), @"size": @(d.size),
                           @"off": @(d.off), @"count": @(d.count), @"namePos": @0, @"blur": @2,
                           @"style": @(d.style), @"iconSize": @(d.iconSize), @"centerSize": @(d.centerSize)};
    for (NSString *k in vals)
        CFPreferencesSetAppValue((__bridge CFStringRef)k, (__bridge CFPropertyListRef)vals[k], CS_DOMAIN);
    CFPreferencesAppSynchronize(CS_DOMAIN);
    [self reloadSpecifiers];
    [self.preview reloadWith:vals];
}

- (void)respring {
    CFPreferencesAppSynchronize(CS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.vn.circleswitcher/respring"), NULL, NULL, YES);
}

@end
