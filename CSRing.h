// CSRing.h - cong thuc vong 3D DUNG CHUNG cho switcher that (Tweak.x) va khung xem truoc (prefs).
// Hai ben dung cung mot ham nay nen hinh trong cai dat khop voi ngoai man hinh.
#ifndef CSRING_H
#define CSRING_H
#include <math.h>

typedef struct {
    double radius, tilt, cam, size, off;
    int count;
} CSRingCfg;

typedef struct {
    double x, y;      // lech so voi tam man hinh (px, theo man hinh that)
    double z;         // zPosition
    double scale;     // ti le the so voi chieu rong man hinh (0.46 = 46%)
    double yaw;       // radian, quay quanh truc Y
    double opacity;   // 0..1
    double perspective; // P cho m34
} CSPose;

static inline double CSClamp(double v, double a, double b) { return v < a ? a : (v > b ? b : v); }

static inline CSRingCfg CSRingDefaults(void) {
    CSRingCfg c;
    c.radius = 120; c.tilt = 35; c.cam = 8; c.size = 100; c.off = 0; c.count = 8;
    return c;
}

// phi = goc cua the tren vong (do), 0 = o chinh giua phia truoc
static inline CSPose CSRingPose(double phi, CSRingCfg c) {
    const double P = 900.0;
    double r = phi * M_PI / 180.0, e = c.cam * M_PI / 180.0, R = c.radius * 2.2;
    double depth = R * cos(r) - R;
    double z = depth * cos(e), y = depth * sin(e);
    double s = 1.0 / (1.0 - z / P);
    CSPose p;
    p.x = R * sin(r) * s;
    p.y = c.off + y * s;
    p.z = z;
    p.scale = 0.46 * c.size / 100.0 * s;
    p.yaw = -c.tilt * CSClamp(phi / 45.0, -1, 1) * M_PI / 180.0;
    p.opacity = 0.4 + 0.6 * (cos(r) + 1.0) / 2.0;
    p.perspective = P;
    return p;
}

#endif
