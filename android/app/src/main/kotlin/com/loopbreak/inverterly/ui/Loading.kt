package com.loopbreak.inverterly.ui

import androidx.compose.animation.Crossfade
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/** Said one after another under the title while the first reading is on its way. */
private val Lines = listOf(
    "Getting the latest numbers",
    "Waking up the logger",
    "Asking the cloud nicely",
    "Checking on the sun",
    "Counting electrons",
    "Peeking at the battery",
    "Listening to the grid",
    "Almost there",
)

/** One line at a time, fading to the next every couple of seconds. */
@Composable
private fun RotatingLine() {
    var index by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(2400)
            // Stay on the last line rather than loop back to "Getting the latest numbers".
            if (index < Lines.lastIndex) index++ else index = 1
        }
    }
    Crossfade(index, animationSpec = tween(500), label = "line") { i ->
        Text(Lines[i] + "…", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
    }
}

private val Navy = Color(0xFF16263A)
private val NavyTop = Color(0xFF223650)
private val Sun = Color(0xFFFFD478)

/**
 * Shown full screen, with no header or tab bar, until the first reading arrives. It opens on the
 * same navy and the same sun and wave as the splash, so the two read as one: the sun's rays pulse
 * one after another and the wave runs along beneath it, like power on a wire.
 */
@Composable
fun LoadingScreen() {
    val transition = rememberInfiniteTransition(label = "loading")
    // 0..1 around the rays: a ripple that travels across them.
    val ripple by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(1800, easing = LinearEasing), RepeatMode.Restart), label = "ripple")
    val wave by transition.animateFloat(0f, (2 * PI).toFloat(), infiniteRepeatable(tween(1600, easing = LinearEasing), RepeatMode.Restart), label = "wave")
    val breathe by transition.animateFloat(0f, 1f, infiniteRepeatable(tween(1800, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "breathe")

    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(NavyTop, Navy))), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(28.dp)) {
            Canvas(Modifier.size(200.dp)) {
                val u = size.width / 108f   // the artwork is drawn on the splash icon's 108 unit canvas
                val centre = Offset(54f * u, (50f - 3f * breathe) * u)
                // Glow behind the sun that swells with the breath.
                drawCircle(Brush.radialGradient(listOf(Sun.copy(alpha = 0.10f + 0.12f * breathe), Color.Transparent), centre, 34f * u), 34f * u, centre)
                // Half sun.
                val sun = Path().apply {
                    moveTo(centre.x - 11 * u, centre.y)
                    arcTo(androidx.compose.ui.geometry.Rect(centre.x - 11 * u, centre.y - 11 * u, centre.x + 11 * u, centre.y + 11 * u), 180f, 180f, false)
                    close()
                }
                drawPath(sun, Sun)
                // Rays: each brightens and stretches as the ripple passes it.
                for ((i, deg) in listOf(-160, -125, -90, -55, -20).withIndex()) {
                    val a = Math.toRadians(deg.toDouble())
                    val phase = (ripple - i / 5f + 1f) % 1f
                    val lit = (1f - (phase * 2.2f).coerceAtMost(1f)).let { it * it }
                    val inner = 16f + 0.5f * lit
                    val outer = 23f + 3.5f * lit
                    drawLine(Sun.copy(alpha = 0.45f + 0.55f * lit), Offset(centre.x + (cos(a) * inner).toFloat() * u, centre.y + (sin(a) * inner).toFloat() * u),
                        Offset(centre.x + (cos(a) * outer).toFloat() * u, centre.y + (sin(a) * outer).toFloat() * u), 3.4f * u, StrokeCap.Round)
                }
                // The wave runs left to right and fades out at both ends.
                val wavePath = Path()
                val left = 28f * u; val right = 80f * u; val mid = 66f * u
                var x = left
                var first = true
                while (x <= right) {
                    val t = (x - left) / (right - left)
                    val y = mid + (sin((t * 2.0 * 2 * PI) - wave) * 5.2 * u).toFloat()
                    if (first) { wavePath.moveTo(x, y); first = false } else wavePath.lineTo(x, y)
                    x += 1.5f * u
                }
                drawPath(wavePath, Brush.horizontalGradient(listOf(Color.Transparent, Color.White, Color.White, Color.Transparent), left, right),
                    style = Stroke(3.6f * u, cap = StrokeCap.Round, join = StrokeJoin.Round))
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.padding(horizontal = 32.dp)) {
                Text("Reading your inverter", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                RotatingLine()
            }
        }
    }
}
