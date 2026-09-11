// Co system NAPRAWDĘ pokazuje jako ikonę danego pakietu.
//
//   swift scripts/ikona_systemowa.swift /Applications/Foo.app [wyjscie.png]
//
// Sens jest ten sam, co przy sprawdzaniu czcionek: lista zainstalowanych
// rzeczy bywa nieaktualna, więc pytamy wprost o to, co zobaczy użytkownik.
// Jeśli ikona jest generyczna, dostaniemy dokładnie ten sam obraz, co dla
// byle jakiej aplikacji bez własnej ikony.

import AppKit

let argumenty = CommandLine.arguments
guard argumenty.count >= 2 else {
    print("użycie: swift ikona_systemowa.swift ŚCIEŻKA.app [wyjscie.png]")
    exit(1)
}
let ścieżka = argumenty[1]
let url = URL(fileURLWithPath: ścieżka)

// --- Flaga „element ma własną ikonę" (ta sama, którą ustawia SetFile -a C).
// Jest zdradliwa: każe Finderowi szukać pliku „Icon\r" wewnątrz pakietu,
// a gdy go tam nie ma, Finder przestaje czytać CFBundleIconFile i pokazuje
// zwykły folder. Dlatego sprawdzamy ją wprost, a nie tylko sam obraz.
let zasoby = try? url.resourceValues(forKeys: [.customIconKey])
let wlasna = (zasoby?.customIcon != nil)
print("flaga własnej ikony: \(wlasna ? "USTAWIONA — to psuje ikonę pakietu" : "brak (dobrze)")")

let ikona = NSWorkspace.shared.icon(forFile: ścieżka)
print("ścieżka:        \(ścieżka)")
print("rozmiar punktowy: \(Int(ikona.size.width))x\(Int(ikona.size.height))")
print("reprezentacje:  \(ikona.representations.count)")
for r in ikona.representations {
    print("   \(type(of: r))  \(r.pixelsWide)x\(r.pixelsHigh)")
}

// Porównanie z DWOMA wzorcami. Poprzednia wersja sprawdzała tylko ikonę
// generycznej aplikacji i ogłaszała sukces, gdy system zwracał generyczny
// folder — bo to przecież inny obraz. Test, który nie odróżnia awarii od
// sukcesu, jest gorszy niż jego brak.
let moja = ikona.tiffRepresentation ?? Data()
func toSamObraz(_ wzorzec: NSImage) -> Bool {
    return moja == (wzorzec.tiffRepresentation ?? Data())
}

if toSamObraz(NSWorkspace.shared.icon(for: .application)) {
    print("WYNIK:               generyczna ikona APLIKACJI — system nie widzi własnej")
} else if toSamObraz(NSWorkspace.shared.icon(for: .folder)) {
    print("WYNIK:               zwykły FOLDER — pakiet nie jest brany za aplikację")
} else {
    print("WYNIK:               własna ikona pakietu działa")
}

if argumenty.count >= 3 {
    if let tiff = ikona.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: argumenty[2]))
        print("podgląd:        \(argumenty[2])")
    }
}
