package com.balloonhunter.app.data.ble

import kotlin.math.roundToInt

class BleAfcSmoother(private val capacity: Int = 10) {
    private val history = ArrayDeque<Int>()

    fun add(value: Int): AfcData {
        if (history.size >= capacity) {
            history.removeFirst()
        }
        history.addLast(value)
        val avg = history.average()
        return AfcData(currentFrequency = value, smoothedFrequency = avg.roundToInt())
    }

    fun reset() {
        history.clear()
    }
}

data class AfcData(val currentFrequency: Int, val smoothedFrequency: Int)
