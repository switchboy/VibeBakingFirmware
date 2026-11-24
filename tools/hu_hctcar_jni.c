/* libhctcar.so: the two JNI natives of HCT's com.android.server.microntek.CarService for Android 14.
 *
 * Android 10 had them in libandroid_servers.so (disassembled 2026-11-24, docs/findings.md):
 *   native_setParameters(String)I  : fd = open("/dev/mtc-car", O_RDWR); r = ioctl(fd, strlen(s), s); close
 *   native_getParameters(String)S  : copy s into a buffer, ioctl(fd, strlen(s) | 0x10000, buf), the MCU
 *                                    driver writes its answer into buf, return NewStringUTF(buf)
 * Android 14's libandroid_servers.so has neither, so this library registers them itself from JNI_OnLoad
 * (System.load from the code that hosts CarService; FindClass then uses that caller's class loader).
 *
 * Freestanding on purpose: no libc, raw aarch64 syscalls, only the JNI function tables, so a zig/musl
 * toolchain produces a .so the bionic linker loads without any DT_NEEDED.
 * Build: zig cc -target aarch64-linux-musl -shared -nostdlib -fPIC -O2 -fno-stack-protector \
 *        -Wl,--hash-style=both -Wl,-soname,libhctcar.so -o libhctcar.so tools/hu_hctcar_jni.c
 */
typedef unsigned long size_t;
typedef void *jobject;
typedef jobject jclass, jstring;
typedef int jint;
typedef unsigned char jboolean;
typedef const struct JNINativeInterface *JNIEnv;
typedef const struct JNIInvokeInterface *JavaVM;
typedef struct { const char *name; const char *signature; void *fnPtr; } JNINativeMethod;

/* Only the slots used here are named; the indices are the JNI spec's. */
struct JNINativeInterface { void *slot[229]; };
struct JNIInvokeInterface { void *slot[8]; };
#define JNI_FindClass             6
#define JNI_ExceptionClear        17
#define JNI_NewStringUTF          167
#define JNI_GetStringUTFChars     169
#define JNI_ReleaseStringUTFChars 170
#define JNI_RegisterNatives       215
#define VM_GetEnv                 6
#define JNI_VERSION_1_6           0x00010006

#define HU_MTC_DEV "/dev/mtc-car"
#define HU_BUF 3072          /* Android 10 used a 0xc00-byte response buffer */

static long sys3(long n, long a, long b, long c) {
  register long x8 __asm__("x8") = n;
  register long x0 __asm__("x0") = a;
  register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c;
  __asm__ volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
  return x0;
}
#define SYS_ioctl 29
#define SYS_openat 56
#define SYS_close 57
#define AT_FDCWD (-100)
#define O_RDWR_CLOEXEC (02 | 02000000)

static size_t hu_strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }

/* The compiler may lower the buffer loops to memset/memcpy calls; with -nostdlib they must exist here. */
__attribute__((visibility("hidden"))) void *memset(void *d, int c, size_t n) {
  unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d;
}
__attribute__((visibility("hidden"))) void *memcpy(void *d, const void *s, size_t n) {
  unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d;
}

static const char *utf(JNIEnv *env, jstring s) {
  typedef const char *(*F)(JNIEnv *, jstring, jboolean *);
  return ((F)(*env)->slot[JNI_GetStringUTFChars])(env, s, 0);
}
static void unutf(JNIEnv *env, jstring s, const char *c) {
  typedef void (*F)(JNIEnv *, jstring, const char *);
  ((F)(*env)->slot[JNI_ReleaseStringUTFChars])(env, s, c);
}

static jint native_setParameters(JNIEnv *env, jobject thiz, jstring s) {
  (void)thiz;
  if (!s) return -1;
  long fd = sys3(SYS_openat, AT_FDCWD, (long)HU_MTC_DEV, O_RDWR_CLOEXEC);
  if (fd < 0) return -1;
  const char *c = utf(env, s);
  long r = -1;
  if (c) { r = sys3(SYS_ioctl, fd, (long)hu_strlen(c), (long)c); unutf(env, s, c); }
  sys3(SYS_close, fd, 0, 0);
  return (jint)r;
}

static jstring native_getParameters(JNIEnv *env, jobject thiz, jstring s) {
  (void)thiz;
  typedef jstring (*NewStr)(JNIEnv *, const char *);
  char buf[HU_BUF];
  for (int i = 0; i < HU_BUF; i++) buf[i] = 0;
  if (!s) return ((NewStr)(*env)->slot[JNI_NewStringUTF])(env, "");
  long fd = sys3(SYS_openat, AT_FDCWD, (long)HU_MTC_DEV, O_RDWR_CLOEXEC);
  if (fd < 0) return ((NewStr)(*env)->slot[JNI_NewStringUTF])(env, "");
  const char *c = utf(env, s);
  if (c) {
    size_t n = hu_strlen(c);
    if (n >= HU_BUF) n = HU_BUF - 1;
    for (size_t i = 0; i < n; i++) buf[i] = c[i];
    unutf(env, s, c);
    sys3(SYS_ioctl, fd, (long)(n | 0x10000), (long)buf);
  }
  sys3(SYS_close, fd, 0, 0);
  buf[HU_BUF - 1] = 0;
  return ((NewStr)(*env)->slot[JNI_NewStringUTF])(env, buf);
}

static const JNINativeMethod methods[] = {
  { "native_setParameters", "(Ljava/lang/String;)I", (void *)native_setParameters },
  { "native_getParameters", "(Ljava/lang/String;)Ljava/lang/String;", (void *)native_getParameters },
};

__attribute__((visibility("default"))) jint JNI_OnLoad(JavaVM *vm, void *reserved) {
  (void)reserved;
  JNIEnv *env = 0;
  typedef jint (*GetEnv)(JavaVM *, void **, jint);
  if (((GetEnv)(*vm)->slot[VM_GetEnv])(vm, (void **)&env, JNI_VERSION_1_6) != 0 || !env) return -1;
  typedef jclass (*Find)(JNIEnv *, const char *);
  jclass cls = ((Find)(*env)->slot[JNI_FindClass])(env, "com/android/server/microntek/CarService");
  if (!cls) { ((void (*)(JNIEnv *))(*env)->slot[JNI_ExceptionClear])(env); return -1; }
  typedef jint (*Reg)(JNIEnv *, jclass, const JNINativeMethod *, jint);
  if (((Reg)(*env)->slot[JNI_RegisterNatives])(env, cls, methods, 2) != 0) return -1;
  return JNI_VERSION_1_6;
}
