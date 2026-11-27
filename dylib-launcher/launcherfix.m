// TS3 Launcher Fix — corrige le launcher Mac de Les Sims 3 sur macOS moderne.
//
// 1) Crash (SIGILL / exception ObjC) en affichant les listes Téléchargements /
//    Chargements / Contenu installé : ItemContainer tableView:objectValueForTableColumn:row:
//    encode une NSImage avec +[NSArchiver archivedDataWithRootObject:] (archive
//    non "keyed"). Depuis macOS 11, -[NSImage encodeWithCoder:] lève
//    _NSRequestConcreteObject dans ce cas -> exception non rattrapée pendant le
//    dessin de la NSTableView. Les deux seuls sites d'archivage et les deux
//    seuls sites de désarchivage sont dans le même processus (data source ->
//    NewImageCell/NewPreviewTextFieldCell setObjectValue:), donc on remplace
//    l'archive par un jeton opaque et on rend l'objet d'origine au désarchivage.
//
// 2) Boutons "Afficher le fichier" : NSWorkspace selectFile:inFileViewerRootedAtPath:
//    passe par un Apple event vers le Finder (bloqué/silencieux sans
//    autorisation TCC). On le réimplémente avec activateFileViewerSelectingURLs:
//    et, si le chemin natif est introuvable, on ouvre le dossier utilisateur
//    correspondant à l'onglet courant.
//
// 3) Crash à la fermeture : le timer UpdateBusinessLogic: continue de tirer
//    pendant -[NSApplication terminate:] alors que l'hôte C++ est détruit.
//
// 4) Boutons "Installer" / "Désinstaller" sans effet : pour (dés)installer un
//    .Sims3Pack le launcher relance le jeu avec -ccinstall / -ccuninstall via
//    posix_spawn. Lancé par exec direct, le DRM du jeu (libActivation64,
//    EAAccess::LicenseChecker) refuse de démarrer, ouvre une URL origin2:// pour
//    l'app EA et quitte avec le code 100010. On réaiguille ces lancements vers
//    LaunchServices, où le même jeu installe normalement.
//
// Aucune adresse codée en dur : tout passe par le runtime ObjC et par
// l'interposition dyld, donc le correctif ne dépend pas de l'emplacement du jeu
// ni de la version exacte du launcher.

#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <pthread.h>
#import <fcntl.h>
#import <dlfcn.h>
#import <spawn.h>
#import <unistd.h>

static void SetupStderrCapture(void);

#pragma mark - Journal

static NSString *LogPath(void) {
    static NSString *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/TS3LauncherFix.log"];
    });
    return p;
}

static void FixLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LogPath()];
    if (!fh) {
        [line writeToFile:LogPath() atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

#pragma mark - 1) NSArchiver : jeton au lieu d'une archive

static const char kTokenMagic[] = "TS3LFIXTOK";   // 10 octets + compteur 8 octets
static const NSUInteger kTokenLen = 10 + 8;
static const NSUInteger kStoreMax = 256;

static NSMutableDictionary *gStore;        // NSNumber(uint64) -> objet
static NSMutableArray      *gStoreOrder;  // FIFO des clés
static uint64_t             gStoreNext;
static pthread_mutex_t      gStoreLock = PTHREAD_MUTEX_INITIALIZER;

static NSData *(*gOrigArchive)(id, SEL, id);
static id      (*gOrigUnarchive)(id, SEL, NSData *);

static NSData *FixArchivedDataWithRootObject(id cls, SEL sel, id root) {
    if (root == nil) return gOrigArchive(cls, sel, root);

    pthread_mutex_lock(&gStoreLock);
    uint64_t key = ++gStoreNext;
    NSNumber *k = [NSNumber numberWithUnsignedLongLong:key];
    gStore[k] = root;
    [gStoreOrder addObject:k];
    while (gStoreOrder.count > kStoreMax) {
        [gStore removeObjectForKey:gStoreOrder[0]];
        [gStoreOrder removeObjectAtIndex:0];
    }
    pthread_mutex_unlock(&gStoreLock);

    uint8_t buf[kTokenLen];
    memcpy(buf, kTokenMagic, 10);
    memcpy(buf + 10, &key, 8);
    return [NSData dataWithBytes:buf length:kTokenLen];
}

static id FixUnarchiveObjectWithData(id cls, SEL sel, NSData *data) {
    if (data.length == kTokenLen && memcmp(data.bytes, kTokenMagic, 10) == 0) {
        uint64_t key = 0;
        memcpy(&key, (const uint8_t *)data.bytes + 10, 8);
        pthread_mutex_lock(&gStoreLock);
        id obj = gStore[[NSNumber numberWithUnsignedLongLong:key]];
        pthread_mutex_unlock(&gStoreLock);
        return obj;
    }
    return gOrigUnarchive(cls, sel, data);
}

#pragma mark - 2) Afficher le fichier

static BOOL gRevealed;

// Dossier utilisateur du jeu : ~/Documents/Electronic Arts/<Les Sims 3|The Sims 3|...>
static NSString *UserGameFolder(void) {
    NSString *ea = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Electronic Arts"];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray *kids = [fm contentsOfDirectoryAtPath:ea error:NULL];
    for (NSString *name in kids) {
        NSString *dir = [ea stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Downloads"]] &&
            [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"Options.ini"]]) {
            return dir;
        }
    }
    return nil;
}

static BOOL RevealURLs(NSArray<NSURL *> *urls) {
    if (urls.count == 0) return NO;
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
    return YES;
}

static BOOL (*gOrigSelectFile)(id, SEL, NSString *, NSString *);

static BOOL FixSelectFile(id ws, SEL sel, NSString *path, NSString *root) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (path.length && [fm fileExistsAtPath:path]) {
        gRevealed = RevealURLs(@[[NSURL fileURLWithPath:path]]);
        FixLog(@"Afficher le fichier : %@", path);
        if (gRevealed) return YES;
    }
    // Chemin absent (fichier déplacé/supprimé) : on ouvre au moins le dossier parent.
    NSString *parent = path.length ? path.stringByDeletingLastPathComponent : nil;
    if (parent.length && [fm fileExistsAtPath:parent]) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:parent]];
        gRevealed = YES;
        FixLog(@"Fichier introuvable, dossier ouvert : %@", parent);
        return YES;
    }
    FixLog(@"selectFile inutilisable (chemin « %@ ») -> appel d'origine", path);
    return gOrigSelectFile(ws, sel, path, root);
}

// Repli : si l'appel d'origine n'a rien révélé, on ouvre le dossier de l'onglet.
static void (*gOrigListAction3)(id, SEL, id);

static void FixListAction3(id self, SEL sel, id sender) {
    gRevealed = NO;
    gOrigListAction3(self, sel, sender);
    if (gRevealed) return;

    int page = 0;
    @try { page = [[self valueForKey:@"CurrentPage"] intValue]; } @catch (__unused id e) {}

    NSString *base = UserGameFolder();
    if (!base) { FixLog(@"repli impossible : dossier utilisateur du jeu introuvable"); return; }

    NSString *sub = nil;
    switch (page) {
        case 1:  sub = @"Downloads"; break;   // Téléchargements
        case 4:  sub = @"Exports";   break;   // Chargements
        case 3:  sub = @"Library";   break;   // Contenu installé
        default: sub = nil;          break;
    }
    NSString *dir = sub ? [base stringByAppendingPathComponent:sub] : base;
    if (![NSFileManager.defaultManager fileExistsAtPath:dir]) dir = base;
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:dir]];
    FixLog(@"Chemin natif indisponible (page %d) -> dossier ouvert : %@", page, dir);
}

#pragma mark - 3) Crash à la fermeture

static BOOL gTerminating;
static __weak id gLauncher;

static void (*gOrigUpdateBusinessLogic)(id, SEL, id);

static void FixUpdateBusinessLogic(id self, SEL sel, id timer) {
    if (gTerminating) return;
    gLauncher = self;
    gOrigUpdateBusinessLogic(self, sel, timer);
}

static void (*gOrigTerminate)(id, SEL, id);

static void FixTerminate(id app, SEL sel, id sender) {
    gTerminating = YES;
    id launcher = gLauncher;
    if (launcher) {
        @try {
            NSTimer *t = [launcher valueForKey:@"businessLogicTimer"];
            if ([t isKindOfClass:NSTimer.class]) [t invalidate];
        } @catch (__unused id e) {}
    }
    gOrigTerminate(app, sel, sender);
}


#pragma mark - Diagnostic : journal interne du launcher

// Le launcher écrit son diagnostic avec NSLog, donc sur stderr, qui est jeté
// quand l'app est lancée depuis le Finder. Si le fichier témoin
// ~/Library/Logs/TS3LauncherFix.debug existe, on redirige stderr vers le journal.
static void SetupStderrCapture(void) {
    NSString *flag = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/TS3LauncherFix.debug"];
    if (![NSFileManager.defaultManager fileExistsAtPath:flag]) return;
    int fd = open(LogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    if (fd > STDERR_FILENO) close(fd);
    FixLog(@"capture de stderr active");
}

#pragma mark - 4) Installation des .Sims3Pack / lancement du jeu

// Pour installer un .Sims3Pack, le launcher relance le jeu avec
// posix_spawn("…/The Sims 3", "-ccinstall:\"<liste>\"", "-r:800x600", "-w", "-nosound").
// Lancé ainsi (exec direct), le DRM du jeu (libActivation64, EAAccess::LicenseChecker)
// refuse de démarrer : il ouvre une URL « origin2://game/launch/?… » destinée à
// l'app EA puis quitte avec le code 100010, donc rien ne s'installe. Lancé par
// LaunchServices, le même jeu avec les mêmes arguments installe normalement.
// On réaiguille donc ces lancements vers NSWorkspace, en retirant au passage les
// guillemets littéraux qu'EA met autour du chemin (inutiles sans shell).

// Idiome dyld : dans l'image qui déclare l'interposition, l'appel direct au
// symbole atteint la vraie fonction (pas de récursion). Ne PAS passer par dlsym.
#define TS3_INTERPOSE(_repl, _orig) \
    __attribute__((used)) static struct { const void *r; const void *o; } \
    _interpose_##_orig __attribute__((section("__DATA,__interpose"))) = \
    { (const void *)&_repl, (const void *)&_orig }

// « …/The Sims 3.app/Contents/MacOS/The Sims 3 » (avec d'éventuels « .. ») -> le bundle
static NSURL *GameBundleURL(const char *path) {
    if (!path) return nil;
    NSString *p = [[NSString stringWithUTF8String:path] stringByStandardizingPath];
    if (![p.lastPathComponent isEqualToString:@"The Sims 3"]) return nil;
    NSString *bundle = p.stringByDeletingLastPathComponent   // MacOS
                        .stringByDeletingLastPathComponent   // Contents
                        .stringByDeletingLastPathComponent;  // The Sims 3.app
    if (![bundle.pathExtension isEqualToString:@"app"]) return nil;
    if (![NSFileManager.defaultManager fileExistsAtPath:p]) return nil;
    return [NSURL fileURLWithPath:bundle];
}

// Le launcher écrit la liste des .Sims3Pack dans un fichier temporaire et le
// supprime dès que son processus fils se termine. Comme /usr/bin/open rend la
// main tout de suite, la liste disparaît avant que le jeu, démarré un instant
// plus tard par LaunchServices, ait pu la lire — d'où « aucun ensemble de
// fichiers à installer ». On en garde donc une copie à nous, que personne
// d'autre n'efface, et c'est elle qu'on passe au jeu.
static NSString *StableListCopy(NSString *list) {
    NSData *d = [NSData dataWithContentsOfFile:list];
    if (!d) return nil;
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:
                     @"Library/Application Support/TS3MacFixes/launcher-lists"];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL]) return nil;
    // ménage : les copies de plus d'un jour
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-86400];
    for (NSString *old in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        NSString *f = [dir stringByAppendingPathComponent:old];
        NSDate *m = [fm attributesOfItemAtPath:f error:NULL].fileModificationDate;
        if (m && [m compare:cutoff] == NSOrderedAscending) [fm removeItemAtPath:f error:NULL];
    }
    NSString *dst = [dir stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, list.lastPathComponent]];
    return [d writeToFile:dst atomically:YES] ? dst : nil;
}

// On relance le jeu par /usr/bin/open (donc par LaunchServices) tout en restant
// un vrai posix_spawn : le launcher reçoit un vrai processus fils, comme avant.
static int SpawnViaOpen(pid_t *pid, NSString *bundle,
                        const posix_spawn_file_actions_t *fa,
                        const posix_spawnattr_t *attr,
                        char *const argv[], char *const envp[]) {
    NSMutableArray<NSString *> *a = [NSMutableArray arrayWithObjects:
                                     @"open", @"-n", @"-a", bundle, @"--args", nil];
    for (int i = 1; argv && argv[i]; i++) {
        // EA entoure le chemin de guillemets, qu'aucun shell ne retire ici
        NSString *arg = [[NSString stringWithUTF8String:argv[i]]
                         stringByReplacingOccurrencesOfString:@"\"" withString:@""];
        if (!arg.length) continue;
        for (NSString *opt in @[@"-ccinstall:", @"-ccuninstall:"]) {
            if (![arg hasPrefix:opt]) continue;
            NSString *copy = StableListCopy([arg substringFromIndex:opt.length]);
            if (copy) arg = [opt stringByAppendingString:copy];
        }
        [a addObject:arg];
    }
    for (NSString *arg in a) {
        if (![arg hasPrefix:@"-ccinstall:"] && ![arg hasPrefix:@"-ccuninstall:"]) continue;
        NSString *list = [arg substringFromIndex:[arg rangeOfString:@":"].location + 1];
        NSString *txt = [NSString stringWithContentsOfFile:list encoding:NSUTF8StringEncoding error:NULL];
        FixLog(@"  liste « %@ » : %@", list, txt ?: @"(illisible)");
        for (NSString *f in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            if (!f.length) continue;
            FixLog(@"    %@ : %@", [NSFileManager.defaultManager fileExistsAtPath:f] ? @"présent" : @"ABSENT", f);
        }
    }
    char **cargv = calloc(a.count + 1, sizeof(char *));
    if (!cargv) return -1;
    for (NSUInteger i = 0; i < a.count; i++) cargv[i] = strdup(a[i].fileSystemRepresentation);
    int r = posix_spawn(pid, "/usr/bin/open", fa, attr, cargv, envp);
    FixLog(@"jeu relancé par LaunchServices -> %d (pid %d) : %@", r, pid ? *pid : -1,
           [[a subarrayWithRange:NSMakeRange(4, a.count - 4)] componentsJoinedByString:@" "]);
    for (NSUInteger i = 0; i < a.count; i++) free(cargv[i]);
    free(cargv);
    return r;
}

// Quand c'est l'app EA qui a démarré le launcher, elle lui transmet une session
// (EALicenseToken, EALaunchCode, EARtPLaunchCode, EALsxPort…). Le jeu lancé par
// posix_spawn en hérite, et c'est précisément ce que son contrôle de licence
// attend pour accepter des paramètres comme -ccinstall. LaunchServices, lui,
// démarre le jeu avec un environnement propre : la session est perdue et le jeu
// repart aussitôt. Donc : session présente -> on ne touche à rien.
static BOOL StartedByEAApp(void) {
    return getenv("EALicenseToken") || getenv("EALaunchCode") || getenv("EARtPLaunchCode");
}

static int ts3_posix_spawn(pid_t *pid, const char *path,
                           const posix_spawn_file_actions_t *fa,
                           const posix_spawnattr_t *attr,
                           char *const argv[], char *const envp[]) {
    NSURL *bundle = GameBundleURL(path);
    if (bundle && StartedByEAApp()) {
        FixLog(@"session EA présente : lancement d'origine du jeu, environnement conservé");
        return posix_spawn(pid, path, fa, attr, argv, envp);
    }
    if (bundle) {
        int r = SpawnViaOpen(pid, bundle.path, fa, attr, argv, envp);
        if (r == 0) return 0;
        FixLog(@"échec, lancement direct (le DRM refusera peut-être)");
    }
    return posix_spawn(pid, path, fa, attr, argv, envp);
}
TS3_INTERPOSE(ts3_posix_spawn, posix_spawn);

#pragma mark - 5) Textes manquants du launcher

// 23 clés de Localizable.strings n'ont jamais été livrées dans la version Mac :
// toutes les mentions de packs requis, plus les deux avertissements de
// dépendances. localizedStringForKey: renvoie alors la clé brute, que le
// launcher affiche telle quelle (« Sims3Launcher/Strings/kWarn_… »). On fournit
// les textes manquants.

static BOOL LauncherSpeaksFrench(void) {
    NSString *l = NSBundle.mainBundle.preferredLocalizations.firstObject
                   ?: NSLocale.preferredLanguages.firstObject;
    return [l.lowercaseString hasPrefix:@"fr"];
}

static NSDictionary<NSString *, NSString *> *MissingStrings(void) {
    static NSDictionary *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        BOOL fr = LauncherSpeaksFrench();
        NSArray *packs = fr ? @[@"Destination Aventure", @"Ambitions", @"Accès VIP", @"Générations",
                                @"Animaux & Cie", @"Showtime", @"Super-pouvoirs", @"Saisons",
                                @"University", @"Île de Rêve", @"En route vers le futur"]
                            : @[@"World Adventures", @"Ambitions", @"Late Night", @"Generations",
                                @"Pets", @"Showtime", @"Supernatural", @"Seasons",
                                @"University Life", @"Island Paradise", @"Into the Future"];
        NSArray *kits = fr ? @[@"Inspiration Loft", @"Accélérateur", @"Détente au Soleil",
                               @"Vie Citadine", @"Suite de Rêve", @"Délices Sucrés de Katy Perry",
                               @"Diesel", @"Rétro (70, 80, 90)", @"Cinéma"]
                           : @[@"High-End Loft Stuff", @"Fast Lane Stuff", @"Outdoor Living Stuff",
                               @"Town Life Stuff", @"Master Suite Stuff", @"Katy Perry Sweet Treats",
                               @"Diesel Stuff", @"70s, 80s, & 90s Stuff", @"Movie Stuff"];
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < packs.count; i++)
            m[[NSString stringWithFormat:@"Sims3Launcher/Strings/RequiresEP%02lu:Text", (unsigned long)(i + 1)]] =
                [NSString stringWithFormat:fr ? @"Nécessite Les Sims 3 %@" : @"Requires The Sims 3 %@", packs[i]];
        for (NSUInteger i = 0; i < kits.count; i++)
            m[[NSString stringWithFormat:@"Sims3Launcher/Strings/RequiresSP%02lu:Text", (unsigned long)(i + 1)]] =
                [NSString stringWithFormat:fr ? @"Nécessite le kit %@" : @"Requires the %@ pack", kits[i]];
        m[@"Sims3Launcher/Strings/RequiresEP_Generic_MAC:Text"] = fr
            ? @"Nécessite un pack d'extension ou un kit que tu n'as pas installé."
            : @"Requires an expansion or stuff pack that is not installed.";
        m[@"Sims3Launcher/Strings/kWarn_VerifyEPDependenciesFail:Text"] = fr
            ? @"Ce contenu réclame des éléments absents de ton installation, probablement un pack "
               "d'extension ou un kit que tu n'as pas.\n\nL'installation continue quand même : ce qui "
               "dépend du pack manquant risque de ne pas apparaître dans le jeu."
            : @"This content needs items that are missing from your installation, most likely an "
               "expansion or stuff pack you do not own.\n\nIt will be installed anyway: whatever "
               "depends on the missing pack may not show up in the game.";
        m[@"Sims3Launcher/Strings/kError_VerifyEPModeFail:Text"] = fr
            ? @"Ce contenu a été créé avec des packs que tu n'as pas tous.\n\nL'installation continue "
               "quand même : certains éléments risquent de manquer dans le jeu."
            : @"This content was created with packs you do not all own.\n\nIt will be installed "
               "anyway: some items may be missing in the game.";
        d = m;
    });
    return d;
}

static NSString *(*gOrigLocalized)(id, SEL, NSString *);

static NSString *FixLocalizedStringForKey(id cls, SEL sel, NSString *key) {
    NSString *s = gOrigLocalized(cls, sel, key);
    if (key.length && (s.length == 0 || [s isEqualToString:key])) {
        NSString *mine = MissingStrings()[key];
        if (mine) return mine;
    }
    return s;
}

#pragma mark - Installation

static BOOL SwizzleInstance(Class cls, SEL sel, IMP repl, void *origOut) {
    Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!m) return NO;
    *(IMP *)origOut = method_getImplementation(m);
    method_setImplementation(m, repl);
    return YES;
}

static BOOL SwizzleClassMethod(Class cls, SEL sel, IMP repl, void *origOut) {
    Method m = cls ? class_getClassMethod(cls, sel) : NULL;
    if (!m) return NO;
    *(IMP *)origOut = method_getImplementation(m);
    method_setImplementation(m, repl);
    return YES;
}

static void InstallLauncherHooks(void) {
    static BOOL done;
    if (done) return;
    Class launcher = objc_getClass("SIMS3Launcher");
    if (!launcher) return;
    done = YES;
    BOOL a = SwizzleInstance(launcher, @selector(buttonPressed_ListAction3:),
                             (IMP)FixListAction3, &gOrigListAction3);
    BOOL b = SwizzleInstance(launcher, @selector(UpdateBusinessLogic:),
                             (IMP)FixUpdateBusinessLogic, &gOrigUpdateBusinessLogic);
    BOOL t = SwizzleClassMethod(objc_getClass("Sims3Util"), @selector(localizedStringForKey:),
                                (IMP)FixLocalizedStringForKey, &gOrigLocalized);
    FixLog(@"hooks SIMS3Launcher : ListAction3=%d UpdateBusinessLogic=%d textes=%d", a, b, t);
}

__attribute__((constructor))
static void TS3LauncherFixInit(void) {
    @autoreleasepool {
        gStore = [NSMutableDictionary new];
        gStoreOrder = [NSMutableArray new];

        BOOL ar = SwizzleClassMethod(objc_getClass("NSArchiver"),
                                     @selector(archivedDataWithRootObject:),
                                     (IMP)FixArchivedDataWithRootObject, &gOrigArchive);
        BOOL un = SwizzleClassMethod(objc_getClass("NSUnarchiver"),
                                     @selector(unarchiveObjectWithData:),
                                     (IMP)FixUnarchiveObjectWithData, &gOrigUnarchive);
        BOOL sf = SwizzleInstance(NSWorkspace.class,
                                  @selector(selectFile:inFileViewerRootedAtPath:),
                                  (IMP)FixSelectFile, &gOrigSelectFile);
        BOOL tm = SwizzleInstance(NSApplication.class, @selector(terminate:),
                                  (IMP)FixTerminate, &gOrigTerminate);
        FixLog(@"TS3 Launcher Fix chargé : archive=%d désarchive=%d selectFile=%d terminate=%d",
               ar, un, sf, tm);

        SetupStderrCapture();
        InstallLauncherHooks();
        if (!objc_getClass("SIMS3Launcher")) {
            dispatch_async(dispatch_get_main_queue(), ^{ InstallLauncherHooks(); });
        }
    }
}
