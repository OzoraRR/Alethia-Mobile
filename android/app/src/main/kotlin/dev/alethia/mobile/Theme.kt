package dev.alethia.mobile

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

val Navy950 = Color(0xFF050B14)
val Navy900 = Color(0xFF091321)
val Navy700 = Color(0xFF1B3550)
val Signal = Color(0xFFA6E86B)
val ReportAccent = Signal
val ModuleAccent = Color(0xFFFF7078)
val Ice = Color(0xFFE6EDF4)
val Muted = Color(0xFF8DA0B4)
val Warning = Color(0xFFF2C879)

@Composable
fun AlethiaTheme(content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = darkColorScheme(
        primary = Signal, onPrimary = Navy950, secondary = Warning,
        background = Navy950, onBackground = Ice, surface = Navy900,
        onSurface = Ice, onSurfaceVariant = Muted, outline = Navy700,
    ), content = content)
}
