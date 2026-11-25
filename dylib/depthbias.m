// Routes enneigées qui « percent » les murs : relevé et correction des décalages de profondeur (depth bias).
// conf : biastrace=1 (relevé seul) ; biasfix=1 annule le décalage, 2 inverse son signe, 3 le divise par 1000.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import <pthread.h>

int gBiasTrace = 0, gBiasFix = 0, gStencilFix = 0;
static FILE *sB;
static void BL(const char *fmt, ...) {
    if (!sB) sB = fopen("/tmp/ts3_bias.log", "w");
    if (sB) { va_list a; va_start(a, fmt); vfprintf(sB, fmt, a); va_end(a); fputc('\n', sB); fflush(sB); }
}

typedef struct { float bias, slope, clamp; unsigned long n; } BiasStat;
static BiasStat sStats[64]; static int sNStats; static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static unsigned long sOther;

typedef void (*setBias_t)(id, SEL, float, float, float);
static setBias_t o_setBias;
static void my_setBias(id self, SEL c, float bias, float slope, float clamp) {
    os_unfair_lock_lock(&sLock);
    int i = 0;
    for (; i < sNStats; i++) if (sStats[i].bias == bias && sStats[i].slope == slope && sStats[i].clamp == clamp) break;
    if (i < sNStats) sStats[i].n++;
    else if (sNStats < 64) sStats[sNStats++] = (BiasStat){ bias, slope, clamp, 1 };
    else sOther++;
    os_unfair_lock_unlock(&sLock);
    switch (gBiasFix) {
    case 1: bias = 0; slope = 0; clamp = 0; break;
    case 2: bias = -bias; slope = -slope; clamp = -clamp; break;
    case 3: bias /= 1000.f; slope /= 1000.f; clamp /= 1000.f; break;
    }
    o_setBias(self, c, bias, slope, clamp);
}

static const char *cmpName(MTLCompareFunction f) {
    static const char *n[] = { "Never", "Less", "Equal", "LessEqual", "Greater", "NotEqual", "GreaterEqual", "Always" };
    return f < 8 ? n[f] : "?";
}
typedef id (*newDSS_t)(id, SEL, MTLDepthStencilDescriptor *);
static newDSS_t o_newDSS;
static id my_newDSS(id self, SEL c, MTLDepthStencilDescriptor *d) {
    BL("état profondeur : test=%s écriture=%d stencil=%d", cmpName(d.depthCompareFunction), d.depthWriteEnabled,
       d.frontFaceStencil != nil && d.frontFaceStencil.stencilCompareFunction != MTLCompareFunctionAlways);
    if (gStencilFix && (d.frontFaceStencil || d.backFaceStencil)) {
        d.frontFaceStencil = nil; d.backFaceStencil = nil;
        BL("   -> stencil désactivé pour cet état");
    }
    return o_newDSS(self, c, d);
}

static void *dump(void *u) {
    for (;;) {
        sleep(10);
        BiasStat copy[64]; int n; unsigned long other;
        os_unfair_lock_lock(&sLock); n = sNStats; memcpy(copy, sStats, sizeof copy); other = sOther; os_unfair_lock_unlock(&sLock);
        BL("--- décalages de profondeur utilisés (biasfix=%d) ---", gBiasFix);
        for (int i = 0; i < n; i++)
            BL("  bias=%-12g slope=%-12g clamp=%-12g  x%lu", copy[i].bias, copy[i].slope, copy[i].clamp, copy[i].n);
        if (other) BL("  (autres valeurs : %lu)", other);
    }
    return NULL;
}

void TS3DepthBiasInit(void) {
    BL("=== relevé des décalages de profondeur, biasfix=%d stencilfix=%d ===", gBiasFix, gStencilFix);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    Method m = class_getInstanceMethod(object_getClass(dev), @selector(newDepthStencilStateWithDescriptor:));
    if (m) { o_newDSS = (newDSS_t)method_getImplementation(m); method_setImplementation(m, (IMP)my_newDSS); }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *p = [MTLRenderPassDescriptor renderPassDescriptor];
    p.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:p];
    Method mb = class_getInstanceMethod(object_getClass(e), @selector(setDepthBias:slopeScale:clamp:));
    if (mb) { o_setBias = (setBias_t)method_getImplementation(mb); method_setImplementation(mb, (IMP)my_setBias);
        BL("hook setDepthBias sur %s", class_getName(object_getClass(e))); }
    else BL("setDepthBias introuvable");
    [e endEncoding];
    pthread_t th; pthread_create(&th, NULL, dump, NULL); pthread_detach(th);
}
