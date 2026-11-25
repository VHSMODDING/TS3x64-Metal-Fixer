// Traceur des chargements de textures (peinture terrain). Lecture seule : ne modifie aucun appel.
// Signale les paramètres que Metal sur puce Apple ignore silencieusement (alignements, débordements).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdatomic.h>

int gUpTrace = 0, gMtlVal = 0;
static FILE *sUp; static pthread_mutex_t sUpLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic unsigned long sUpCount, sUpBad;
static void UL(const char *fmt, ...) {
    pthread_mutex_lock(&sUpLock);
    if (!sUp) sUp = fopen("/tmp/ts3_upload.log", "w");
    if (sUp) { va_list a; va_start(a, fmt); vfprintf(sUp, fmt, a); va_end(a); fputc('\n', sUp); fflush(sUp); }
    pthread_mutex_unlock(&sUpLock);
}
static double now(void) { return [NSDate timeIntervalSinceReferenceDate]; }
static double sT0;

static NSUInteger bpp(MTLPixelFormat f) {
    switch (f) {
    case MTLPixelFormatA8Unorm: case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Uint: case MTLPixelFormatR8Snorm: return 1;
    case MTLPixelFormatRG8Unorm: case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Float: case MTLPixelFormatB5G6R5Unorm:
    case MTLPixelFormatA1BGR5Unorm: case MTLPixelFormatABGR4Unorm: case MTLPixelFormatBGR5A1Unorm: return 2;
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm_sRGB:
    case MTLPixelFormatR32Float: case MTLPixelFormatRG16Float: case MTLPixelFormatRG16Unorm: case MTLPixelFormatRGB10A2Unorm: return 4;
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatRG32Float: return 8;
    case MTLPixelFormatRGBA32Float: return 16;
    default: return 0;   // compressés (BC/DXT) : contrôle de largeur seulement
    }
}
static BOOL interesting(id<MTLTexture> t) {
    // la peinture : textures non compressées, petites/moyennes, hors cibles de rendu
    return t && bpp(t.pixelFormat) && !(t.usage & MTLTextureUsageRenderTarget) && t.width <= 2048 && t.height <= 2048;
}
static void report(const char *api, id<MTLTexture> t, MTLRegion r, NSUInteger level, NSUInteger bpr, NSUInteger extra, const char *why) {
    unsigned long n = atomic_fetch_add(&sUpCount, 1);
    if (why) atomic_fetch_add(&sUpBad, 1);
    if (why || n < 400 || n % 200 == 0)
        UL("[%8.3f] %s tex=%p %lux%lu fmt=%lu stor=%lu mip=%lu/%lu région=(%lu,%lu %lux%lu) bpr=%lu %lu%s%s",
           now() - sT0, api, t, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat,
           (unsigned long)t.storageMode, (unsigned long)level, (unsigned long)t.mipmapLevelCount,
           (unsigned long)r.origin.x, (unsigned long)r.origin.y, (unsigned long)r.size.width, (unsigned long)r.size.height,
           (unsigned long)bpr, (unsigned long)extra, why ? "  !!! " : "", why ? why : "");
}
static const char *check(id<MTLTexture> t, MTLRegion r, NSUInteger level, NSUInteger bpr) {
    NSUInteger w = MAX((NSUInteger)1, t.width >> level), h = MAX((NSUInteger)1, t.height >> level), b = bpp(t.pixelFormat);
    if (level >= t.mipmapLevelCount) return "niveau mip inexistant";
    if (r.origin.x + r.size.width > w || r.origin.y + r.size.height > h) return "région hors texture";
    if (b && bpr < r.size.width * b) return "bytesPerRow trop petit";
    return NULL;
}

typedef void (*rr_t)(id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger);
static rr_t o_rr;
static void my_rr(id self, SEL c, MTLRegion r, NSUInteger lvl, const void *bytes, NSUInteger bpr) {
    if (interesting(self)) report("replaceRegion", self, r, lvl, bpr, 0, check(self, r, lvl, bpr));
    o_rr(self, c, r, lvl, bytes, bpr);
}
typedef void (*rrs_t)(id, SEL, MTLRegion, NSUInteger, NSUInteger, const void *, NSUInteger, NSUInteger);
static rrs_t o_rrs;
static void my_rrs(id self, SEL c, MTLRegion r, NSUInteger lvl, NSUInteger slice, const void *bytes, NSUInteger bpr, NSUInteger bpi) {
    if (interesting(self)) report("replaceRegion+slice", self, r, lvl, bpr, slice, check(self, r, lvl, bpr));
    o_rrs(self, c, r, lvl, slice, bytes, bpr, bpi);
}

typedef void (*cbt_t)(id, SEL, id, NSUInteger, NSUInteger, NSUInteger, MTLSize, id, NSUInteger, NSUInteger, MTLOrigin);
static cbt_t o_cbt;
static void my_cbt(id self, SEL c, id<MTLBuffer> buf, NSUInteger off, NSUInteger bpr, NSUInteger bpi, MTLSize sz,
                   id<MTLTexture> t, NSUInteger slice, NSUInteger lvl, MTLOrigin o) {
    if (interesting(t)) {
        MTLRegion r = { o, sz };
        const char *why = check(t, r, lvl, bpr);
        if (!why && off % MAX((NSUInteger)1, bpp(t.pixelFormat))) why = "sourceOffset non aligné sur la taille de pixel";
        if (!why && off + bpr * (sz.height - 1) + sz.width * bpp(t.pixelFormat) > buf.length) why = "lecture au-delà du tampon";
        report("copyFromBuffer", t, r, lvl, bpr, off, why);
    }
    o_cbt(self, c, buf, off, bpr, bpi, sz, t, slice, lvl, o);
}

typedef id (*bt_t)(id, SEL, MTLTextureDescriptor *, NSUInteger, NSUInteger);
static bt_t o_bt;
static id my_bt(id self, SEL c, MTLTextureDescriptor *d, NSUInteger off, NSUInteger bpr) {
    id<MTLTexture> t = o_bt(self, c, d, off, bpr);
    NSUInteger al = [((id<MTLBuffer>)self).device minimumLinearTextureAlignmentForPixelFormat:d.pixelFormat];
    const char *why = !t ? "création REFUSÉE (nil)" : (al && off % al) ? "offset non aligné (linéaire)" : (al && bpr % al) ? "bytesPerRow non aligné (linéaire)" : NULL;
    UL("[%8.3f] bufferTexture %lux%lu fmt=%lu off=%lu bpr=%lu alignement requis=%lu -> %p%s%s", now() - sT0,
       (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.pixelFormat, (unsigned long)off, (unsigned long)bpr,
       (unsigned long)al, t, why ? "  !!! " : "", why ? why : "");
    if (why) atomic_fetch_add(&sUpBad, 1);
    return t;
}

typedef id (*nt_t)(id, SEL, MTLTextureDescriptor *);
static nt_t o_nt;
static _Atomic unsigned long sNewNil;
static id my_nt(id self, SEL c, MTLTextureDescriptor *d) {
    id t = o_nt(self, c, d);
    if (!t) { atomic_fetch_add(&sNewNil, 1);
        UL("[%8.3f] newTexture REFUSÉE %lux%lu fmt=%lu mips=%lu usage=0x%lx stor=%lu  !!!", now() - sT0,
           (unsigned long)d.width, (unsigned long)d.height, (unsigned long)d.pixelFormat, (unsigned long)d.mipmapLevelCount,
           (unsigned long)d.usage, (unsigned long)d.storageMode); }
    return t;
}

static void swz(Class c, SEL s, IMP n, IMP *o, const char *what) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) { UL("hook absent : %s", what); return; }
    *o = method_getImplementation(m); method_setImplementation(m, n);
    UL("hook : %s sur %s", what, class_getName(c));
}

static void *summary(void *u) {
    for (;;) { sleep(10); UL("--- %lu chargements surveillés, %lu suspects, %lu créations refusées ---",
                             atomic_load(&sUpCount), atomic_load(&sUpBad), atomic_load(&sNewNil)); }
    return NULL;
}

void TS3UpTraceInit(void) {
    sT0 = now();
    UL("=== traceur de chargements de textures (validation Metal=%d) ===", gMtlVal);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:4 height:4 mipmapped:NO];
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    id<MTLBuffer> buf = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
    swz(object_getClass(dev), @selector(newTextureWithDescriptor:), (IMP)my_nt, (IMP *)&o_nt, "newTextureWithDescriptor:");
    swz(object_getClass(tex), @selector(replaceRegion:mipmapLevel:withBytes:bytesPerRow:), (IMP)my_rr, (IMP *)&o_rr, "replaceRegion");
    swz(object_getClass(tex), @selector(replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:), (IMP)my_rrs, (IMP *)&o_rrs, "replaceRegion+slice");
    swz(object_getClass(be), @selector(copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:),
        (IMP)my_cbt, (IMP *)&o_cbt, "copyFromBuffer:toTexture:");
    swz(object_getClass(buf), @selector(newTextureWithDescriptor:offset:bytesPerRow:), (IMP)my_bt, (IMP *)&o_bt, "buffer newTexture");
    [be endEncoding];
    pthread_t th; pthread_create(&th, NULL, summary, NULL); pthread_detach(th);
}
