// Bissection en jeu : supprime les dessins d'un groupe de shaders, groupe choisi au clavier.
// Ctrl+Option+N = groupe suivant, Ctrl+Option+P = précédent, Ctrl+Option+0 = rien supprimé.
// Le groupe courant est annoncé par la voix du Mac et noté dans /tmp/ts3_drawskip.log.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <pthread.h>

int gDrawSkip = 0, gSnowFix = 0, gWinFix = 0, gFrostGuard = 0, gPaintFix = 0;
static FILE *sL;
static void DL(const char *fmt, ...) {
    if (!sL) sL = fopen("/tmp/ts3_drawskip.log", "w");
    if (sL) { va_list a; va_start(a, fmt); vfprintf(sL, fmt, a); va_end(a); fputc('\n', sL); fflush(sL); }
}

// Groupes : motif cherché dans le source MSL du shader de sommets ou de pixels.
typedef struct { const char *name; const char *pattern; int depthOnly; } Group;
static const Group kGroups[] = {
    { "rien",                         NULL, 0 },
    { "passes de profondeur seule",   NULL, 1 },
    { "sol et routes deplaces par la neige", "kMaxSnowDepth", 0 },
    { "neige des routes",             "RoadSnowTexture", 0 },
    { "neige du sol",                 "TerrainSnowDiffuseMap", 0 },
    { "meteo",                        "GlobalWeatherParams", 0 },
    { "decoupes",                     "CutoutMap", 0 },
    { "translucides",                 "translucentTexture", 0 },
    { "plateformes",                  "PlatformOffsetFactor", 0 },
    { "lightmap",                     "LightmapSizeParameters", 0 },
    { "ombres",                       "Shadow", 0 },
    { "profondeur seule AVEC neige",  NULL, 2 },
    { "profondeur seule SANS neige",  NULL, 3 },
    { "profondeur seule ECRAN principal", NULL, 4 },
    { "profondeur seule textures carrees", NULL, 5 },
    { "correctif murs enneiges", NULL, 6 },
    { "neige sur les objets",         "ObjectSnowNormalMap", 0 },
    { "neige sur les toits",          "RoofSnowNormalMap", 0 },
    { "fonte de neige",               "SnowMeltingMap", 0 },
    { "lumieres emissives",           "EmissionMap", 0 },
    { "visible seulement la nuit",    "VisibleOnlyAtNight", 0 },
    { "reflet du ciel sous la pluie", "SkyReflectionForRain", 0 },
    { "sondes de lumiere vives",      "SharpSpecularLightProbe", 0 },
    { "neige des fenetres, test souple", NULL, 7 },
    { "neige des fenetres, decalage faible", NULL, 7 },
    { "neige des fenetres, decalage moyen", NULL, 7 },
    { "neige des fenetres, decalage fort", NULL, 7 },
    { "vitres givrees : textures manquantes en noir", NULL, 8 },
    { "peinture : composition des couches", "WeightMap", 0 },
    { "sol des lots", "WorldToLotTransAndLotScale", 0 },
    { "melange du terrain", "blendMap", 0 },
    { "couches du terrain", "LayerSelect0", 0 },
    { "detail du terrain", "terrain_detail", 0 },
    { "eclairage du terrain", "terrainLightMap", 0 },
};
#define NG (int)(sizeof kGroups / sizeof kGroups[0])
static _Atomic int sMode;
static _Atomic unsigned long sSkipped, sDraws;
static _Atomic unsigned long sGrpDraws[64];

static char kTagKey;
static uint64_t tagFor(NSString *src) {
    uint64_t t = 0;
    for (int i = 0; i < NG; i++) if (kGroups[i].pattern && [src rangeOfString:@(kGroups[i].pattern)].location != NSNotFound) t |= 1ull << i;
    return t;
}
static void setTag(id o, uint64_t t) { objc_setAssociatedObject(o, &kTagKey, @(t), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
static uint64_t getTag(id o) { NSNumber *n = o ? objc_getAssociatedObject(o, &kTagKey) : nil; return n.unsignedLongLongValue; }

// bibliothèques compilées depuis le source
static char kSrcKey, kPSrcKey, kIdxKey, kSlotKey, kSetKey;
static void keepSrc(id p, MTLRenderPipelineDescriptor *d) {
    id vs = objc_getAssociatedObject(d.vertexFunction, &kSrcKey), fs = objc_getAssociatedObject(d.fragmentFunction, &kSrcKey);
    if (fs) {
        uint32_t mask = 0; NSMutableArray *names = [NSMutableArray arrayWithCapacity:32]; for (int i = 0; i < 32; i++) [names addObject:@""];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"texture(?:2d|cube|3d|2d_array)<[^>]*>\\s+(\\w+)\\s*\\[\\[\\s*texture\\((\\d+)\\)" options:0 error:nil];
        for (NSTextCheckingResult *m in [re matchesInString:fs options:0 range:NSMakeRange(0, [fs length])]) {
            int slot = [[fs substringWithRange:[m rangeAtIndex:2]] intValue];
            if (slot < 32) { mask |= 1u << slot; names[slot] = [fs substringWithRange:[m rangeAtIndex:1]]; }
        }
        objc_setAssociatedObject(p, &kSlotKey, @[ @(mask), names ], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (vs || fs) objc_setAssociatedObject(p, &kPSrcKey, [NSString stringWithFormat:@"// ===== VERTEX %@\n%@\n// ===== FRAGMENT %@\n%@\n", d.vertexFunction.name, vs ?: @"(source non gardée)", d.fragmentFunction.name, fs ?: @"(source non gardée)"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
typedef id (*libSrc_t)(id, SEL, NSString *, MTLCompileOptions *, NSError **);
static libSrc_t o_libSrc;
static id my_libSrc(id self, SEL c, NSString *src, MTLCompileOptions *opt, NSError **err) {
    id lib = o_libSrc(self, c, src, opt, err);
    if (lib) { uint64_t t = tagFor(src); setTag(lib, t); if (t & ((1ull << 16) | (1ull << 28))) objc_setAssociatedObject(lib, &kSrcKey, src, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return lib;
}
typedef void (*libSrcAsync_t)(id, SEL, NSString *, MTLCompileOptions *, MTLNewLibraryCompletionHandler);
static libSrcAsync_t o_libSrcAsync;
static void my_libSrcAsync(id self, SEL c, NSString *src, MTLCompileOptions *opt, MTLNewLibraryCompletionHandler h) {
    uint64_t t = tagFor(src);
    o_libSrcAsync(self, c, src, opt, ^(id<MTLLibrary> lib, NSError *e) { if (lib) { setTag(lib, t); if (t & ((1ull << 16) | (1ull << 28))) objc_setAssociatedObject(lib, &kSrcKey, src, OBJC_ASSOCIATION_RETAIN_NONATOMIC); } h(lib, e); });
}
// fonctions héritent du tag de leur bibliothèque
typedef id (*newFn_t)(id, SEL, NSString *);
static newFn_t o_newFn;
static id my_newFn(id self, SEL c, NSString *name) {
    id f = o_newFn(self, c, name);
    if (f) { setTag(f, getTag(self)); id src = objc_getAssociatedObject(self, &kSrcKey); if (src) objc_setAssociatedObject(f, &kSrcKey, src, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return f;
}
// pipelines : tag des deux fonctions + bit "profondeur seule"
static uint64_t pipeTag(MTLRenderPipelineDescriptor *d) {
    uint64_t t = getTag(d.vertexFunction) | getTag(d.fragmentFunction);
    BOOL anyColor = NO;
    for (int i = 0; i < 8; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *a = d.colorAttachments[i];
        if (a.pixelFormat != MTLPixelFormatInvalid && a.writeMask != MTLColorWriteMaskNone) anyColor = YES;
    }
    if (!anyColor && d.depthAttachmentPixelFormat != MTLPixelFormatInvalid) t |= 1ull << 1;
    return t;
}
typedef id (*newPipe_t)(id, SEL, MTLRenderPipelineDescriptor *, NSError **);
static newPipe_t o_newPipe;
static id my_newPipe(id self, SEL c, MTLRenderPipelineDescriptor *d, NSError **e) {
    id p = o_newPipe(self, c, d, e);
    if (p) keepSrc(p, d);
    if (p) { uint64_t t = pipeTag(d); setTag(p, t); static int k; if (k++ < 5) DL("pipeline %p tag=0x%llx", p, t); }
    return p;
}
typedef void (*newPipeAsync_t)(id, SEL, MTLRenderPipelineDescriptor *, MTLNewRenderPipelineStateCompletionHandler);
static newPipeAsync_t o_newPipeAsync;
static void my_newPipeAsync(id self, SEL c, MTLRenderPipelineDescriptor *d, MTLNewRenderPipelineStateCompletionHandler h) {
    uint64_t t = pipeTag(d);
    MTLRenderPipelineDescriptor *dc = [d copy];
    o_newPipeAsync(self, c, d, ^(id<MTLRenderPipelineState> p, NSError *e) { if (p) { setTag(p, t); keepSrc(p, dc); } h(p, e); });
}
typedef id (*newPipeRefl_t)(id, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption, MTLAutoreleasedRenderPipelineReflection *, NSError **);
static newPipeRefl_t o_newPipeRefl;
static id my_newPipeRefl(id self, SEL c, MTLRenderPipelineDescriptor *d, MTLPipelineOption o, MTLAutoreleasedRenderPipelineReflection *r, NSError **e) {
    id p = o_newPipeRefl(self, c, d, o, r, e);
    if (p) { setTag(p, pipeTag(d)); keepSrc(p, d); }
    return p;
}

// recherche guidée parmi les pipelines « neige sur les objets »
static NSMutableArray *sObj; static _Atomic int sBis, sLo, sHi;
static int objIndex(id p) {
    NSNumber *n = objc_getAssociatedObject(p, &kIdxKey);
    if (n) return n.intValue;
    @synchronized (sObj) { n = objc_getAssociatedObject(p, &kIdxKey);
        if (!n) { n = @(sObj.count); [sObj addObject:p]; objc_setAssociatedObject(p, &kIdxKey, n, OBJC_ASSOCIATION_RETAIN_NONATOMIC); } }
    return n.intValue;
}

// encodeur : pipeline courante -> sauter ou non
static char kSkipKey, kMainKey, kSnowObjKey, kCurPipeKey, kCurTagKey, kCurPipeKey2;
typedef id (*newEnc_t)(id, SEL, MTLRenderPassDescriptor *);
static newEnc_t o_newEnc;
static id my_newEnc(id self, SEL c, MTLRenderPassDescriptor *d) {
    id e = o_newEnc(self, c, d);
    id<MTLTexture> z = d.depthAttachment.texture;
    if (e && z) objc_setAssociatedObject(e, &kMainKey, z.width != z.height ? @1 : @2, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return e;
}
typedef struct { uint64_t tag; unsigned long main, square; } PipeStat;
static PipeStat sPS[256]; static int sNPS; static _Atomic int sPSLock;
typedef void (*setPipe_t)(id, SEL, id);
static setPipe_t o_setPipe;
static void my_setPipe(id self, SEL c, id p) {
    int m = atomic_load(&sMode);
    uint64_t t = getTag(p);
    BOOL depthOnly = (t & 2) != 0, snow = (t & 4) != 0;
    int kind = [objc_getAssociatedObject(self, &kMainKey) intValue];   // 1 écran principal, 2 carré, 0 sans profondeur
    BOOL skip = NO;
    if (m > 0 && (m <= 10 || (m >= 16 && m <= 22) || m >= 28)) skip = (t & (1ull << m)) != 0;
    else if (m == 11) skip = depthOnly && snow;
    else if (m == 12) skip = depthOnly && !snow;
    else if (m == 13) skip = depthOnly && kind == 1;
    else if (m == 14) skip = depthOnly && kind == 2;
    else if (m == 15) skip = depthOnly && snow && kind == 1;
    if (gSnowFix && depthOnly && snow && kind == 1) skip = YES;
    if ((t & (1ull << 16)) && p) {
        int idx = objIndex(p), b = atomic_load(&sBis), lo = atomic_load(&sLo), hi = atomic_load(&sHi);
        if (b == 1) { int mid = (lo + hi) / 2; if (idx >= lo && idx < mid) skip = YES; }
        else if (b == 2 && idx == lo) skip = YES;
    }
    objc_setAssociatedObject(self, &kSnowObjKey, (t & (1ull << 16)) ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kSetKey, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kCurPipeKey, (t & (1ull << 16)) ? p : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (depthOnly) {
        int expected = 0;
        if (atomic_compare_exchange_strong(&sPSLock, &expected, 1)) {
            int i = 0; for (; i < sNPS; i++) if (sPS[i].tag == t) break;
            if (i == sNPS && sNPS < 256) { sPS[sNPS].tag = t; sNPS++; }
            if (i < sNPS) { if (kind == 1) sPS[i].main++; else sPS[i].square++; }
            atomic_store(&sPSLock, 0);
        }
    }
    objc_setAssociatedObject(self, &kSkipKey, skip ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kCurTagKey, @(t), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (gDrawSkip || gPaintFix) objc_setAssociatedObject(self, &kCurPipeKey2, (t & (1ull << 28)) ? p : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    o_setPipe(self, c, p);
}
// --- textures de fragment fournies depuis le dernier changement de pipeline
typedef void (*setFT_t)(id, SEL, id, NSUInteger);
static setFT_t o_setFT;
static char kBoundKey;
static NSPointerArray *boundOf(id enc) {
    NSPointerArray *a = objc_getAssociatedObject(enc, &kBoundKey);
    if (!a) { a = [NSPointerArray strongObjectsPointerArray]; a.count = 32; objc_setAssociatedObject(enc, &kBoundKey, a, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    return a;
}
static void my_setFT(id self, SEL c, id tex, NSUInteger idx) {
    if ((gDrawSkip || gPaintFix) && idx < 32) [boundOf(self) replacePointerAtIndex:idx withPointer:(__bridge void *)tex];
    if (idx < 32) { uint32_t m = [objc_getAssociatedObject(self, &kSetKey) unsignedIntValue]; objc_setAssociatedObject(self, &kSetKey, @(m | (1u << idx)), OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    o_setFT(self, c, tex, idx);
}
typedef void (*setFTs_t)(id, SEL, const id __unsafe_unretained *, NSRange);
static setFTs_t o_setFTs;
static void my_setFTs(id self, SEL c, const id __unsafe_unretained *texs, NSRange r) {
    uint32_t m = [objc_getAssociatedObject(self, &kSetKey) unsignedIntValue];
    for (NSUInteger i = r.location; i < r.location + r.length && i < 32; i++) { m |= 1u << i;
        if (gDrawSkip || gPaintFix) [boundOf(self) replacePointerAtIndex:i withPointer:(__bridge void *)texs[i - r.location]]; }
    objc_setAssociatedObject(self, &kSetKey, @(m), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    o_setFTs(self, c, texs, r);
}
static id sBlack2D, sBlackCube;
static NSMutableSet *sReported;
static void frostCheck(id enc) {
    id p = objc_getAssociatedObject(enc, &kCurPipeKey); if (!p) return;
    NSArray *info = objc_getAssociatedObject(p, &kSlotKey); if (!info) return;
    uint32_t need = [info[0] unsignedIntValue], have = [objc_getAssociatedObject(enc, &kSetKey) unsignedIntValue], miss = need & ~have;
    if (!miss) return;
    NSArray *names = info[1]; int idx = [objc_getAssociatedObject(p, &kIdxKey) intValue];
    NSString *key = [NSString stringWithFormat:@"%d/%x", idx, miss];
    BOOL first; @synchronized (sReported) { first = ![sReported containsObject:key]; if (first) [sReported addObject:key]; }
    if (first) { NSMutableString *l = [NSMutableString string];
        for (int i = 0; i < 32; i++) if (miss & (1u << i)) [l appendFormat:@" %d:%@", i, names[i]];
        DL("textures NON fournies par le jeu, pipeline neige n°%d :%s", idx, l.UTF8String); }
    int m = atomic_load(&sMode);
    if (gFrostGuard || m == 27) for (int i = 0; i < 32; i++) if (miss & (1u << i)) {
        NSString *n = names[i];
        BOOL cube = [n rangeOfString:@"Probe"].location != NSNotFound;
        o_setFT(enc, @selector(setFragmentTexture:atIndex:), cube ? sBlackCube : sBlack2D, i);
    }
}

// --- neige des fenêtres : départager la couche de neige et la fenêtre (z-fighting)
static char kDescKey, kVarKey, kDSSKey, kBiasKey;
static _Atomic unsigned long sSnowObjCmp[8];
typedef id (*newDSS_t)(id, SEL, MTLDepthStencilDescriptor *);
static newDSS_t o_newDSS;
static id my_newDSS(id self, SEL c, MTLDepthStencilDescriptor *d) {
    id st = o_newDSS(self, c, d);
    if (st) objc_setAssociatedObject(st, &kDescKey, [d copy], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return st;
}
typedef void (*setDSS_t)(id, SEL, id);
static setDSS_t o_setDSS;
static void my_setDSS(id self, SEL c, id st) {
    objc_setAssociatedObject(self, &kDSSKey, st, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    o_setDSS(self, c, st);
}
typedef void (*setBias_t)(id, SEL, float, float, float);
static setBias_t o_setBias;
static void my_setBias(id self, SEL c, float b, float sl, float cl) {
    float v[3] = { b, sl, cl };
    objc_setAssociatedObject(self, &kBiasKey, [NSData dataWithBytes:v length:sizeof v], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    o_setBias(self, c, b, sl, cl);
}
static id variantOf(id st) {
    if (!st) return nil;
    id v = objc_getAssociatedObject(st, &kVarKey);
    if (v) return v == (id)[NSNull null] ? nil : v;
    MTLDepthStencilDescriptor *d = objc_getAssociatedObject(st, &kDescKey);
    if (d && (d.depthCompareFunction == MTLCompareFunctionLess || d.depthCompareFunction == MTLCompareFunctionEqual)) {
        MTLDepthStencilDescriptor *n = [d copy]; n.depthCompareFunction = MTLCompareFunctionLessEqual;
        v = o_newDSS([(id<MTLDepthStencilState>)st device], @selector(newDepthStencilStateWithDescriptor:), n);
    }
    objc_setAssociatedObject(st, &kVarKey, v ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return v;
}
static int winLevel(void) { int m = atomic_load(&sMode); return (m >= 23 && m <= 26) ? m - 22 : gWinFix; }
static int preWin(id enc) {
    if (!objc_getAssociatedObject(enc, &kSnowObjKey)) return 0;
    frostCheck(enc);
    id st = objc_getAssociatedObject(enc, &kDSSKey);
    MTLDepthStencilDescriptor *d = st ? objc_getAssociatedObject(st, &kDescKey) : nil;
    if (d) atomic_fetch_add(&sSnowObjCmp[d.depthCompareFunction & 7], 1);
    int lvl = winLevel(); if (!lvl || !o_setDSS || !o_setBias) return 0;
    id v = variantOf(st); if (v) o_setDSS(enc, @selector(setDepthStencilState:), v);
    static const float B[5] = { 0, 0, -100, -1000, -10000 }, S[5] = { 0, 0, -1, -2, -4 };
    if (lvl >= 2) o_setBias(enc, @selector(setDepthBias:slopeScale:clamp:), B[lvl], S[lvl], 0);
    { static int k; if (k++ < 5) DL("fenêtres : niveau %d, test %s, décalage %g/%g", lvl, v ? "assoupli" : "inchangé", B[lvl], S[lvl]); }
    return 1;
}
static void postWin(id enc) {
    id st = objc_getAssociatedObject(enc, &kDSSKey);
    if (st) o_setDSS(enc, @selector(setDepthStencilState:), st);
    NSData *bv = objc_getAssociatedObject(enc, &kBiasKey); float z[3] = { 0, 0, 0 };
    const float *v = bv ? bv.bytes : z;
    o_setBias(enc, @selector(setDepthBias:slopeScale:clamp:), v[0], v[1], v[2]);
}

// --- traceur peinture : textures WeightMap (contenu des envois, relectures GPU)
static NSHashTable *sWeightSeen; static char kShadowKey; static _Atomic unsigned long sMerges;
typedef void (*gb_t)(id, SEL, void *, NSUInteger, MTLRegion, NSUInteger);
static gb_t o_gb;
static void zoneStats(const uint8_t *p, NSUInteger w, NSUInteger h, NSUInteger bpr, NSUInteger bpp, char *out, size_t n) {
    unsigned long nz = 0; NSUInteger x0 = w, y0 = h, x1 = 0, y1 = 0;
    for (NSUInteger y = 0; y < h; y++) { const uint8_t *r = p + y * bpr;
        for (NSUInteger x = 0; x < w; x++) { BOOL any = NO; for (NSUInteger k = 0; k < bpp; k++) if (r[x * bpp + k]) { any = YES; break; }
            if (any) { nz++; if (x < x0) x0 = x; if (y < y0) y0 = y; if (x > x1) x1 = x; if (y > y1) y1 = y; } } }
    if (nz) snprintf(out, n, "%lu/%lu points peints, zone x %lu-%lu y %lu-%lu", nz, (unsigned long)(w * h), (unsigned long)x0, (unsigned long)x1, (unsigned long)y0, (unsigned long)y1);
    else snprintf(out, n, "0/%lu points peints (vide)", (unsigned long)(w * h));
}
static NSUInteger bppOf(MTLPixelFormat f) { return f == MTLPixelFormatR8Unorm || f == MTLPixelFormatA8Unorm ? 1 : f == MTLPixelFormatRG8Unorm ? 2 : 4; }
static void weightSeen(id enc) {
    id p = objc_getAssociatedObject(enc, &kCurPipeKey2); if (!p) return;
    NSArray *info = objc_getAssociatedObject(p, &kSlotKey); if (!info) return;
    NSUInteger slot = [info[1] indexOfObject:@"WeightMap"]; if (slot == NSNotFound || slot >= 32) return;
    id<MTLTexture> t = (__bridge id)[boundOf(enc) pointerAtIndex:slot]; if (!t) return;
    BOOL first; @synchronized (sWeightSeen) { first = ![sWeightSeen containsObject:t]; if (first) [sWeightSeen addObject:t]; }
    if (!first) return;
    char st[160] = "contenu illisible (texture privée)";
    if (t.storageMode != MTLStorageModePrivate && t.width <= 4096 && t.height <= 4096) {
        NSUInteger b = bppOf(t.pixelFormat), bpr = t.width * b; NSMutableData *buf = [NSMutableData dataWithLength:bpr * t.height];
        if (o_gb) o_gb(t, @selector(getBytes:bytesPerRow:fromRegion:mipmapLevel:), buf.mutableBytes, bpr, MTLRegionMake2D(0, 0, t.width, t.height), 0);
        else [t getBytes:buf.mutableBytes bytesPerRow:bpr fromRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0];
        zoneStats(buf.bytes, t.width, t.height, bpr, b, st, sizeof st);
        if (gPaintFix) objc_setAssociatedObject(t, &kShadowKey, buf, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    DL("[%.2f] WeightMap AFFICHÉE (nouvelle) %p %lux%lu fmt=%lu stockage=%lu usage=0x%lx : %s", CFAbsoluteTimeGetCurrent(), t,
       (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)t.storageMode, (unsigned long)t.usage, st);
}
// Fusion : le moteur Mac envoie une WeightMap ne contenant que le coup de pinceau en cours.
// On garde une copie complète ; les points vides de l'envoi reprennent la peinture précédente.
static NSData *mergeWeights(id<MTLTexture> t, MTLRegion r, const void *bytes, NSUInteger bpr, NSUInteger *outBpr) {
    NSMutableData *sh = objc_getAssociatedObject(t, &kShadowKey);
    NSUInteger b = bppOf(t.pixelFormat), W = t.width;
    if (!sh || sh.length != W * t.height * b || r.origin.x + r.size.width > W || r.origin.y + r.size.height > t.height) return nil;
    NSUInteger ob = r.size.width * b; NSMutableData *out = [NSMutableData dataWithLength:ob * r.size.height];
    uint8_t *o = out.mutableBytes, *shp = sh.mutableBytes; const uint8_t *src = bytes;
    unsigned long kept = 0, fresh = 0;
    for (NSUInteger y = 0; y < r.size.height; y++) {
        const uint8_t *s = src + y * bpr; uint8_t *d = o + y * ob; uint8_t *h = shp + ((r.origin.y + y) * W + r.origin.x) * b;
        for (NSUInteger x = 0; x < r.size.width; x++) {
            BOOL any = NO; for (NSUInteger k = 0; k < b; k++) if (s[x * b + k]) { any = YES; break; }
            if (any) { memcpy(d + x * b, s + x * b, b); memcpy(h + x * b, s + x * b, b); fresh++; }
            else { memcpy(d + x * b, h + x * b, b); BOOL hk = NO; for (NSUInteger k = 0; k < b; k++) if (h[x * b + k]) { hk = YES; break; } if (hk) kept++; }
        }
    }
    unsigned long n = atomic_fetch_add(&sMerges, 1);
    if (n < 40 || n % 200 == 0) DL("[%.2f] FUSION WeightMap %p : %lu points du coup en cours + %lu points de peinture conservés", CFAbsoluteTimeGetCurrent(), t, fresh, kept);
    *outBpr = ob; return out;
}
typedef void (*rr_t)(id, SEL, MTLRegion, NSUInteger, NSUInteger, const void *, NSUInteger, NSUInteger);
static rr_t o_rrs;
static void my_rrs(id self, SEL c, MTLRegion r, NSUInteger lvl, NSUInteger slice, const void *bytes, NSUInteger bpr, NSUInteger bpi) {
    BOOL known; @synchronized (sWeightSeen) { known = [sWeightSeen containsObject:self]; }
    if (known && gDrawSkip && bytes && lvl == 0) { char st[160]; zoneStats(bytes, r.size.width, r.size.height, bpr, bppOf(((id<MTLTexture>)self).pixelFormat), st, sizeof st);
        DL("[%.2f] ENVOI vers WeightMap %p région (%lu,%lu %lux%lu) : %s", CFAbsoluteTimeGetCurrent(), self, (unsigned long)r.origin.x, (unsigned long)r.origin.y,
           (unsigned long)r.size.width, (unsigned long)r.size.height, st); }
    if (known && gPaintFix && bytes && lvl == 0 && slice == 0) { NSUInteger ob; NSData *m = mergeWeights(self, r, bytes, bpr, &ob);
        if (m) { o_rrs(self, c, r, lvl, slice, m.bytes, ob, ob * r.size.height); return; } }
    o_rrs(self, c, r, lvl, slice, bytes, bpr, bpi);
}
typedef void (*rr1_t)(id, SEL, MTLRegion, NSUInteger, const void *, NSUInteger);
static rr1_t o_rr1;
static void my_rr1(id self, SEL c, MTLRegion r, NSUInteger lvl, const void *bytes, NSUInteger bpr) {
    BOOL known; @synchronized (sWeightSeen) { known = [sWeightSeen containsObject:self]; }
    if (known && gDrawSkip && bytes && lvl == 0) { char st[160]; zoneStats(bytes, r.size.width, r.size.height, bpr, bppOf(((id<MTLTexture>)self).pixelFormat), st, sizeof st);
        DL("[%.2f] ENVOI vers WeightMap %p région (%lu,%lu %lux%lu) : %s", CFAbsoluteTimeGetCurrent(), self, (unsigned long)r.origin.x, (unsigned long)r.origin.y,
           (unsigned long)r.size.width, (unsigned long)r.size.height, st); }
    if (known && gPaintFix && bytes && lvl == 0) { NSUInteger ob; NSData *m = mergeWeights(self, r, bytes, bpr, &ob);
        if (m) { o_rr1(self, c, r, lvl, m.bytes, ob); return; } }
    o_rr1(self, c, r, lvl, bytes, bpr);
}
static _Atomic unsigned long sReadbacks;
static void my_gb(id self, SEL c, void *out, NSUInteger bpr, MTLRegion r, NSUInteger lvl) {
    o_gb(self, c, out, bpr, r, lvl);
    unsigned long n = atomic_fetch_add(&sReadbacks, 1);
    if (n < 200) { id<MTLTexture> t = self; char st[160] = "";
        if (out && lvl == 0) zoneStats(out, r.size.width, r.size.height, bpr, bppOf(t.pixelFormat), st, sizeof st);
        DL("[%.2f] RELECTURE GPU->CPU getBytes %p %lux%lu fmt=%lu région %lux%lu : %s", CFAbsoluteTimeGetCurrent(), t, (unsigned long)t.width, (unsigned long)t.height,
           (unsigned long)t.pixelFormat, (unsigned long)r.size.width, (unsigned long)r.size.height, st); }
}
typedef void (*ctb_t)(id, SEL, id, NSUInteger, NSUInteger, MTLOrigin, MTLSize, id, NSUInteger, NSUInteger, NSUInteger);
static ctb_t o_ctb;
static void my_ctb(id self, SEL c, id<MTLTexture> t, NSUInteger sl, NSUInteger lv, MTLOrigin o, MTLSize sz, id buf, NSUInteger off, NSUInteger bpr, NSUInteger bpi) {
    unsigned long n = atomic_fetch_add(&sReadbacks, 1);
    if (n < 200) DL("[%.2f] RELECTURE GPU copyFromTexture->buffer %p %lux%lu fmt=%lu taille %lux%lu", CFAbsoluteTimeGetCurrent(), t, (unsigned long)t.width,
                    (unsigned long)t.height, (unsigned long)t.pixelFormat, (unsigned long)sz.width, (unsigned long)sz.height);
    o_ctb(self, c, t, sl, lv, o, sz, buf, off, bpr, bpi);
}

static inline BOOL skipping(id enc) {
    atomic_fetch_add(&sDraws, 1);
    { uint64_t t = [objc_getAssociatedObject(enc, &kCurTagKey) unsignedLongLongValue];
      for (int g = 28; g < 34; g++) if (t & (1ull << g)) atomic_fetch_add(&sGrpDraws[g], 1);
      if ((gDrawSkip || gPaintFix) && (t & (1ull << 28))) weightSeen(enc); }
    if ((atomic_load(&sMode) || gSnowFix) && objc_getAssociatedObject(enc, &kSkipKey)) { atomic_fetch_add(&sSkipped, 1); return YES; }
    return NO;
}
typedef void (*d1_t)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger);
static d1_t o_d1;
static void my_d1(id s, SEL c, MTLPrimitiveType t, NSUInteger a, NSUInteger b) { if (skipping(s)) return; int w = preWin(s); o_d1(s, c, t, a, b); if (w) postWin(s); }
typedef void (*d2_t)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger);
static d2_t o_d2;
static void my_d2(id s, SEL c, MTLPrimitiveType t, NSUInteger a, NSUInteger b, NSUInteger n) { if (skipping(s)) return; int w = preWin(s); o_d2(s, c, t, a, b, n); if (w) postWin(s); }
typedef void (*d3_t)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger);
static d3_t o_d3;
static void my_d3(id s, SEL c, MTLPrimitiveType t, NSUInteger n, MTLIndexType it, id b, NSUInteger o) { if (skipping(s)) return; int w = preWin(s); o_d3(s, c, t, n, it, b, o); if (w) postWin(s); }
typedef void (*d4_t)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger, NSUInteger);
static d4_t o_d4;
static void my_d4(id s, SEL c, MTLPrimitiveType t, NSUInteger n, MTLIndexType it, id b, NSUInteger o, NSUInteger k) { if (skipping(s)) return; int w = preWin(s); o_d4(s, c, t, n, it, b, o, k); if (w) postWin(s); }
typedef void (*d5_t)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger, NSUInteger, NSInteger, NSUInteger);
static d5_t o_d5;
static void my_d5(id s, SEL c, MTLPrimitiveType t, NSUInteger n, MTLIndexType it, id b, NSUInteger o, NSUInteger k, NSInteger bv, NSUInteger bi) { if (skipping(s)) return; int w = preWin(s); o_d5(s, c, t, n, it, b, o, k, bv, bi); if (w) postWin(s); }

static void swz(Class c, SEL s, IMP n, IMP *o) {
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) { DL("hook absent : %s sur %s", sel_getName(s), c ? class_getName(c) : "?"); return; }
    *o = method_getImplementation(m); method_setImplementation(m, n);
    DL("hook : %s sur %s", sel_getName(s), class_getName(c));
}

static void announce(void) {
    int m = atomic_load(&sMode);
    DL("[%.1f s] MODE %d : %s supprimés (dessins sautés jusqu'ici : %lu / %lu)", CFAbsoluteTimeGetCurrent(), m, kGroups[m].name,
       atomic_load(&sSkipped), atomic_load(&sDraws));
    for (int i = 0; i < sNPS; i++) DL("   pipelines profondeur seule tag=0x%llx : écran principal %lu, carrées %lu", sPS[i].tag, sPS[i].main, sPS[i].square);
    DL("   neige des fenêtres : dessins par test de profondeur Never/Less/Equal/LessEqual/Greater/NotEqual/GreaterEqual/Always = %lu/%lu/%lu/%lu/%lu/%lu/%lu/%lu",
       sSnowObjCmp[0], sSnowObjCmp[1], sSnowObjCmp[2], sSnowObjCmp[3], sSnowObjCmp[4], sSnowObjCmp[5], sSnowObjCmp[6], sSnowObjCmp[7]);
    NSString *say = m ? [NSString stringWithFormat:@"%d. %s", m, kGroups[m].name] : @"zero. tout normal";
    NSTask *t = [NSTask new]; t.launchPath = @"/usr/bin/say"; t.arguments = @[ say ];
    @try { [t launch]; } @catch (...) {}
}

static void say(NSString *t) {
    NSTask *x = [NSTask new]; x.launchPath = @"/usr/bin/say"; x.arguments = @[ t ];
    @try { [x launch]; } @catch (...) {}
}
static void bisectKey(NSString *k) {
    int lo = atomic_load(&sLo), hi = atomic_load(&sHi), n;
    @synchronized (sObj) { n = (int)sObj.count; }
    if ([k isEqualToString:@"b"]) { atomic_store(&sMode, 0); lo = 0; hi = n; atomic_store(&sBis, 1); }
    else if (atomic_load(&sBis) != 1) return;
    else { int mid = (lo + hi) / 2; if ([k isEqualToString:@"1"]) lo = mid; else hi = mid; }
    atomic_store(&sLo, lo); atomic_store(&sHi, hi);
    DL("recherche : candidats [%d, %d) sur %d (touche %s)", lo, hi, n, k.UTF8String);
    if (hi - lo <= 1) {
        atomic_store(&sBis, 2);
        id p; @synchronized (sObj) { p = lo < (int)sObj.count ? sObj[lo] : nil; }
        NSString *src = p ? objc_getAssociatedObject(p, &kPSrcKey) : nil;
        NSString *path = [NSString stringWithFormat:@"/tmp/ts3_coupable_%d.metal", lo];
        [(src ?: @"source introuvable") writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        DL("TROUVÉ : pipeline n°%d -> %s (seul ce shader est maintenant supprimé)", lo, path.UTF8String);
        say(@"Trouvé. Seule cette neige est enlevée. Vérifie les fenêtres.");
    } else say([NSString stringWithFormat:@"%d candidats. Si ça clignote encore, contrôle option 1. Sinon, contrôle option 2.", hi - lo]);
}

static void *counters(void *u) {
    unsigned long last[64] = {0};
    for (;;) { sleep(2);
        NSMutableString *l = [NSMutableString string];
        for (int g = 28; g < 34; g++) { unsigned long v = atomic_load(&sGrpDraws[g]); [l appendFormat:@" %s=%lu", kGroups[g].name, v - last[g]]; last[g] = v; }
        DL("[%.0f] dessins/2s :%s", CFAbsoluteTimeGetCurrent(), l.UTF8String); }
    return NULL;
}
void TS3DrawSkipInit(void) {
    sObj = [NSMutableArray new];
    if (gDrawSkip) { pthread_t th; pthread_create(&th, NULL, counters, NULL); pthread_detach(th); }
    sWeightSeen = [NSHashTable weakObjectsHashTable];
    DL("=== bissection des dessins : Ctrl+Option+N suivant, P précédent, 0 normal ===");
    for (int i = 0; i < NG; i++) DL("  groupe %d : %s", i, kGroups[i].name);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    Class dc = object_getClass(dev);
    swz(dc, @selector(newLibraryWithSource:options:error:), (IMP)my_libSrc, (IMP *)&o_libSrc);
    swz(dc, @selector(newDepthStencilStateWithDescriptor:), (IMP)my_newDSS, (IMP *)&o_newDSS);
    swz(dc, @selector(newLibraryWithSource:options:completionHandler:), (IMP)my_libSrcAsync, (IMP *)&o_libSrcAsync);
    swz(dc, @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)my_newPipe, (IMP *)&o_newPipe);
    swz(dc, @selector(newRenderPipelineStateWithDescriptor:completionHandler:), (IMP)my_newPipeAsync, (IMP *)&o_newPipeAsync);
    swz(dc, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:), (IMP)my_newPipeRefl, (IMP *)&o_newPipeRefl);
    id<MTLLibrary> lib = [dev newLibraryWithSource:@"vertex float4 v(){return 0;}" options:nil error:nil];
    if (lib) swz(object_getClass(lib), @selector(newFunctionWithName:), (IMP)my_newFn, (IMP *)&o_newFn);
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
    id<MTLRenderCommandEncoder> e = [[[dev newCommandQueue] commandBuffer] renderCommandEncoderWithDescriptor:rp];
    Class ec = object_getClass(e);
    { id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
      swz(object_getClass(cb), @selector(renderCommandEncoderWithDescriptor:), (IMP)my_newEnc, (IMP *)&o_newEnc); }
    swz(ec, @selector(setRenderPipelineState:), (IMP)my_setPipe, (IMP *)&o_setPipe);
    swz(ec, @selector(setDepthStencilState:), (IMP)my_setDSS, (IMP *)&o_setDSS);
    swz(ec, @selector(setFragmentTexture:atIndex:), (IMP)my_setFT, (IMP *)&o_setFT);
    if (gDrawSkip || gPaintFix) {
        MTLTextureDescriptor *td2 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:4 height:4 mipmapped:NO];
        id<MTLTexture> tx = [dev newTextureWithDescriptor:td2];
        swz(object_getClass(tx), @selector(replaceRegion:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:), (IMP)my_rrs, (IMP *)&o_rrs);
        swz(object_getClass(tx), @selector(replaceRegion:mipmapLevel:withBytes:bytesPerRow:), (IMP)my_rr1, (IMP *)&o_rr1);
        swz(object_getClass(tx), @selector(getBytes:bytesPerRow:fromRegion:mipmapLevel:), (IMP)my_gb, (IMP *)&o_gb);
        id<MTLBlitCommandEncoder> be = [[[dev newCommandQueue] commandBuffer] blitCommandEncoder];
        swz(object_getClass(be), @selector(copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:), (IMP)my_ctb, (IMP *)&o_ctb);
        [be endEncoding];
    }
    swz(ec, @selector(setFragmentTextures:withRange:), (IMP)my_setFTs, (IMP *)&o_setFTs);
    { sReported = [NSMutableSet new]; uint32_t px = 0;
      MTLTextureDescriptor *b = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
      sBlack2D = [dev newTextureWithDescriptor:b]; [sBlack2D replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&px bytesPerRow:4];
      MTLTextureDescriptor *cb2 = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm size:1 mipmapped:NO];
      sBlackCube = [dev newTextureWithDescriptor:cb2];
      for (int f = 0; f < 6; f++) [sBlackCube replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 slice:f withBytes:&px bytesPerRow:4 bytesPerImage:4]; }
    swz(ec, @selector(setDepthBias:slopeScale:clamp:), (IMP)my_setBias, (IMP *)&o_setBias);
    swz(ec, @selector(drawPrimitives:vertexStart:vertexCount:), (IMP)my_d1, (IMP *)&o_d1);
    swz(ec, @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:), (IMP)my_d2, (IMP *)&o_d2);
    swz(ec, @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:), (IMP)my_d3, (IMP *)&o_d3);
    swz(ec, @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:), (IMP)my_d4, (IMP *)&o_d4);
    swz(ec, @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:), (IMP)my_d5, (IMP *)&o_d5);
    [e endEncoding];
    if (!gDrawSkip) { if (gSnowFix) atomic_store(&sMode, 15); DL("correctifs actifs : murs=%d fenêtres=%d givre=%d", gSnowFix, gWinFix, gFrostGuard); return; }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *ev) {
            NSEventModifierFlags f = ev.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
            if ((f & NSEventModifierFlagControl) && (f & NSEventModifierFlagOption)) {
                NSString *k = ev.charactersIgnoringModifiers.lowercaseString;
                int m = atomic_load(&sMode);
                if ([k isEqualToString:@"n"]) m = (m + 1) % NG;
                else if ([k isEqualToString:@"p"]) m = (m + NG - 1) % NG;
                else if ([k isEqualToString:@"0"]) { m = 0; atomic_store(&sBis, 0); }
                else if ([k isEqualToString:@"b"] || [k isEqualToString:@"1"] || [k isEqualToString:@"2"]) { bisectKey(k); return nil; }
                else return ev;
                atomic_store(&sMode, m); announce();
                return nil;
            }
            return ev;
        }];
        DL("raccourcis clavier actifs");
    });
}
