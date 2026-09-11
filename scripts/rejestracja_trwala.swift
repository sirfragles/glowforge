// Czy font z ~/Library/Fonts staje sie widoczny dla SYSTEMU, czy tylko
// dla procesu, ktory go zarejestrowal? Sprawdzamy miedzy procesami.
//
//   ./rejestracja_trwala list            — co widzi system
//   ./rejestracja_trwala reg <plik>      — rejestracja trwala (scope .persistent)
//   ./rejestracja_trwala proc <plik>     — rejestracja tylko w procesie
import CoreText
import Foundation

let tryb = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "list"

func widoczne() -> [String] {
    (CTFontManagerCopyAvailablePostScriptNames() as? [String]) ?? []
}

switch tryb {
case "reg", "proc", "rereg":
    let sciezka = CommandLine.arguments[2]
    let url = URL(fileURLWithPath: sciezka) as CFURL
    // "rereg" najpierw wyrejestrowuje. Rejestracja jest przypisana do ADRESU
    // pliku, wiec po nadpisaniu pliku nowa trescia CoreText uznaje adres za
    // "juz zarejestrowany" (kod 105), a mimo to fontu nie ma na liscie.
    // Wyrejestrowanie kasuje ten wpis i pozwala wczytac plik od nowa.
    if tryb == "rereg" {
        var uerr: Unmanaged<CFError>?
        let uok = CTFontManagerUnregisterFontsForURL(url, .persistent, &uerr)
        var ukod = 0
        if !uok, let e = uerr { ukod = CFErrorGetCode(e.takeRetainedValue()) }
        print("wyrejestrowanie:", uok ? "OK" : "nie udalo sie", " kod:", ukod)
    }
    let zakres: CTFontManagerScope = (tryb == "proc") ? .process : .persistent
    var err: Unmanaged<CFError>?
    let ok = CTFontManagerRegisterFontsForURL(url, zakres, &err)
    var kod = 0
    if !ok, let e = err { kod = CFErrorGetCode(e.takeRetainedValue()) }
    print("zakres: \(zakres == .persistent ? "persistent" : "process")")
    print("rejestracja:", ok ? "OK" : "ODRZUCONA", " kod:", kod)
    let n = widoczne()
    print("w TYM procesie widac \(n.count) fontow, w tym glow:",
          n.filter { $0.lowercased().contains("glow") }.sorted())
default:
    let n = widoczne()
    print("proces widzi \(n.count) fontow")
    let g = n.filter { $0.lowercased().contains("glow") }.sorted()
    print("z tego 'glow':", g.isEmpty ? "ZADNEGO" : g.joined(separator: ", "))
}
