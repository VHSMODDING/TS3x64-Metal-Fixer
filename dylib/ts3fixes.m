// TS3 Mac Fixer — dylib pilotée par config. Lit ~/Library/Application Support/TS3MacFixes/ts3fixes.conf :
//   fullscreen= / resolution= / aniso= / buffering=  (absente => tout activé).
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <string.h>
#import <fcntl.h>
#import <unistd.h>
#import "fishhook.h"

static int gFull=1, gRes=1, gAniso=1, gBuffer=1, gSS=0;  // supersampling off par défaut
static double gSSFactor=1.5;
extern void TS3MetalTraceEnable(void);
static int gMetalTrace=0;
extern int gDepthClamp,gLoadFix,gAudioDiag,gAudioFix,gAudioBuf,gClearFix,gAudioLP,gUpTrace,gMtlVal; extern void TS3UpTraceInit(void); extern char gAudioPrio[64]; extern void TS3LabInit(void);
static FILE*gLog; static void LG(const char*fmt,...){ if(!gLog)gLog=fopen("/tmp/ts3_gfx.log","a"); if(gLog){va_list a;va_start(a,fmt);vfprintf(gLog,fmt,a);va_end(a);fputc('\n',gLog);fflush(gLog);} }
static void readConf(void){
  const char*home=getenv("HOME"); if(!home) return;
  char path[2048];
  snprintf(path,sizeof(path),"%s/Library/Application Support/TS3MacFixes/ts3fixes.conf",home);
  FILE*f=fopen(path,"r"); if(!f) return;
  char line[256];
  while(fgets(line,sizeof(line),f)){
    if(strstr(line,"fullscreen=0")) gFull=0; else if(strstr(line,"fullscreen=1")) gFull=1;
    if(strstr(line,"resolution=0")) gRes=0; else if(strstr(line,"resolution=1")) gRes=1;
    if(strstr(line,"aniso=0")) gAniso=0; else if(strstr(line,"aniso=1")) gAniso=1;
    if(strstr(line,"buffering=0")) gBuffer=0; else if(strstr(line,"buffering=1")) gBuffer=1;
    if(strstr(line,"ss=0")) gSS=0; else if(strstr(line,"ss=1")) gSS=1;
    { int v; if(sscanf(line,"loadfix=%d",&v)==1) gLoadFix=v; if(sscanf(line,"audiodiag=%d",&v)==1) gAudioDiag=v;
      if(sscanf(line,"audiofix=%d",&v)==1) gAudioFix=v; if(sscanf(line,"audiobuf=%d",&v)==1) gAudioBuf=v;
      if(sscanf(line,"clearfix=%d",&v)==1) gClearFix=v; if(sscanf(line,"audioprio=%63[^\n]",gAudioPrio)!=1 && strncmp(line,"audioprio=",10)==0) gAudioPrio[0]=0; extern char gBoost[128]; extern int gAudioRec, gAudioLP; if(sscanf(line,"audiolp=%d",&v)==1) gAudioLP=v; if(sscanf(line,"uptrace=%d",&v)==1) gUpTrace=v; if(sscanf(line,"mtlval=%d",&v)==1) gMtlVal=v; if(sscanf(line,"depthclamp=%d",&v)==1) gDepthClamp=v; if(sscanf(line,"audiorec=%d",&v)==1) gAudioRec=v; if(sscanf(line,"boost=%127[^\n]",gBoost)!=1 && strncmp(line,"boost=",6)==0) gBoost[0]=0; }
    if(strstr(line,"metaltrace=0")) gMetalTrace=0; else if(strstr(line,"metaltrace=1")) gMetalTrace=1;
  }
  fclose(f);
}
// --- résolutions : pixel -> logique (+1728x1117) ---
static size_t(*o_W)(CGDisplayModeRef),(*o_H)(CGDisplayModeRef),(*o_PW)(CGDisplayModeRef),(*o_PH)(CGDisplayModeRef);
static void lo(CGDisplayModeRef m,size_t*w,size_t*h){size_t lw=o_W(m),lh=o_H(m); if(lw==1800&&lh==1169){lw=1728;lh=1117;} *w=lw;*h=lh;}
static size_t my_PW(CGDisplayModeRef m){size_t w,h;lo(m,&w,&h);return w;}
static size_t my_PH(CGDisplayModeRef m){size_t w,h;lo(m,&w,&h);return h;}
// --- plein écran : fenêtre TITRÉE couvrant l'écran, barre masquée ---
static BOOL gInFS=NO; static NSRect gSaved;
static void setButtons(NSWindow*w,BOOL hidden){
  @try{ [w standardWindowButton:NSWindowCloseButton].hidden=hidden;
        [w standardWindowButton:NSWindowMiniaturizeButton].hidden=hidden;
        [w standardWindowButton:NSWindowZoomButton].hidden=hidden; }@catch(...){}
}
static void goFull(NSWindow*w){ NSScreen*s=w.screen?:[NSScreen mainScreen]; gSaved=w.frame; gInFS=YES;
  [NSApp setPresentationOptions:NSApplicationPresentationHideDock|NSApplicationPresentationHideMenuBar];
  @try{ w.styleMask = w.styleMask | NSWindowStyleMaskFullSizeContentView;
        w.titlebarAppearsTransparent=YES; w.titleVisibility=NSWindowTitleHidden; }@catch(...){}
  setButtons(w,YES);
  [w setFrame:s.frame display:YES]; [w makeKeyAndOrderFront:nil]; }
static void goWin(NSWindow*w){ gInFS=NO; [NSApp setPresentationOptions:NSApplicationPresentationDefault];
  @try{ w.styleMask = w.styleMask & ~NSWindowStyleMaskFullSizeContentView;
        w.titlebarAppearsTransparent=NO; w.titleVisibility=NSWindowTitleVisible; }@catch(...){}
  setButtons(w,NO);
  [w setFrame:gSaved display:YES]; }
static void my_toggle(id self,SEL _cmd,id s){ if(!gInFS)goFull((NSWindow*)self); else goWin((NSWindow*)self); }
static void swz(const char*cls,SEL s,IMP ni){ Class c=objc_getClass(cls); if(!c)return; Method m=class_getInstanceMethod(c,s); if(!m)return; method_setImplementation(m,ni); }
static void swzc(Class c,SEL s,IMP ni){ if(!c)return; Method m=class_getInstanceMethod(c,s); if(!m)return; method_setImplementation(m,ni); }

// --- filtrage anisotrope : force maxAnisotropy=16 sur les samplers de texture linéaires ---
static id(*o_newSampler)(id,SEL,id);
static int gAnisoApplied=0;
static id my_newSampler(id self,SEL _cmd,id desc){
  @try{ MTLSamplerDescriptor*d=(MTLSamplerDescriptor*)desc;
    if(d.maxAnisotropy<=1 && d.minFilter==MTLSamplerMinMagFilterLinear && d.magFilter==MTLSamplerMinMagFilterLinear){
      d.maxAnisotropy=16; if(gAnisoApplied++<3) LG("aniso: sampler linéaire -> maxAnisotropy 16"); }
  }@catch(...){}
  return o_newSampler(self,_cmd,desc);
}
// --- triple buffering : force maximumDrawableCount>=3 ---
static void(*o_setMDC)(id,SEL,NSUInteger);
static void my_setMDC(id self,SEL _cmd,NSUInteger n){ NSUInteger v=n<3?3:n; static int k=0; if(k++<3) LG("buffering: maximumDrawableCount %lu -> %lu",(unsigned long)n,(unsigned long)v); o_setMDC(self,_cmd,v); }
// --- supersampling : agrandit le drawable (rendu > écran, réduit par le calque) ---
static void(*o_setDS)(id,SEL,CGSize);
static void my_setDS(id self,SEL _cmd,CGSize s){ CGSize n=s; n.width=s.width*gSSFactor; n.height=s.height*gSSFactor;
  static int k=0; if(k++<3) LG("ss: drawable %.0fx%.0f -> %.0fx%.0f",s.width,s.height,n.width,n.height); o_setDS(self,_cmd,n); }

__attribute__((constructor)) static void init(void){
  readConf();
  if(gMtlVal){ setenv("MTL_DEBUG_LAYER","1",1); setenv("MTL_DEBUG_LAYER_ERROR_MODE","nslog",1);
    setenv("MTL_DEBUG_LAYER_WARNING_MODE","nslog",1); setenv("METAL_DEVICE_WRAPPER_TYPE","1",1);
    int fd=open("/tmp/ts3_metal_validation.log",O_WRONLY|O_CREAT|O_TRUNC,0644); if(fd>=0){ dup2(fd,2); close(fd);} }
  LG("=== gfx init: full=%d res=%d aniso=%d buffer=%d ===",gFull,gRes,gAniso,gBuffer);
  if(gRes){ o_W=(void*)CGDisplayModeGetWidth; o_H=(void*)CGDisplayModeGetHeight;
    struct rebinding rb[2]={{"CGDisplayModeGetPixelWidth",(void*)my_PW,(void**)&o_PW},{"CGDisplayModeGetPixelHeight",(void*)my_PH,(void**)&o_PH}};
    rebind_symbols(rb,2); }
  if(gFull){ swz("Sims4Window",@selector(toggleFullScreen:),(IMP)my_toggle); }
  if(gAniso){ id<MTLDevice> dev=MTLCreateSystemDefaultDevice();
    if(dev){ Class dc=object_getClass(dev); Method m=class_getInstanceMethod(dc,@selector(newSamplerStateWithDescriptor:));
      if(m){ o_newSampler=(id(*)(id,SEL,id))method_getImplementation(m); method_setImplementation(m,(IMP)my_newSampler); LG("aniso: hook sampler sur %s",class_getName(dc)); } } }
  if(gBuffer){ Class cml=objc_getClass("CAMetalLayer");
    if(cml){ Method m=class_getInstanceMethod(cml,@selector(setMaximumDrawableCount:));
      if(m){ o_setMDC=(void(*)(id,SEL,NSUInteger))method_getImplementation(m); method_setImplementation(m,(IMP)my_setMDC); LG("buffering: hook CAMetalLayer"); } } }
  if(gSS){ Class cml=objc_getClass("CAMetalLayer");
    if(cml){ Method m=class_getInstanceMethod(cml,@selector(setDrawableSize:));
      if(m){ o_setDS=(void(*)(id,SEL,CGSize))method_getImplementation(m); method_setImplementation(m,(IMP)my_setDS); LG("ss: hook drawableSize (x%.2f)",gSSFactor); } } }
  if(gMetalTrace) TS3MetalTraceEnable();
  if(gUpTrace) TS3UpTraceInit();
  if(gLoadFix||gAudioDiag||gAudioFix||gClearFix||gAudioLP||gDepthClamp) TS3LabInit();
}
