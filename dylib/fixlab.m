// Expériences peinture terrain + son. Piloté par ts3fixes.conf :
//   loadfix=0|1|2   1 = attachements couleur DontCare -> Load/Store ; 2 = aussi profondeur/stencil
//   audiodiag=0|1   mesure du rendu audio du jeu -> /tmp/ts3_audio.log
//   audiofix=0|1    MaximumFramesPerSlice 4096 sur les unités du graphe + tampon périphérique audiobuf=
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach/mach_time.h>
#import <pthread.h>
#import <stdatomic.h>
#import <unistd.h>
#import <math.h>
#import "fishhook.h"

int gDepthClamp = 0;
int gLoadFix = 0, gAudioDiag = 0, gAudioFix = 0, gAudioBuf = 0, gClearFix = 0;
char gAudioPrio[64] = "";
char gBoost[128] = "";
int gAudioRec = 0, gAudioLP = 0;
static float sLPc[5]; static float sLPz[2][2][4];
#define REC_N (48000 * 30)
static float *sRec[2]; static _Atomic uint64_t sRecPos; static double sRecRate = 48000;
#import <mach/mach.h>
#import <mach/thread_policy.h>

static FILE *sLog;
static pthread_mutex_t sLogLock = PTHREAD_MUTEX_INITIALIZER;
static void LL(const char *fmt, ...) {
    pthread_mutex_lock(&sLogLock);
    if (!sLog) sLog = fopen("/tmp/ts3_lab.log", "w");
    if (sLog) { va_list a; va_start(a, fmt); vfprintf(sLog, fmt, a); va_end(a); fputc('\n', sLog); fflush(sLog); }
    pthread_mutex_unlock(&sLogLock);
}

// ---------------------------------------------------------------- peinture
static _Atomic unsigned long sDepthClamped;
static _Atomic unsigned long sPasses, sColorFixed, sStoreFixed, sDepthFixed, sClearCand, sClearFixed;
typedef id (*newEnc_t)(id, SEL, MTLRenderPassDescriptor *);
static newEnc_t sOrigEnc;
static id labEnc(id self, SEL cmd, MTLRenderPassDescriptor *d) {
    atomic_fetch_add(&sPasses, 1);
    if (gDepthClamp) {
        MTLRenderPassDepthAttachmentDescriptor *dz = d.depthAttachment;
        if (dz.texture && (dz.clearDepth > 1.0 || dz.clearDepth < 0.0)) {
            unsigned long n = atomic_fetch_add(&sDepthClamped, 1);
            if (n < 60 || n % 5000 == 0) {
                id<MTLTexture> c0 = d.colorAttachments[0].texture;
                LL("depthclamp #%lu: clearDepth %.1f -> %.1f  prof %lux%lu fmt=%lu load=%lu store=%lu | couleur0 %lux%lu fmt=%lu load=%lu",
                   n, dz.clearDepth, dz.clearDepth > 1.0 ? 1.0 : 0.0, (unsigned long)dz.texture.width, (unsigned long)dz.texture.height,
                   (unsigned long)dz.texture.pixelFormat, (unsigned long)dz.loadAction, (unsigned long)dz.storeAction,
                   (unsigned long)c0.width, (unsigned long)c0.height, (unsigned long)c0.pixelFormat, (unsigned long)d.colorAttachments[0].loadAction);
            }
            if (gDepthClamp == 1) dz.clearDepth = dz.clearDepth > 1.0 ? 1.0 : 0.0;
        }
    }
    for (NSUInteger i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *c = d.colorAttachments[i];
        id<MTLTexture> t = c.texture;
        if (!t || t.storageMode == MTLStorageModeMemoryless) continue;
        if (c.loadAction == MTLLoadActionDontCare) { c.loadAction = MTLLoadActionLoad; atomic_fetch_add(&sColorFixed, 1); }
        if (c.storeAction == MTLStoreActionDontCare) { c.storeAction = MTLStoreActionStore; atomic_fetch_add(&sStoreFixed, 1); }
        if (c.loadAction == MTLLoadActionClear) {
            NSUInteger w = t.width, h = t.height;
            BOOL cand = t.storageMode == MTLStorageModePrivate && !t.isFramebufferOnly && w == h && w >= 256 && w <= 1024
                        && (t.pixelFormat == MTLPixelFormatBGRA8Unorm || t.pixelFormat == MTLPixelFormatRGBA8Unorm);
            if (cand) { atomic_fetch_add(&sClearCand, 1); if (gClearFix) { c.loadAction = MTLLoadActionLoad; atomic_fetch_add(&sClearFixed, 1); } }
        }
    }
    if (gLoadFix >= 2) {
        MTLRenderPassDepthAttachmentDescriptor *z = d.depthAttachment;
        if (z.texture && z.texture.storageMode != MTLStorageModeMemoryless) {
            if (z.loadAction == MTLLoadActionDontCare) { z.loadAction = MTLLoadActionLoad; atomic_fetch_add(&sDepthFixed, 1); }
            if (z.storeAction == MTLStoreActionDontCare) z.storeAction = MTLStoreActionStore;
        }
        MTLRenderPassStencilAttachmentDescriptor *s = d.stencilAttachment;
        if (s.texture && s.texture.storageMode != MTLStorageModeMemoryless) {
            if (s.loadAction == MTLLoadActionDontCare) s.loadAction = MTLLoadActionLoad;
            if (s.storeAction == MTLStoreActionDontCare) s.storeAction = MTLStoreActionStore;
        }
    }
    return sOrigEnc(self, cmd, d);
}
static void installLoadFix(void) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> b = [q commandBuffer];
    if (!b) { LL("loadfix: pas de command buffer"); return; }
    Class c = object_getClass(b);
    Method m = class_getInstanceMethod(c, @selector(renderCommandEncoderWithDescriptor:));
    if (!m) { LL("loadfix: méthode absente sur %s", class_getName(c)); return; }
    sOrigEnc = (newEnc_t)method_getImplementation(m);
    method_setImplementation(m, (IMP)labEnc);
    LL("loadfix=%d installé sur %s", gLoadFix, class_getName(c));
}

// ---------------------------------------------------------------- son
// Aucune E/S dans les hooks : événements dans un anneau, écrits par un thread.
typedef struct { uint64_t t; int kind; uint32_t a, b, c, d; uint8_t data[48]; } Ev;
static Ev sRing[1024];
static _Atomic unsigned sHead; static unsigned sTail;
static void push(int kind, uint32_t a, uint32_t b, uint32_t c, uint32_t d, const void *data, uint32_t n) {
    unsigned i = atomic_fetch_add(&sHead, 1);
    if (i - sTail >= 1024) return;
    Ev *e = &sRing[i & 1023];
    e->t = mach_absolute_time(); e->kind = kind; e->a = a; e->b = b; e->c = c; e->d = d;
    memset(e->data, 0, 48); if (data) memcpy(e->data, data, n > 48 ? 48 : n);
}

typedef struct {
    AURenderCallback proc; void *ref; uint32_t node, bus;
    _Atomic uint64_t calls, maxTicks, sumTicks, late, errs, gapMax, lastT;
    _Atomic uint32_t minFrames, maxFrames;
    _Atomic uint64_t holes, jumps, silent; float last[2]; int wasSound;
} Slot;
static volatile mach_port_t sAUThread;
static Slot sSlots[16]; static _Atomic int sNSlots;
static double sTicksToMs; static double sRate = 44100.0;

static OSStatus labRender(void *ref, AudioUnitRenderActionFlags *f, const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 frames, AudioBufferList *io) {
    Slot *s = ref;
    if (!sAUThread) sAUThread = pthread_mach_thread_np(pthread_self());
    uint64_t t0 = mach_absolute_time();
    OSStatus r = s->proc(s->ref, f, ts, bus, frames, io);
    uint64_t t1 = mach_absolute_time(), dt = t1 - t0;
    uint64_t prev = atomic_exchange(&s->lastT, t0);
    if (prev) { uint64_t gap = t0 - prev; if (gap > atomic_load(&s->gapMax)) atomic_store(&s->gapMax, gap); }
    atomic_fetch_add(&s->calls, 1); atomic_fetch_add(&s->sumTicks, dt);
    if (dt > atomic_load(&s->maxTicks)) atomic_store(&s->maxTicks, dt);
    double budget = frames / sRate * 1000.0;
    if (dt * sTicksToMs > budget * 0.8) atomic_fetch_add(&s->late, 1);
    if (r) atomic_fetch_add(&s->errs, 1);
    if (!r && io && frames && sRec[0] && s == &sSlots[0]) {
        uint64_t pos = atomic_fetch_add(&sRecPos, frames);
        for (int k = 0; k < 2; k++) {
            int src = io->mNumberBuffers > 1 ? k : 0; float *x = io->mBuffers[src].mData;
            if (!x) continue;
            for (UInt32 j = 0; j < frames; j++) sRec[k][(pos + j) % REC_N] = x[j];
        }
    }
    if (!r && io && frames && gAudioLP && s == &sSlots[0]) {
        int nb = io->mNumberBuffers > 2 ? 2 : io->mNumberBuffers;
        for (int k = 0; k < nb; k++) {
            float *x = io->mBuffers[k].mData; if (!x) continue;
            UInt32 n = io->mBuffers[k].mDataByteSize / 4; if (n > frames) n = frames;
            for (int st = 0; st < 2; st++) {
                float *z = sLPz[k][st], b0 = sLPc[0], b1 = sLPc[1], b2 = sLPc[2], a1 = sLPc[3], a2 = sLPc[4];
                for (UInt32 j = 0; j < n; j++) {
                    float v = x[j], o = b0 * v + b1 * z[0] + b2 * z[1] - a1 * z[2] - a2 * z[3];
                    z[1] = z[0]; z[0] = v; z[3] = z[2]; z[2] = o; x[j] = o;
                }
            }
        }
    }
    if (!r && io && frames) {
        float peak = 0, inner = 0; int nb = io->mNumberBuffers > 2 ? 2 : io->mNumberBuffers;
        for (int k = 0; k < nb; k++) {
            float *x = io->mBuffers[k].mData; UInt32 n = io->mBuffers[k].mDataByteSize / 4; if (!x || !n) continue;
            if (n > frames) n = frames;
            for (UInt32 j = 0; j < n; j++) { float a = fabsf(x[j]); if (a > peak) peak = a; if (j) { float d = fabsf(x[j] - x[j-1]); if (d > inner) inner = d; } }
            float jump = fabsf(x[0] - s->last[k]);
            if (s->wasSound && jump > 0.2f && jump > 4 * inner) atomic_fetch_add(&s->jumps, 1);
            s->last[k] = x[n - 1];
        }
        if (peak == 0) { atomic_fetch_add(&s->silent, 1); if (s->wasSound) atomic_fetch_add(&s->holes, 1); }
        s->wasSound = peak > 0;
    }
    if (frames < atomic_load(&s->minFrames)) atomic_store(&s->minFrames, frames);
    if (frames > atomic_load(&s->maxFrames)) atomic_store(&s->maxFrames, frames);
    return r;
}

static OSStatus (*o_SetCB)(AUGraph, AUNode, UInt32, const AURenderCallbackStruct *);
static OSStatus my_SetCB(AUGraph g, AUNode n, UInt32 in, const AURenderCallbackStruct *cb) {
    if (!cb || !cb->inputProc) return o_SetCB(g, n, in, cb);
    int i = atomic_fetch_add(&sNSlots, 1);
    if (i >= 16) return o_SetCB(g, n, in, cb);
    Slot *s = &sSlots[i];
    s->proc = cb->inputProc; s->ref = cb->inputProcRefCon; s->node = (uint32_t)n; s->bus = in;
    atomic_store(&s->minFrames, 0xffffffff);
    push(1, (uint32_t)n, in, i, 0, NULL, 0);
    AURenderCallbackStruct w = { labRender, s };
    return o_SetCB(g, n, in, &w);
}

static OSStatus (*o_SetProp)(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus my_SetProp(AudioUnit u, AudioUnitPropertyID p, AudioUnitScope sc, AudioUnitElement el, const void *d, UInt32 n) {
    UInt32 big = 4096;
    if (gAudioFix && p == kAudioUnitProperty_MaximumFramesPerSlice && d && n == 4 && *(const UInt32 *)d < big) {
        push(3, p, sc, el, *(const UInt32 *)d, NULL, 0);
        d = &big;
    }
    if (p == kAudioUnitProperty_StreamFormat && d && n >= sizeof(AudioStreamBasicDescription) && sc == kAudioUnitScope_Input)
        { sRate = ((const AudioStreamBasicDescription *)d)->mSampleRate ?: sRate; sRecRate = sRate; }
    OSStatus r = o_SetProp(u, p, sc, el, d, n);
    push(2, p, sc, el, (uint32_t)r, d, n);
    return r;
}

static OSStatus (*o_GraphInit)(AUGraph);
static OSStatus my_GraphInit(AUGraph g) {
    if (gAudioFix) {
        UInt32 count = 0; AUGraphGetNodeCount(g, &count);
        for (UInt32 i = 0; i < count; i++) {
            AUNode node; AudioUnit unit = NULL; AudioComponentDescription desc;
            if (AUGraphGetIndNode(g, i, &node) || AUGraphNodeInfo(g, node, &desc, &unit) || !unit) continue;
            UInt32 big = 4096;
            OSStatus r = o_SetProp(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &big, 4);
            push(4, desc.componentType, desc.componentSubType, (uint32_t)node, (uint32_t)r, NULL, 0);
            if (gAudioBuf && desc.componentType == kAudioUnitType_Output) {
                UInt32 fr = (UInt32)gAudioBuf;
                OSStatus r2 = AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &fr, 4);
                push(5, fr, (uint32_t)r2, 0, 0, NULL, 0);
            }
        }
    }
    OSStatus r = o_GraphInit(g);
    UInt32 count = 0; AUGraphGetNodeCount(g, &count);
    for (UInt32 i = 0; i < count; i++) {
        AUNode node; AudioUnit unit = NULL; AudioComponentDescription desc;
        if (AUGraphGetIndNode(g, i, &node) || AUGraphNodeInfo(g, node, &desc, &unit) || !unit) continue;
        UInt32 mf = 0, sz = 4; AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &mf, &sz);
        AudioStreamBasicDescription f = {0}; sz = sizeof f;
        AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, &sz);
        push(6, desc.componentType, desc.componentSubType, mf, (uint32_t)node, &f, sizeof f);
    }
    push(7, (uint32_t)r, count, 0, 0, NULL, 0);
    return r;
}

static OSStatus (*o_DevGet)(AudioDeviceID, UInt32, Boolean, AudioDevicePropertyID, UInt32 *, void *);
static OSStatus my_DevGet(AudioDeviceID dev, UInt32 ch, Boolean isIn, AudioDevicePropertyID p, UInt32 *sz, void *out) {
    OSStatus r = o_DevGet(dev, ch, isIn, p, sz, out);
    push(8, p, (uint32_t)r, sz ? *sz : 0, isIn, out, sz ? *sz : 0);
    return r;
}

static _Atomic unsigned long sOverloads;
static OSStatus overloadCB(AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a, void *c) {
    atomic_fetch_add(&sOverloads, 1); return 0;
}


typedef struct { uint64_t id, cpu; } TPrev;
static TPrev sPrev[512]; static int sNPrev;
static uint64_t sPromoted[64]; static int sNPromoted;
static void promote(thread_act_t th, uint64_t id, const char *name) {
    for (int i = 0; i < sNPromoted; i++) if (sPromoted[i] == id) return;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    double nsToAbs = (double)tb.denom / tb.numer;
    thread_time_constraint_policy_data_t p;
    p.period = (uint32_t)(11600000 * nsToAbs); p.computation = (uint32_t)(3000000 * nsToAbs);
    p.constraint = (uint32_t)(11000000 * nsToAbs); p.preemptible = 1;
    kern_return_t kr = thread_policy_set(th, THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    if (sNPromoted < 64) sPromoted[sNPromoted++] = id;
    LL("audioprio: thread '%s' (id %llu) -> temps réel : %d", name, id, kr);
}

static int inList(const char *list, const char *name) {
    char buf[128]; strlcpy(buf, list, sizeof buf);
    for (char *save = NULL, *tok = strtok_r(buf, ",", &save); tok; tok = strtok_r(NULL, ",", &save)) {
        while (*tok == ' ') tok++;
        if (*tok && strcmp(tok, name) == 0) return 1;
    }
    return 0;
}
static uint64_t sBoosted[64]; static int sNBoosted;
static void boost(thread_act_t th, uint64_t id, const char *name) {
    for (int i = 0; i < sNBoosted; i++) if (sBoosted[i] == id) return;
    thread_precedence_policy_data_t pr = { 15 };
    kern_return_t a = thread_policy_set(th, THREAD_PRECEDENCE_POLICY, (thread_policy_t)&pr, THREAD_PRECEDENCE_POLICY_COUNT);
    thread_throughput_qos_policy_data_t tq = { THROUGHPUT_QOS_TIER_0 };
    kern_return_t b = thread_policy_set(th, THREAD_THROUGHPUT_QOS_POLICY, (thread_policy_t)&tq, THREAD_THROUGHPUT_QOS_POLICY_COUNT);
    thread_latency_qos_policy_data_t lq = { LATENCY_QOS_TIER_0 };
    kern_return_t c = thread_policy_set(th, THREAD_LATENCY_QOS_POLICY, (thread_policy_t)&lq, THREAD_LATENCY_QOS_POLICY_COUNT);
    if (sNBoosted < 64) sBoosted[sNBoosted++] = id;
    LL("boost: thread '%s' (id %llu) -> priorité haute : %d/%d/%d", name, id, a, b, c);
}
static void census(int report) {
    thread_act_array_t list; mach_msg_type_number_t n;
    if (task_threads(mach_task_self(), &list, &n)) return;
    struct { uint64_t d; char name[64]; int pri; uint64_t id; int au; } top[256]; int nt = 0;
    TPrev cur[512]; int nc = 0;
    for (mach_msg_type_number_t i = 0; i < n; i++) {
        thread_identifier_info_data_t idi; mach_msg_type_number_t c1 = THREAD_IDENTIFIER_INFO_COUNT;
        thread_extended_info_data_t ext; mach_msg_type_number_t c2 = THREAD_EXTENDED_INFO_COUNT;
        if (thread_info(list[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&idi, &c1) ||
            thread_info(list[i], THREAD_EXTENDED_INFO, (thread_info_t)&ext, &c2)) { mach_port_deallocate(mach_task_self(), list[i]); continue; }
        uint64_t cpu = ext.pth_user_time + ext.pth_system_time, prev = cpu;
        for (int k = 0; k < sNPrev; k++) if (sPrev[k].id == idi.thread_id) { prev = sPrev[k].cpu; break; }
        if (nc < 512) cur[nc++] = (TPrev){ idi.thread_id, cpu };
        if (ext.pth_name[0] && inList(gAudioPrio, ext.pth_name)) promote(list[i], idi.thread_id, ext.pth_name);
        else if (ext.pth_name[0] && inList(gBoost, ext.pth_name)) boost(list[i], idi.thread_id, ext.pth_name);
        if (nt < 256) { top[nt].d = cpu - prev; strlcpy(top[nt].name, ext.pth_name, 64); top[nt].pri = ext.pth_curpri;
            top[nt].id = idi.thread_id; top[nt].au = list[i] == sAUThread; nt++; }
        mach_port_deallocate(mach_task_self(), list[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)list, n * sizeof(thread_act_t));
    memcpy(sPrev, cur, nc * sizeof(TPrev)); sNPrev = nc;
    if (!report) return;
    for (int a = 0; a < nt; a++) for (int b = a + 1; b < nt; b++) if (top[b].d > top[a].d) { __typeof__(top[0]) t = top[a]; top[a] = top[b]; top[b] = t; }
    LL("--- threads (%d) : CPU sur 10 s ---", nt);
    for (int a = 0; a < nt && a < 14; a++)
        LL("  %6.0f ms  pri=%2d  id=%llu  '%s'%s", top[a].d / 1e6, top[a].pri, top[a].id, top[a].name, top[a].au ? "  <= sortie audio CoreAudio" : "");
}


static void dumpWav(void) {
    uint64_t end = atomic_load(&sRecPos); if (end < 48000) return;
    uint64_t n = end < REC_N ? end : REC_N, start = end - n;
    FILE *f = fopen("/tmp/ts3_audio.wav.tmp", "wb"); if (!f) return;
    uint32_t rate = (uint32_t)sRecRate, dataBytes = (uint32_t)(n * 8), v32; uint16_t v16;
    fwrite("RIFF", 1, 4, f); v32 = 36 + dataBytes; fwrite(&v32, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    v32 = 16; fwrite(&v32, 4, 1, f); v16 = 3; fwrite(&v16, 2, 1, f); v16 = 2; fwrite(&v16, 2, 1, f);
    fwrite(&rate, 4, 1, f); v32 = rate * 8; fwrite(&v32, 4, 1, f); v16 = 8; fwrite(&v16, 2, 1, f); v16 = 32; fwrite(&v16, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&dataBytes, 4, 1, f);
    for (uint64_t i = start; i < end; i++) { float fr[2] = { sRec[0][i % REC_N], sRec[1][i % REC_N] }; fwrite(fr, 4, 2, f); }
    fclose(f); rename("/tmp/ts3_audio.wav.tmp", "/tmp/ts3_audio.wav");
}

static void fourcc(uint32_t v, char *o) { o[0]=v>>24; o[1]=v>>16; o[2]=v>>8; o[3]=v; o[4]=0; for (int i=0;i<4;i++) if (o[i]<32||o[i]>126) o[i]='.'; }

static void *logger(void *unused) {
    unsigned long lastOv = 0, lastPasses = 0; uint64_t lastCalls[16] = {0};
    int tick = 0;
    for (;;) {
        usleep(250000);
        unsigned h = atomic_load(&sHead);
        if (h - sTail > 1024) { LL("!! %u événements perdus", h - sTail - 1024); sTail = h - 1024; }
        while (sTail != h) {
            Ev *e = &sRing[sTail & 1023]; char c4[5];
            double ms = e->t * sTicksToMs;
            switch (e->kind) {
            case 1: LL("[%.0f] callback node=%u bus=%u slot=%u", ms, e->a, e->b, e->c); break;
            case 2: fourcc(e->a, c4);
                if (e->a == kAudioUnitProperty_StreamFormat) { AudioStreamBasicDescription *f = (void *)e->data;
                    fourcc(f->mFormatID, c4);
                    LL("[%.0f] SetProp StreamFormat scope=%u el=%u -> %d : %.0f Hz %s flags=0x%x ch=%u bits=%u bpf=%u", ms, e->b, e->c, (int)e->d,
                       f->mSampleRate, c4, f->mFormatFlags, f->mChannelsPerFrame, f->mBitsPerChannel, f->mBytesPerFrame);
                } else LL("[%.0f] SetProp id=%u scope=%u el=%u -> %d val=%u", ms, e->a, e->b, e->c, (int)e->d, *(uint32_t *)e->data);
                break;
            case 3: LL("[%.0f] audiofix: MaximumFramesPerSlice %u -> 4096 (scope=%u el=%u)", ms, e->d, e->b, e->c); break;
            case 4: { char t[5], s[5]; fourcc(e->a, t); fourcc(e->b, s); LL("[%.0f] audiofix: unité %s/%s node=%u MaxFrames 4096 -> %d", ms, t, s, e->c, (int)e->d); } break;
            case 5: LL("[%.0f] audiofix: tampon périphérique %u trames -> %d", ms, e->a, (int)e->b); break;
            case 6: { char t[5], s[5]; fourcc(e->a, t); fourcc(e->b, s); AudioStreamBasicDescription *f = (void *)e->data;
                LL("[%.0f] graphe: unité %s/%s node=%u MaxFrames=%u entrée %.0f Hz ch=%u bits=%u flags=0x%x", ms, t, s, e->d, e->c,
                   f->mSampleRate, f->mChannelsPerFrame, f->mBitsPerChannel, f->mFormatFlags); } break;
            case 7: LL("[%.0f] AUGraphInitialize -> %d (%u unités)", ms, (int)e->a, e->b); break;
            case 8: fourcc(e->a, c4); LL("[%.0f] AudioDeviceGetProperty '%s' -> %d taille=%u val=%u", ms, c4, (int)e->b, e->c, *(uint32_t *)e->data); break;
            }
            sTail++;
        }
        if (sRec[0] && tick % 80 == 79) dumpWav();
        if (tick % 40 == 39) census(tick > 40);
        else if (tick % 8 == 7 && (gAudioPrio[0] || gBoost[0])) census(0);
        if (++tick % 8) continue;   // statistiques toutes les 2 s
        unsigned long ov = atomic_load(&sOverloads);
        int n = atomic_load(&sNSlots); if (n > 16) n = 16;
        for (int i = 0; i < n; i++) {
            Slot *s = &sSlots[i];
            uint64_t calls = atomic_load(&s->calls);
            if (calls == lastCalls[i] && ov == lastOv) continue;
            uint64_t dc = calls - lastCalls[i]; lastCalls[i] = calls;
            double maxMs = atomic_exchange(&s->maxTicks, 0) * sTicksToMs;
            double sumMs = atomic_exchange(&s->sumTicks, 0) * sTicksToMs;
            double gapMs = atomic_exchange(&s->gapMax, 0) * sTicksToMs;
            LL("[%.0f] audio slot%d: %llu appels/2s, trames %u-%u, moy %.2f ms, max %.2f ms, écart max entre appels %.1f ms, en retard %llu, erreurs %llu, SURCHARGES +%lu, TROUS %llu, SAUTS %llu, blocs muets %llu",
               mach_absolute_time() * sTicksToMs, i, dc, atomic_load(&s->minFrames), atomic_load(&s->maxFrames),
               dc ? sumMs / dc : 0, maxMs, gapMs, atomic_exchange(&s->late, 0), atomic_exchange(&s->errs, 0), ov - lastOv, atomic_exchange(&s->holes, 0), atomic_exchange(&s->jumps, 0), atomic_exchange(&s->silent, 0));
        }
        lastOv = ov;
        unsigned long p = atomic_load(&sPasses);
        if ((gLoadFix || gClearFix) && p != lastPasses && tick % 40 == 0)
            LL("metal: %lu passes, DontCare->Load %lu, store %lu, prof %lu, Clear candidats peinture %lu, Clear->Load %lu", p, atomic_load(&sColorFixed), atomic_load(&sStoreFixed), atomic_load(&sDepthFixed), atomic_load(&sClearCand), atomic_load(&sClearFixed));
        lastPasses = p;
    }
    return NULL;
}

static void installAudio(void) {
    const struct mach_header *mh = _dyld_get_image_header(0);
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    LL("audio: image principale %s", _dyld_get_image_name(0));
    struct rebinding rb[] = {
        { "AUGraphSetNodeInputCallback", (void *)my_SetCB, (void **)&o_SetCB },
        { "AudioUnitSetProperty", (void *)my_SetProp, (void **)&o_SetProp },
        { "AUGraphInitialize", (void *)my_GraphInit, (void **)&o_GraphInit },
        { "AudioDeviceGetProperty", (void *)my_DevGet, (void **)&o_DevGet },
    };
    rebind_symbols_image((void *)mh, slide, rb, 4);
    if (!o_SetProp) o_SetProp = AudioUnitSetProperty;
    LL("audio: hooks SetCB=%p SetProp=%p Init=%p DevGet=%p", o_SetCB, o_SetProp, o_GraphInit, o_DevGet);
    AudioObjectID dev = 0; UInt32 n = sizeof dev;
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (!AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &n, &dev) && dev) {
        a.mSelector = kAudioDeviceProcessorOverload;
        OSStatus r = AudioObjectAddPropertyListener(dev, &a, overloadCB, NULL);
        LL("audio: écoute des surcharges du périphérique %u -> %d", dev, (int)r);
    }
}

void TS3LabInit(void) {
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    sTicksToMs = (double)tb.numer / tb.denom / 1e6;
    LL("=== TS3 lab v3 depthclamp=%d: loadfix=%d clearfix=%d audiodiag=%d audiofix=%d audiobuf=%d audioprio='%s' boost='%s' audiorec=%d audiolp=%d ===", gDepthClamp, gLoadFix, gClearFix, gAudioDiag, gAudioFix, gAudioBuf, gAudioPrio, gBoost, gAudioRec, gAudioLP);
    if (gLoadFix || gClearFix || gDepthClamp) installLoadFix();
    if (gAudioLP > 0) {
        double w = 2 * M_PI * gAudioLP / 48000.0, al = sin(w) / (2 * 0.7071), c = cos(w), a0 = 1 + al;
        sLPc[0] = (1 - c) / 2 / a0; sLPc[1] = (1 - c) / a0; sLPc[2] = (1 - c) / 2 / a0; sLPc[3] = -2 * c / a0; sLPc[4] = (1 - al) / a0;
        LL("audiolp: passe-bas %d Hz (4e ordre) sur la sortie du mélangeur", gAudioLP);
    }
    if (gAudioRec) { sRec[0] = calloc(REC_N, 4); sRec[1] = calloc(REC_N, 4); }
    if (gAudioDiag || gAudioFix) installAudio();
    pthread_t th; pthread_create(&th, NULL, logger, NULL); pthread_detach(th);
}
