package com.loopbreak.inverterly.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.background
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface

/** The few colours the energy sources and states carry, shared by tiles, charts and the hero. Same system palette as the iOS app. */
@Immutable
class Marks(
    val solar: Color,
    val grid: Color,
    val battery: Color,
    val alert: Color,
    val warning: Color,
    val card: Color,
    val secondary: Color,
    /** The grid's plug icon: the system blue, where the grid's bars and lines stay grey. */
    val gridIcon: Color = Color(0xFF007AFF),
)

val LocalMarks = staticCompositionLocalOf {
    Marks(Color(0xFFFF9500), Color(0xFF8E8E93), Color(0xFF34C759), Color(0xFFFF3B30), Color(0xFFFF9500),
        Color.White, Color(0xFF8E8E93))
}

private val LightMarks = Marks(
    solar = Color(0xFFFF9500), grid = Color(0xFF8E8E93), battery = Color(0xFF34C759),
    alert = Color(0xFFFF3B30), warning = Color(0xFFFF9500), card = Color.White, secondary = Color(0x993C3C43),
)
private val DarkMarks = Marks(
    solar = Color(0xFFFF9F0A), grid = Color(0xFF8E8E93), battery = Color(0xFF30D158),
    alert = Color(0xFFFF453A), warning = Color(0xFFFF9F0A), card = Color(0xFF1C1C1E), secondary = Color(0x99EBEBF5),
    gridIcon = Color(0xFF0A84FF),
)

private val LightColors = lightColorScheme(
    primary = Color(0xFFFF9500), onPrimary = Color.White,
    background = Color(0xFFF2F2F7), onBackground = Color.Black,
    surface = Color(0xFFF2F2F7), onSurface = Color.Black,
    surfaceVariant = Color(0xFFE5E5EA), onSurfaceVariant = Color(0x993C3C43),
    surfaceContainer = Color.White, surfaceContainerHigh = Color.White,
    outlineVariant = Color(0x293C3C43), error = Color(0xFFFF3B30),
    secondaryContainer = Color(0x26FF9500), onSecondaryContainer = Color(0xFFB35F00),
)
private val DarkColors = darkColorScheme(
    primary = Color(0xFFFF9F0A), onPrimary = Color.Black,
    background = Color.Black, onBackground = Color.White,
    surface = Color.Black, onSurface = Color.White,
    surfaceVariant = Color(0xFF2C2C2E), onSurfaceVariant = Color(0x99EBEBF5),
    surfaceContainer = Color(0xFF1C1C1E), surfaceContainerHigh = Color(0xFF2C2C2E),
    outlineVariant = Color(0x54545458), error = Color(0xFFFF453A),
    secondaryContainer = Color(0x33FF9F0A), onSecondaryContainer = Color(0xFFFFB340),
)

@Composable
fun InverterlyTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    androidx.compose.runtime.CompositionLocalProvider(LocalMarks provides if (dark) DarkMarks else LightMarks) {
        val colors = if (dark) DarkColors else LightColors
        MaterialTheme(colorScheme = colors) {
            // Text outside a Surface takes its colour from here; without it the default is black, which vanishes on dark pages.
            Surface(Modifier.fillMaxSize(), color = colors.background, contentColor = colors.onBackground, content = content)
        }
    }
}

val marks: Marks @Composable @ReadOnlyComposable get() = LocalMarks.current

/** A grouped card on the page background. */
@Composable
fun PhoneCard(
    modifier: Modifier = Modifier,
    title: String? = null,
    padding: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
        color = MaterialTheme.colorScheme.surfaceContainer,
    ) {
        Column(
            modifier = if (padding) Modifier.padding(16.dp) else Modifier,
            verticalArrangement = Arrangement.spacedBy(12.dp),
            content = {
                if (title != null) Text(title, style = MaterialTheme.typography.titleMedium)
                content()
            },
        )
    }
}

/** A banner under the header: a tinted symbol and a line of text. */
@Composable
fun Banner(icon: ImageVector, text: String, tint: Color, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(14.dp))
            .background(tint.copy(alpha = 0.12f))
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurface)
    }
}

/** A small filled dot, used in legends and the live indicator. */
fun Modifier.dot(color: Color) = this.drawBehind {
    drawCircle(color)
}
