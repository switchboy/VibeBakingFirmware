/*
 * libhugnss.so - LD_PRELOAD shim for the head unit's GNSS HAL process (android.hardware.gnss@1.0-service).
 *
 * Problem: the stock legacy module /vendor/lib64/hw/gps.default.so (derived from AOSP's emulator NMEA driver) reports
 * positions without GPS_LOCATION_HAS_ACCURACY. Android 10 accepted that; Android 14's LocationResult.validate()
 * rejects a location without accuracy with IllegalArgumentException("incomplete location"), thrown inside
 * system_server (GnssLocationProvider.handleReportLocation), so every fix restarts the framework.
 *
 * Fix: interpose hw_get_module(). For the "gps" module, wrap open() -> gps_device_t.get_gps_interface() ->
 * GpsInterface.init(callbacks) and replace two callbacks:
 *   nmea_cb      - parse HDOP from $xxGGA (field 8) and $xxGSA (field 16), then pass the sentence on unchanged;
 *   location_cb  - if the module left out the accuracy, set it to HDOP * 5 m (a common user-equivalent range
 *                  error), at least 5 m, or 50 m if no HDOP has been seen; if the timestamp is 0, use the
 *                  system clock. Everything else is passed on unchanged.
 * The module itself is not modified.
 *
 * Only the legacy (frozen) GPS HAL ABI from hardware/libhardware's former gps.h is used: the fields touched are at
 * fixed offsets at the start of each struct. hardware.h still ships with Android 14.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <hardware/hardware.h>
#include <android/log.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TAG "hugnss"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)

/* ---- legacy gps.h subset ---- */
typedef int64_t GpsUtcTime;
typedef struct {
    size_t size;
    uint16_t flags;
    double latitude, longitude, altitude;
    float speed, bearing, accuracy;
    GpsUtcTime timestamp;
} GpsLocation;
#define GPS_LOCATION_HAS_ACCURACY 0x0010

typedef void (*gps_location_callback)(GpsLocation *);
typedef void (*gps_nmea_callback)(GpsUtcTime, const char *, int);
typedef struct {
    size_t size;
    gps_location_callback location_cb;
    void *status_cb;
    void *sv_status_cb;
    gps_nmea_callback nmea_cb;
    /* set_capabilities_cb, acquire/release_wakelock_cb, create_thread_cb, request_utc_time_cb, ... follow */
} GpsCallbacksHead;

typedef struct {
    size_t size;
    int (*init)(void *callbacks);
    /* start, stop, cleanup, inject_time, inject_location, delete_aiding_data, set_position_mode, get_extension */
} GpsInterfaceHead;

struct gps_device_t {
    struct hw_device_t common;
    const void *(*get_gps_interface)(struct gps_device_t *dev);
};

/* ---- state ---- */
static gps_location_callback real_location_cb;
static gps_nmea_callback real_nmea_cb;
static volatile float last_hdop = -1.0f;
static unsigned char cb_copy[512];
static unsigned char iface_copy[512];
static int (*real_init)(void *);
static const void *(*real_get_iface)(struct gps_device_t *);
static int (*real_open)(const struct hw_module_t *, const char *, struct hw_device_t **);
static struct hw_module_t module_copy;
static struct hw_module_methods_t methods_copy;
static const struct hw_module_t *real_module;

/* field n (0 = sentence id) of a comma-separated NMEA sentence, as a float; -1 if empty or missing */
static float nmea_field(const char *s, int len, int n) {
    int f = 0, i = 0;
    for (; i < len && f < n; i++)
        if (s[i] == ',') f++;
        else if (s[i] == '*') return -1.0f;
    if (f != n || i >= len || s[i] == ',' || s[i] == '*') return -1.0f;
    char buf[16]; int k = 0;
    while (i < len && k < 15 && s[i] != ',' && s[i] != '*') buf[k++] = s[i++];
    buf[k] = 0;
    return strtof(buf, NULL);
}

static void hu_nmea_cb(GpsUtcTime ts, const char *nmea, int len) {
    if (nmea && len > 6 && nmea[0] == '$') {
        float h = -1.0f;
        if (!memcmp(nmea + 3, "GGA", 3)) h = nmea_field(nmea, len, 8);
        else if (!memcmp(nmea + 3, "GSA", 3)) h = nmea_field(nmea, len, 16);
        if (h > 0.0f && h < 99.0f) last_hdop = h;   /* 99.99 = no solution */
    }
    if (real_nmea_cb) real_nmea_cb(ts, nmea, len);
}

static void hu_location_cb(GpsLocation *loc) {
    static int logged;
    if (loc && !(loc->flags & GPS_LOCATION_HAS_ACCURACY)) {
        float h = last_hdop;
        float acc = h > 0.0f ? h * 5.0f : 50.0f;
        loc->accuracy = acc < 5.0f ? 5.0f : acc;
        loc->flags |= GPS_LOCATION_HAS_ACCURACY;
        if (!logged++) LOGI("module reported no accuracy: set %.1f m (hdop %.2f); logged once", loc->accuracy, h);
    }
    if (loc && loc->timestamp == 0) {
        struct timespec t; clock_gettime(CLOCK_REALTIME, &t);
        loc->timestamp = (GpsUtcTime)t.tv_sec * 1000 + t.tv_nsec / 1000000;
    }
    if (real_location_cb) real_location_cb(loc);
}

static int hu_init(void *callbacks) {
    GpsCallbacksHead *in = callbacks;
    size_t n = in->size < sizeof(cb_copy) ? in->size : sizeof(cb_copy);
    if (n < sizeof(GpsCallbacksHead)) return real_init(callbacks);
    memcpy(cb_copy, in, n);
    GpsCallbacksHead *c = (GpsCallbacksHead *)cb_copy;
    real_location_cb = in->location_cb; c->location_cb = hu_location_cb;
    real_nmea_cb = in->nmea_cb; c->nmea_cb = hu_nmea_cb;
    LOGI("wrapped GpsCallbacks (size %zu): location_cb, nmea_cb", in->size);
    return real_init(cb_copy);
}

static const void *hu_get_iface(struct gps_device_t *dev) {
    const GpsInterfaceHead *in = real_get_iface(dev);
    if (!in || in->size < sizeof(GpsInterfaceHead) || in->size > sizeof(iface_copy)) return in;
    memcpy(iface_copy, in, in->size);
    GpsInterfaceHead *c = (GpsInterfaceHead *)iface_copy;
    real_init = in->init; c->init = hu_init;
    return c;
}

static int hu_open(const struct hw_module_t *m, const char *id, struct hw_device_t **dev) {
    (void)m;
    int r = real_open(real_module, id, dev);
    if (r == 0 && dev && *dev) {
        struct gps_device_t *g = (struct gps_device_t *)*dev;
        real_get_iface = g->get_gps_interface;
        g->get_gps_interface = hu_get_iface;   /* the device is heap/data memory of the module: writable */
    }
    return r;
}

int hw_get_module(const char *id, const struct hw_module_t **module) {
    static int (*real)(const char *, const struct hw_module_t **);
    if (!real) real = (int (*)(const char *, const struct hw_module_t **))dlsym(RTLD_NEXT, "hw_get_module");
    if (!real) return -1;
    int r = real(id, module);
    if (r == 0 && id && !strcmp(id, "gps") && module && *module && (*module)->methods) {
        real_module = *module;
        module_copy = **module;
        methods_copy = *(*module)->methods;
        real_open = methods_copy.open;
        methods_copy.open = hu_open;
        module_copy.methods = &methods_copy;
        *module = &module_copy;
        LOGI("wrapping gps module '%s'", real_module->name ? real_module->name : "?");
    }
    return r;
}

__attribute__((constructor)) static void hu_ctor(void) {
    unsetenv("LD_PRELOAD");   /* do not leak into anything this process starts */
}
