package com.balloonhunter.app.data.ble

object RadioSettings {
    fun frequencyToDigits(frequency: Double): List<Int> {
        val rounded = String.format("%06.2f", frequency)
        return rounded.replace(".", "").map { it.digitToInt() }
    }

    fun isValidDigits(digits: List<Int>): Boolean {
        if (digits.size != 5) return false
        val (d0, d1, d2, d3, d4) = digits
        if (d0 != 4) return false
        if (d1 != 0) return false
        if (d2 !in 0..6) return false
        if (d3 !in 0..9) return false
        if (d2 == 6 && d3 != 0) return false
        if (d4 !in 0..9) return false
        if (d2 == 6 && d3 == 0 && d4 != 0) return false
        return true
    }
}
