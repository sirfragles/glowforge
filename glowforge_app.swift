// glowforge — wybierasz font, kręcisz jasnością, widzisz na żywo, zapisujesz.
//
// Trzy warunki, które muszą zachodzić jednocześnie, żeby EDR zadziałał:
//   1. kontekst CG w extendedLinearSRGB (1.0 = biel SDR, wartości > 1.0 legalne)
//   2. tekstura .rgba16Float + warstwa z wantsExtendedDynamicRangeContent
//   3. mało jasnych plam — panel XDR obniża zapas przy wysokim APL
//
// Jasność glifów jest WYPALONA w pliku fontu, więc suwak działa tak:
//   - podczas przeciągania: tekst rysowany obrysami w wybranej jasności (natychmiast)
//   - po puszczeniu: glowforge przebudowuje prawdziwy font i podmienia go (0,5 s)
//
// Budowanie:    swiftc -O glowforge_app.swift -o glowforge_app
// Uruchomienie: ./glowforge_app

import AppKit
import CoreText
import Metal
import MetalKit

let CONTENT_W = 1600
let CONTENT_H = 900
let MARGIN: CGFloat = 70

// Repozytorium moze lezec w roznych miejscach — szukamy glowforge.py,
// zeby dalo sie uruchomic aplikacje zarowno z ~/glowforge, jak i ze
// starego ~/web_hdr/glowforge bez przerabiania sciezek.
let REPO: String = {
    for k in ["~/glowforge", "~/web_hdr/glowforge"] {
        let p = (k as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: p + "/glowforge.py") { return p }
    }
    return ("~/glowforge" as NSString).expandingTildeInPath
}()
let FORGE = REPO + "/glowforge"
let TMPFONT = REPO + "/out/_podglad.ttf"
let INSTALLDIR = ("~/Library/Fonts" as NSString).expandingTildeInPath

// Nazwa fontu podglądowego MUSI być unikalna. Gdyby była taka sama jak fontu
// już zainstalowanego w systemie, rejestracja w procesie kończy się konfliktem
// (kCTFontManagerErrorAlreadyRegistered) i podgląd nigdy nie wchodzi w tryb
// „na żywo". Do instalacji budujemy osobny plik pod właściwą nazwą.
let PREVIEW_NAME = "GlowForge Preview"

// ===========================================================================
// 0. Stan
// ===========================================================================

struct Face {
    let family: String
    let sub: String
    let ps: String
    let path: String
}

var faces: [Face] = []
var sourceFace: Face?
var sourceFont: CTFont?
var glowFont: CTFont?
var glowIsReal = false          // czy dolna linia to prawdziwe bitmapy, czy obrys
var level: CGFloat = 8.0
var sampleText = "Warszawa 0123"
var statusLine = "wybieram font..."
var registeredURL: URL?
var building = false
var installing = false
var renderer: Renderer?
var statusLabel: NSTextField?
var debounce: Timer?

// ===========================================================================
// 1. glowforge z linii poleceń + rejestracja fontów
// ===========================================================================

func runForge(_ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: FORGE)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "nie moge uruchomic glowforge: \(error)") }
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}

func loadFaces() -> [Face] {
    let (code, out) = runForge(["list", "--tsv"])
    guard code == 0 else { return [] }
    var seen = Set<String>()
    var list: [Face] = []
    for line in out.split(separator: "\n") {
        let c = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard c.count >= 4, !c[2].isEmpty, !c[0].isEmpty else { continue }
        // Pomijamy fonty, ktore maja juz tabele sbix — czyli nasze wlasne
        // produkty. Konwertowanie skonwertowanego fontu nie ma sensu i tylko
        // zasmieca liste.
        if c.count >= 5, c[4].split(separator: ",").contains("sbix") {
            loguj("[lista] pomijam (ma juz sbix): \(c[0])")
            continue
        }
        if seen.contains(c[2].lowercased()) { continue }
        seen.insert(c[2].lowercased())
        list.append(Face(family: c[0], sub: c[1], ps: c[2], path: c[3]))
    }
    return list.sorted { $0.family.lowercased() < $1.family.lowercased() }
}

/// Rejestruje font tylko w tym procesie — bez instalowania w systemie.
/// Przed rejestracją nowego wyrejestrowuje poprzedni, bo kolejne przebudowy
/// dają ten sam PostScript name i system by je odrzucił jako duplikat.
@discardableResult
func registerGlow(_ path: String) -> CTFont? {
    if let u = registeredURL {
        CTFontManagerUnregisterFontsForURL(u as CFURL, .process, nil)
        registeredURL = nil
    }
    let url = URL(fileURLWithPath: path) as CFURL
    var err: Unmanaged<CFError>?
    guard CTFontManagerRegisterFontsForURL(url, .process, &err) else { return nil }
    registeredURL = url as URL
    guard let ds = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor],
          let d = ds.first else { return nil }
    return CTFontCreateWithFontDescriptor(d, 0, nil)
}

func fileSizeMB(_ path: String) -> Double {
    let a = try? FileManager.default.attributesOfItem(atPath: path)
    return Double((a?[.size] as? Int) ?? 0) / 1048576.0
}

/// Dziennik zdarzen. Bez tego nie ma jak dojsc, co zawiodlo w GUI.
let LOGCEST = ("~/web_hdr/glowforge_app.log" as NSString).expandingTildeInPath
func loguj(_ s: String) {
    let linia = s + "\n"
    if let h = FileHandle(forWritingAtPath: LOGCEST) {
        h.seekToEndOfFile()
        h.write(linia.data(using: .utf8)!)
        h.closeFile()
    } else {
        try? linia.write(toFile: LOGCEST, atomically: true, encoding: .utf8)
    }
    print(s)
}

// ===========================================================================
// 2. Rasteryzacja treści do kontekstu float
// ===========================================================================

func bufferRow0IsBottom() -> Bool {
    let w = 4, h = 4
    let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32,
                              bytesPerRow: w * 16, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.floatComponents.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return false }
    ctx.setFillColor(CGColor(colorSpace: cs, components: [0, 0, 0, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(CGColor(colorSpace: cs, components: [1, 1, 1, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    guard let raw = ctx.data else { return false }
    return raw.bindMemory(to: Float32.self, capacity: w * h * 4)[0] > 0.5
}

func makeContent(flipVertically: Bool) -> [Float32] {
    let w = CONTENT_W, h = CONTENT_H
    let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32,
                        bytesPerRow: w * 16, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                  | CGBitmapInfo.floatComponents.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)!

    func col(_ v: CGFloat) -> CGColor { CGColor(colorSpace: cs, components: [v, v, v, 1])! }

    func draw(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat,
              _ v: CGFloat, _ f: CTFont) {
        // UWAGA: font trzymamy bez rozmiaru (CTFontCreateWithName z zerem daje
        // 12 pt), więc rozmiar trzeba nadac DOPIERO TUTAJ. Wcześniej parametr
        // `size` był przyjmowany i ignorowany — cały tekst rysował się w 12 pt
        // i podgląd wyglądał, jakby font się nie wczytał.
        let fs = CTFontCreateCopyWithAttributes(f, size, nil, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: fs,
            kCTForegroundColorAttributeName: col(v),
        ]
        let a = CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary)!
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(a), ctx)
    }

    func ui(_ size: CGFloat) -> CTFont {
        CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    // --- czarne tło. To nie kosmetyka: duże jasne plamy obniżają zapas EDR,
    //     więc im mniej światła poza tekstem, tym mocniej widać różnicę.
    ctx.setFillColor(col(0.0))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

    // --- mała skala odniesienia (świadomie mała — patrz wyżej)
    draw("skala odniesienia:", CGFloat(w) - MARGIN - 460, 855, 20, 1.0, ui(20))
    for (i, v) in [1.0, 2.0, 4.0, 8.0, 16.0].enumerated() {
        let x = CGFloat(w) - MARGIN - CGFloat(5 - i) * 66
        ctx.setFillColor(col(CGFloat(v)))
        ctx.fill(CGRect(x: x, y: 840, width: 50, height: 50))
    }

    guard let sf = sourceFont else {
        draw(statusLine, MARGIN, 440, 28, 1.0, ui(28))
        return flush(ctx, flipVertically: flipVertically)
    }

    // --- linia 1: oryginalny font, biel SDR. Punkt odniesienia.
    draw("zwykly \(sourceFace?.family ?? "?") — biel SDR 1.0", MARGIN, 720, 22, 1.0, ui(22))
    draw(sampleText, MARGIN, 640, 64, 1.0, sf)

    // --- linia 2: ten sam tekst, ta sama wartość koloru (1.0), inny font.
    let opis = glowIsReal
        ? String(format: "GLOW — font na zywo, boost %.1fx", Double(level))
        : String(format: "GLOW — szybki podglad obrysem, %.1fx", Double(level))
    draw(opis, MARGIN, 500, 22, 1.0, ui(22))

    if glowIsReal, let gf = glowFont {
        // bitmapy niosą własną jasność — atrybut koloru jest ignorowany
        draw(sampleText, MARGIN, 420, 64, 1.0, gf)
    } else {
        // podgląd zastępczy: obrys oryginału w wybranej jasności
        draw(sampleText, MARGIN, 420, 64, level, sf)
    }

    draw(statusLine, MARGIN, 300, 20, 1.0, ui(20))

    return flush(ctx, flipVertically: flipVertically)
}

func flush(_ ctx: CGContext, flipVertically: Bool) -> [Float32] {
    let w = CONTENT_W, h = CONTENT_H
    let n = w * h * 4
    let src = ctx.data!.bindMemory(to: Float32.self, capacity: n)
    var out = [Float32](repeating: 0, count: n)
    if flipVertically {
        for y in 0..<h {
            let sy = h - 1 - y
            for x in 0..<(w * 4) { out[y * w * 4 + x] = src[sy * w * 4 + x] }
        }
    } else {
        for i in 0..<n { out[i] = src[i] }
    }
    return out
}

// ===========================================================================
// 3. Metal
// ===========================================================================

final class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    var texture: MTLTexture?
    let flip: Bool

    init?(device: MTLDevice, flip: Bool) {
        guard let q = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = q
        self.flip = flip

        let src = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 pos [[position]]; float2 uv; };
        vertex VOut vmain(uint vid [[vertex_id]]) {
            float2 p = float2(float((vid << 1) & 2), float(vid & 2));
            VOut o;
            o.pos = float4(p.x * 2.0 - 1.0, 1.0 - p.y * 2.0, 0.0, 1.0);
            o.uv  = float2(p.x, p.y);
            return o;
        }
        fragment float4 fmain(VOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler s [[sampler(0)]]) {
            return tex.sample(s, in.uv);
        }
        """
        guard let lib = try? device.makeLibrary(source: src, options: nil),
              let vfn = lib.makeFunction(name: "vmain"),
              let ffn = lib.makeFunction(name: "fmain") else { return nil }

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vfn
        pd.fragmentFunction = ffn
        pd.colorAttachments[0].pixelFormat = .rgba16Float
        guard let ps = try? device.makeRenderPipelineState(descriptor: pd) else { return nil }
        self.pipeline = ps

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sm = device.makeSamplerState(descriptor: sd) else { return nil }
        self.sampler = sm

        super.init()
        rebuild()
    }

    func rebuild() {
        let px = makeContent(flipVertically: flip)
        let w = CONTENT_W, h = CONTENT_H
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { return }
        var half = [Float16](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h * 4) { half[i] = Float16(px[i]) }
        half.withUnsafeBytes { buf in
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: buf.baseAddress!, bytesPerRow: w * 8)
        }
        texture = tex
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let tex = texture,
              let rpd = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(tex, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }
}

// ===========================================================================
// 4. Logika: wybór fontu i przebudowa
// ===========================================================================

func refresh() {
    renderer?.rebuild()
    // KLUCZOWE: widok ma isPaused = true i enableSetNeedsDisplay = true,
    // czyli NIE przerysowuje sie sam. Bez tego ponizszego wywolania na ekranie
    // zostaje pierwsza klatka z momentu startu — zmiana fontu i suwak nie daja
    // wtedy zadnego widocznego efektu, mimo ze cala logika dziala.
    mtk.needsDisplay = true
    // Status pokazujemy DWIEMA drogami: w pasku na dole i w tytule okna.
    // Tytul jest niezawodny — widac go nawet gdy pasek z jakiegos powodu
    // nie odswiezy sie, wiec od razu widac, czy stan sie zmienia.
    if let l = statusLabel {
        l.stringValue = statusLine
        // Samo stringValue ustawia tekst, ale nie zawsze wymusza odrysowanie
        // (widok warstwowy, okno w tle). Wymuszamy jawnie.
        l.needsDisplay = true
        l.displayIfNeeded()
        if refreshCount < 6 {
            loguj("[odswiez] pasek OK  ramka=\(l.frame)  w oknie=\(l.superview != nil)"
                  + "  tekst=\"\(statusLine.prefix(34))\"")
        }
    } else {
        loguj("[odswiez] UWAGA: statusLabel = nil — pasek nie istnieje")
    }
    win.title = "glowforge — " + String(statusLine.prefix(70))
    refreshCount += 1
}
var refreshCount = 0

func buildRealFont() {
    guard let f = sourceFace, !building else { return }
    building = true
    let lv = Double(level)
    statusLine = String(format: "buduje font dla %.1fx...", lv)
    refresh()
    loguj(String(format: "[budowa] start  %.1fx  %@", lv, f.path))

    let path = f.path
    let boostArg = String(format: "%g", lv)
    DispatchQueue.global().async {
        let (code, out) = runForge(["convert", path,
                                    "--boost", boostArg,
                                    "--charset", "latin",
                                    "--ppem", "32,64,128",
                                    "--mode", "cicp",
                                    "--name", PREVIEW_NAME,
                                    "-o", TMPFONT])
        DispatchQueue.main.async {
            building = false
            if code != 0 {
                glowIsReal = false
                let last = out.split(separator: "\n").last.map(String.init) ?? "?"
                statusLine = "budowa nie udala sie: " + last
                loguj("[budowa] BLAD kod=\(code): \(last)")
                refresh()
                return
            }
            if let gf = registerGlow(TMPFONT) {
                glowFont = gf
                glowIsReal = true
                statusLine = String(format:
                    "font na zywo — boost %.1fx, %.1f MB. Suwak zmienia jasnosc, "
                    + "po puszczeniu font sie przebudowuje.", lv, fileSizeMB(TMPFONT))
                loguj(String(format: "[budowa] OK  %.1fx  %.1f MB  PS=%@", lv,
                             fileSizeMB(TMPFONT),
                             CTFontCopyPostScriptName(gf) as String))
            } else {
                glowIsReal = false
                statusLine = "nie udalo sie zarejestrowac zbudowanego fontu"
                loguj("[budowa] rejestracja ODRZUCONA dla \(TMPFONT)")
            }
            refresh()
        }
    }
}

func scheduleBuild() {
    debounce?.invalidate()
    debounce = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
        buildRealFont()
    }
}

/// CTFontCreateWithName NIGDY nie zwraca nil — przy nieznanej nazwie po cichu
/// podstawia font domyślny. Dlatego trzeba sprawdzić, co się naprawdę dostało,
/// inaczej wybór z listy potrafi nie działać bez jednego znaku ostrzeżenia.
func fontDla(_ f: Face) -> CTFont? {
    for nazwa in [f.ps, f.family] where !nazwa.isEmpty {
        let t = CTFontCreateWithName(nazwa as CFString, 12, nil)
        let ps = CTFontCopyPostScriptName(t) as String
        let fam = CTFontCopyFamilyName(t) as String
        if ps.caseInsensitiveCompare(nazwa) == .orderedSame
            || fam.caseInsensitiveCompare(f.family) == .orderedSame {
            return t
        }
    }
    return nil
}

/// Czy font o tej nazwie PostScript jest NAPRAWDE dostepny?
///
/// Nie da sie tego sprawdzic przez CTFontManagerCopyAvailablePostScriptNames()
/// — ta lista bywa nieaktualna i nie zawiera fontu, ktory jest zarejestrowany
/// i dziala (zmierzone: Courie rGlow16x byl dostepny po nazwie, a na liscie
/// go nie bylo). Sprawdzamy wiec UZYCIEM: tworzymy font po nazwie i patrzymy,
/// co naprawde przyszlo — bo CTFontCreateWithName przy nieznanej nazwie
/// po cichu podstawia font domyslny, zamiast zwrocic nil.
func fontDostepny(_ ps: String) -> Bool {
    guard !ps.isEmpty else { return false }
    let f = CTFontCreateWithName(ps as CFString, 14, nil)
    let got = CTFontCopyPostScriptName(f) as String
    return got.caseInsensitiveCompare(ps) == .orderedSame
}

func selectFace(_ f: Face) {
    sourceFace = f
    if let t = fontDla(f) {
        sourceFont = t
        let got = CTFontCopyPostScriptName(t) as String
        loguj("[wybor] \(f.family)  zadane PS=\(f.ps)  dostane PS=\(got)  glifow=\(CTFontGetGlyphCount(t))")
    } else {
        sourceFont = nil
        loguj("[wybor] NIE UDALO SIE wczytac \(f.family) (PS=\(f.ps))")
    }
    glowFont = nil
    glowIsReal = false
    statusLine = String(format: "wybrany: %@ — buduje podglad...", f.family)
    refresh()
    buildRealFont()
}

// ===========================================================================
// 5. Aplikacja i interfejs
// ===========================================================================

let app = NSApplication.shared
app.setActivationPolicy(.regular)

guard let device = MTLCreateSystemDefaultDevice() else {
    print("BŁĄD: brak urządzenia Metal"); exit(1)
}
print("GPU:", device.name)
if let s = NSScreen.main {
    print(String(format: "headroom: %.2fx (potencjalny %.2fx)",
                 Double(s.maximumExtendedDynamicRangeColorComponentValue),
                 Double(s.maximumPotentialExtendedDynamicRangeColorComponentValue)))
    if s.maximumExtendedDynamicRangeColorComponentValue < 1.5 {
        print(">>> UWAGA: zapas EDR prawie zerowy — zejdz z jasnoscia ekranu.")
    }
}

let flip = bufferRow0IsBottom()
print("bufor CG: wiersz 0 to \(flip ? "DÓŁ" : "GÓRA") obrazu -> flip = \(flip)")

let winW: CGFloat = 1180, winH: CGFloat = 800
let barH: CGFloat = 104
let win = NSWindow(contentRect: CGRect(x: 60, y: 100, width: winW, height: winH),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
win.title = "glowforge — swiecace fonty (EDR)"
win.backgroundColor = .black

let root = NSView(frame: CGRect(x: 0, y: 0, width: winW, height: winH))
root.wantsLayer = true
root.layer?.backgroundColor = NSColor.black.cgColor
win.contentView = root

let mtk = MTKView(frame: CGRect(x: 0, y: barH, width: winW, height: winH - barH),
                  device: device)
mtk.autoresizingMask = [.width, .height]
mtk.colorPixelFormat = .rgba16Float
mtk.framebufferOnly = true
mtk.isPaused = true
mtk.enableSetNeedsDisplay = true
mtk.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
if let cs = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) { mtk.colorspace = cs }
if let layer = mtk.layer as? CAMetalLayer { layer.wantsExtendedDynamicRangeContent = true }
root.addSubview(mtk)

func label(_ s: String, _ r: CGRect, _ size: CGFloat = 12) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.frame = r
    t.font = .monospacedSystemFont(ofSize: size, weight: .regular)
    t.textColor = .white
    t.backgroundColor = .clear
    t.drawsBackground = false
    return t
}

// --- rząd 1: font, tekst, jasność, przycisk
let popup = NSPopUpButton(frame: CGRect(x: 14, y: barH - 62, width: 330, height: 26))
popup.target = nil
root.addSubview(label("font:", CGRect(x: 14, y: barH - 34, width: 60, height: 16), 11))
root.addSubview(popup)

let textField = NSTextField(frame: CGRect(x: 356, y: barH - 62, width: 250, height: 26))
textField.stringValue = sampleText
textField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
textField.target = nil
root.addSubview(label("tekst:", CGRect(x: 356, y: barH - 34, width: 60, height: 16), 11))
root.addSubview(textField)

let slider = NSSlider(frame: CGRect(x: 626, y: barH - 62, width: 300, height: 26))
slider.minValue = 1.0
slider.maxValue = 16.0
slider.doubleValue = Double(level)
slider.isContinuous = true
root.addSubview(label("jasnosc (x bieli SDR):", CGRect(x: 626, y: barH - 34, width: 200, height: 16), 11))
root.addSubview(slider)

let btn = NSButton(frame: CGRect(x: 946, y: barH - 62, width: 220, height: 28))
btn.title = "Zainstaluj w systemie"
btn.bezelStyle = .rounded
root.addSubview(btn)

// --- rząd 2: status
let st = label(statusLine, CGRect(x: 14, y: 12, width: winW - 28, height: 30), 11)
st.textColor = NSColor(white: 0.72, alpha: 1)
st.autoresizingMask = [.width]
st.lineBreakMode = .byTruncatingMiddle
statusLabel = st
root.addSubview(st)

renderer = Renderer(device: device, flip: flip)
mtk.delegate = renderer

// --- akcje
final class Actions: NSObject {
    @objc func faceChanged(_ s: NSPopUpButton) {
        let i = s.indexOfSelectedItem
        guard i >= 0 && i < faces.count else { return }
        selectFace(faces[i])
    }
    @objc func textChanged(_ s: NSTextField) {
        sampleText = s.stringValue.isEmpty ? " " : s.stringValue
        refresh()
    }
    @objc func levelChanged(_ s: NSSlider) {
        level = CGFloat(s.doubleValue)
        glowIsReal = false          // natychmiast: podglad obrysem
        refresh()
        scheduleBuild()             // po chwili: prawdziwy font
    }
    @objc func install(_ s: NSButton) {
        guard let f = sourceFace else {
            statusLine = "nie wybrano fontu"
            loguj("[instalacja] brak wybranego fontu")
            refresh(); return
        }
        if installing {
            statusLine = "instalacja juz trwa..."
            refresh(); return
        }
        installing = true
        let lv = Double(level)
        statusLine = String(format: "buduje wersje do instalacji (%.1fx)...", lv)
        refresh()
        loguj(String(format: "[instalacja] start  %.1fx  %@", lv, f.path))

        let path = f.path
        let boostArg = String(format: "%g", lv)
        DispatchQueue.global().async {
            // Bez --name: font dostaje właściwą nazwę (np. „Monaco Glow 8x”),
            // a --install kopiuje go do ~/Library/Fonts pod tą nazwą.
            let (code, out) = runForge(["convert", path,
                                        "--boost", boostArg,
                                        "--charset", "latin",
                                        "--ppem", "32,64,128",
                                        "--mode", "cicp",
                                        "--install"])
            DispatchQueue.main.async {
                installing = false
                if code != 0 {
                    let tail = out.split(separator: "\n").suffix(2).joined(separator: " ")
                    statusLine = "instalacja nie udala sie: " + tail
                    loguj("[instalacja] BLAD kod=\(code): \(tail)")
                } else {
                    let lines = out.split(separator: "\n").map(String.init)
                    let sciezka = lines.first { $0.contains("zainstalowany:") }?
                        .replacingOccurrences(of: "zainstalowany:", with: "")
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    let ps = lines.first { $0.contains("PostScript") }?
                        .split(separator: ":").last
                        .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""

                    // SAMA KOPIA DO ~/Library/Fonts NIE WYSTARCZA.
                    // System nie zauwaza pliku wrzuconego tam przez program:
                    // CoreText go nie widzi, wiec Font Book tez nie. Trzeba
                    // zarejestrowac font trwale (zakres .persistent).
                    var err: Unmanaged<CFError>?
                    let ok = CTFontManagerRegisterFontsForURL(
                        URL(fileURLWithPath: sciezka) as CFURL, .persistent, &err)
                    var kod = 0
                    if !ok, let e = err { kod = CFErrorGetCode(e.takeRetainedValue()) }

                    // Nie ufamy kodom bledow — kod 105 znaczy "juz zarejestrowany"
                    // i jest w porzadku. Sprawdzamy SKUTEK: czy font da sie uzyc.
                    let widoczny = fontDostepny(ps)

                    statusLine = widoczny
                        ? "zainstalowany i widoczny w systemie: \(sciezka)"
                        : "skopiowany, ale system go nie widzi (kod \(kod)): \(sciezka)"
                    loguj("[instalacja] ok=\(ok) kod=\(kod) widoczny=\(widoczny) ps=\(ps)"
                          + "  plik=\(sciezka)")
                }
                refresh()
            }
        }
    }
}
let actions = Actions()
popup.target = actions
popup.action = #selector(Actions.faceChanged(_:))
textField.target = actions
textField.action = #selector(Actions.textChanged(_:))
slider.target = actions
slider.action = #selector(Actions.levelChanged(_:))
btn.target = actions
btn.action = #selector(Actions.install(_:))

// --- start: wczytaj liste fontow
DispatchQueue.global().async {
    let list = loadFaces()
    DispatchQueue.main.async {
        faces = list
        popup.removeAllItems()
        popup.addItems(withTitles: list.map { "\($0.family) — \($0.sub)" })
        if list.isEmpty {
            statusLine = "nie widze zadnych fontow (czy glowforge dziala?)"
            refresh()
            return
        }
        // domyslnie Monaco, jesli jest
        let idx = list.firstIndex { $0.ps == "Monaco" } ?? 0
        popup.selectItem(at: idx)
        selectFace(list[idx])
    }
}

win.makeKeyAndOrderFront(nil)
win.center()
app.activate(ignoringOtherApps: true)
app.run()
