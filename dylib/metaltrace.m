// Read-only Metal render-pass tracer for TS3 investigation.
// Enabled only by `metaltrace=1` in ts3fixes.conf.  It changes no texture,
// sampler, command, or draw state; it writes pass summaries to /tmp only.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <unistd.h>

static int sEnabled;
static FILE *sLog;
static pthread_mutex_t sLock = PTHREAD_MUTEX_INITIALIZER;
static unsigned sPassNumber;
static unsigned sCapturedPasses;
static int sCapturing, sTriggered;

typedef struct {
    __unsafe_unretained id encoder;
    __unsafe_unretained id target;
    __unsafe_unretained id pipeline;
    __unsafe_unretained id textures[8];
    NSUInteger width, height, format;
    unsigned draws;
} TracePass;
static TracePass sPasses[64];

static void trace(const char *fmt, ...) {
    pthread_mutex_lock(&sLock);
    if (!sLog) sLog = fopen("/tmp/ts3_metal_trace.log", "a");
    if (sLog) {
        va_list ap; va_start(ap, fmt); vfprintf(sLog, fmt, ap); va_end(ap);
        fputc('\n', sLog); fflush(sLog);
    }
    pthread_mutex_unlock(&sLock);
}

static TracePass *passFor(id encoder, int create) {
    TracePass *empty = NULL;
    for (unsigned i = 0; i < 64; i++) {
        if (sPasses[i].encoder == encoder) return &sPasses[i];
        if (!sPasses[i].encoder && !empty) empty = &sPasses[i];
    }
    if (!create || !empty) return NULL;
    memset(empty, 0, sizeof(*empty)); empty->encoder = encoder;
    return empty;
}

static const char *labelOf(id object) {
    @try { NSString *label = [object respondsToSelector:@selector(label)] ? [object label] : nil; return label ? label.UTF8String : "-"; }
    @catch (...) { return "?"; }
}

// Creating this empty file while the game is running starts one bounded trace.
// This avoids spending the log budget on menus and world loading.
static void startCaptureIfRequested(void) {
    if (sTriggered || access("/tmp/ts3_metal_trace.trigger", F_OK) != 0) return;
    unlink("/tmp/ts3_metal_trace.trigger");
    pthread_mutex_lock(&sLock);
    if (sLog) fclose(sLog);
    sLog = fopen("/tmp/ts3_metal_trace.log", "w");
    pthread_mutex_unlock(&sLock);
    sTriggered = sCapturing = 1; sPassNumber = sCapturedPasses = 0;
    trace("=== capture triggered: next 1800 render passes ===");
}

typedef id (*newTexture_t)(id, SEL, MTLTextureDescriptor *);
static newTexture_t sNewTexture;
static id traceNewTexture(id self, SEL cmd, MTLTextureDescriptor *descriptor) {
    id texture = sNewTexture(self, cmd, descriptor);
    if (texture && (descriptor.usage & MTLTextureUsageRenderTarget)) {
        trace("TEX %p %lux%lu fmt=%lu usage=0x%lx storage=%lu label=%s", texture,
              (unsigned long)descriptor.width, (unsigned long)descriptor.height,
              (unsigned long)descriptor.pixelFormat, (unsigned long)descriptor.usage,
              (unsigned long)descriptor.storageMode, labelOf(texture));
    }
    return texture;
}

typedef id (*newEncoder_t)(id, SEL, MTLRenderPassDescriptor *);
static newEncoder_t sNewEncoder;
static Class sEncoderClass;
static id traceNewEncoder(id self, SEL cmd, MTLRenderPassDescriptor *descriptor);

typedef void (*setPipeline_t)(id, SEL, id);
static setPipeline_t sSetPipeline;
static void traceSetPipeline(id self, SEL cmd, id pipeline) {
    TracePass *p = passFor(self, 0); if (p) p->pipeline = pipeline;
    sSetPipeline(self, cmd, pipeline);
}

typedef void (*setTexture_t)(id, SEL, id, NSUInteger);
static setTexture_t sSetFragmentTexture;
static void traceSetFragmentTexture(id self, SEL cmd, id texture, NSUInteger index) {
    TracePass *p = passFor(self, 0); if (p && index < 8) p->textures[index] = texture;
    sSetFragmentTexture(self, cmd, texture, index);
}

typedef void (*draw_t)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger);
static draw_t sDraw;
static void traceDraw(id self, SEL cmd, MTLPrimitiveType primitive, NSUInteger start, NSUInteger count) {
    TracePass *p = passFor(self, 0); if (p) p->draws++;
    sDraw(self, cmd, primitive, start, count);
}

typedef void (*end_t)(id, SEL);
static end_t sEnd;
static void traceEnd(id self, SEL cmd) {
    startCaptureIfRequested();
    TracePass *p = passFor(self, 0);
    if (p && p->target && sCapturing && sCapturedPasses < 1800) {
        trace("PASS %05u out=%p %lux%lu fmt=%lu draw=%u pipe=%p(%s) tex0=%p(%s) tex1=%p(%s) tex2=%p(%s)",
              ++sPassNumber, p->target, (unsigned long)p->width, (unsigned long)p->height,
              (unsigned long)p->format, p->draws, p->pipeline, labelOf(p->pipeline),
              p->textures[0], labelOf(p->textures[0]), p->textures[1], labelOf(p->textures[1]),
              p->textures[2], labelOf(p->textures[2]));
        if (++sCapturedPasses == 1800) { sCapturing = 0; trace("=== capture complete ==="); }
    }
    if (p) memset(p, 0, sizeof(*p));
    sEnd(self, cmd);
}

static void hook(Class c, SEL selector, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(c, selector);
    if (!method) { trace("MISSING %s on %s", sel_getName(selector), class_getName(c)); return; }
    *original = method_getImplementation(method); method_setImplementation(method, replacement);
}

static id traceNewEncoder(id self, SEL cmd, MTLRenderPassDescriptor *descriptor) {
    id encoder = sNewEncoder(self, cmd, descriptor);
    if (!encoder) return encoder;
    MTLRenderPassColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
    id<MTLTexture> target = color.texture;
    if (target) {
        TracePass *p = passFor(encoder, 1);
        p->target = target; p->width = target.width; p->height = target.height; p->format = target.pixelFormat;
    }
    if (!sEncoderClass) {
        sEncoderClass = object_getClass(encoder);
        hook(sEncoderClass, @selector(setRenderPipelineState:), (IMP)traceSetPipeline, (IMP *)&sSetPipeline);
        hook(sEncoderClass, @selector(setFragmentTexture:atIndex:), (IMP)traceSetFragmentTexture, (IMP *)&sSetFragmentTexture);
        hook(sEncoderClass, @selector(drawPrimitives:vertexStart:vertexCount:), (IMP)traceDraw, (IMP *)&sDraw);
        hook(sEncoderClass, @selector(endEncoding), (IMP)traceEnd, (IMP *)&sEnd);
        trace("encoder class %s hooked", class_getName(sEncoderClass));
    }
    return encoder;
}

void TS3MetalTraceEnable(void) {
    if (sEnabled++) return;
    trace("=== TS3 Metal render trace enabled (read-only) ===");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { trace("no Metal device"); return; }
    Class deviceClass = object_getClass(device);
    hook(deviceClass, @selector(newTextureWithDescriptor:), (IMP)traceNewTexture, (IMP *)&sNewTexture);
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    if (buffer) hook(object_getClass(buffer), @selector(renderCommandEncoderWithDescriptor:), (IMP)traceNewEncoder, (IMP *)&sNewEncoder);
}
