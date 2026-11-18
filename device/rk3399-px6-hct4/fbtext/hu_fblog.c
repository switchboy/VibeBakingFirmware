/* hu_fblog - old-school scrolling boot log painted straight onto /dev/fb0.
 *
 * Why this exists: the OEM kernel has no CONFIG_FRAMEBUFFER_CONSOLE and no CONFIG_VT (measured in
 * analysis/hu_kernel_config_live-20261113.txt), so the kernel cannot put text on the panel itself.
 * CONFIG_FB=y + CONFIG_DRM_FBDEV_EMULATION=y does give us /dev/fb0, and the DRM fbdev emulation
 * scans out whatever that buffer contains - so a userspace painter can show a log before
 * SurfaceFlinger exists. That is the stage we need to see: init, module loading, mount failures,
 * SELinux denials, panics.
 *
 * It must die when SurfaceFlinger starts (init stops it via hu.rc): SF commits through DRM atomic
 * modesetting, which overwrites the fbdev scanout, and repainting would only flicker.
 *
 * Panic handling: a panic freezes userspace, so the painter cannot draw the panic text itself - the
 * screen keeps whatever was painted last. panic=12 in the kernel cmdline (the kernel's own default is
 * CONFIG_PANIC_TIMEOUT=5, overridden by the cmdline) gives ~12 s of stall, and this program flushes a
 * panic line immediately instead of waiting for the paint throttle, so the last painted screen -
 * which includes a red band naming the failure - is what stays visible during that stall.
 *
 * Usage:
 *   hu_fblog            paint /dev/kmsg + logcat onto /dev/fb0 until SIGTERM or SF takes over
 *   hu_fblog --self-test  print the glyph grid + geometry to stdout, never touches the fb
 * Safety: it only reads kmsg/logcat and writes the framebuffer. It never opens an eMMC block device,
 * never mounts anything, never reboots. Run as root (init does that); /dev/fb0 is root-owned.
 */
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <linux/fb.h>

#include "fb_font.h"

static volatile sig_atomic_t quit = 0;
static void on_signal(int sig) { (void)sig; quit = 1; }

/* Pending lines, newest at the tail. Painted as a batch, at most ~10 fps. */
#define LINE_MAX 200
#define LINE_CAP 48
static char lines[LINE_CAP][LINE_MAX];
static int nlines = 0;

static uint16_t fb_w, fb_h;          /* cell size */
static unsigned cols, rows;

struct fb {
    unsigned char *map;
    size_t len;
    unsigned stride;                 /* bytes per virtual row */
    unsigned bpp;
    unsigned r_off, r_len, g_off, g_len, b_off, b_len, a_off, a_len;
};

static uint32_t pack(struct fb *f, unsigned char r, unsigned char g, unsigned char b) {
    uint32_t v = ((unsigned)r << f->r_off) | ((unsigned)g << f->g_off) | ((unsigned)b << f->b_off);
    if (f->a_len) v |= 0xFFu << f->a_off;
    return v;
}

static void put_pixel(struct fb *f, unsigned x, unsigned y, uint32_t v) {
    if (f->bpp == 2) {
        uint16_t *p = (uint16_t *)(f->map + (size_t)y * f->stride + (size_t)x * 2);
        *p = (uint16_t)v;
    } else {
        uint32_t *p = (uint32_t *)(f->map + (size_t)y * f->stride + (size_t)x * 4);
        *p = v;
    }
}

static void paint_line(struct fb *f, const char *s, unsigned char r, unsigned char g, unsigned char b) {
    unsigned row = rows - 1;               /* always the bottom row; scroll happens first */
    unsigned x = 0;
    for (; *s && x < cols; s++) {
        unsigned char ch = (unsigned char)*s;
        if (ch < FB_FONT_FIRST || ch > FB_FONT_LAST) ch = '?';
        const unsigned short *gl = fb_font[ch - FB_FONT_FIRST];
        for (int gy = 0; gy < FB_FONT_H; gy++) {
            unsigned short bits = gl[gy];
            for (int gx = 0; gx < FB_FONT_W; gx++) {
                if (bits & (1u << gx)) put_pixel(f, x + gx, row * FB_FONT_H + gy, pack(f, r, g, b));
            }
        }
        x += fb_w;
    }
    /* Clear the rest of the row so a shorter line does not leave stale text. */
    for (; x < cols; x += fb_w) {
        for (int gy = 0; gy < FB_FONT_H; gy++) {
            for (int gx = 0; gx < FB_FONT_W; gx++) put_pixel(f, x + gx, row * FB_FONT_H + gy, 0);
        }
    }
}

static void scroll(struct fb *f) {
    size_t linelen = (size_t)cols * fb_w * f->bpp;
    for (unsigned i = 0; i + 1 < rows; i++) {
        memmove(f->map + (size_t)i * f->stride, f->map + (size_t)(i + 1) * f->stride, linelen);
    }
    memset(f->map + (size_t)(rows - 1) * f->stride, 0, linelen);
}

static int looks_bad(const char *s) {
    static const char *words[] = {"error", "Error", "ERROR", "fatal", "FATAL", "denied", "avc",
                                  "panic", "Unable", "unable", "fail", "Fail", "FAIL", "cannot", "Cannot"};
    for (unsigned i = 0; i < sizeof(words) / sizeof(words[0]); i++)
        if (strstr(s, words[i])) return 1;
    return 0;
}

/* The lines that mean "this boot freezes momentarily". A panic stops userspace, so the panel keeps
 * whatever was painted last; these get a red band with black text and are flushed immediately. */
static int is_panic(const char *s) {
    static const char *words[] = {"Kernel panic", "kernel panic", "not syncing", "Attempted to kill init",
                                  "Attempt to kill init", "init cannot continue", "Fatal error", "Oops",
                                  "BUG:", "general protection fault", "Unable to mount"};
    for (unsigned i = 0; i < sizeof(words) / sizeof(words[0]); i++)
        if (strstr(s, words[i])) return 1;
    return 0;
}

/* Black text on a full-width red row: the one thing that stays readable during panic stalls. */
static void paint_band(struct fb *f, const char *s) {
    unsigned row = rows - 1;
    uint32_t red = pack(f, 255, 0, 0);
    for (unsigned y = 0; y < FB_FONT_H; y++)
        for (unsigned x = 0; x < cols * fb_w; x++) put_pixel(f, x, row * FB_FONT_H + y, red);
    unsigned x = 0;
    for (; *s && x < cols; s++) {
        unsigned char ch = (unsigned char)*s;
        if (ch < FB_FONT_FIRST || ch > FB_FONT_LAST) ch = '?';
        const unsigned short *gl = fb_font[ch - FB_FONT_FIRST];
        for (int gy = 0; gy < FB_FONT_H; gy++) {
            unsigned short bits = gl[gy];
            for (int gx = 0; gx < FB_FONT_W; gx++) {
                if (bits & (1u << gx)) put_pixel(f, x + gx, row * FB_FONT_H + gy, 0);
            }
        }
        x += fb_w;
    }
}

static void flush(struct fb *f) {
    for (int i = 0; i < nlines; i++) {
        scroll(f);
        if (is_panic(lines[i])) { paint_band(f, lines[i]); continue; }
        int bad = looks_bad(lines[i]);
        /* kernel lines are green, framework lines white, anything alarming red */
        unsigned char r = bad ? 255 : (lines[i][0] == 'k' ? 0 : 255);
        unsigned char g = bad ? 0 : (lines[i][0] == 'k' ? 255 : 255);
        unsigned char b = bad ? 0 : (lines[i][0] == 'k' ? 0 : 255);
        paint_line(f, lines[i], r, g, b);
    }
    nlines = 0;
}

static int panic_pending = 0;

static void queue(const char *s) {
    if (nlines >= LINE_CAP) return;        /* flood: drop rather than thrash the panel */
    snprintf(lines[nlines], LINE_MAX, "%s", s);
    if (is_panic(lines[nlines])) panic_pending = 1;
    nlines++;
}

static long now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec * 1000 + t.tv_nsec / 1000000;
}

static void banner(void) {
    FILE *fp = fopen("/proc/cmdline", "r");
    char cmd[512] = "cmdline: (unreadable)";
    if (fp) {
        if (fgets(cmd, sizeof(cmd), fp)) cmd[strlen(cmd) - 1] = '\0';
        fclose(fp);
    }
    queue(cmd);
    queue("hu_fblog: kernel+framework log, no fbcon in this kernel, exits when SurfaceFlinger starts");
}

static int open_fb(struct fb *f) {
    int fd = open("/dev/fb0", O_RDWR);
    if (fd < 0) { fprintf(stderr, "hu_fblog: no /dev/fb0: %s\n", strerror(errno)); return 1; }
    struct fb_var_screeninfo var;
    struct fb_fix_screeninfo fix;
    if (ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0) {
        fprintf(stderr, "hu_fblog: FBIOGET_VSCREENINFO failed: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    if (ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0) {
        fprintf(stderr, "hu_fblog: FBIOGET_FSCREENINFO failed: %s\n", strerror(errno));
        close(fd);
        return 1;
    }
    if (var.xres == 0 || var.yres == 0 || var.xres_virtual == 0) {
        fprintf(stderr, "hu_fblog: unusable mode %ux%u\n", var.xres, var.yres);
        close(fd);
        return 1;
    }
    if (var.bits_per_pixel != 16 && var.bits_per_pixel != 32) {
        fprintf(stderr, "hu_fblog: unsupported bpp %u\n", var.bits_per_pixel);
        close(fd);
        return 1;
    }
    f->bpp = var.bits_per_pixel / 8;
    /* line_length and smem_len live in the FIXED info; the var info carries no buffer geometry. */
    f->stride = fix.line_length ? (size_t)fix.line_length : (size_t)var.xres_virtual * f->bpp;
    f->len = fix.smem_len ? (size_t)fix.smem_len : f->stride * var.yres_virtual;
    f->r_off = var.red.offset; f->r_len = var.red.length;
    f->g_off = var.green.offset; f->g_len = var.green.length;
    f->b_off = var.blue.offset; f->b_len = var.blue.length;
    f->a_off = var.transp.offset; f->a_len = var.transp.length;
    if (f->r_len == 0 || f->g_len == 0 || f->b_len == 0) {
        fprintf(stderr, "hu_fblog: colour channels report zero length\n");
        close(fd);
        return 1;
    }
    f->map = mmap(NULL, f->len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (f->map == MAP_FAILED) {
        fprintf(stderr, "hu_fblog: mmap %zu B failed: %s\n", f->len, strerror(errno));
        close(fd);
        return 1;
    }
    close(fd);
    cols = var.xres / fb_w;
    rows = var.yres / fb_h;
    /* Never paint past the mapped buffer: scroll() moves whole rows, so rows must fit in len, and
     * a row must fit in line_length. */
    while (cols && (size_t)cols * fb_w * f->bpp > f->stride) cols--;
    while (rows && (size_t)rows * FB_FONT_H * f->stride > f->len) rows--;
    if (cols == 0 || rows == 0) { fprintf(stderr, "hu_fblog: panel too small for the font\n"); return 1; }
    memset(f->map, 0, (size_t)rows * fb_h * f->stride);   /* black background, visible area only */
    fprintf(stderr, "hu_fblog: fb %ux%u %ubpp, %ux%u cells of %ux%u\n",
            var.xres, var.yres, var.bits_per_pixel, cols, rows, fb_w, fb_h);
    return 0;
}

static int spawn_logcat(int *pipe_fd) {
    int p[2];
    if (pipe(p) < 0) return 1;
    pid_t pid = fork();
    if (pid < 0) { close(p[0]); close(p[1]); return 1; }
    if (pid == 0) {
        dup2(p[1], STDOUT_FILENO);
        close(p[0]); close(p[1]);
        execl("/system/bin/logcat", "logcat", "-b", "all", "-T", "0", "-v", "threadtime", (char *)NULL);
        _exit(127);
    }
    close(p[1]);
    int fl = fcntl(p[0], F_GETFL, 0);
    fcntl(p[0], F_SETFL, fl | O_NONBLOCK);
    *pipe_fd = p[0];
    return 0;
}

/* /dev/kmsg: one record per read(), prefixed "<level>.". Turn it into "k <text>". */
static void read_kmsg(int fd) {
    char buf[LINE_MAX];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n <= 0) return;
    buf[n] = '\0';
    char *t = buf;
    if (t[0] == '<' && t[1] >= '0' && t[1] <= '7' && t[2] == '>') t += 3;
    char nl = '\n';
    /* keep one line per record; kmsg records may hold several lines - take the first */
    for (char *p = t; *p; p++) if (*p == '\n') { nl = *p; *p = '\0'; break; }
    (void)nl;
    char out[LINE_MAX];
    snprintf(out, sizeof(out), "k %s", t);
    queue(out);
}

/* logcat lines already carry a timestamp; tag them 'l' so they paint white. */
static void read_logcat(int fd) {
    char buf[LINE_MAX];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    if (n <= 0) { quit = 1; return; }
    buf[n] = '\0';
    for (char *p = strtok(buf, "\n"); p; p = strtok(NULL, "\n")) {
        char out[LINE_MAX];
        snprintf(out, sizeof(out), "l %s", p);
        queue(out);
    }
}

static int self_test(void) {
    printf("hu_fblog self-test: font %ux%u, ASCII %d..%d, panel 1024x600 -> %u cols x %u rows\n",
           fb_w, fb_h, FB_FONT_FIRST, FB_FONT_LAST, 1024 / fb_w, 600 / fb_h);
    const char *sample = "init: mounted /system as ext4";
    for (int gy = 0; gy < FB_FONT_H; gy++) {
        for (const char *s = sample; *s; s++) {
            unsigned char ch = (unsigned char)*s;
            if (ch < FB_FONT_FIRST || ch > FB_FONT_LAST) ch = '?';
            unsigned short bits = fb_font[ch - FB_FONT_FIRST][gy];
            for (int gx = 0; gx < fb_w; gx++) putchar(bits & (1u << gx) ? '#' : ' ');
            putchar(' ');
        }
        putchar('\n');
    }
    return 0;
}

int main(int argc, char **argv) {
    fb_w = FB_FONT_W;
    fb_h = FB_FONT_H;
    if (argc > 1 && strcmp(argv[1], "--self-test") == 0) return self_test();

    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    signal(SIGPIPE, SIG_IGN);

    /* Refuse to touch a framebuffer anywhere but an Android device: a workstation's /dev/fb0 is the
     * text console's buffer, and painting it would wipe the operator's terminal. */
    if (access("/system/bin/logcat", X_OK) != 0) {
        fprintf(stderr, "hu_fblog: no /system/bin/logcat - this is not an Android system image, refusing to paint\n");
        return 1;
    }

    struct fb f;
    memset(&f, 0, sizeof(f));
    if (open_fb(&f) != 0) return 1;

    int kmsg = open("/dev/kmsg", O_RDONLY | O_NONBLOCK);
    if (kmsg < 0) { fprintf(stderr, "hu_fblog: no /dev/kmsg: %s\n", strerror(errno)); return 1; }
    int lcat = -1;
    if (spawn_logcat(&lcat) != 0) fprintf(stderr, "hu_fblog: logcat child failed, painting kernel only\n");

    banner();
    long last_paint = 0;
    while (!quit) {
        fd_set rf;
        FD_ZERO(&rf);
        FD_SET(kmsg, &rf);
        if (lcat >= 0) FD_SET(lcat, &rf);
        struct timeval tv = {0, 200000};
        int max = kmsg > lcat ? kmsg : lcat;
        int r = select(max + 1, &rf, NULL, NULL, &tv);
        if (r > 0) {
            if (FD_ISSET(kmsg, &rf)) read_kmsg(kmsg);
            if (lcat >= 0 && FD_ISSET(lcat, &rf)) read_logcat(lcat);
        }
        long t = now_ms();
        /* A panic line must reach the panel before the freeze, so it skips the paint throttle. */
        if (nlines && (panic_pending || t - last_paint >= 100)) { flush(&f); last_paint = t; panic_pending = 0; }
    }

    queue("hu_fblog: exiting, SurfaceFlinger takes the panel");
    flush(&f);
    if (lcat >= 0) close(lcat);
    close(kmsg);
    return 0;
}
