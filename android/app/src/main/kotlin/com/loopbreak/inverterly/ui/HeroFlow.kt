package com.loopbreak.inverterly.ui

import android.provider.Settings
import androidx.compose.foundation.Canvas
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.sp
import com.loopbreak.inverterly.core.EnergyFlows
import com.loopbreak.inverterly.core.EnergySnapshot
import com.loopbreak.inverterly.core.HeroMath
import com.loopbreak.inverterly.core.InverterMode
import com.loopbreak.inverterly.core.PowerFormat
import kotlinx.coroutines.delay
import java.time.Instant
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlinx.coroutines.android.awaitFrame

/** Height the hero wants on the Now tab. */
const val HERO_HEIGHT_DP = 186

/**
 * The energy-flow map: sun and grid on the left, home and battery on the right, a small inverter
 * hub in the middle, joined by hairline conduits. Comets travel each conduit from source to sink:
 * more power means more comets, moving faster. The battery ring's arc is its state of charge and
 * its conduit reverses with the sign of the battery power. Comets leaving the hub carry the colour
 * of the source that feeds them.
 *
 * When a reading changes, the flows ease from the old values to the new over [RAMP] seconds so a
 * flow builds up or dies away instead of popping. Read-only, like everything else here.
 */
@Composable
fun HeroFlow(snapshot: EnergySnapshot?, active: Boolean, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val reduceMotion = remember {
        Settings.Global.getFloat(context.contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f) == 0f
    }
    val state = remember { HeroState() }
    var tick by remember { mutableLongStateOf(0L) }

    // A new reading restarts the ramp from whatever is on screen now.
    LaunchedEffect(snapshot) {
        state.adopt(snapshot, clock())
        tick++
    }

    // Frames are produced only while something is moving and the app is in front.
    LaunchedEffect(active, reduceMotion) {
        if (!active || reduceMotion) { tick++; return@LaunchedEffect }
        var last = clock()
        while (true) {
            val moving = state.target != EnergyFlows.Zero || state.transitioning(clock())
            if (!moving) { delay(250); last = clock(); continue }
            awaitFrame()
            val now = clock()
            state.advance(now, min(0.1, now - last))
            last = now
            tick++
        }
    }

    val ink = MaterialTheme.colorScheme.onSurface
    val tones = marks
    val measurer = rememberTextMeasurer()
    val dark = ink.red > 0.5f
    val settled = reduceMotion || !active
    Canvas(modifier) {
        tick.let { }   // read, so each frame redraws
        val now = if (settled) state.changedAt + RAMP + 1 else clock()
        val d = density
        withTransform({ scale(d, d, Offset.Zero) }) {
            drawFlow(Size(size.width / d, size.height / d), state, now, ink, tones, dark, measurer)
        }
    }
}

private const val RAMP = 1.1
private fun clock() = System.nanoTime() / 1e9

/** The flows before the latest reading and the moment it arrived, plus how far each conduit's comets have travelled. */
private class HeroState {
    var snapshot: EnergySnapshot? = null
    var previous = EnergyFlows.Zero
    var changedAt = -1e9
    val target: EnergyFlows get() = snapshot?.flows ?: EnergyFlows.Zero
    /** Cycles travelled on the sun, grid, battery and home conduits. Integrated per frame, so a change of speed never makes a comet jump. */
    val phase = DoubleArray(4)

    fun progress(now: Double): Double {
        val raw = min(1.0, max(0.0, (now - changedAt) / RAMP))
        return if (raw < 0.5) 2 * raw * raw else 1 - (-2 * raw + 2).pow(2) / 2
    }

    fun flows(now: Double) = previous.mix(target, progress(now))

    fun transitioning(now: Double) = now - changedAt < RAMP + 0.1

    fun adopt(new: EnergySnapshot?, now: Double) {
        val shown = flows(now)
        val newTarget = new?.flows ?: EnergyFlows.Zero
        if (newTarget != target || snapshot == null) {
            previous = shown
            changedAt = now
        }
        snapshot = new
    }

    fun advance(now: Double, dt: Double) {
        val f = clean(flows(now))
        phase[0] += rate(f.solarW) * dt
        phase[1] += rate(max(f.gridW, f.exportW)) * dt
        phase[2] += rate(abs(f.batteryW)) * dt
        phase[3] += rate(f.loadW) * dt
    }
}

// region Layout

private object Metric {
    const val ring = 20f          // node radius
    const val reach = 116f        // node centre to hub centre, across
    const val rise = 45f          // node centre to hub centre, up or down
    const val hubW = 34f
    const val hubH = 42f
    const val port = 8f           // conduit ports sit this far above and below the hub's middle
    const val labels = 30f        // value and caption beneath a node
    const val edge = 6f           // labels keep this far from the canvas edge
    const val slots = 4           // most comets on one conduit
}

/** A conduit: an S-curve from a node's rim to a hub port, walkable at constant speed. */
private class Track(node: Offset, port: Offset) {
    val p0 = node
    val p3 = port
    private val pull = (port.x - node.x) * 0.52f
    val p1 = Offset(node.x + pull, node.y)
    val p2 = Offset(port.x - pull, port.y)
    private val lengths = DoubleArray(STEPS + 1).also { sums ->
        var last = node
        var run = 0.0
        for (i in 1..STEPS) {
            val p = bezier(i.toDouble() / STEPS)
            run += hypot((p.x - last.x).toDouble(), (p.y - last.y).toDouble())
            sums[i] = run
            last = p
        }
    }

    private fun bezier(t: Double): Offset {
        val u = 1 - t
        val wa = u * u * u; val wb = 3 * u * u * t; val wc = 3 * u * t * t; val wd = t * t * t
        return Offset((wa * p0.x + wb * p1.x + wc * p2.x + wd * p3.x).toFloat(),
            (wa * p0.y + wb * p1.y + wc * p2.y + wd * p3.y).toFloat())
    }

    /** Point at a fraction of the arc length: 0 at the node, 1 at the hub. */
    fun at(s: Double): Offset {
        val want = min(1.0, max(0.0, s)) * lengths[STEPS]
        var i = 1
        while (i < STEPS && lengths[i] < want) i++
        val a = lengths[i - 1]; val b = lengths[i]
        val local = if (b > a) (want - a) / (b - a) else 0.0
        return bezier((i - 1 + local) / STEPS)
    }

    fun path() = Path().apply {
        moveTo(p0.x, p0.y)
        cubicTo(p1.x, p1.y, p2.x, p2.y, p3.x, p3.y)
    }

    private companion object { const val STEPS = 16 }
}

// endregion

// region Motion

private fun smooth(a: Double, b: Double, x: Double): Double {
    val t = min(1.0, max(0.0, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}

private fun finite(x: Double) = if (x.isFinite()) x else 0.0

/** A reading with anything unusable zeroed, so one bad number from the feed cannot poison the drawing. */
private fun clean(f: EnergyFlows) = EnergyFlows(max(0.0, finite(f.solarW)), max(0.0, finite(f.gridW)),
    finite(f.batteryW), max(0.0, finite(f.loadW)), max(0.0, finite(f.exportW)))

/** [HeroMath.intensity] with a soft start, so a few stray watts draw a faint comet, not one at its floor. */
private fun level(watts: Double) = HeroMath.intensity(watts) * smooth(1.0, 25.0, watts)

/** 0 for an idle element, 1 as soon as its level reaches the floor a real flow has. */
private fun presence(level: Double) = min(1.0, max(0.0, level) / 0.12)

/** Conduit lengths per second. */
private fun rate(watts: Double) = 0.15 + 0.5 * HeroMath.intensity(watts).pow(1.7)

private val slotOffsets = doubleArrayOf(0.0, 0.5, 0.25, 0.75)
private val slotGates = doubleArrayOf(0.0, 0.45, 0.68, 0.86)     // roughly 0, 300 W, 1 kW, 2.5 kW

private class Comet(
    val spine: List<Offset>,
    val body: Path,
    val tail: Offset,
    val head: Offset,
    val color: Color,
    val tailAlpha: Float,
    val headAlpha: Float,
    val dotAlpha: Float,
    val width: Float,
)

private fun addComets(
    comets: MutableList<Comet>, track: Track, towardHub: Boolean, strength: Double, travel: Double,
    vigor: Double, tone: (Int) -> Color,
) {
    if (vigor <= 0 || strength <= 0.004) return
    val samples = 8
    val points = Array(samples + 1) { Offset.Zero }
    val edge = Array(samples + 1) { Offset.Zero }

    fun emit(head: Double, length: Double, width: Float, alpha: Double, color: Color) {
        // The comet enters at the source, crosses, and is swallowed by the sink: clip it to the conduit.
        val tail = head - length
        val lo = max(tail, 0.0); val hi = min(head, 1.0)
        if (hi - lo <= 0.015 || alpha <= 0.008) return
        for (step in 0..samples) {
            val s = lo + (hi - lo) * step / samples
            points[step] = track.at(if (towardHub) s else 1 - s)
        }
        val body = Path()
        for (step in 0..samples) {
            val a = points[max(0, step - 1)]; val b = points[min(samples, step + 1)]
            val run = max(0.001f, hypot(b.x - a.x, b.y - a.y))
            val nx = -(b.y - a.y) / run; val ny = (b.x - a.x) / run
            val along = (lo + (hi - lo) * step / samples - tail) / length
            val half = width / 2 * (0.1 + 0.9 * along.pow(0.85)).toFloat()
            val p = points[step]
            edge[step] = Offset(p.x - nx * half, p.y - ny * half)
            val near = Offset(p.x + nx * half, p.y + ny * half)
            if (step == 0) body.moveTo(near.x, near.y) else body.lineTo(near.x, near.y)
        }
        for (step in samples downTo 0) body.lineTo(edge[step].x, edge[step].y)
        body.close()
        comets += Comet(points.toList(), body, points[0], points[samples], color,
            (alpha * ((lo - tail) / length).pow(1.2)).toFloat(),
            (alpha * ((hi - tail) / length).pow(1.2)).toFloat(),
            (alpha * (1 - smooth(0.95, 1.0, head)) * smooth(0.0, 0.05, head)).toFloat(), width)
    }

    // Brightness: fades in up to the floor, and a trickle stays dimmer than a real flow.
    val glow = presence(strength) * (0.55 + 0.45 * smooth(0.1, 0.5, strength)) * vigor
    for (slot in 0 until Metric.slots) {
        val gate = if (slot == 0) 1.0 else smooth(slotGates[slot] - 0.07, slotGates[slot] + 0.07, strength)
        if (gate <= 0.01) continue
        // A comet that is only partly earned is smaller as well as fainter, so it reads as a small one.
        val length = (0.26 + 0.07 * strength) * (0.6 + 0.4 * gate)
        val width = ((2.3 + 0.9 * strength) * (0.75 + 0.25 * gate)).toFloat()
        val cycle = HeroMath.fract(travel + slotOffsets[slot] + (HeroMath.hash(slot * 7 + 3) - 0.5) * 0.05)
        emit(cycle * (1 + length), length, width, glow * gate, tone(slot))
    }
}

// endregion

// region Drawing

/** Text is measured at density 1 inside a canvas that is already scaled to dp, so sizes stay in dp. */
private val unitDensity = Density(1f, 1f)

private fun TextMeasurer.layout(text: AnnotatedString, maxWidth: Float? = null): TextLayoutResult =
    measure(text, density = unitDensity, softWrap = false, maxLines = 1, overflow = TextOverflow.Ellipsis,
        constraints = if (maxWidth != null) Constraints(maxWidth = max(1, maxWidth.toInt())) else Constraints())

private fun DrawScope.drawCentered(layout: TextLayoutResult, at: Offset) {
    drawText(layout, topLeft = Offset(at.x - layout.size.width / 2f, at.y - layout.size.height / 2f))
}

private fun DrawScope.drawFlow(
    size: Size, state: HeroState, now: Double, ink: Color, tones: Marks, dark: Boolean, measurer: TextMeasurer,
) {
    val snap = state.snapshot
    val live = snap != null
    val stale = snap?.isStale(now = Instant.now()) ?: false
    val vigor = if (stale) 0.45 else 1.0

    // Geometry: four nodes on the corners of a rectangle, the hub at its centre.
    val radius = Metric.ring
    val mid = size.width / 2
    val reach = min(Metric.reach, mid - radius - 22)
    val block = 2 * (Metric.rise + radius) + Metric.labels
    val hubC = Offset(mid, (size.height - block) / 2 + radius + Metric.rise)
    val sunC = Offset(mid - reach, hubC.y - Metric.rise)
    val gridC = Offset(mid - reach, hubC.y + Metric.rise)
    val homeC = Offset(mid + reach, hubC.y - Metric.rise)
    val battC = Offset(mid + reach, hubC.y + Metric.rise)
    val hubLeft = hubC.x - Metric.hubW / 2; val hubRight = hubC.x + Metric.hubW / 2
    val hubTop = hubC.y - Metric.hubH / 2; val hubBottom = hubC.y + Metric.hubH / 2
    val sunTrack = Track(Offset(sunC.x + radius, sunC.y), Offset(hubLeft, hubC.y - Metric.port))
    val gridTrack = Track(Offset(gridC.x + radius, gridC.y), Offset(hubLeft, hubC.y + Metric.port))
    val homeTrack = Track(Offset(homeC.x - radius, homeC.y), Offset(hubRight, hubC.y - Metric.port))
    val battTrack = Track(Offset(battC.x - radius, battC.y), Offset(hubRight, hubC.y + Metric.port))

    // Facts. The labels count in watts, exactly as the eased flows have them.
    val progress = state.progress(now)
    val before = clean(state.previous); val after = clean(state.target)
    val flows = before.mix(after, progress)
    val solarW = flows.solarW; val gridW = flows.gridW; val loadW = flows.loadW; val battW = flows.batteryW
    val percent = snap?.batteryPercent?.takeIf { it.isFinite() }?.coerceIn(0.0, 100.0)
    val low = (percent ?: 100.0) < 20
    // An outage is a grid voltage that is reported and too low. A voltage the feed left out proves nothing.
    val outage = snap?.gridVoltage?.let { it.isFinite() && !snap.gridPresent } ?: false
    val battTone = if (low) tones.alert else tones.battery

    // What is drawn eases in visual level, not in watts: intensity is logarithmic, so a flow rising
    // from nothing would otherwise reach half its final strength in the first tenth of the ramp.
    fun eased(a: Double, b: Double) = a + (b - a) * progress
    val cut = if (outage) 1.0 else 0.0
    val solarLevel = eased(level(before.solarW), level(after.solarW))
    val importLevel = eased(level(before.gridW), level(after.gridW)) * (1 - cut)
    val exportLevel = eased(level(before.exportW), level(after.exportW))
    // The grid conduit carries whichever way the power is going: in from the grid, or out to it.
    val gridLevel = max(importLevel, exportLevel)
    val homeLevel = eased(level(before.loadW), level(after.loadW))
    // Without a battery voltage the feed gives current but no watts: the direction is still known,
    // and is drawn at the faintest real level rather than left out.
    val amps = snap?.let { finite(it.batteryChargeA) - finite(it.batteryDischargeA) } ?: 0.0
    val blind = !((snap?.batteryVoltage ?: 0.0) > 0) && abs(amps) > 0.4
    val charging = if (blind) amps > 0 else battW > 0
    val battLevel = if (blind) 0.14 else eased(level(abs(before.batteryW)), level(abs(after.batteryW)))

    val solarOn = presence(solarLevel); val gridOn = presence(gridLevel)
    val homeOn = presence(homeLevel); val battOn = presence(battLevel)

    // Comets leaving the hub wear the colour of what feeds them, in proportion.
    data class Feed(val color: Color, val watts: Double, val battery: Boolean)
    val feeds = listOf(Feed(tones.solar, after.solarW, false), Feed(tones.grid, after.gridW, false),
        Feed(battTone, after.batteryDischargeW, true)).sortedByDescending { it.watts }
    fun feedColor(slot: Int, battery: Boolean): Color {
        val usable = feeds.filter { battery || !it.battery }
        val total = usable.sumOf { it.watts }
        if (total <= 1) return ink.copy(alpha = if (dark) 0.8f else 0.5f)
        val want = (slotOffsets[slot] + 0.125) * total
        var run = 0.0
        for (item in usable) { run += item.watts; if (want < run) return item.color }
        return usable[0].color
    }

    val comets = ArrayList<Comet>()
    addComets(comets, sunTrack, true, solarLevel, state.phase[0], vigor) { tones.solar }
    addComets(comets, gridTrack, exportLevel <= importLevel, gridLevel, state.phase[1] + 0.37, vigor) { slot ->
        if (exportLevel > importLevel) feedColor(slot, true) else tones.grid
    }
    addComets(comets, battTrack, !charging, battLevel, state.phase[2] + 0.61, vigor) { slot ->
        if (charging) feedColor(slot, false) else battTone
    }
    addComets(comets, homeTrack, false, homeLevel, state.phase[3] + 0.83, vigor) { slot -> feedColor(slot, true) }

    val time = now

    // 1. Halos: a soft pool of light behind whatever is working.
    val pulse = 0.5 + 0.5 * sin(time * 2.4)
    val glowGain = (if (dark) 1.0 else 0.75) * vigor
    fun halo(c: Offset, color: Color, alpha: Double) {
        if (alpha <= 0.004) return
        val r = radius + 11
        drawCircle(Brush.radialGradient(listOf(color.copy(alpha = (alpha * glowGain).toFloat().coerceIn(0f, 1f)), Color.Transparent),
            center = c, radius = r), r, c)
    }
    halo(sunC, tones.solar, 0.34 * solarLevel)
    halo(gridC, tones.grid, 0.32 * gridLevel)
    halo(homeC, ink, 0.12 * homeLevel)
    if (low && live) halo(battC, tones.alert, 0.20 + 0.16 * pulse * min(1.0, battOn + 0.3))
    else halo(battC, tones.battery, 0.30 * battLevel)

    // 2. Conduits: always there as hairlines, a little brighter while they carry power.
    fun conduit(track: Track, on: Double, broken: Double = 0.0) {
        val alpha = if (live) 0.13 + 0.17 * on else 0.09
        if (broken < 1) drawPath(track.path(), ink.copy(alpha = (alpha * (1 - broken)).toFloat()), style = Stroke(1f, cap = StrokeCap.Round))
        if (broken > 0) drawPath(track.path(), ink.copy(alpha = (alpha * broken).toFloat()),
            style = Stroke(1f, cap = StrokeCap.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(1.5f, 4.5f))))
    }
    conduit(sunTrack, solarOn); conduit(gridTrack, gridOn, cut); conduit(homeTrack, homeOn); conduit(battTrack, battOn)

    // 3. Comets: a soft bloom underneath, then the tapered body and its head.
    for (comet in comets) {
        val bloom = Path()
        comet.spine.forEachIndexed { i, p -> if (i == 0) bloom.moveTo(p.x, p.y) else bloom.lineTo(p.x, p.y) }
        val peak = comet.headAlpha * (if (dark) 0.5f else 0.36f)
        drawPath(bloom, Brush.linearGradient(listOf(comet.color.copy(alpha = 0f), comet.color.copy(alpha = peak.coerceIn(0f, 1f))), comet.tail, comet.head),
            style = Stroke(comet.width + 2.4f, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
    for (comet in comets) {
        drawPath(comet.body, Brush.linearGradient(
            listOf(comet.color.copy(alpha = (comet.tailAlpha * 0.8f).coerceIn(0f, 1f)), comet.color.copy(alpha = comet.headAlpha.coerceIn(0f, 1f))),
            comet.tail, comet.head))
        if (comet.dotAlpha > 0.02f) drawCircle(comet.color.copy(alpha = comet.dotAlpha.coerceIn(0f, 1f)), comet.width / 2 + 0.35f, comet.head)
    }

    // 4. Nodes.
    fun disc(c: Offset, on: Double, dashed: Double = 0.0) {
        val top = if (live) 0.09f else 0.05f; val bottom = if (live) 0.03f else 0.02f
        drawCircle(Brush.verticalGradient(listOf(ink.copy(alpha = top), ink.copy(alpha = bottom)), c.y - radius, c.y + radius), radius, c)
        val alpha = if (live) 0.17 + 0.23 * on else 0.12
        if (dashed < 1) drawCircle(ink.copy(alpha = (alpha * (1 - dashed)).toFloat()), radius, c, style = Stroke(1f))
        if (dashed > 0) drawCircle(ink.copy(alpha = (alpha * dashed).toFloat()), radius, c,
            style = Stroke(1f, cap = StrokeCap.Round, pathEffect = PathEffect.dashPathEffect(floatArrayOf(2f, 3.5f))))
    }
    fun glyphAlpha(on: Double) = if (live) 0.36 + 0.54 * on else 0.22

    disc(sunC, solarOn)
    drawSun(sunC, glyphAlpha(solarOn), solarOn, solarLevel, time, ink, tones.solar)

    disc(gridC, gridOn, cut)
    drawPylon(gridC, glyphAlpha(gridOn) + (0.26 - glyphAlpha(gridOn)) * cut, cut, ink)

    disc(homeC, homeOn)
    drawHouse(homeC, glyphAlpha(homeOn), homeLevel, ink)

    disc(battC, battOn)
    if (percent != null) {
        val fraction = percent / 100
        val arcColor = if (low) tones.alert else ink.copy(alpha = ((0.42 + 0.3 * battOn) * (if (dark) 1.0 else 0.85)).toFloat().coerceIn(0f, 1f))
        if (fraction > 0.995) drawCircle(arcColor, radius, battC, style = Stroke(1.8f))
        else drawArc(arcColor, -90f, 360f * max(0.012, fraction).toFloat(), false, Offset(battC.x - radius, battC.y - radius),
            Size(radius * 2, radius * 2), style = Stroke(1.8f, cap = StrokeCap.Round))
    }
    drawBattery(battC, glyphAlpha(max(battOn, if (percent == null) 0.0 else 0.35)), percent?.div(100), low, ink, tones.alert)

    // 5. Hub. It wakes when power reaches it.
    val through = max(max(solarLevel, gridLevel), if (charging) 0.0 else battLevel).coerceAtLeast(homeLevel)
    drawHub(Offset(hubLeft, hubTop), Size(Metric.hubW, Metric.hubH), if (live) through * vigor else 0.0, live, time, dark, ink,
        listOf(sunTrack.p3 to solarOn, gridTrack.p3 to gridOn, homeTrack.p3 to homeOn, battTrack.p3 to battOn))

    // 6. Labels.
    val lift = if (dark) 1.0 else 1.22
    fun valueText(text: String, alpha: Double, color: Color = ink) = buildAnnotatedString {
        withStyle(SpanStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, fontFamily = FontFamily.SansSerif,
            color = color.copy(alpha = min(1.0, alpha * lift).toFloat()), fontFeatureSettings = "tnum")) { append(text) }
    }
    fun captionText(text: String, alpha: Double, color: Color = ink) = buildAnnotatedString {
        withStyle(SpanStyle(fontSize = 9.5.sp, fontWeight = FontWeight.Medium, color = color.copy(alpha = min(1.0, alpha * lift).toFloat()))) { append(text) }
    }
    fun reading(text: String, on: Double, fade: Double = 1.0) =
        if (live) valueText(text, (0.38 + 0.54 * on * (if (stale) 0.6 else 1.0)) * fade) else valueText("--", 0.24)
    fun valuePoint(c: Offset) = Offset(c.x, c.y + radius + 11.5f)
    fun captionPoint(c: Offset) = Offset(c.x, c.y + radius + 24f)
    val quiet = if (live) 0.42 else 0.3

    drawCentered(measurer.layout(reading(PowerFormat.watts(solarW), solarOn)), valuePoint(sunC))
    drawCentered(measurer.layout(captionText("Solar", quiet + 0.12 * solarOn)), captionPoint(sunC))
    drawCentered(measurer.layout(reading(PowerFormat.watts(loadW), homeOn)), valuePoint(homeC))
    drawCentered(measurer.layout(captionText("Home", quiet + 0.12 * homeOn)), captionPoint(homeC))

    // Grid: its watts, or "Outage" once the line is gone.
    if (outage) drawCentered(measurer.layout(valueText("Outage", 1.0, tones.alert)), valuePoint(gridC))
    else if (flows.exportW > 15) drawCentered(measurer.layout(reading("↑ " + PowerFormat.watts(flows.exportW), gridOn)), valuePoint(gridC))
    else drawCentered(measurer.layout(reading(PowerFormat.watts(gridW), gridOn)), valuePoint(gridC))
    drawCentered(measurer.layout(captionText(if (flows.exportW > 15) "Export" else "Grid", quiet + 0.12 * gridOn)), captionPoint(gridC))

    // Battery: watts (or amps when that is all the feed gives), then charge and what it is doing.
    val filling = if (blind) amps > 0 else battW > 15
    val draining = if (blind) amps < 0 else battW < -15
    val stateText = when {
        filling -> "Charging"
        low -> "Low"
        draining -> "Discharging"
        percent != null -> if (percent >= 99.5) "Full" else "Idle"
        else -> null
    }
    val battReading = if (blind) "${min(999.0, abs(amps)).toInt()} A" else PowerFormat.watts(battW)
    drawCentered(measurer.layout(reading(battReading, if (blind) 1.0 else battOn)), valuePoint(battC))
    val battCaption = if (percent != null) buildAnnotatedString {
        withStyle(SpanStyle(fontSize = 9.5.sp, fontWeight = FontWeight.SemiBold, fontFeatureSettings = "tnum",
            color = if (low) tones.alert else ink.copy(alpha = 0.9f))) { append("${Math.round(percent)}%") }
        withStyle(SpanStyle(fontSize = 9.5.sp, fontWeight = FontWeight.Medium,
            color = if (low) tones.alert.copy(alpha = 0.85f) else ink.copy(alpha = min(1.0, (quiet + 0.12 * battOn) * lift).toFloat()))) {
            append("  ${stateText ?: ""}")
        }
    } else captionText(if (live) stateText ?: "Battery" else "Battery", quiet + 0.12 * battOn)
    val resolved = measurer.layout(battCaption)
    // The widest label on the map: keep it centred under its node unless that would push it off the canvas.
    val half = resolved.size.width / 2f
    val battX = max(half + Metric.edge, min(battC.x, size.width - Metric.edge - half))
    drawCentered(resolved, Offset(battX, captionPoint(battC).y))

    // Status under the hub: what is carrying the load, then anything that needs attention.
    // Each line is cut to the room between the two lower conduits at its own height.
    fun room(y: Float): Float {
        var halfRoom = mid - Metric.edge
        for (step in 0..12) {
            val p = gridTrack.at(step / 12.0)
            if (abs(p.y - y) < 8) halfRoom = min(halfRoom, mid - p.x - 6)
        }
        return max(24f, halfRoom * 2)
    }
    val status = ArrayList<AnnotatedString>()
    if (snap != null) {
        if (stale && snap.deviceTime != null) {
            val minutes = max(1L, ((Instant.now().epochSecond - snap.deviceTime.epochSecond) / 60))
            val ago = if (minutes < 100) "$minutes min" else if (minutes < 48 * 60) "${minutes / 60} h" else "${minutes / 1440} d"
            status += captionText("Updated $ago ago", 0.55)
        } else if (snap.mode != InverterMode.Unknown) {
            status += captionText(snap.mode.label, 0.55)
        }
        // One line, whatever the feed sends: no line breaks, and no more text than could ever fit.
        val warning = (snap.activeWarning ?: "").split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ").take(60)
        if (warning.isNotEmpty()) status += buildAnnotatedString {
            withStyle(SpanStyle(fontSize = 9.5.sp, fontWeight = FontWeight.SemiBold, color = tones.alert)) { append(warning) }
        }
    } else {
        status += captionText("Waiting for data", 0.5)
    }
    status.forEachIndexed { row, line ->
        val y = hubBottom + 12 + 13 * row
        drawCentered(measurer.layout(line, room(y)), Offset(hubC.x, y))
    }
}

// endregion

// region Glyphs

private val line = Stroke(1.3f, cap = StrokeCap.Round, join = StrokeJoin.Round)

private fun DrawScope.drawSun(c: Offset, alpha: Double, on: Double, level: Double, time: Double, ink: Color, tone: Color) {
    val rays = Path()
    for (k in 0 until 8) {
        val angle = k * Math.PI / 4
        val shimmer = sin(time * 1.9 + k * 2.4) * 0.9 * level
        val inner = 6.4; val outer = 8.6 + 0.9 * level + shimmer
        rays.moveTo((c.x + cos(angle) * inner).toFloat(), (c.y + sin(angle) * inner).toFloat())
        rays.lineTo((c.x + cos(angle) * outer).toFloat(), (c.y + sin(angle) * outer).toFloat())
    }
    drawPath(rays, ink.copy(alpha = alpha.toFloat()), style = line)
    // The core warms up as soon as the panels produce anything, and brightens with output.
    if (on > 0.01) drawCircle(tone.copy(alpha = (on * (0.45 + 0.5 * level)).toFloat().coerceIn(0f, 1f)), 3.8f, c)
    drawCircle(ink.copy(alpha = alpha.toFloat()), 3.8f, c, style = line)
}

/** [cut] runs 0…1 as an outage sets in: the strike-through draws itself across the tower. */
private fun DrawScope.drawPylon(c: Offset, alpha: Double, cut: Double, ink: Color) {
    fun p(x: Float, y: Float) = Offset(c.x + x, c.y + y)
    val tower = Path()
    fun seg(a: Offset, b: Offset) { tower.moveTo(a.x, a.y); tower.lineTo(b.x, b.y) }
    tower.moveTo(p(-5.5f, 9f).x, p(-5.5f, 9f).y)
    tower.lineTo(p(-1.5f, -9f).x, p(-1.5f, -9f).y); tower.lineTo(p(1.5f, -9f).x, p(1.5f, -9f).y); tower.lineTo(p(5.5f, 9f).x, p(5.5f, 9f).y)
    seg(p(-7f, -5f), p(7f, -5f))
    seg(p(-8.5f, -0.5f), p(8.5f, -0.5f))
    seg(p(-7f, -5f), p(-7f, -3.2f)); seg(p(7f, -5f), p(7f, -3.2f))
    seg(p(-8.5f, -0.5f), p(-8.5f, 1.3f)); seg(p(8.5f, -0.5f), p(8.5f, 1.3f))
    tower.moveTo(p(-3.4f, -0.5f).x, p(-3.4f, -0.5f).y)
    tower.lineTo(p(4.6f, 5f).x, p(4.6f, 5f).y); tower.lineTo(p(-4.6f, 5f).x, p(-4.6f, 5f).y); tower.lineTo(p(3.4f, -0.5f).x, p(3.4f, -0.5f).y)
    drawPath(tower, ink.copy(alpha = alpha.toFloat().coerceIn(0f, 1f)), style = Stroke(1.15f, cap = StrokeCap.Round, join = StrokeJoin.Round))
    if (cut > 0.02) {
        // No grid: the tower is struck through.
        val drawn = (smooth(0.0, 1.0, cut) * 21).toFloat()
        val slash = Path().apply { moveTo(c.x - 10.5f, c.y + 10.5f); lineTo(c.x - 10.5f + drawn, c.y + 10.5f - drawn) }
        drawPath(slash, ink.copy(alpha = (0.62 * smooth(0.0, 0.2, cut)).toFloat()), style = line)
    }
}

private fun DrawScope.drawHouse(c: Offset, alpha: Double, lit: Double, ink: Color) {
    fun x(v: Float) = c.x + v
    fun y(v: Float) = c.y + v - 0.5f
    val door = Path().apply {
        moveTo(x(-2.1f), y(7.8f)); lineTo(x(-2.1f), y(3.6f))
        quadraticTo(x(0f), y(1.2f), x(2.1f), y(3.6f))
        lineTo(x(2.1f), y(7.8f))
    }
    if (lit > 0.01) drawPath(door, ink.copy(alpha = (min(1.0, lit * 1.5) * 0.55).toFloat()))
    val house = Path().apply {
        moveTo(x(-8.8f), y(-0.6f)); lineTo(x(0f), y(-8.4f)); lineTo(x(8.8f), y(-0.6f))
        moveTo(x(-6.3f), y(-2.6f)); lineTo(x(-6.3f), y(7.8f)); lineTo(x(6.3f), y(7.8f)); lineTo(x(6.3f), y(-2.6f))
    }
    drawPath(house, ink.copy(alpha = alpha.toFloat().coerceIn(0f, 1f)), style = line)
    drawPath(door, ink.copy(alpha = (alpha * 0.8).toFloat().coerceIn(0f, 1f)), style = Stroke(1.1f, cap = StrokeCap.Round, join = StrokeJoin.Round))
}

private fun DrawScope.drawBattery(c: Offset, alpha: Double, fraction: Double?, low: Boolean, ink: Color, alert: Color) {
    val a = alpha.toFloat().coerceIn(0f, 1f)
    val bodyTL = Offset(c.x - 9, c.y - 5)
    drawRoundRect(ink.copy(alpha = a), bodyTL, Size(15.5f, 10f), CornerRadius(3f), style = Stroke(1.3f))
    drawRoundRect(ink.copy(alpha = a), Offset(bodyTL.x + 15.5f + 1.3f, c.y - 2), Size(1.7f, 4f), CornerRadius(0.8f))
    if (fraction != null) {
        val well = Size(15.5f - 4.2f, 10f - 4.2f)
        val fill = Size(max(1.6f, well.width * fraction.toFloat()), well.height)
        drawRoundRect(if (low) alert else ink.copy(alpha = (a * 0.75f)), Offset(bodyTL.x + 2.1f, bodyTL.y + 2.1f), fill, CornerRadius(1.1f))
    }
}

private fun DrawScope.drawHub(
    origin: Offset, rect: Size, activity: Double, live: Boolean, time: Double, dark: Boolean, ink: Color,
    ports: List<Pair<Offset, Double>>,
) {
    val shellColors = listOf(ink.copy(alpha = if (live) 0.12f else 0.07f), ink.copy(alpha = if (live) 0.04f else 0.03f))
    drawRoundRect(Brush.verticalGradient(shellColors, origin.y, origin.y + rect.height), origin, rect, CornerRadius(9f))
    drawRoundRect(ink.copy(alpha = if (live) (0.22 + 0.2 * min(1.0, activity * 2)).toFloat() else 0.13f), origin, rect, CornerRadius(9f), style = Stroke(1f))
    drawLine(ink.copy(alpha = if (live) 0.14f else 0.07f), Offset(origin.x + 9, origin.y + 1.5f), Offset(origin.x + rect.width - 9, origin.y + 1.5f),
        1f, StrokeCap.Round)

    // Display: a flat trace at rest, a sine wave while the inverter is making AC.
    val window = Pair(Offset(origin.x + 5, origin.y + 5.5f), Size(rect.width - 10, 14f))
    drawRoundRect(Color.Black.copy(alpha = if (dark) 0.34f else 0.10f), window.first, window.second, CornerRadius(4f))
    val swing = 3.8 * min(1.0, activity * 1.6)
    val wave = Path()
    val span = window.second.width - 7
    val midY = window.first.y + window.second.height / 2
    for (step in 0..18) {
        val f = step / 18.0
        val envelope = sin(Math.PI * f)
        val y = (midY + sin(f * 3.4 * Math.PI - time * 3.2) * swing * (0.35 + 0.65 * envelope)).toFloat()
        val x = window.first.x + 3.5f + span * f.toFloat()
        if (step == 0) wave.moveTo(x, y) else wave.lineTo(x, y)
    }
    drawPath(wave, ink.copy(alpha = if (live) (0.4 + 0.5 * min(1.0, activity * 2)).toFloat() else 0.2f),
        style = Stroke(1.15f, cap = StrokeCap.Round, join = StrokeJoin.Round))

    // Vents.
    for (row in 0 until 3) {
        val y = origin.y + 25.5f + row * 4
        drawLine(ink.copy(alpha = if (live) 0.17f else 0.1f), Offset(origin.x + rect.width / 2 - 7, y), Offset(origin.x + rect.width / 2 + 7, y), 1f, StrokeCap.Round)
    }

    // Ports where the conduits land.
    for ((point, on) in ports) {
        drawCircle(ink.copy(alpha = if (live) (0.3 + 0.34 * on).toFloat().coerceIn(0f, 1f) else 0.18f), 1.6f, point)
    }
}

// endregion
