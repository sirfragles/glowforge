// Sonda zapasu EDR. Na ekranach XDR zapas zalezy od ustawionej jasnosci:
// przy jasnosci bliskiej maksimum spada do ~1.0 i HDR przestaje byc widoczny.
import AppKit

let fm = FileManager.default
for (i, s) in NSScreen.screens.enumerated() {
    print("ekran \(i + 1): \(s.localizedName)")
    print(String(format: "  zapas AKTUALNY      %.2fx", s.maximumExtendedDynamicRangeColorComponentValue))
    print(String(format: "  zapas POTENCJALNY   %.2fx", s.maximumPotentialExtendedDynamicRangeColorComponentValue))
    print(String(format: "  zapas REFERENCYJNY  %.2fx", s.maximumReferenceExtendedDynamicRangeColorComponentValue))
    if #available(macOS 12.0, *) {
        // ile zapasu zostalo do wykorzystania na tej jasnosci
        let cur = s.maximumExtendedDynamicRangeColorComponentValue
        if cur < 1.5 {
            print("  >>> ZAPAS PRAWIE ZERO - HDR nie bedzie widoczny.")
            print("      Zjedz jasnoscia ekranu w dol i sprawdz ponownie.")
        } else {
            print(String(format: "  >>> HDR widoczny, biel moze byc %.1f razy jasniejsza", cur))
        }
    }
}
