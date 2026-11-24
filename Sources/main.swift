// Busca Busca Limpa Limpa — libera espaço no SSD interno com um clique.
// Compilar: ./build.sh

import SwiftUI
import AppKit
import Darwin
import SQLite3

// MARK: - Básico

let fm = FileManager.default
let home = NSHomeDirectory()
let ownBundleID = (Bundle.main.bundleIdentifier ?? "com.buscabusca.limpalimpa").lowercased()

func fmtBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
    return f.string(fromByteCount: b)
}

func exists(_ u: URL) -> Bool {
    var st = stat()
    return lstat(u.path, &st) == 0
}

/// Expande caminhos com "~" e curingas ("*") em qualquer componente.
func expand(_ pattern: String) -> [URL] {
    let path = (pattern as NSString).expandingTildeInPath
    var bases = [URL(fileURLWithPath: "/")]
    for comp in path.split(separator: "/").map(String.init) {
        var next: [URL] = []
        for base in bases {
            if comp.contains("*") {
                let kids = (try? fm.contentsOfDirectory(atPath: base.path)) ?? []
                for k in kids.sorted() where k != ".DS_Store" && k != ".localized" && fnmatch(comp, k, 0) == 0 {
                    next.append(base.appendingPathComponent(k))
                }
            } else {
                let u = base.appendingPathComponent(comp)
                if exists(u) { next.append(u) }
            }
        }
        bases = next
        if bases.isEmpty { break }
    }
    return bases
}

/// Espaço real ocupado no disco (não segue links simbólicos).
func allocatedSize(_ url: URL) -> Int64 {
    let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
    guard let rv = try? url.resourceValues(forKeys: keys) else { return 0 }
    if rv.isSymbolicLink == true { return 0 }
    if rv.isDirectory != true { return Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? 0) }
    var total: Int64 = 0
    if let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) {
        for case let f as URL in en {
            if let v = try? f.resourceValues(forKeys: keys), v.isRegularFile == true {
                total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            }
        }
    }
    return total
}

/// Trava de segurança: só apaga dentro de pastas conhecidas de cache/lixo do usuário.
let allowedRoots = [home + "/Library/", home + "/Movies/CacheClip/", home + "/.Trash/", home + "/Downloads/", home + "/.npm/",
                    home + "/.cache/huggingface/", home + "/.ollama/", home + "/.lmstudio/models/",
                    "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Extras/"]
let forbiddenRoots = ["Library/Mobile Documents", "Library/Mail", "Library/Messages", "Library/Photos",
                      "Library/Keychains", "Library/CloudStorage", "Library/Containers", "Library/Group Containers"].map { home + "/" + $0 }

/// Pastas protegidas que podem ser limpas mesmo assim (só estas).
let whatsappMedia = home + "/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media"
let whatsappCaches = home + "/Library/Containers/net.whatsapp.WhatsApp/Data/Library/Caches"
let explicitAllowed = [whatsappMedia + "/", whatsappCaches + "/"]

func isSafe(_ u: URL) -> Bool {
    let p = u.standardizedFileURL.path
    if explicitAllowed.contains(where: { p.hasPrefix($0) && p.count > $0.count }) { return true }
    guard allowedRoots.contains(where: { p.hasPrefix($0) && p.count > $0.count }) else { return false }
    return !forbiddenRoots.contains { p == $0 || p.hasPrefix($0 + "/") }
}

// MARK: - Modelo

enum CleanMode { case delete, trash }

/// Botão extra ao lado de um item (ex.: abrir Ajustes).
struct ItemAction {
    let label: String
    let run: () -> Void
}

struct Target {
    let url: URL
    let name: String
    var hints: [String] = []   // apps que precisam estar fechados (bundle id ou nome)
    var note: String? = nil    // explicação completa (botão ⓘ)
    var warning: String? = nil // aviso curto, sempre visível embaixo do item
    var selected = true        // marcado por padrão dentro da categoria
    var deletable = true       // false = só informa (ex.: arquivos protegidos do macOS)
    var sizeOf: [URL]? = nil   // mede o tamanho destes caminhos em vez de `url`
    var action: ItemAction? = nil
}

struct CategoryDef {
    let key: String
    let name: String
    let icon: String
    let detail: String
    let defaultOn: Bool
    var risky = false
    var mode: CleanMode = .delete
    var info = ""              // explicação mostrada ao passar o mouse
    let resolve: () -> [Target]
}

struct CleanItem: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
    let hints: [String]
    var note: String? = nil
    var warning: String? = nil
    var deletable = true
    var action: ItemAction? = nil
    var selected = true
    var showInfo = false
}

struct CategoryState: Identifiable {
    let def: CategoryDef
    var items: [CleanItem]
    var enabled: Bool
    var expanded = false
    var id: String { def.key }
    var totalSize: Int64 { items.filter(\.deletable).reduce(0) { $0 + $1.size } }
    var selectedSize: Int64 { enabled ? items.filter { $0.selected && $0.deletable }.reduce(0) { $0 + $1.size } : 0 }
    var hasDeletable: Bool { items.contains(where: \.deletable) }
}

// MARK: - Categorias

let chromiumCacheDirs = ["Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
                         "Service Worker/CacheStorage", "Service Worker/ScriptCache"]

func contents(_ pattern: String, hints: [String] = [], label: String? = nil) -> [Target] {
    expand(pattern).map { u in
        Target(url: u, name: label.map { "\($0) › \(u.lastPathComponent)" } ?? u.lastPathComponent, hints: hints)
    }
}

func chromiumProfiles(_ base: String, label: String, hints: [String]) -> [Target] {
    var out: [Target] = []
    for profile in expand(base + "/*") {
        for sub in chromiumCacheDirs {
            let u = profile.appendingPathComponent(sub)
            if exists(u) { out.append(Target(url: u, name: "\(label) › \(profile.lastPathComponent) › \(sub)", hints: hints)) }
        }
    }
    for sub in ["ShaderCache", "GrShaderCache", "GraphiteDawnCache", "component_crx_cache", "Crashpad/completed"] {
        let u = URL(fileURLWithPath: (base as NSString).expandingTildeInPath).appendingPathComponent(sub)
        if exists(u) { out.append(Target(url: u, name: "\(label) › \(sub)", hints: hints)) }
    }
    return out
}

func makeCategories() -> [CategoryDef] {
    let chrome = ["com.google.Chrome"]
    let resolve = ["com.blackmagic-design.DaVinciResolve"]
    let adobe = ["com.adobe.PremierePro", "com.adobe.AfterEffects", "com.adobe.ame", "com.adobe.Audition", "com.adobe.Photoshop"]

    return [
        CategoryDef(key: "chrome", name: "Google Chrome", icon: "globe",
                    detail: "Cache de páginas, vídeos e código. Logins e abas não são afetados.", defaultOn: true,
                    info: "Arquivos temporários que o Chrome guarda para abrir sites mais rápido. Seguro apagar: senhas, favoritos, histórico, logins e abas continuam iguais. Os primeiros sites podem abrir um pouco mais devagar.") {
            contents("~/Library/Caches/Google/Chrome/*", hints: chrome, label: "Chrome")
            + chromiumProfiles("~/Library/Application Support/Google/Chrome", label: "Chrome", hints: chrome)
        },
        CategoryDef(key: "browsers", name: "Outros navegadores", icon: "safari",
                    detail: "Safari, Brave, Edge, Arc, Firefox e Opera.", defaultOn: true,
                    info: "Mesmo tipo de cache temporário dos outros navegadores. Logins e favoritos não são afetados. O Safari só aparece se o app tiver Acesso Total ao Disco.") {
            contents("~/Library/Caches/com.apple.Safari/*", hints: ["com.apple.Safari"], label: "Safari")
            + contents("~/Library/Caches/BraveSoftware/*", hints: ["com.brave.Browser"], label: "Brave")
            + chromiumProfiles("~/Library/Application Support/BraveSoftware/Brave-Browser", label: "Brave", hints: ["com.brave.Browser"])
            + contents("~/Library/Caches/Microsoft Edge/*", hints: ["com.microsoft.edgemac"], label: "Edge")
            + chromiumProfiles("~/Library/Application Support/Microsoft Edge", label: "Edge", hints: ["com.microsoft.edgemac"])
            + contents("~/Library/Caches/Arc/*", hints: ["company.thebrowser.Browser"], label: "Arc")
            + chromiumProfiles("~/Library/Application Support/Arc/User Data", label: "Arc", hints: ["company.thebrowser.Browser"])
            + contents("~/Library/Caches/Firefox/Profiles/*/cache2", hints: ["org.mozilla.firefox"], label: "Firefox")
            + contents("~/Library/Caches/com.operasoftware.Opera/*", hints: ["com.operasoftware.Opera"], label: "Opera")
        },
        CategoryDef(key: "resolve", name: "DaVinci Resolve", icon: "film",
                    detail: "Render cache, mídia otimizada (CacheClip) e logs. O Resolve recria quando precisar.", defaultOn: true,
                    info: "CacheClip guarda render cache (Smart/User) e mídia otimizada. Apagar não mexe em projetos, mídia original, proxies externos nem na database. Ao abrir o projeto, o Resolve renderiza o cache de novo, então a timeline pode ficar mais pesada nos primeiros minutos.") {
            contents("~/Movies/CacheClip/*", hints: resolve, label: "CacheClip")
            + contents("~/Library/Caches/com.blackmagic-design.DaVinciResolve*", hints: resolve)
            + contents("~/Library/Application Support/Blackmagic Design/DaVinci Resolve/logs/*", hints: resolve, label: "Logs")
            + contents("~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Cache/*", hints: resolve, label: "Fusion")
        },
        CategoryDef(key: "adobe", name: "Adobe (Premiere, After Effects…)", icon: "square.stack.3d.up",
                    detail: "Media Cache, Peak Files e Disk Cache. São recriados automaticamente.", defaultOn: true,
                    info: "Arquivos de conformação de áudio, formas de onda e cache de disco do Premiere, After Effects e Media Encoder. A Adobe recria tudo ao abrir o projeto. Seus projetos e mídias não são afetados.") {
            contents("~/Library/Application Support/Adobe/Common/Media Cache Files/*", hints: adobe, label: "Media Cache Files")
            + contents("~/Library/Application Support/Adobe/Common/Media Cache/*", hints: adobe, label: "Media Cache")
            + contents("~/Library/Application Support/Adobe/Common/Peak Files/*", hints: adobe, label: "Peak Files")
            + contents("~/Library/Caches/Adobe/*", hints: adobe, label: "Adobe")
        },
        CategoryDef(key: "apps", name: "Apps (Slack, Discord, Spotify, VS Code, Claude…)", icon: "app.badge",
                    detail: "Cache de apps de comunicação, música e Electron.", defaultOn: true,
                    info: "Cache de apps como Slack, Discord, Claude, VS Code, Notion e músicas offline em cache do Spotify. Conversas, contas e configurações continuam. Apps abertos precisam ser fechados para limpar.") {
            var out = contents("~/Library/Application Support/Spotify/PersistentCache/*", hints: ["com.spotify.client"], label: "Spotify")
            let asup = home + "/Library/Application Support"
            let skip: Set<String> = ["Google", "BraveSoftware", "Microsoft Edge", "Arc", "Blackmagic Design", "Adobe", "Spotify"]
            for name in ((try? fm.contentsOfDirectory(atPath: asup)) ?? []).sorted() where !skip.contains(name) {
                let base = URL(fileURLWithPath: asup).appendingPathComponent(name)
                // Assinatura de app Electron/Chromium
                guard ["Code Cache", "GPUCache"].contains(where: { exists(base.appendingPathComponent($0)) }) else { continue }
                for sub in chromiumCacheDirs + ["CachedData", "Crashpad/completed"] {
                    let u = base.appendingPathComponent(sub)
                    if exists(u) { out.append(Target(url: u, name: "\(name) › \(sub)", hints: [name])) }
                }
            }
            return out
        },
        CategoryDef(key: "dev", name: "Desenvolvimento", icon: "hammer",
                    detail: "Xcode DerivedData, simuladores e cache do npm.", defaultOn: true,
                    info: "Arquivos de compilação e pacotes baixados por ferramentas de programação. Recriados automaticamente no próximo build ou instalação.") {
            contents("~/Library/Developer/Xcode/DerivedData/*", hints: ["com.apple.dt.Xcode"], label: "DerivedData")
            + contents("~/Library/Developer/Xcode/iOS DeviceSupport/*", hints: ["com.apple.dt.Xcode"], label: "DeviceSupport")
            + contents("~/Library/Developer/CoreSimulator/Caches/*", label: "Simulator")
            + contents("~/.npm/_cacache", label: "npm")
        },
        CategoryDef(key: "whatsapp", name: "WhatsApp (mídias baixadas)", icon: "message",
                    detail: "Fotos, vídeos, áudios e documentos que o WhatsApp guarda escondidos.",
                    defaultOn: false, risky: true,
                    info: "O WhatsApp do Mac e o WhatsApp Web guardam todas as mídias recebidas numa pasta escondida, que pode chegar a dezenas de GB. Depois de apagar, a mídia aparece borrada na conversa. Dá para baixar de novo enquanto ainda estiver no celular. Salve antes o que for importante. Nada vem marcado: escolha conversa por conversa.") {
            findWhatsApp()
        },
        CategoryDef(key: "ai", name: "Modelos de IA", icon: "brain",
                    detail: "Modelos baixados por apps de IA. Leia o aviso de cada item antes de marcar.",
                    defaultOn: false, risky: true,
                    info: "Arquivos grandes que apps de IA baixam sozinhos, como Claude, Chrome (Gemini Nano), DaVinci Resolve, Hugging Face, Ollama e LM Studio. Só apague o que você NÃO usa: se o app precisar, ele baixa tudo de novo (vários GB). Nenhum item vem marcado; escolha um por um.") {
            findAIModels()
        },
        CategoryDef(key: "caches", name: "Caches gerais", icon: "archivebox",
                    detail: "Demais caches de apps em ~/Library/Caches. Recriados quando necessário.", defaultOn: true,
                    info: "Pasta onde os apps guardam arquivos temporários. Os apps recriam o que precisarem. Caches do próprio macOS (com.apple…) não são tocados.") {
            let keep: Set<String> = ["CloudKit", "FamilyCircle", "familycircled", "PassKit", "GeoServices"]
            return expand("~/Library/Caches/*").filter { u in
                let n = u.lastPathComponent
                return !keep.contains(n) && !n.hasPrefix("com.apple.") && n.lowercased() != ownBundleID
            }.map { Target(url: $0, name: $0.lastPathComponent) }
        },
        CategoryDef(key: "logs", name: "Logs e relatórios", icon: "doc.text",
                    detail: "Arquivos de log e relatórios de falha antigos.", defaultOn: true,
                    info: "Registros de atividade e de travamentos dos apps. Só servem para diagnóstico técnico.") {
            contents("~/Library/Logs/*")
        },
        CategoryDef(key: "leftovers", name: "Restos de apps desinstalados", icon: "puzzlepiece.extension",
                    detail: "Preferências e dados de apps que não estão mais no Mac. Vão para a Lixeira — revise a lista.",
                    defaultOn: false, risky: true, mode: .trash,
                    info: "Preferências e dados de apps que não estão mais instalados. Por segurança, nada é apagado direto: vai para a Lixeira, e dá para recuperar. Se algum app tiver sido instalado em um disco que não está conectado agora, desmarque os itens dele.") {
            findLeftovers()
        },
        CategoryDef(key: "installers", name: "Instaladores em Downloads", icon: "shippingbox",
                    detail: "Arquivos .dmg e .pkg já usados. Vão para a Lixeira.", defaultOn: false, risky: true, mode: .trash,
                    info: "Instaladores baixados que normalmente não servem mais depois que o app foi instalado. Vão para a Lixeira.") {
            contents("~/Downloads/*.dmg") + contents("~/Downloads/*.pkg")
        },
        CategoryDef(key: "trash", name: "Esvaziar Lixeira", icon: "trash",
                    detail: "Apaga para sempre o que está na Lixeira.", defaultOn: false, risky: true,
                    info: "Apaga definitivamente tudo que está na Lixeira. Não dá para desfazer.") {
            contents("~/.Trash/*")
        },
    ]
}

// MARK: - Varredura

func scanCategories(_ defs: [CategoryDef], enabled: (CategoryDef) -> Bool, progress: (String) -> Void) -> [CategoryState] {
    var claimed: [String] = []
    var results: [CategoryState] = []
    for def in defs {
        progress(def.name)
        var items: [CleanItem] = []
        for t in def.resolve() {
            let s: Int64
            if t.deletable {
                let p = t.url.standardizedFileURL.path
                guard isSafe(t.url) else { continue }
                if claimed.contains(where: { p == $0 || p.hasPrefix($0 + "/") || $0.hasPrefix(p + "/") }) { continue }
                claimed.append(p)
                s = allocatedSize(t.url)
            } else {
                s = (t.sizeOf ?? [t.url]).reduce(0) { $0 + allocatedSize($1) }
            }
            if s > 0 || (!t.deletable && t.sizeOf?.isEmpty == true) {
                items.append(CleanItem(url: t.url, name: t.name, size: s, hints: t.hints, note: t.note, warning: t.warning,
                                       deletable: t.deletable, action: t.action, selected: t.selected))
            }
        }
        items.sort { ($0.deletable ? 0 : 1, -$0.size) < ($1.deletable ? 0 : 1, -$1.size) }
        results.append(CategoryState(def: def, items: items, enabled: enabled(def)))
    }
    return results
}

// MARK: - WhatsApp

/// Lê só os NOMES de contatos e grupos dos bancos locais do WhatsApp (nada sai do Mac, nenhuma mensagem é lida).
/// O formato dos bancos não é documentado, então a leitura é genérica: em cada tabela, junta colunas de texto
/// com "JID"/"LID"/"WHATSAPPID" no nome (identificadores) e colunas com "NAME" (nomes).
func whatsappNames() -> [String: String] {
    let roots = ["group.net.whatsapp.WhatsApp.shared", "group.net.whatsapp.WhatsApp.private"]
        .map { home + "/Library/Group Containers/" + $0 }
    var dbs: [String] = []
    for r in roots {
        for f in (try? fm.contentsOfDirectory(atPath: r)) ?? [] where f.hasSuffix(".sqlite") { dbs.append(r + "/" + f) }
    }
    // Banco das conversas primeiro: o nome da conversa vale mais que o do contato
    dbs.sort { ($0.contains("ChatStorage") ? 0 : 1) < ($1.contains("ChatStorage") ? 0 : 1) }

    var names: [String: String] = [:]
    var links: [(String, String)] = []   // pares LID <-> número do mesmo contato

    for path in dbs {
        var db: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { sqlite3_close(db); continue }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)

        var tables: [String] = []
        var st: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT name FROM sqlite_master WHERE type='table'", -1, &st, nil) == SQLITE_OK {
            while sqlite3_step(st) == SQLITE_ROW { if let c = sqlite3_column_text(st, 0) { tables.append(String(cString: c)) } }
        }
        sqlite3_finalize(st)

        for t in tables {
            let up = t.uppercased()
            if ["MESSAGE", "MEDIA", "RECEIPT", "CALL", "EVENT", "REACTION", "POLL"].contains(where: { up.contains($0) }) { continue }
            var cols: [String] = []
            if sqlite3_prepare_v2(db, "PRAGMA table_info(\"\(t)\")", -1, &st, nil) == SQLITE_OK {
                while sqlite3_step(st) == SQLITE_ROW { if let c = sqlite3_column_text(st, 1) { cols.append(String(cString: c)) } }
            }
            sqlite3_finalize(st)
            let idCols = cols.filter { let u = $0.uppercased(); return u.contains("JID") || u.hasSuffix("LID") || u.contains("WHATSAPPID") }
            let nameCols = cols.filter { let u = $0.uppercased(); return u.contains("NAME") && !u.contains("FILE") && !u.contains("PATH") }
            guard !idCols.isEmpty, !nameCols.isEmpty else { continue }
            let sql = "SELECT " + (idCols + nameCols).map { "\"\($0)\"" }.joined(separator: ",") + " FROM \"\(t)\" LIMIT 200000"
            guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { sqlite3_finalize(st); continue }
            while sqlite3_step(st) == SQLITE_ROW {
                var ids: [String] = []
                for i in 0..<idCols.count {
                    if let c = sqlite3_column_text(st, Int32(i)) { let v = String(cString: c); if v.contains("@") { ids.append(v.lowercased()) } }
                }
                var name: String?
                for j in 0..<nameCols.count {
                    if let c = sqlite3_column_text(st, Int32(idCols.count + j)) {
                        let v = String(cString: c).trimmingCharacters(in: .whitespacesAndNewlines)
                        if looksLikeName(v) { name = v; break }
                    }
                }
                let lids = ids.filter { $0.hasSuffix("@lid") }, pns = ids.filter { $0.hasSuffix("@s.whatsapp.net") }
                if lids.count == 1 && pns.count == 1 { links.append((lids[0], pns[0])) }
                // Só associa nome quando a linha fala de um único contato/grupo
                let distinct = Set(ids)
                if let n = name, distinct.count == 1 || (lids.count == 1 && pns.count == 1 && distinct.count == 2) {
                    for id in distinct where names[id] == nil { names[id] = n }
                }
            }
            sqlite3_finalize(st)
        }
    }
    for (l, p) in links {
        if names[l] == nil, let n = names[p] { names[l] = n }
        if names[p] == nil, let n = names[l] { names[p] = n }
    }
    return names
}

/// Descarta valores que não são nomes (códigos base64, identificadores, números soltos).
func looksLikeName(_ v: String) -> Bool {
    guard !v.isEmpty, v.count <= 80, !v.contains("@") else { return false }
    let b64 = v.range(of: "^[A-Za-z0-9+/_-]+={0,2}$", options: .regularExpression) != nil
    if b64 && (v.hasSuffix("=") || (v.count >= 16 && !v.contains(" "))) { return false }
    if v.hasPrefix("+") && v.dropFirst().contains(where: { $0.isLetter }) { return false }
    return v.contains(where: { $0.isLetter || $0.isNumber })
}

func whatsappLabel(_ jid: String, names: [String: String]) -> String {
    let id = jid.lowercased()
    let isGroup = id.hasSuffix("@g.us")
    if let n = names[id] {
        return isGroup && !n.lowercased().hasPrefix("grupo") ? "Grupo \(n)" : n
    }
    let code = jid.split(separator: "@").first.map(String.init) ?? jid
    if isGroup { return "Grupo sem nome (…\(code.suffix(4)))" }
    if id.hasSuffix("@s.whatsapp.net") { return "+" + code }
    return "Conversa sem nome (…\(code.suffix(4)))"
}

func findWhatsApp() -> [Target] {
    var out: [Target] = []
    let hints = ["net.whatsapp.WhatsApp", "WhatsApp"]
    let mediaNote = "Fotos, vídeos, áudios e documentos recebidos nesta conversa pelo app do WhatsApp no Mac. Depois de apagar, aparecem borrados no chat. Dá para baixar de novo enquanto ainda estiverem no celular. Salve antes o que for importante. As mensagens de texto não são apagadas."

    if fm.fileExists(atPath: whatsappMedia) {
        if let chats = try? fm.contentsOfDirectory(atPath: whatsappMedia) {
            let names = whatsappNames()
            for c in chats where c != ".DS_Store" {
                let label = whatsappLabel(c, names: names)
                out.append(Target(url: URL(fileURLWithPath: whatsappMedia).appendingPathComponent(c),
                                  name: "WhatsApp: \(label)", hints: hints, note: mediaNote, selected: false))
            }
        } else {
            // Pasta existe mas o macOS bloqueou a leitura
            out.append(Target(url: URL(fileURLWithPath: whatsappMedia), name: "WhatsApp: mídias (sem permissão para ler)",
                              note: "O macOS protege a pasta de mídias do WhatsApp. Para o app conseguir medir e limpar, ative-o em Ajustes › Privacidade e Segurança › Acesso Total ao Disco e abra o app de novo.",
                              warning: "Precisa de Acesso Total ao Disco", deletable: false, sizeOf: [],
                              action: ItemAction(label: "Dar permissão") { openSettings("com.apple.preference.security?Privacy_AllFiles") }))
        }
    }
    if fm.fileExists(atPath: whatsappCaches) {
        out += expand(whatsappCaches + "/*").map {
            Target(url: $0, name: "WhatsApp: cache › \($0.lastPathComponent)", hints: hints,
                   note: "Cache temporário do app do WhatsApp. Seguro apagar: conversas e mídias continuam.", selected: true)
        }
    }

    // WhatsApp Web nos navegadores (Chrome, Brave, Edge, Arc)
    let webNote = "Dados que o WhatsApp Web guarda no navegador, incluindo as mídias já abertas. Ao apagar, o WhatsApp Web DESCONECTA, e você vai precisar escanear o QR code de novo pelo celular. Conversas e mídias continuam no celular."
    for (base, label, hint) in [("~/Library/Application Support/Google/Chrome", "Chrome", "com.google.Chrome"),
                                ("~/Library/Application Support/BraveSoftware/Brave-Browser", "Brave", "com.brave.Browser"),
                                ("~/Library/Application Support/Microsoft Edge", "Edge", "com.microsoft.edgemac"),
                                ("~/Library/Application Support/Arc/User Data", "Arc", "company.thebrowser.Browser")] {
        for u in expand(base + "/*/IndexedDB/https_web.whatsapp.com_*") {
            out.append(Target(url: u, name: "WhatsApp Web no \(label) (\(u.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent))",
                              hints: [hint], note: webNote, warning: "Desconecta o WhatsApp Web: será preciso ler o QR code de novo", selected: false))
        }
    }
    return out
}

// MARK: - Modelos de IA

func openSettings(_ pane: String) {
    if let u = URL(string: "x-apple.systempreferences:" + pane) { NSWorkspace.shared.open(u) }
}

func findAIModels() -> [Target] {
    var out: [Target] = []
    let asup = home + "/Library/Application Support"

    // Claude: máquina virtual do Cowork / modo agente
    for (sub, label) in [("vm_bundles", "Claude: máquina virtual (Cowork e modo agente)"), ("claude-code-vm", "Claude: máquina virtual do Claude Code")] {
        let u = URL(fileURLWithPath: asup + "/Claude/" + sub)
        if exists(u) {
            out.append(Target(url: u, name: label, hints: ["Claude", "com.anthropic.claudefordesktop"],
                              note: "Ambiente que o app do Claude baixa para rodar tarefas no Mac (Cowork, modo agente, Claude Code no app). Se você usa o Claude no Mac, NÃO apague: na próxima tarefa ele baixa tudo de novo (cerca de 10 GB). Só vale apagar se você não usa esses recursos.",
                              warning: "Se você usa o Claude no Mac, não apague: ele baixa tudo de novo", selected: false))
        }
    }

    // Chrome: Gemini Nano
    for (sub, label) in [("OptGuideOnDeviceModel", "Chrome: Gemini Nano (IA no navegador)"),
                         ("optimization_guide_model_store", "Chrome: modelos auxiliares de IA")] {
        let u = URL(fileURLWithPath: asup + "/Google/Chrome/" + sub)
        if exists(u) {
            out.append(Target(url: u, name: label, hints: ["com.google.Chrome"],
                              note: """
                              Modelo de IA que o Chrome baixa sozinho (\"Ajude-me a escrever\", resumos, detecção de golpes). Se você só apagar, o Chrome baixa de novo. Desative antes:

                              Como desativar o Gemini Nano:
                              1. Feche este aviso e clique em \"Config. do Chrome\" (ou digite chrome://settings/system na barra do Chrome).
                              2. Desligue \"IA no dispositivo\" (On-device AI). O Chrome apaga o modelo e não baixa mais.
                              3. Se essa opção não aparecer: digite chrome://flags, procure \"Enables optimization guide on device\", mude para Disabled e clique em Reiniciar.
                              4. Depois volte aqui e apague o item.
                              """,
                              warning: "Desative a IA no Chrome antes, senão ele baixa de novo", selected: false,
                              action: ItemAction(label: "Config. do Chrome") {
                                  let p = Process()
                                  p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                                  p.arguments = ["-a", "Google Chrome", "chrome://settings/system"]
                                  try? p.run()
                              }))
        }
    }

    // DaVinci Resolve: pacotes de IA baixados (Extras)
    let extras = URL(fileURLWithPath: "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Extras")
    for u in expand(extras.path + "/*") {
        let isVoice = exists(u.appendingPathComponent("VoiceTraining"))
        out.append(Target(url: u, name: isVoice ? "DaVinci Resolve: treino de voz (Voice Training)"
                                                : "DaVinci Resolve: pacote de IA \(u.lastPathComponent.prefix(6))",
                          hints: ["com.blackmagic-design.DaVinciResolve"],
                          note: "Modelos de IA que o Resolve baixa para recursos como Voice Isolation, Magic Mask, IntelliScript e conversão de voz. Se você usa esses recursos, NÃO apague: o Resolve vai pedir para baixar de novo, ou o recurso deixa de funcionar até reinstalar o Resolve.",
                          warning: "Se você usa Voice Isolation ou Magic Mask, não apague", selected: false))
    }

    // Hugging Face (Whisper, MLX, etc.). Os arquivos ficam em pasta compartilhada, então é um item só.
    let hf = URL(fileURLWithPath: home + "/.cache/huggingface/hub")
    if exists(hf) {
        let models = expand(hf.path + "/models--*").map {
            $0.lastPathComponent.replacingOccurrences(of: "models--", with: "").replacingOccurrences(of: "--", with: "/")
        }
        out.append(Target(url: hf, name: "Hugging Face: " + (models.isEmpty ? "modelos baixados" : models.joined(separator: ", ")),
                          note: "Modelos baixados por ferramentas de IA (ex.: transcrição com Whisper, apps com MLX): \(models.joined(separator: ", ")). Se a ferramenta for usada de novo, ela baixa os modelos outra vez.",
                          warning: "A ferramenta baixa de novo se for usada", selected: false))
    }

    // Ollama e LM Studio
    let ollama = URL(fileURLWithPath: home + "/.ollama/models")
    if exists(ollama) {
        out.append(Target(url: ollama, name: "Ollama: todos os modelos", hints: ["Ollama"],
                          note: "Todos os modelos de IA locais do Ollama. Para apagar só alguns, use \"ollama rm <modelo>\" no Terminal.",
                          warning: "Apaga todos os modelos do Ollama", selected: false))
    }
    for u in expand("~/.lmstudio/models/*/*") {
        out.append(Target(url: u, name: "LM Studio: \(u.deletingLastPathComponent().lastPathComponent)/\(u.lastPathComponent)",
                          hints: ["LM Studio"], note: "Modelo de IA local baixado no LM Studio. Dá para baixar de novo pelo próprio app.",
                          selected: false))
    }

    // Apple Intelligence: protegido pelo macOS, só informa e leva aos Ajustes
    let prefixes = ["com_apple_MobileAsset_UAF_FM_", "com_apple_MobileAsset_UAF_IF_", "com_apple_MobileAsset_UAF_Photos_",
                    "com_apple_MobileAsset_UAF_Handwriting", "com_apple_MobileAsset_UAF_Summarization",
                    "com_apple_MobileAsset_UAF_Shortcuts_Generator", "com_apple_MobileAsset_UAF_TKModel",
                    "com_apple_MobileAsset_ImageCaptionModel"]
    var aiDirs: [URL] = []
    for root in ["/System/Library/AssetsV2", "/private/var/MobileAsset/AssetsV2"] {
        for name in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where prefixes.contains(where: { name.hasPrefix($0) }) {
            aiDirs.append(URL(fileURLWithPath: root).appendingPathComponent(name))
        }
    }
    if !aiDirs.isEmpty {
        out.append(Target(url: URL(fileURLWithPath: "/System/Library/AssetsV2"), name: "Apple Intelligence (modelos do macOS)",
                          note: "Modelos que o macOS instala sozinho nas atualizações (Ferramentas de Escrita, resumos, Image Playground, Limpar nas Fotos). Ficam numa pasta protegida do sistema, então nenhum app pode apagá-los. Para liberar esse espaço: Ajustes › Apple Intelligence e Siri › desative Apple Intelligence. O macOS remove os modelos sozinho; se você reativar, ele baixa de novo.",
                          warning: "Protegido pelo macOS: desative nos Ajustes para liberar", deletable: false, sizeOf: aiDirs,
                          action: ItemAction(label: "Abrir Ajustes") { openSettings("com.apple.Siri-Settings.extension") }))
    }
    return out
}

// MARK: - Restos de apps desinstalados

func installedBundleIDs() -> Set<String> {
    var ids = Set<String>()
    func add(_ path: String) {
        if let id = Bundle(path: path)?.bundleIdentifier { ids.insert(id.lowercased()) }
    }
    // Spotlight encontra apps em qualquer lugar (inclusive discos externos)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    p.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    if (try? p.run()) != nil {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        String(decoding: data, as: UTF8.self).split(separator: "\n").forEach { add(String($0)) }
    }
    for root in ["/Applications", "/System/Applications", home + "/Applications", "/System/Library/CoreServices"] {
        guard let en = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: nil,
                                     options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
        for case let u as URL in en {
            if en.level > 4 { en.skipDescendants(); continue }
            if u.pathExtension == "app" { add(u.path) }
        }
    }
    NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).forEach { ids.insert($0.lowercased()) }
    for dir in [home + "/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"] {
        for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.hasSuffix(".plist") {
            ids.insert(String(f.dropLast(6)).lowercased())
        }
    }
    return ids
}

func vendor(_ id: String) -> String { id.lowercased().split(separator: ".").prefix(2).joined(separator: ".") }

func looksLikeBundleID(_ n: String) -> Bool {
    let parts = n.split(separator: ".")
    guard parts.count >= 3, !n.contains(" "), let first = parts.first,
          (2...7).contains(first.count), first.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return false }
    return true
}

func findLeftovers() -> [Target] {
    let installed = installedBundleIDs()
    // Conservador: se existe QUALQUER app instalado do mesmo fabricante, não mexe.
    // Fabricantes de componentes do próprio macOS, que não têm .app
    let vendors = Set(installed.map(vendor)).union(["org.cups", "com.openssh", "org.openssh", "com.vmware.fusion"])
    let places: [(String, String)] = [
        ("Application Support", "Dados"), ("Preferences", "Preferências"),
        ("Saved Application State", "Estado salvo"), ("HTTPStorages", "Cookies"), ("WebKit", "WebKit"),
        ("Application Scripts", "Scripts"),
    ]
    var out: [Target] = []
    for (dir, label) in places {
        let base = URL(fileURLWithPath: home + "/Library/" + dir)
        for name in ((try? fm.contentsOfDirectory(atPath: base.path)) ?? []).sorted() {
            var id = name
            for suf in [".plist", ".savedState", ".binarycookies"] where id.hasSuffix(suf) { id = String(id.dropLast(suf.count)) }
            let low = id.lowercased()
            guard looksLikeBundleID(id), !low.hasPrefix("com.apple."), !low.hasPrefix("group."),
                  !low.contains("apple"), low != ownBundleID, !low.hasPrefix(ownBundleID),
                  !installed.contains(low), !vendors.contains(vendor(low)) else { continue }
            out.append(Target(url: base.appendingPathComponent(name), name: "\(id) — \(label)"))
        }
    }
    return out
}

// MARK: - Apps abertos

func matchingApps(_ hints: [String], in apps: [NSRunningApplication]) -> [NSRunningApplication] {
    let hs = hints.map { $0.lowercased() }
    return apps.filter { app in
        let bid = app.bundleIdentifier?.lowercased() ?? ""
        let nm = app.localizedName?.lowercased() ?? ""
        return hs.contains { h in (h.contains(".") && !bid.isEmpty && bid.hasPrefix(h)) || nm == h }
    }
}

func otherRunningApps() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
        $0.processIdentifier != getpid() && $0.activationPolicy == .regular && !$0.isTerminated
    }
}

// MARK: - Motor

enum Phase: Equatable { case idle, scanning(String), cleaning(String) }

struct CleanResult { let freed: Int64; let trashed: Int64; let failed: Int }

final class Cleaner: ObservableObject {
    @Published var cats: [CategoryState] = [] {
        didSet { for c in cats { UserDefaults.standard.set(c.enabled, forKey: "enabled.\(c.def.key)") } }
    }
    @Published var phase: Phase = .idle
    @Published var free: Int64 = 0
    @Published var total: Int64 = 0
    @Published var result: CleanResult?
    @Published var hasFullDiskAccess = true

    var busy: Bool { phase != .idle }
    var selectedTotal: Int64 { cats.reduce(0) { $0 + $1.selectedSize } }

    func refreshDisk() {
        let url = URL(fileURLWithPath: home)
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            free = v.volumeAvailableCapacityForImportantUsage ?? 0
            total = Int64(v.volumeTotalCapacity ?? 0)
        }
        hasFullDiskAccess = (try? fm.contentsOfDirectory(atPath: home + "/Library/Safari")) != nil
    }

    func scan() {
        guard !busy || phase == .idle else { return }
        phase = .scanning("")
        let defs = makeCategories()
        let saved = UserDefaults.standard
        DispatchQueue.global(qos: .userInitiated).async {
            let results = scanCategories(defs, enabled: { saved.object(forKey: "enabled.\($0.key)") as? Bool ?? $0.defaultOn },
                                         progress: { name in DispatchQueue.main.async { self.phase = .scanning(name) } })
            DispatchQueue.main.async {
                var r = results
                if CommandLine.arguments.contains("--expand") { for i in r.indices { r[i].expanded = true } }
                self.cats = r
                self.phase = .idle
                self.refreshDisk()
            }
        }
    }

    func clean() {
        var work: [(CleanMode, CleanItem)] = []
        for c in cats where c.enabled { for i in c.items where i.selected && i.deletable { work.append((c.def.mode, i)) } }
        guard !work.isEmpty, !busy else { return }

        // Confirmação só quando há itens que não são cache
        let risky = cats.filter { $0.enabled && $0.def.risky && $0.selectedSize > 0 }
        if !risky.isEmpty {
            let a = NSAlert()
            a.messageText = "Confirmar limpeza"
            a.informativeText = "Além dos caches, você marcou:\n\n" + risky.map { c in
                "• \(c.def.name) (\(fmtBytes(c.selectedSize)))" + (c.def.mode == .trash ? " → vai para a Lixeira" : " → apagado para sempre")
            }.joined(separator: "\n")
            a.addButton(withTitle: "Limpar")
            a.addButton(withTitle: "Cancelar")
            if a.runModal() != .alertFirstButtonReturn { return }
        }

        // Apps que precisam ser fechados
        let blocking = matchingApps(Array(Set(work.flatMap { $0.1.hints })), in: otherRunningApps())
        var shouldClose = false
        if !blocking.isEmpty {
            let names = Array(Set(blocking.compactMap(\.localizedName))).sorted()
            let a = NSAlert()
            a.messageText = "Feche estes apps para limpar o cache deles"
            a.informativeText = names.map { "• \($0)" }.joined(separator: "\n")
                + "\n\nSalve seus projetos antes. Se preferir, a limpeza continua sem eles."
            a.addButton(withTitle: "Fechar apps e limpar")
            a.addButton(withTitle: "Limpar sem eles")
            a.addButton(withTitle: "Cancelar")
            switch a.runModal() {
            case .alertFirstButtonReturn: shouldClose = true
            case .alertSecondButtonReturn: break
            default: return
            }
        }

        let emptyTrash = cats.first { $0.def.key == "trash" }?.enabled ?? false
        result = nil
        phase = .cleaning("Preparando…")
        if shouldClose { blocking.forEach { $0.terminate() } }

        DispatchQueue.global(qos: .userInitiated).async {
            if shouldClose {
                for _ in 0..<40 where blocking.contains(where: { !$0.isTerminated }) { usleep(500_000) }
            }
            let stillRunning = otherRunningApps()
            var freed: Int64 = 0, trashed: Int64 = 0, failed = 0
            // Primeiro o que vai para a Lixeira, depois o que é apagado
            for (mode, item) in work.sorted(by: { $0.0 == .trash && $1.0 == .delete }) {
                if !item.hints.isEmpty && !matchingApps(item.hints, in: stillRunning).isEmpty { failed += 1; continue }
                guard isSafe(item.url) else { continue }
                DispatchQueue.main.async { self.phase = .cleaning(item.name) }
                if mode == .trash {
                    var resulting: NSURL?
                    if (try? fm.trashItem(at: item.url, resultingItemURL: &resulting)) != nil {
                        if emptyTrash, let r = resulting as URL?, (try? fm.removeItem(at: r)) != nil { freed += item.size }
                        else { trashed += item.size }
                    } else { failed += 1 }
                } else {
                    try? fm.removeItem(at: item.url)
                    let remaining = exists(item.url) ? allocatedSize(item.url) : 0
                    freed += max(0, item.size - remaining)
                    if remaining > 0 { failed += 1 }
                }
            }
            DispatchQueue.main.async {
                self.result = CleanResult(freed: freed, trashed: trashed, failed: failed)
                self.phase = .idle
                self.scan()
            }
        }
    }
}

// MARK: - Interface

/// Paleta Social da Trendsy. Cores de texto têm variante para o modo claro (contraste ≥ 4.5:1).
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(NSColor(name: nil) { a in
        NSColor(hex: a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
    })
}
enum Brand {
    static let lime = Color(NSColor(hex: 0xCEEE4B))                // preenchimentos (texto preto em cima: 16:1)
    static let limeText = dynamic(light: 0x3F4A0A, dark: 0xCEEE4B) // 7.8:1 no claro, 13.8:1 no escuro
    static let blue = dynamic(light: 0x2A64B4, dark: 0x99C3FA)
    static let background = dynamic(light: 0xE8E8E8, dark: 0x151519)
    static let support = Color(NSColor(hex: 0x565656))
}
/// Poppins vai dentro do app (licença OFL). Se faltar, o sistema usa a fonte padrão.
func poppins(_ weight: String, _ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
    .custom("Poppins-\(weight)", size: size, relativeTo: style)
}

/// Botão principal: painel lima com texto preto em caixa alta, como nas peças Trendsy.
struct LimeButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.black)
            .background(Brand.lime, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .contentShape(Capsule())
    }
}

/// Símbolo com alternativa para macOS mais antigos.
func symbol(_ name: String, fallback: String) -> String {
    NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : fallback
}
let cleanSymbol = symbol("bubbles.and.sparkles", fallback: "sparkles")

struct ContentView: View {
    @ObservedObject var c: Cleaner
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    var safeIdx: [Int] { c.cats.indices.filter { !c.cats[$0].def.risky && !c.cats[$0].items.isEmpty } }
    var reviewIdx: [Int] { c.cats.indices.filter { c.cats[$0].def.risky && !c.cats[$0].items.isEmpty } }
    var emptyNames: [String] { c.cats.filter { $0.items.isEmpty }.map(\.def.name) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List {
                if !safeIdx.isEmpty {
                    Section {
                        ForEach(safeIdx, id: \.self) { i in CategoryRow(cat: $c.cats[i], busy: c.busy) }
                    } header: {
                        Label("Seguro limpar · o app recria sozinho", systemImage: "checkmark.shield")
                            .foregroundStyle(Brand.limeText)
                    }
                }
                if !reviewIdx.isEmpty {
                    Section {
                        ForEach(reviewIdx, id: \.self) { i in CategoryRow(cat: $c.cats[i], busy: c.busy) }
                    } header: {
                        Label("Revise antes de apagar", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if !emptyNames.isEmpty && !c.cats.isEmpty {
                    Section {
                        Text("Nada encontrado em: " + emptyNames.joined(separator: ", "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay { if c.cats.isEmpty { ProgressView("Analisando o Mac…") } }
        }
        .background(Brand.background)
        .frame(minWidth: 600, minHeight: 640)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { c.scan() } label: { Label("Analisar de novo", systemImage: "arrow.clockwise") }
                    .help("Analisar o Mac de novo (⌘R)")
                    .disabled(c.busy)
            }
        }
        .onAppear { c.refreshDisk(); c.scan() }
    }

    var buttonLabel: String {
        switch c.phase {
        case .scanning(let s): return s.isEmpty ? "Analisando…" : "Analisando \(s)…"
        case .cleaning: return "Limpando…"
        case .idle: return c.selectedTotal > 0 ? "Liberar \(fmtBytes(c.selectedTotal))" : "Nada marcado para limpar"
        }
    }

    var buttonText: String { buttonLabel.uppercased(with: Locale(identifier: "pt_BR")) }

    var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            DiskBar(free: c.free, total: c.total, freeing: c.busy ? 0 : c.selectedTotal, reduceMotion: reduceMotion)

            if !c.hasFullDiskAccess {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield").foregroundStyle(.orange)
                    Text("Sem Acesso Total ao Disco: WhatsApp, Lixeira e Safari ficam de fora.")
                        .font(.callout)
                    Spacer()
                    Button("Permitir…") { openSettings("com.apple.preference.security?Privacy_AllFiles") }
                }
                .padding(10)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            Button(action: c.clean) {
                HStack(spacing: 10) {
                    if c.busy { ProgressView().controlSize(.small).colorScheme(.light) } else { Image(systemName: cleanSymbol) }
                    Text(buttonText).lineLimit(1).truncationMode(.middle)
                }
                .font(poppins("ExtraBoldItalic", 18, relativeTo: .title3))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(LimeButtonStyle())
            .accessibilityLabel(buttonLabel)
            .disabled(c.busy || c.selectedTotal == 0)

            if case .cleaning(let s) = c.phase {
                Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }

            if let r = c.result {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.limeText).font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PRONTO! \(fmtBytes(r.freed)) LIBERADOS")
                            .font(poppins("ExtraBoldItalic", 15, relativeTo: .headline))
                        if r.trashed > 0 { Text("\(fmtBytes(r.trashed)) foram para a Lixeira. Esvazie a Lixeira para liberar.").font(.callout) }
                        if r.failed > 0 { Text("\(r.failed) itens estavam em uso e foram pulados.").font(.callout).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Button { c.result = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Fechar aviso")
                }
                .padding(10)
                .background(Brand.lime.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(20)
    }
}

/// Barra do SSD com prévia do "depois da limpeza".
struct DiskBar: View {
    let free: Int64, total: Int64, freeing: Int64
    let reduceMotion: Bool

    var usedRatio: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
    var freeingRatio: Double { total > 0 ? min(Double(freeing) / Double(total), usedRatio) : 0 }
    var tint: Color { usedRatio > 0.9 ? .red : usedRatio > 0.8 ? .orange : Brand.blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Label("SSD interno", systemImage: "internaldrive").font(poppins("SemiBold", 14, relativeTo: .headline))
                Spacer()
                Text("\(fmtBytes(free)) livres de \(fmtBytes(total))").font(.body).monospacedDigit()
            }
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(tint).frame(width: max(0, w * usedRatio))
                    // trecho que vai ficar livre
                    Rectangle().fill(Brand.lime)
                        .frame(width: max(4, w * freeingRatio))
                        .offset(x: max(0, w * (usedRatio - freeingRatio) - (w * freeingRatio < 4 ? 4 - w * freeingRatio : 0)))
                        .opacity(freeing > 0 ? 1 : 0)
                }
                .clipShape(Capsule())
            }
            .frame(height: 10)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.6), value: free)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: freeing)
            .accessibilityElement()
            .accessibilityLabel("Uso do SSD interno")
            .accessibilityValue("\(Int(usedRatio * 100)) por cento usado")

            Text(freeing > 0 ? "Depois da limpeza: \(fmtBytes(free + freeing)) livres (+\(fmtBytes(freeing)))" : " ")
                .font(.callout).monospacedDigit()
                .foregroundStyle(Brand.limeText)
        }
    }
}

struct CategoryRow: View {
    @Binding var cat: CategoryState
    let busy: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $cat.expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if !cat.def.info.isEmpty {
                    Text(cat.def.info)
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 2)
                }
                ForEach(Array(cat.items.indices.prefix(300)), id: \.self) { i in itemRow(i) }
                if cat.items.count > 300 {
                    Text("+ \(cat.items.count - 300) itens").font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 34)
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 10) {
                Toggle(cat.def.name, isOn: Binding(get: { cat.enabled && cat.hasDeletable }, set: { cat.enabled = $0 }))
                    .labelsHidden().toggleStyle(.checkbox)
                    .disabled(!cat.hasDeletable || busy)
                Image(systemName: cat.def.icon)
                    .frame(width: 22)
                    .foregroundStyle(cat.def.risky ? Color.orange : Brand.blue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cat.def.name).fontWeight(.medium)
                    Text(cat.def.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                .contentShape(Rectangle())
                .onTapGesture { cat.expanded.toggle() }
                Spacer()
                Text(cat.hasDeletable ? fmtBytes(cat.enabled ? cat.selectedSize : cat.totalSize) : "—")
                    .monospacedDigit()
                    .foregroundStyle(cat.enabled ? .primary : .secondary)
                    .accessibilityLabel(cat.enabled ? "\(fmtBytes(cat.selectedSize)) marcados" : "\(fmtBytes(cat.totalSize)) encontrados")
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    func itemRow(_ i: Int) -> some View {
        let item = cat.items[i]
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if item.deletable {
                    Toggle(item.name, isOn: $cat.items[i].selected).labelsHidden().toggleStyle(.checkbox)
                        .disabled(busy || !cat.enabled)
                } else {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).frame(width: 14)
                        .accessibilityLabel("Não pode ser apagado pelo app")
                }
                Text(item.name).lineLimit(1).truncationMode(.middle)
                    .help(item.url.path)
                if let note = item.note {
                    Button { cat.items[i].showInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .frame(minWidth: 20, minHeight: 20)
                        .help("Saiba mais")
                        .accessibilityLabel("Saiba mais sobre \(item.name)")
                        .popover(isPresented: $cat.items[i].showInfo, arrowEdge: .trailing) {
                            Text(note)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: 340, alignment: .leading)
                                .padding(16)
                        }
                }
                Spacer()
                if let a = item.action {
                    Button(a.label, action: a.run).controlSize(.small)
                }
                Text(item.size > 0 ? fmtBytes(item.size) : "—").monospacedDigit().foregroundStyle(.secondary)
            }
            if let w = item.warning {
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(.leading, item.deletable ? 22 : 20)
            }
        }
        .font(.callout)
        .contextMenu {
            Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// `LimpaLimpa --scan` lista o que seria limpo, sem apagar nada.
func dryRun() {
    var grand: Int64 = 0
    for c in scanCategories(makeCategories(), enabled: { $0.defaultOn }, progress: { _ in }) {
        if c.def.defaultOn { grand += c.totalSize }
        print("\n[\(c.def.defaultOn ? "x" : " ")] \(c.def.name): \(fmtBytes(c.totalSize)) em \(c.items.count) itens")
        for i in c.items.prefix(10) {
            print("   \(i.deletable ? (i.selected ? "x" : "-") : "i") \(fmtBytes(i.size))\t\(i.name)\t\(i.url.path)")
        }
    }
    print("\nTotal marcado por padrão: \(fmtBytes(grand))")
}

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--scan") { dryRun(); return }
        if CommandLine.arguments.contains("--wa-check") {
            let chats = ((try? fm.contentsOfDirectory(atPath: whatsappMedia)) ?? []).filter { $0.contains("@") }
            let names = whatsappNames()
            let named = chats.filter { names[$0.lowercased()] != nil }
            print("conversas: \(chats.count), com nome: \(named.count), nomes no banco: \(names.count)")
            for k in ["@g.us", "@lid", "@s.whatsapp.net"] {
                let all = chats.filter { $0.hasSuffix(k) }
                print("  \(k): \(all.filter { names[$0.lowercased()] != nil }.count)/\(all.count)")
            }
            return
        }
        LimpaLimpaApp.main()
    }
}

struct LimpaLimpaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var cleaner = Cleaner()

    var body: some Scene {
        WindowGroup("Busca Busca Limpa Limpa") { ContentView(c: cleaner) }
            .windowResizability(.contentMinSize)
            .commands { CleanerCommands(c: cleaner) }
    }
}

struct CleanerCommands: Commands {
    @ObservedObject var c: Cleaner
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Analisar de novo") { c.scan() }
                .keyboardShortcut("r")
                .disabled(c.busy)
            Button(c.selectedTotal > 0 ? "Liberar \(fmtBytes(c.selectedTotal))" : "Liberar espaço") { c.clean() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(c.busy || c.selectedTotal == 0)
        }
    }
}
