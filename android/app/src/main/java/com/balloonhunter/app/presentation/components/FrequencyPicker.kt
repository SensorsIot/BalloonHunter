package com.balloonhunter.app.presentation.components

import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment

/**
 * A single digit picker for frequency input.
 * Displays up/down arrows and the current digit value.
 */
@Composable
fun FrequencyDigitPicker(
    value: Int,
    onValueChange: (Int) -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        IconButton(
            onClick = {
                val newVal = if (value >= 9) 0 else value + 1
                onValueChange(newVal)
            }
        ) {
            Icon(Icons.Default.KeyboardArrowUp, contentDescription = "Increase digit")
        }

        Text(
            text = value.toString(),
            style = MaterialTheme.typography.headlineSmall
        )

        IconButton(
            onClick = {
                val newVal = if (value <= 0) 9 else value - 1
                onValueChange(newVal)
            }
        ) {
            Icon(Icons.Default.KeyboardArrowDown, contentDescription = "Decrease digit")
        }
    }
}

/**
 * Converts a frequency value (e.g., 403.50) to a list of 5 digits.
 */
fun frequencyToDigits(frequency: Double): List<Int> {
    val freq = (frequency * 100).toInt()
    return listOf(
        (freq / 10000) % 10,
        (freq / 1000) % 10,
        (freq / 100) % 10,
        (freq / 10) % 10,
        freq % 10
    )
}

/**
 * Converts a list of 5 digits back to a frequency value.
 */
fun digitsToFrequency(digits: List<Int>): Double {
    val whole = digits[0] * 100 + digits[1] * 10 + digits[2]
    val decimal = digits[3] * 10 + digits[4]
    return whole + decimal / 100.0
}

/**
 * Validates if a digit is valid at the given position for sonde frequencies (400-406 MHz).
 */
fun isValidFrequencyDigit(digit: Int, position: Int, allDigits: List<Int>): Boolean {
    return when (position) {
        0 -> digit == 4
        1 -> digit == 0
        2 -> digit in 0..6
        3 -> if (allDigits[2] == 6) digit == 0 else true
        4 -> if (allDigits[2] == 6 && allDigits[3] == 0) digit == 0 else true
        else -> true
    }
}
