import Foundation

struct ESP32PinRules {
    static func outputWarning(pin: Int) -> String? {
        if (34...39).contains(pin) { return "GPIO34–39 are input-only on ESP32." }
        if (6...11).contains(pin) { return "GPIO6–11 are flash pins; avoid using them." }
        if [0, 2, 5, 12, 15].contains(pin) { return "Boot strap pin; avoid for outputs (may break boot)." }
        return nil
    }

    static func i2cWarning(pin: Int) -> String? {
        if (34...39).contains(pin) { return "GPIO34–39 are input-only; not valid for I²C." }
        if (6...11).contains(pin) { return "GPIO6–11 are flash pins; avoid using them." }
        if [0, 2, 5, 12, 15].contains(pin) { return "Boot strap pin; avoid for I²C (may affect boot)." }
        return nil
    }

    static func batteryWarning(pin: Int) -> String? {
        if !(32...39).contains(pin) { return "Prefer ADC1 GPIO32–39 for battery sensing." }
        return nil
    }
}

