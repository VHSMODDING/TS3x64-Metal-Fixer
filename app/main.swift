// TS3 Mac Fixes : applique les correctifs communautaires à une install légale des Sims 3 (macOS).
// Ne redistribue aucun code d'EA : il modifie l'app du joueur (dylib ajoutée, re-signature ad-hoc,
// packages copiés) et sait tout annuler. Réversible via les sauvegardes.
import SwiftUI
import AppKit

// MARK: - Localisation (anglais si le système est en anglais, sinon français)

let appIsEnglish: Bool = (Locale.preferredLanguages.first ?? "fr").lowercased().hasPrefix("en")
func tr(_ fr: String, _ en: String) -> String { appIsEnglish ? en : fr }
// parse les liens Markdown [texte](url) d'une String runtime en AttributedString cliquable
func md(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s)) ?? AttributedString(s)
}

// MARK: - Modèle

enum FixKind { case native, package, override_, shader, config }

struct Fix: Identifiable {
    let id: String
    let name: String
    let detail: String
    let kind: FixKind
    var beta: Bool = false
}

let FIXES: [Fix] = [
    Fix(id: "resolution", name: tr("Résolutions natives macOS","Native macOS resolutions"), detail: tr("Ajoute 1512×982, 1728×1117 et les tailles Apple Silicon.","Adds 1512×982, 1728×1117 and Apple Silicon sizes."), kind: .native),
    Fix(id: "fullscreen", name: tr("Plein écran","Fullscreen"), detail: "", kind: .native),
    Fix(id: "aniso", name: tr("Filtrage anisotrope","Anisotropic filtering"), detail: tr("Textures du sol plus nettes en biais.","Sharper ground textures at angles."), kind: .native, beta: true),
    Fix(id: "buffering", name: tr("Triple buffering","Triple buffering"), detail: tr("Rendu un peu plus fluide.","Slightly smoother rendering."), kind: .native, beta: true),
    Fix(id: "terrainpaint", name: tr("Peinture du terrain qui disparaît","Disappearing terrain paint"), detail: tr("La peinture du lot reste affichée après chaque coup de pinceau.","Lot paint stays visible after each brush stroke."), kind: .native),
    Fix(id: "snowwalls", name: tr("Murs troués par les routes enneigées","Walls holed by snowy roads"), detail: tr("En hiver, les murs ne laissent plus voir la route derrière eux.","In winter, walls no longer show the road behind them."), kind: .native),
    Fix(id: "oceaninsect", name: tr("Clic océan + insectes","Ocean + insects clicking"), detail: tr("Rend l'océan, les insectes et les collectibles cliquables.","Makes the ocean, insects and collectibles clickable."), kind: .override_),
    Fix(id: "smoothpatch", name: "Smooth Patch", detail: tr("Jeu plus fluide ([LazyDuchess](https://modthesims.info/m/10124945)).","Smoother gameplay ([LazyDuchess](https://modthesims.info/m/10124945))."), kind: .package),
    Fix(id: "sfprofont", name: "Police SF Font Bold", detail: tr("(Police native macOS)","(Native macOS font)"), kind: .override_),
    Fix(id: "redpool", name: tr("Correction piscines rouges","Red pools fix"), detail: "", kind: .shader),
    Fix(id: "redflash", name: tr("Correction flash rose","Pink flash fix"), detail: "", kind: .shader, beta: true),
    Fix(id: "frostwindows", name: tr("Vitres givrées qui clignotent","Flickering frosted windows"), detail: tr("En hiver, les fenêtres des bâtiments communautaires ne clignotent plus.","In winter, community building windows no longer flicker."), kind: .shader),
    Fix(id: "gfxrules", name: tr("Optimisation des paramètres graphiques conseillés pour Apple Silicon","Recommended graphics settings for Apple Silicon"), detail: "", kind: .config),
    Fix(id: "perfini", name: tr("Réglages de performance conseillés pour Apple Silicon","Recommended performance settings for Apple Silicon"), detail: tr("Plus de temps de calcul pour les Sims, les chargements et les textures, mémoire de ressources 512 Mo.","More processing time for Sims, loading and textures; 512 MB resource memory."), kind: .config),
]

// MARK: - Moteur

final class Engine: ObservableObject {
    @Published var gamePath: String = ""      // chemin du Sims3Launcher.app (ou The Sims 3.app)
    @Published var log: String = ""
    @Published var enabled: [String: Bool] = ["resolution": true, "oceaninsect": true, "redpool": true, "snowwalls": true, "frostwindows": true, "terrainpaint": true]
    @Published var busy = false

    var bundleRes: String { Bundle.main.resourcePath ?? "" }
    var supportDir: String {
        let d = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/TS3MacFixes")
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        return d
    }

    func L(_ s: String) { DispatchQueue.main.async { self.log += s + "\n" } }

    // Trouve l'app interne "The Sims 3.app/Contents" à partir du chemin choisi.
    func innerContents(_ picked: String) -> String? {
        let fm = FileManager.default
        // cas 1 : on a pointé le Sims3Launcher.app
        let c1 = (picked as NSString).appendingPathComponent("Contents/Resources/The Sims 3.app/Contents")
        if fm.fileExists(atPath: (c1 as NSString).appendingPathComponent("MacOS/The Sims 3")) { return c1 }
        // cas 2 : on a pointé directement The Sims 3.app
        let c2 = (picked as NSString).appendingPathComponent("Contents")
        if fm.fileExists(atPath: (c2 as NSString).appendingPathComponent("MacOS/The Sims 3")) { return c2 }
        return nil
    }

    // Coche les toggles selon ce qui est DÉJÀ installé, pour refléter l'état réel.
    func detectState() {
        guard let c = innerContents(gamePath) else { return }
        let fm = FileManager.default
        let macos = (c as NSString).appendingPathComponent("MacOS")
        let hasDylib = fm.fileExists(atPath: (macos as NSString).appendingPathComponent("libts3fix.dylib"))
        var full = false, res = false
        var aniso = false, buffering = false, snow = false, paint = false
        if hasDylib, let conf = try? String(contentsOfFile: (supportDir as NSString).appendingPathComponent("ts3fixes.conf"), encoding: .utf8) {
            full = conf.contains("fullscreen=1"); res = conf.contains("resolution=1")
            aniso = conf.contains("aniso=1"); buffering = conf.contains("buffering=1")
            snow = conf.contains("snowfix=1"); paint = conf.contains("paintfix=1")
        } else if hasDylib { full = true; res = true; aniso = true; buffering = true }
        let (f,r,a,bf,sw,tp) = (full,res,aniso,buffering,snow,paint)
        DispatchQueue.main.async { self.enabled["fullscreen"] = f; self.enabled["resolution"] = r; self.enabled["aniso"] = a; self.enabled["buffering"] = bf; self.enabled["snowwalls"] = sw; self.enabled["terrainpaint"] = tp }
        if let mods = userMods() {
            for (id, file) in packageFiles {
                let on = fm.fileExists(atPath: (mods as NSString).appendingPathComponent(file))
                DispatchQueue.main.async { self.enabled[id] = on }
            }
        }
        if let overrides = userOverrides() {
            for (id, file) in overrideFiles {
                let legacy = id == "oceaninsect" && userMods().map { fm.fileExists(atPath: ($0 as NSString).appendingPathComponent(file)) } == true
                let on = legacy || fm.fileExists(atPath: (overrides as NSString).appendingPathComponent(file))
                DispatchQueue.main.async { self.enabled[id] = on }
            }
        }
        if let data = fm.contents(atPath: shaderPath(c)) {
            for id in ["redpool","redflash","frostwindows"] {
                var on = false
                if let r = shaderRanges(id) { on = (checkShader(data, r, install: true) == .already) }
                let v = on; DispatchQueue.main.async { self.enabled[id] = v }
            }
        }
        for cfg in configPatches {
            if let cp = configPatch(cfg.json),
               let txt = try? String(contentsOfFile: (c as NSString).appendingPathComponent(cp.file), encoding: .utf8) {
                let on = gfxState(txt, cp.pairs, install: true) == .already, id = cfg.id
                DispatchQueue.main.async { self.enabled[id] = on }
            }
        }
        // état du dossier Mods
        if let root = userDataRoot() {
            let mods = (root as NSString).appendingPathComponent("Mods")
            let pk = fm.fileExists(atPath: (mods as NSString).appendingPathComponent("Packages"))
            let ov = fm.fileExists(atPath: (mods as NSString).appendingPathComponent("Overrides"))
            let cf = fm.fileExists(atPath: (mods as NSString).appendingPathComponent("Resource.cfg"))
            L(tr("Dossier Mods :", "Mods folder:") + " Packages \(pk ? "✓" : "✗"), Overrides \(ov ? "✓" : "✗"), Resource.cfg \(cf ? "✓" : "✗")" + ((pk && ov && cf) ? "" : tr(" : sera créé à l'application.", ": missing items will be created when applying.")))
        } else {
            L(tr("Dossier de jeu utilisateur non trouvé (lance le jeu une fois pour le créer).", "Game user folder not found (launch the game once to create it)."))
        }
    }

    func autodetect() {
        guard !busy else { return }
        busy = true
        L(tr("Recherche du jeu…", "Searching for the game…"))
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var candidates: [String] = []
            // Spotlight finds registered applications even outside the usual folders.
            let (_, output) = self.run("/usr/bin/mdfind", ["kMDItemFSName == 'Sims3Launcher.app'c || kMDItemFSName == 'The Sims 3.app'c || kMDItemFSName == 'The Sims 3 Launcher.app'c"])
            candidates += output.components(separatedBy: .newlines).filter { !$0.isEmpty }
            // Also search application folders when Spotlight is disabled or incomplete.
            for root in ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")] {
                guard let enumerator = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isPackageKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                    candidates.append(url.path)
                }
            }
            let found = candidates.sorted().first { self.innerContents($0) != nil }
            DispatchQueue.main.async {
                self.busy = false
                if let path = found {
                    self.gamePath = path
                    self.L(tr("Jeu détecté : \(path)", "Game detected: \(path)"))
                    self.detectState()
                } else {
                    self.L(tr("Jeu non détecté automatiquement : utilise « Parcourir ».", "Game not detected automatically. Use Browse to select it."))
                }
            }
        }
    }

    // Racine utilisateur "Electronic Arts/<Les Sims 3|The Sims 3|...>".
    func userDataRoot() -> String? {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Electronic Arts")
        let fm = FileManager.default
        // noms connus d'abord
        for name in ["Les Sims 3", "The Sims 3", "Die Sims 3", "Los Sims 3", "The Sims 3 "] {
            let p = (base as NSString).appendingPathComponent(name)
            if fm.fileExists(atPath: p) { return p }
        }
        // sinon, tout dossier contenant "Sims 3"
        if let items = try? fm.contentsOfDirectory(atPath: base) {
            for it in items where it.contains("Sims 3") {
                let p = (base as NSString).appendingPathComponent(it)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { return p }
            }
        }
        return nil
    }

    func userMods() -> String? {
        guard let root = userDataRoot() else { return nil }
        return (root as NSString).appendingPathComponent("Mods/Packages")
    }

    static let resourcesCfg = """
    Priority 500
    PackedFile Packages/*.package
    PackedFile Packages/*/*.package
    PackedFile Packages/*/*/*.package
    PackedFile Packages/*/*/*/*.package
    PackedFile Packages/*/*/*/*/*.package

    Priority 1000
    PackedFile Overrides/*.package
    PackedFile Overrides/*/*.package
    PackedFile Overrides/*/*/*.package

    """

    // Crée Mods/Packages, Mods/Overrides et Resource.cfg si besoin. Renvoie false si pas de dossier jeu.
    @discardableResult
    func ensureModsSetup() -> Bool {
        guard let root = userDataRoot() else {
            L(tr("⚠️ Dossier du jeu introuvable dans Documents/Electronic Arts : lance le jeu une fois, puis réessaie.", "⚠️ Game folder not found in Documents/Electronic Arts. Launch the game once, then try again."))
            return false
        }
        let fm = FileManager.default
        let mods = (root as NSString).appendingPathComponent("Mods")
        let pkgs = (mods as NSString).appendingPathComponent("Packages")
        let over = (mods as NSString).appendingPathComponent("Overrides")
        do {
            for d in [mods, pkgs, over] where !fm.fileExists(atPath: d) {
                try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
                L(tr("Créé : \(d)", "Created: \(d)"))
            }
            let cfg = (mods as NSString).appendingPathComponent("Resource.cfg")
            if !fm.fileExists(atPath: cfg) {
                try Engine.resourcesCfg.write(toFile: cfg, atomically: true, encoding: .utf8)
                L(tr("Resource.cfg créé.", "Resource.cfg created."))
            } else {
                let existing = try String(contentsOfFile: cfg, encoding: .utf8)
                let lines = existing.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                func hasRule(_ path: String) -> Bool {
                    lines.contains { line in
                        let parts = line.split(whereSeparator: { $0.isWhitespace })
                        return parts.count >= 2 && parts[0] == "packedfile" && parts[1] == Substring(path)
                    }
                }
                var additions = ""
                if !hasRule("packages/*.package") { additions += "\nPriority 500\nPackedFile Packages/*.package\n" }
                if !hasRule("overrides/*.package") { additions += "\nPriority 1000\nPackedFile Overrides/*.package\n" }
                if additions.isEmpty {
                    L(tr("Resource.cfg déjà configuré.", "Resource.cfg is already configured."))
                } else {
                    let backup = cfg + ".bak_ts3macfixes"
                    if !fm.fileExists(atPath: backup) { try fm.copyItem(atPath: cfg, toPath: backup) }
                    try (existing + "\n" + additions).write(toFile: cfg, atomically: true, encoding: .utf8)
                    L(tr("Resource.cfg mis à jour (sauvegarde conservée).", "Resource.cfg updated (backup preserved)."))
                }
            }
        } catch {
            L(tr("Impossible de configurer Mods : \(error)", "Could not configure Mods: \(error)"))
            return false
        }
        return true
    }

    func run(_ exe: String, _ args: [String]) -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, tr("lancement impossible: \(error)", "Could not launch: \(error)")) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: Mach-O : insérer LC_LOAD_DYLIB @loader_path/libts3fix.dylib si absent
    func ensureLoadCommand(_ binaryPath: String) -> Bool {
        guard var d = FileManager.default.contents(atPath: binaryPath) else { L(tr("binaire introuvable", "Binary not found")); return false }
        let name = "@loader_path/libts3fix.dylib"
        if d.withUnsafeBytes({ raw -> Bool in
            let p = raw.bindMemory(to: UInt8.self)
            let nameBytes = Array(name.utf8)
            // recherche grossière de la chaîne déjà présente
            if let _ = (0..<(p.count - nameBytes.count)).first(where: { i in
                var ok = true; for j in 0..<nameBytes.count where p[i+j] != nameBytes[j] { ok = false; break }; return ok
            }) { return true }
            return false
        }) { L(tr("load command déjà présent.", "Load command already present.")); return true }

        func u32(_ off: Int) -> UInt32 { d.subdata(in: off..<off+4).withUnsafeBytes { $0.load(as: UInt32.self) } }
        func setU32(_ off: Int, _ v: UInt32) { var vv = v; let b = Data(bytes: &vv, count: 4); d.replaceSubrange(off..<off+4, with: b) }
        let magic = u32(0)
        guard magic == 0xfeedfacf else { L(tr("pas un Mach-O 64 (0x\(String(magic,radix:16)))", "Not a 64-bit Mach-O (0x\(String(magic,radix:16)))")); return false }
        let ncmds = u32(16); let sizeofcmds = u32(20)
        let endLC = 32 + Int(sizeofcmds)
        // taille commande : 24 + nom (terminé par 0, aligné 8)
        var nameData = Array(name.utf8); nameData.append(0)
        var cmdsize = 24 + nameData.count
        cmdsize = (cmdsize + 7) / 8 * 8
        if endLC + cmdsize > 0x2000 { L(tr("pas de place dans l'en-tête Mach-O.", "No space in the Mach-O header.")); return false }
        var cmd = Data()
        func app32(_ v: UInt32) { var vv = v; cmd.append(Data(bytes: &vv, count: 4)) }
        app32(0xC)                 // LC_LOAD_DYLIB
        app32(UInt32(cmdsize))
        app32(24)                  // name offset
        app32(2)                   // timestamp
        app32(0x10000)             // current version
        app32(0x10000)             // compat version
        cmd.append(contentsOf: nameData)
        while cmd.count < cmdsize { cmd.append(0) }
        d.replaceSubrange(endLC..<endLC+cmdsize, with: cmd)
        setU32(16, ncmds + 1)
        setU32(20, sizeofcmds + UInt32(cmdsize))
        do { try d.write(to: URL(fileURLWithPath: binaryPath)) } catch { L(tr("écriture binaire: \(error)", "Writing binary: \(error)")); return false }
        L(tr("load command inséré.", "Load command inserted."))
        return true
    }

    func backupOnce(_ contents: String) {
        let fm = FileManager.default
        let bdir = (supportDir as NSString).appendingPathComponent("backup")
        try? fm.createDirectory(atPath: bdir, withIntermediateDirectories: true)
        let binBK = (bdir as NSString).appendingPathComponent("The Sims 3.bin.original")
        if !fm.fileExists(atPath: binBK) {
            try? fm.copyItem(atPath: (contents as NSString).appendingPathComponent("MacOS/The Sims 3"), toPath: binBK)
            let csBK = (bdir as NSString).appendingPathComponent("_CodeSignature.original")
            try? fm.copyItem(atPath: (contents as NSString).appendingPathComponent("_CodeSignature"), toPath: csBK)
            L(tr("Sauvegarde d'origine créée.", "Original backup created."))
        }
    }

    let nativeIds = ["resolution","fullscreen","aniso","buffering","snowwalls","terrainpaint"]
    func applyNative(_ contents: String) -> Bool {
        let fm = FileManager.default
        let macos = (contents as NSString).appendingPathComponent("MacOS")
        let dylibSrc = (bundleRes as NSString).appendingPathComponent("libts3fix.dylib")
        let dylibDst = (macos as NSString).appendingPathComponent("libts3fix.dylib")
        let bin = (macos as NSString).appendingPathComponent("The Sims 3")
        let ent = (bundleRes as NSString).appendingPathComponent("entitlements.plist")
        guard fm.fileExists(atPath: dylibSrc) else { L(tr("dylib absente du bundle.", "Dylib missing from the app bundle.")); return false }
        backupOnce(contents)
        // config dans le dossier utilisateur (PAS dans MacOS/, sinon codesign refuse le bundle)
        func b(_ id: String) -> Int { (enabled[id] ?? false) ? 1 : 0 }
        let conf = "fullscreen=\(b("fullscreen"))\nresolution=\(b("resolution"))\naniso=\(b("aniso"))\nbuffering=\(b("buffering"))\nsnowfix=\(b("snowwalls"))\npaintfix=\(b("terrainpaint"))\nss=0\n"
        try? conf.write(toFile: (supportDir as NSString).appendingPathComponent("ts3fixes.conf"), atomically: true, encoding: .utf8)
        // nettoyer un éventuel ancien conf mal placé
        try? FileManager.default.removeItem(atPath: (macos as NSString).appendingPathComponent("ts3fixes.conf"))
        // dylib
        try? fm.removeItem(atPath: dylibDst)
        do { try fm.copyItem(atPath: dylibSrc, toPath: dylibDst) } catch { L(tr("copie dylib: \(error)", "Copying dylib: \(error)")); return false }
        _ = run("/usr/bin/codesign", ["-f","-s","-", dylibDst])
        // load command
        if !ensureLoadCommand(bin) { return false }
        // re-signature de l'app interne (le bundle .app, PAS le dossier Contents)
        let appBundle = (contents as NSString).deletingLastPathComponent
        let (rc, out) = run("/usr/bin/codesign", ["-f","-s","-","--entitlements", ent, appBundle])
        if rc != 0 { L(tr("codesign a échoué:\n\(out)", "Code signing failed:\n\(out)")); return false }
        L(tr("Correctifs natifs appliqués.","Native fixes applied."))
        return true
    }

    func revertNative(_ contents: String) {
        let fm = FileManager.default
        let macos = (contents as NSString).appendingPathComponent("MacOS")
        let bdir = (supportDir as NSString).appendingPathComponent("backup")
        let binBK = (bdir as NSString).appendingPathComponent("The Sims 3.bin.original")
        let bin = (macos as NSString).appendingPathComponent("The Sims 3")
        if fm.fileExists(atPath: binBK) {
            try? fm.removeItem(atPath: bin); try? fm.copyItem(atPath: binBK, toPath: bin)
            let csBK = (bdir as NSString).appendingPathComponent("_CodeSignature.original")
            let cs = (contents as NSString).appendingPathComponent("_CodeSignature")
            if fm.fileExists(atPath: csBK) { try? fm.removeItem(atPath: cs); try? fm.copyItem(atPath: csBK, toPath: cs) }
            L(tr("Binaire + signature d'origine restaurés.", "Original binary and signature restored."))
        }
        try? fm.removeItem(atPath: (macos as NSString).appendingPathComponent("libts3fix.dylib"))
        try? fm.removeItem(atPath: (macos as NSString).appendingPathComponent("ts3fixes.conf"))
        try? fm.removeItem(atPath: (supportDir as NSString).appendingPathComponent("ts3fixes.conf"))
        L(tr("Correctifs natifs retirés.", "Native fixes removed."))
    }

    let packageFiles: [String: String] = [
        "smoothpatch": "SmoothPatchMac.package",
    ]

    let overrideFiles: [String: String] = [
        "oceaninsect": "TS3Mac_OceanAndInsectPicker.package",
        "sfprofont": "SFPro_FontReplacement.package",
    ]

    func userOverrides() -> String? {
        guard let root = userDataRoot() else { return nil }
        return (root as NSString).appendingPathComponent("Mods/Overrides")
    }

    func applyOverride(_ id: String, install: Bool) -> Bool {
        guard let file = overrideFiles[id] else { return false }
        guard let overrides = userOverrides() else { L(tr("Dossier Mods introuvable (lance le jeu une fois ?).", "Mods folder not found (launch the game once first).")); return false }
        let fm = FileManager.default
        let dst = (overrides as NSString).appendingPathComponent(file)
        let legacy = id == "oceaninsect" ? userMods().map { ($0 as NSString).appendingPathComponent(file) } : nil
        do {
            if !install {
                for path in [dst, legacy].compactMap({ $0 }) where fm.fileExists(atPath: path) {
                    try fm.removeItem(atPath: path)
                    L(tr("Override retiré : \(path)", "Override removed: \(path)"))
                }
                return true
            }
            let src = (bundleRes as NSString).appendingPathComponent(file)
            guard fm.fileExists(atPath: src) else { L(tr("override \(file) absent du bundle.", "Override \(file) missing from the app bundle.")); return false }
            try fm.createDirectory(atPath: overrides, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst) { try fm.removeItem(atPath: dst) }
            try fm.copyItem(atPath: src, toPath: dst)
            if let old = legacy, fm.fileExists(atPath: old) { try fm.removeItem(atPath: old) }
            L(tr("Override installé : \(file)", "Override installed: \(file)"))
            return true
        } catch {
            L(tr("copie ou suppression override : \(error)", "Copying or removing override: \(error)"))
            return false
        }
    }

    // Vide les caches TS3 pour forcer le (re)chargement des mods au prochain lancement.
    func clearCaches() {
        guard let root = userDataRoot() else { return }
        let names = ["scriptCache.package","ScriptCache.package","CASPartCache.package",
                     "compositorCache.package","simCompositorCache.package","socialCache.package"]
        var n = 0
        for name in names {
            let p = (root as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: p) { try? FileManager.default.removeItem(atPath: p); n += 1 }
        }
        if n > 0 { L(tr("Caches vidés (\(n)) : les mods se chargeront au prochain lancement.", "Cleared \(n) caches; mods will load on the next launch.")) }
    }

    func applyPackage(_ id: String, install: Bool) -> Bool {
        guard let file = packageFiles[id] else { return false }
        guard let mods = userMods() else { L(tr("Dossier Mods introuvable (lance le jeu une fois ?).", "Mods folder not found (launch the game once first).")); return false }
        let dst = (mods as NSString).appendingPathComponent(file)
        if !install {
            if FileManager.default.fileExists(atPath: dst) { try? FileManager.default.removeItem(atPath: dst); L(tr("Package retiré : \(file)", "Package removed: \(file)")) }
            return true
        }
        try? FileManager.default.createDirectory(atPath: mods, withIntermediateDirectories: true)
        let src = (bundleRes as NSString).appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: src) else { L(tr("package \(file) absent du bundle.", "Package \(file) missing from the app bundle.")); return false }
        try? FileManager.default.removeItem(atPath: dst)
        do { try FileManager.default.copyItem(atPath: src, toPath: dst); L(tr("Package installé : \(file)", "Package installed: \(file)")); return true }
        catch { L(tr("copie package: \(error)", "Copying package: \(error)")); return false }
    }

    // MARK: Shaders (patch à plages vérifiées)
    func hexToBytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count/2)
        var it = s.startIndex
        while it < s.endIndex {
            let nx = s.index(it, offsetBy: 2)
            if let b = UInt8(s[it..<nx], radix: 16) { out.append(b) }
            it = nx
        }
        return out
    }
    func shaderRanges(_ id: String) -> [(Int,[UInt8],[UInt8])]? {
        let patchFiles = ["shader_patches.json", "hdr_tonemap_patch.json"]
        var entry: [String:Any]?
        for file in patchFiles {
            let p = (bundleRes as NSString).appendingPathComponent(file)
            guard let d = FileManager.default.contents(atPath: p),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String:Any] else { continue }
            if let found = obj[id] as? [String:Any] { entry = found; break }
        }
        guard let ranges = entry?["ranges"] as? [[Any]] else { return nil }
        var out = [(Int,[UInt8],[UInt8])]()
        for r in ranges {
            guard r.count == 3, let off = r[0] as? Int, let f = r[1] as? String, let t = r[2] as? String else { return nil }
            out.append((off, hexToBytes(f), hexToBytes(t)))
        }
        return out
    }
    func shaderPath(_ contents: String) -> String {
        (contents as NSString).appendingPathComponent("Resources/Shaders_metal.precomp")
    }
    enum ShaderState { case needsApply, already, incompatible }
    func checkShader(_ data: Data, _ ranges: [(Int,[UInt8],[UInt8])], install: Bool) -> ShaderState {
        var anyToDo = false
        for (off, f, t) in ranges {
            let want = install ? f : t
            let other = install ? t : f
            guard off + f.count <= data.count else { return .incompatible }
            let cur = Array(data[off..<off+f.count])
            if cur == want { anyToDo = true }
            else if cur == other { /* déjà fait pour cette plage */ }
            else { return .incompatible }
        }
        return anyToDo ? .needsApply : .already
    }
    func patchShader(_ contents: String, _ id: String, install: Bool) -> Bool {
        guard let ranges = shaderRanges(id) else { L(tr("données shader absentes pour \(id).", "Shader data missing for \(id).")); return false }
        let path = shaderPath(contents)
        guard var data = FileManager.default.contents(atPath: path) else { L(tr("Shaders_metal.precomp introuvable.", "Shaders_metal.precomp not found.")); return false }
        switch checkShader(data, ranges, install: install) {
        case .already: L(tr("Shader \(id) : déjà dans l'état voulu.", "Shader \(id): already in the requested state.")); return true
        case .incompatible:
            L(tr("Shader \(id) : INCOMPATIBLE avec ta version du jeu (octets différents) : non appliqué, rien touché.", "Shader \(id): incompatible with this game version (bytes differ); no changes made."))
            return false
        case .needsApply: break
        }
        // sauvegarde une seule fois du fichier shader d'origine
        let bdir = (supportDir as NSString).appendingPathComponent("backup")
        try? FileManager.default.createDirectory(atPath: bdir, withIntermediateDirectories: true)
        let shBK = (bdir as NSString).appendingPathComponent("Shaders_metal.precomp.orig")
        if !FileManager.default.fileExists(atPath: shBK) { try? data.write(to: URL(fileURLWithPath: shBK)); L(tr("Sauvegarde shaders créée.", "Shader backup created.")) }
        for (off, f, t) in ranges {
            let want = install ? t : f   // valeur cible
            let from = install ? f : t
            let cur = Array(data[off..<off+f.count])
            if cur == from { data.replaceSubrange(off..<off+from.count, with: want) }
        }
        do { try data.write(to: URL(fileURLWithPath: path)); L(install ? tr("Shader \(id) appliqué.", "Shader \(id) applied.") : tr("Shader \(id) retiré.", "Shader \(id) removed.")) ; return true }
        catch { L(tr("écriture shader: \(error)", "Writing shader: \(error)")); return false }
    }

    // Fichiers de réglages du jeu (GraphicsRules.sgr, Sims3.ini) : remplacements de texte vérifiés, aller-retour exact.
    let configPatches: [(id: String, json: String)] = [("gfxrules", "gfx_rules_patch.json"), ("perfini", "perf_ini_patch.json")]
    func configPatch(_ json: String) -> (file: String, pairs: [(String, String)])? {
        let p = (bundleRes as NSString).appendingPathComponent(json)
        guard let d = FileManager.default.contents(atPath: p),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let file = obj["file"] as? String,
              let pairs = obj["pairs"] as? [[String]] else { return nil }
        return (file, pairs.compactMap { $0.count == 2 ? ($0[0], $0[1]) : nil })
    }
    func occurrences(_ text: String, _ s: String) -> Int { text.components(separatedBy: s).count - 1 }
    func gfxState(_ text: String, _ pairs: [(String, String)], install: Bool) -> ShaderState {
        var todo = false
        for (o, n) in pairs {
            let from = install ? o : n, to = install ? n : o
            if occurrences(text, from) == 1 && occurrences(text, to) == 0 { todo = true }
            else if occurrences(text, to) == 1 && occurrences(text, from) == 0 { }
            else { return .incompatible }
        }
        return todo ? .needsApply : .already
    }
    func patchConfig(_ contents: String, _ json: String, install: Bool) -> Bool {
        guard let cp = configPatch(json) else { L(tr("données \(json) absentes.", "\(json) data missing.")); return false }
        let pairs = cp.pairs, name = (cp.file as NSString).lastPathComponent
        let path = (contents as NSString).appendingPathComponent(cp.file)
        guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { L(tr("\(name) introuvable.", "\(name) not found.")); return false }
        switch gfxState(text, pairs, install: install) {
        case .already: return true
        case .incompatible:
            L(tr("\(name) différent de celui attendu : non modifié.", "\(name) differs from the expected version; not modified."))
            return false
        case .needsApply: break
        }
        let bdir = (supportDir as NSString).appendingPathComponent("backup")
        try? FileManager.default.createDirectory(atPath: bdir, withIntermediateDirectories: true)
        let bk = (bdir as NSString).appendingPathComponent(name + ".orig")
        if !FileManager.default.fileExists(atPath: bk) { try? FileManager.default.copyItem(atPath: path, toPath: bk) }
        for (o, n) in pairs {
            let from = install ? o : n, to = install ? n : o
            if occurrences(text, from) == 1 { text = text.replacingOccurrences(of: from, with: to) }
        }
        do { try text.write(toFile: path, atomically: true, encoding: .utf8)
            L(install ? tr("\(name) : réglages Apple Silicon appliqués.", "\(name): Apple Silicon settings applied.") : tr("\(name) : réglages d'origine remis.", "\(name): original settings restored."))
            return true }
        catch { L(tr("écriture \(name) : \(error)", "Writing \(name): \(error)")); return false }
    }

    func apply() {
        guard !gamePath.isEmpty, let contents = innerContents(gamePath) else { L(tr("Chemin du jeu invalide.", "Invalid game path.")); return }
        busy = true
        DispatchQueue.global().async {
            let anyNative = self.nativeIds.contains { self.enabled[$0] ?? false }
            if anyNative { _ = self.applyNative(contents) }
            else { self.revertNative(contents) } // aucun natif coché => on nettoie le natif
            let anyPkg = self.packageFiles.keys.contains { self.enabled[$0] ?? false }
            let anyOvr = self.overrideFiles.keys.contains { self.enabled[$0] ?? false }
            let modsReady = !(anyPkg || anyOvr) || self.ensureModsSetup()
            for id in self.packageFiles.keys where modsReady || !(self.enabled[id] ?? false) { _ = self.applyPackage(id, install: self.enabled[id] ?? false) }
            for id in self.overrideFiles.keys where modsReady || !(self.enabled[id] ?? false) { _ = self.applyOverride(id, install: self.enabled[id] ?? false) }
            for id in ["redpool","redflash","frostwindows"] { _ = self.patchShader(contents, id, install: self.enabled[id] ?? false) }
            for c in self.configPatches { _ = self.patchConfig(contents, c.json, install: self.enabled[c.id] ?? false) }
            self.clearCaches()
            self.L(tr("Terminé. Relance le jeu pour voir les changements.", "Done. Restart the game to see the changes."))
            DispatchQueue.main.async { self.busy = false }
        }
    }

    func launchGame() {
        guard !gamePath.isEmpty else { return }
        // lance le Sims3Launcher.app (ou The Sims 3.app) puis ferme l'outil
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: gamePath), configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func revertAll() {
        guard !gamePath.isEmpty, let contents = innerContents(gamePath) else { L(tr("Chemin du jeu invalide.", "Invalid game path.")); return }
        busy = true
        DispatchQueue.global().async {
            self.revertNative(contents)
            for id in self.packageFiles.keys { _ = self.applyPackage(id, install: false) }
            for id in self.overrideFiles.keys { _ = self.applyOverride(id, install: false) }
            for id in ["frostwindows","redflash","redpool"] { _ = self.patchShader(contents, id, install: false) }
            for c in self.configPatches { _ = self.patchConfig(contents, c.json, install: false) }
            self.clearCaches()
            self.L(tr("Tout est revenu à l'origine.", "Everything has been restored to its original state."))
            DispatchQueue.main.async { self.busy = false }
        }
    }
}

// MARK: - UI

func sectionTitle(_ k: FixKind) -> String {
    switch k {
    case .native: return tr("AFFICHAGE", "DISPLAY")
    case .package, .override_: return tr("MODS", "MODS")
    case .shader: return tr("SHADERS", "SHADERS")
    case .config: return tr("RÉGLAGES DU JEU", "GAME SETTINGS")
    }
}
// Hauteur adaptée à l'écran (MacBook 13–14 pouces compris), la liste des correctifs défile si besoin.
let windowHeight: CGFloat = {
    let avail = NSScreen.main?.visibleFrame.height ?? 800
    return max(480, min(820, avail - 60))
}()

struct ContentView: View {
    @StateObject var eng = Engine()
    @State private var showingAbout = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TS3 Mac Fixer").font(.title.bold())
                Spacer()
                Button(action: { showingAbout = true }) {
                    Image(systemName: "questionmark.circle").font(.title2)
                }.buttonStyle(.plain).help(tr("À propos","About"))
            }
            Text(tr("Correctifs pour Les Sims 3 sur macOS. À appliquer sur ta propre copie du jeu.",
                    "Fixes for The Sims 3 on macOS. Apply to your own copy of the game."))
                .font(.caption).foregroundColor(.secondary)

            HStack {
                TextField(tr("Chemin de Sims3Launcher.app","Path to Sims3Launcher.app"), text: $eng.gamePath).textFieldStyle(.roundedBorder)
                Button(tr("Parcourir…","Browse…")) { pick() }
                Button(tr("Détecter","Detect")) { eng.autodetect() }
            }

            Divider()
            ScrollView {
            VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(FIXES.enumerated()), id: \.element.id) { i, fix in
                if i == 0 || sectionTitle(FIXES[i - 1].kind) != sectionTitle(fix.kind) {
                    Text(sectionTitle(fix.kind)).font(.caption.bold()).foregroundColor(.secondary)
                        .padding(.top, i == 0 ? 0 : 6)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Toggle(isOn: Binding(get: { eng.enabled[fix.id] ?? false }, set: { eng.enabled[fix.id] = $0 })) {
                        HStack(spacing: 6) {
                            Text(fix.name).fontWeight(.medium)
                            if fix.beta { Text(tr("bêta","beta")).font(.caption2).padding(.horizontal,5).background(Color.orange.opacity(0.25)).cornerRadius(4) }
                        }
                    }
                    if !fix.detail.isEmpty {
                        Text(md(fix.detail)).font(.caption).foregroundColor(.secondary).padding(.leading, 22)
                    }
                }
            }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 8)
            }.frame(minHeight: 160, maxHeight: .infinity)
            Divider()

            HStack {
                Button(action: { eng.apply() }) { Text(tr("Appliquer","Apply")).frame(width:110) }
                    .buttonStyle(.borderedProminent).disabled(eng.busy || eng.gamePath.isEmpty)
                Button(action: { eng.revertAll() }) { Text(tr("Tout annuler","Revert all")) }
                    .disabled(eng.busy || eng.gamePath.isEmpty)
                Spacer()
                Button(action: { eng.launchGame() }) { Text(tr("Lancer le jeu ▶","Launch game ▶")).frame(width:130) }
                    .disabled(eng.busy || eng.gamePath.isEmpty)
                if eng.busy { ProgressView().scaleEffect(0.6) }
            }

            Text(tr("Journal","Log")).font(.caption.bold())
            ScrollView { Text(eng.log).font(.system(.caption, design: .monospaced)).frame(maxWidth:.infinity, alignment:.leading) }
                .frame(height: 110).background(Color(nsColor: .textBackgroundColor)).cornerRadius(6)
        }
        .padding(18).frame(width: 560, height: windowHeight)
        .onAppear { eng.autodetect() }
        .sheet(isPresented: $showingAbout) { AboutView(show: $showingAbout) }
    }

    func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let u = panel.url {
            if eng.innerContents(u.path) != nil { eng.gamePath = u.path; eng.L(tr("Jeu sélectionné : ","Game selected: ") + u.path); eng.detectState() }
            else { eng.L(tr("Ce n'est pas une install TS3 valide : ","Not a valid TS3 install: ") + u.path) }
        }
    }
}

struct AboutView: View {
    @Binding var show: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill").font(.largeTitle).foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TS3 Mac Fixer").font(.title2.bold())
                    Text(tr("Correctifs pour Les Sims 3 macOS 64-bit & Metal",
                            "Fixes for The Sims 3 macOS 64-bit & Metal")).font(.caption).foregroundColor(.secondary)
                }
            }
            Text(.init(tr("by [VHSmodding](https://github.com/VHSMODDING)",
                          "by [VHSmodding](https://github.com/VHSMODDING)")))
            Divider()
            Text(tr("Cet outil modifie ta propre copie du jeu et tout est réversible (« Tout annuler »).",
                    "This tool modifies your own copy of the game and everything is reversible (\"Revert all\").")).font(.callout)
            Text(tr("Si tu veux soutenir mon travail, tu peux m'acheter un café ☕",
                    "If you'd like to support my work, you can buy me a coffee ☕")).font(.callout)
            VStack(spacing: 8) {
                Button(action: { if let u = URL(string: "https://ko-fi.com/vhsmodding") { NSWorkspace.shared.open(u) } }) {
                    Text(tr("Soutenir sur Ko-fi","Support on Ko-fi")).frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                Button(action: { show = false }) {
                    Text(tr("Fermer","Close")).frame(maxWidth: .infinity)
                }.controlSize(.large)
            }
        }
        .padding(20).frame(width: 440)
    }
}

@main struct TS3MacFixesApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
