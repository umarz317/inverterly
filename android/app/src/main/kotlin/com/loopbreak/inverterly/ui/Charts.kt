package com.loopbreak.inverterly.ui

import android.text.format.DateFormat
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
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
import androidx.compose.ui.input.pointer.changedToUp
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.positionChange
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.loopbreak.inverterly.core.DayCurve
import com.loopbreak.inverterly.core.DayCurvePoint
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt

/** Time as the phone shows it elsewhere: "5:22 PM" or "17:22". */
fun clockTime(time: Instant, zone: ZoneId = ZoneId.systemDefault()): String =
    DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(Locale.getDefault()).format(time.atZone(zone))

/**
 * Reads a horizontal drag across a chart: [onScrub] gets the finger's place as a fraction (0 to 1)
 * of the plot, which is the chart's width less [rightPad] for the axis labels, while it is held on a
 * drag that is mostly sideways, and null once it lifts. A mostly vertical drag is left to the page's scroll.
 */
fun Modifier.scrub(rightPad: Dp, onScrub: (Float?) -> Unit): Modifier = pointerInput(rightPad) {
    awaitEachGesture {
        val down = awaitFirstDown(requireUnconsumed = false)
        var total = Offset.Zero
        var sideways = false
        val slop = viewConfiguration.touchSlop
        while (true) {
            val event = awaitPointerEvent()
            val change = event.changes.firstOrNull { it.id == down.id } ?: break
            if (change.changedToUp() || change.isConsumed && !sideways) break
            total += change.positionChange()
            if (!sideways && abs(total.y) > slop && abs(total.y) > abs(total.x)) break
            if (!sideways && abs(total.x) > slop) sideways = true
            if (sideways) {
                onScrub((change.position.x / (size.width - rightPad.toPx())).coerceIn(0f, 1f))
                change.consume()
            }
        }
        onScrub(null)
    }
}

/** 0 and up in steps of 1, 2 or 5 times a power of ten, about [desired] marks in all. */
internal fun niceTicks(maxValue: Double, desired: Int = 4): List<Double> {
    if (maxValue <= 0) return listOf(0.0, 1.0)
    val raw = maxValue / max(1, desired - 1)
    val magnitude = 10.0.pow(floor(log10(raw)))
    val step = listOf(1.0, 2.0, 5.0, 10.0).map { it * magnitude }.first { it >= raw }
    val top = ceil(maxValue / step) * step
    return generateSequence(0.0) { it + step }.takeWhile { it <= top + step / 1000 }.toList()
}

/** A smooth curve through the points that never overshoots them (monotone cubic, Fritsch–Carlson). */
internal fun monotonePath(points: List<Offset>, path: Path = Path()): Path {
    if (points.isEmpty()) return path
    path.moveTo(points[0].x, points[0].y)
    if (points.size == 1) return path
    val n = points.size
    val dx = FloatArray(n - 1) { points[it + 1].x - points[it].x }
    val slope = FloatArray(n - 1) { if (dx[it] == 0f) 0f else (points[it + 1].y - points[it].y) / dx[it] }
    val tangent = FloatArray(n)
    tangent[0] = slope[0]; tangent[n - 1] = slope[n - 2]
    for (i in 1 until n - 1) {
        tangent[i] = if (slope[i - 1] * slope[i] <= 0f) 0f else (slope[i - 1] + slope[i]) / 2
    }
    for (i in 0 until n - 1) {
        if (slope[i] == 0f) { tangent[i] = 0f; tangent[i + 1] = 0f; continue }
        val a = tangent[i] / slope[i]; val b = tangent[i + 1] / slope[i]
        val h = a * a + b * b
        if (h > 9f) {
            val t = 3f / kotlin.math.sqrt(h)
            tangent[i] = t * a * slope[i]; tangent[i + 1] = t * b * slope[i]
        }
    }
    for (i in 0 until n - 1) {
        val d = dx[i] / 3
        path.cubicTo(points[i].x + d, points[i].y + tangent[i] * d, points[i + 1].x - d, points[i + 1].y - tangent[i + 1] * d,
            points[i + 1].x, points[i + 1].y)
    }
    return path
}

private fun TextMeasurer.label(text: String, style: TextStyle): TextLayoutResult = measure(text, style)

private fun DrawScope.drawLabel(layout: TextLayoutResult, centerX: Float? = null, rightX: Float? = null, y: Float, color: Color) {
    val x = when {
        centerX != null -> centerX - layout.size.width / 2f
        rightX != null -> rightX - layout.size.width
        else -> 0f
    }
    drawText(layout, color, Offset(x, y - layout.size.height / 2f))
}

/** Where the day's hour marks sit: midnight, 6 am, noon, 6 pm and midnight. */
private val HourMarks = listOf(0, 6, 12, 18, 24)

@Composable
private fun hourText(hour: Int): String {
    val context = LocalContext.current
    return if (DateFormat.is24HourFormat(context)) "%02d".format(hour % 24)
    else when (hour % 24) { 0 -> "12 AM"; 12 -> "12 PM"; in 1..11 -> "${hour % 24} AM"; else -> "${hour % 24 - 12} PM" }
}

/** Common plot geometry: [right] pixels are kept for the y labels and [bottom] for the x labels. */
private class Plot(val width: Float, val height: Float, val right: Float, val bottom: Float) {
    val w get() = width - right
    val h get() = height - bottom
}

/**
 * Solar as a filled curve, grid and load as lines, midnight to midnight. Dragging across it reads
 * out that moment; otherwise the readout shows the latest point.
 */
@Composable
fun PowerChart(curve: DayCurve, selection: Instant?, onSelect: (Instant?) -> Unit, modifier: Modifier = Modifier) {
    val tones = marks
    val ink = MaterialTheme.colorScheme.onSurface
    val axis = MaterialTheme.colorScheme.onSurfaceVariant
    val measurer = rememberTextMeasurer()
    val axisStyle = TextStyle(fontSize = 11.sp)
    val hours = HourMarks.map { hourText(it) }
    val points = curve.points
    val maxKw = remember(curve) { max(0.5, points.maxOf { max(it.pvW, max(it.gridW, it.loadW)) } / 1000) }
    val ticks = remember(maxKw) { niceTicks(maxKw) }
    val shown = curve.pointNear(selection) ?: points.last()

    Column(modifier) {
        Readout(
            title = (if (selection == null) "Latest · " else "") + clockTime(shown.time),
            items = listOf(EnergySource.Solar to shown.pvW, EnergySource.Grid to shown.gridW, EnergySource.Load to shown.loadW),
        )
        val description = "Chart of today's solar, grid and load power"
        androidx.compose.foundation.layout.Spacer(Modifier.height(12.dp))
        Canvas(
            Modifier.fillMaxWidth().height(240.dp).semantics { contentDescription = description }
                .scrub(34.dp) { f -> onSelect(f?.let { curve.dayStart.plusMillis((it * 24 * 3600_000L).toLong()) }) },
        ) {
            val plot = Plot(size.width, size.height, 34.dp.toPx(), 18.dp.toPx())
            val top = ticks.last()
            fun x(t: Instant) = (t.toEpochMilli() - curve.dayStart.toEpochMilli()).toFloat() / (24 * 3600_000f) * plot.w
            fun y(kw: Double) = plot.h - (kw / top).toFloat() * plot.h

            // Grid and axes.
            for (tick in ticks) {
                drawLine(axis.copy(alpha = 0.18f), Offset(0f, y(tick)), Offset(plot.w, y(tick)), 1.dp.toPx())
                val text = if (tick == 0.0) "0" else "${trim(tick)} kW"
                drawLabel(measurer.label(text, axisStyle), rightX = plot.width, y = y(tick), color = axis)
            }
            HourMarks.forEachIndexed { i, h ->
                val gx = h / 24f * plot.w
                drawLine(axis.copy(alpha = 0.12f), Offset(gx, 0f), Offset(gx, plot.h), 1.dp.toPx())
                val layout = measurer.label(hours[i], axisStyle)
                val cx = (gx).coerceIn(layout.size.width / 2f, plot.w - layout.size.width / 2f + 4.dp.toPx())
                drawLabel(layout, centerX = cx, y = plot.h + 10.dp.toPx(), color = axis)
            }

            val solar = points.map { Offset(x(it.time), y(it.pvW / 1000)) }
            val solarLine = monotonePath(solar)
            val area = Path().apply {
                addPath(solarLine)
                lineTo(solar.last().x, plot.h); lineTo(solar.first().x, plot.h); close()
            }
            drawPath(area, Brush.verticalGradient(listOf(tones.solar.copy(alpha = 0.28f), tones.solar.copy(alpha = 0.02f)), 0f, plot.h))
            val stroke = Stroke(2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
            drawPath(solarLine, tones.solar, style = stroke)
            drawPath(Path().apply { points.forEachIndexed { i, p -> val o = Offset(x(p.time), y(p.gridW / 1000)); if (i == 0) moveTo(o.x, o.y) else lineTo(o.x, o.y) } },
                tones.grid, style = stroke)
            drawPath(monotonePath(points.map { Offset(x(it.time), y(it.loadW / 1000)) }), ink.copy(alpha = 0.8f), style = stroke)

            // The moment shown and a marker on each series.
            val sx = x(shown.time)
            drawLine(axis.copy(alpha = if (selection == null) 0.25f else 0.5f), Offset(sx, 0f), Offset(sx, plot.h), 1.dp.toPx(),
                pathEffect = if (selection == null) PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())) else null)
            drawCircle(tones.solar, 3.5.dp.toPx(), Offset(sx, y(shown.pvW / 1000)))
            drawCircle(tones.grid, 3.5.dp.toPx(), Offset(sx, y(shown.gridW / 1000)))
            drawCircle(ink, 3.5.dp.toPx(), Offset(sx, y(shown.loadW / 1000)))
        }
    }
}

private fun trim(value: Double): String = if (value == Math.rint(value)) value.toInt().toString() else "%.1f".format(Locale.US, value)

/** The battery's charge through the day, sharing the power chart's selected moment. */
@Composable
fun BatteryChart(curve: DayCurve, selection: Instant?, onSelect: (Instant?) -> Unit, modifier: Modifier = Modifier) {
    val tones = marks
    val axis = MaterialTheme.colorScheme.onSurfaceVariant
    val measurer = rememberTextMeasurer()
    val axisStyle = TextStyle(fontSize = 11.sp)
    val hours = HourMarks.map { hourText(it) }
    val points = remember(curve) { curve.points.filter { it.batteryPercent != null } }
    if (points.isEmpty()) return
    val shown = selection?.let { t -> points.minByOrNull { abs(it.time.toEpochMilli() - t.toEpochMilli()) } } ?: points.last()
    val percent = shown.batteryPercent ?: 0.0

    Column(modifier) {
        androidx.compose.foundation.layout.Row(
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(6.dp),
            verticalAlignment = androidx.compose.ui.Alignment.Bottom,
        ) {
            androidx.compose.material3.Text("Battery", style = MaterialTheme.typography.labelLarge, color = axis)
            androidx.compose.material3.Text("${percent.roundToInt()}%", style = MaterialTheme.typography.titleMedium)
            androidx.compose.material3.Text(if (selection == null) "now" else "at " + clockTime(shown.time),
                style = MaterialTheme.typography.labelMedium, color = axis)
        }
        androidx.compose.foundation.layout.Spacer(Modifier.height(8.dp))
        Canvas(
            Modifier.fillMaxWidth().height(120.dp)
                .semantics { contentDescription = "Chart of the battery's charge through the day" }
                .scrub(34.dp) { f -> onSelect(f?.let { curve.dayStart.plusMillis((it * 24 * 3600_000L).toLong()) }) },
        ) {
            val plot = Plot(size.width, size.height, 34.dp.toPx(), 18.dp.toPx())
            fun x(t: Instant) = (t.toEpochMilli() - curve.dayStart.toEpochMilli()).toFloat() / (24 * 3600_000f) * plot.w
            fun y(p: Double) = plot.h - (p / 100).toFloat() * plot.h
            for (tick in listOf(0, 50, 100)) {
                drawLine(axis.copy(alpha = 0.18f), Offset(0f, y(tick.toDouble())), Offset(plot.w, y(tick.toDouble())), 1.dp.toPx())
                drawLabel(measurer.label("$tick%", axisStyle), rightX = plot.width, y = y(tick.toDouble()), color = axis)
            }
            HourMarks.forEachIndexed { i, h ->
                val gx = h / 24f * plot.w
                drawLine(axis.copy(alpha = 0.12f), Offset(gx, 0f), Offset(gx, plot.h), 1.dp.toPx())
                val layout = measurer.label(hours[i], axisStyle)
                drawLabel(layout, centerX = gx.coerceIn(layout.size.width / 2f, plot.w - layout.size.width / 2f + 4.dp.toPx()),
                    y = plot.h + 10.dp.toPx(), color = axis)
            }
            val pts = points.map { Offset(x(it.time), y(it.batteryPercent ?: 0.0)) }
            val line = monotonePath(pts)
            val area = Path().apply { addPath(line); lineTo(pts.last().x, plot.h); lineTo(pts.first().x, plot.h); close() }
            drawPath(area, Brush.verticalGradient(listOf(tones.battery.copy(alpha = 0.22f), tones.battery.copy(alpha = 0.02f)), 0f, plot.h))
            drawPath(line, tones.battery, style = Stroke(2.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
            val sx = x(shown.time)
            drawLine(axis.copy(alpha = if (selection == null) 0.25f else 0.5f), Offset(sx, 0f), Offset(sx, plot.h), 1.dp.toPx(),
                pathEffect = if (selection == null) PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx())) else null)
            drawCircle(tones.battery, 3.5.dp.toPx(), Offset(sx, y(percent)))
        }
    }
}

/** The moment shown and each series' power at it; the coloured marks double as the legend. */
@Composable
private fun Readout(title: String, items: List<Pair<EnergySource, Double>>) {
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    Column(verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
        androidx.compose.material3.Text(title, style = MaterialTheme.typography.labelLarge, color = secondary)
        androidx.compose.foundation.layout.Row {
            for ((source, watts) in items) {
                Column(Modifier.weight(1f)) {
                    androidx.compose.foundation.layout.Row(
                        verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
                        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(5.dp),
                    ) {
                        SourceIcon(source, 14.dp)
                        androidx.compose.material3.Text(source.title, style = MaterialTheme.typography.labelMedium, color = secondary)
                    }
                    androidx.compose.material3.Text(com.loopbreak.inverterly.core.PowerFormat.watts(watts), style = MaterialTheme.typography.titleMedium)
                }
            }
        }
    }
}

// region Period bars

/** One day or month of totals. */
data class Period(
    val id: String,
    val date: java.time.LocalDate,
    val label: String,
    val solar: Double,
    val grid: Double,
    val load: Double,
    /** Today, still adding up. */
    val live: Boolean,
    /** Estimated energy sent to the grid. */
    val export: Double = 0.0,
)

/** Solar stacked under grid for each period; dragging reads one out, otherwise the latest shows. */
@Composable
fun PeriodChart(periods: List<Period>, byDay: Boolean, selection: Period?, onSelect: (Period?) -> Unit, modifier: Modifier = Modifier) {
    val tones = marks
    val axis = MaterialTheme.colorScheme.onSurfaceVariant
    val measurer = rememberTextMeasurer()
    val axisStyle = TextStyle(fontSize = 11.sp)
    val ordered = remember(periods) { periods.sortedBy { it.date } }
    // The slots the bars sit in: every day of the month shown, or every month from the first to the last.
    val slots = remember(ordered, byDay) {
        val first = ordered.first().date; val last = ordered.last().date
        if (byDay) (0 until first.withDayOfMonth(1).lengthOfMonth()).map { first.withDayOfMonth(1).plusDays(it.toLong()) }
        else generateSequence(first.withDayOfMonth(1)) { it.plusMonths(1) }.takeWhile { !it.isAfter(last) }.toList()
    }
    fun slotOf(p: Period) = slots.indexOfFirst { if (byDay) it == p.date else it.year == p.date.year && it.month == p.date.month }
    val maxKwh = remember(ordered) { max(1.0, ordered.maxOf { it.solar + it.grid }) }
    val ticks = remember(maxKwh) { niceTicks(maxKwh) }

    Column(modifier) {
        val shown = selection ?: periods.first()
        Column(verticalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(8.dp)) {
            androidx.compose.material3.Text(if (shown.live) shown.label + " · so far" else shown.label,
                style = MaterialTheme.typography.labelLarge, color = axis)
            androidx.compose.foundation.layout.Row {
                KwhValue(EnergySource.Solar, shown.solar, Modifier.weight(1f))
                KwhValue(EnergySource.Grid, shown.grid, Modifier.weight(1f))
                KwhValue(EnergySource.Load, shown.load, Modifier.weight(1f))
                if (shown.export > 0) KwhValue(EnergySource.Export, shown.export, Modifier.weight(1f))
            }
        }
        androidx.compose.foundation.layout.Spacer(Modifier.height(12.dp))
        Canvas(
            Modifier.fillMaxWidth().height(200.dp)
                .semantics { contentDescription = "Bar chart of solar and grid energy for each ${if (byDay) "day" else "month"}, in kilowatt hours" }
                .scrub(34.dp) { f ->
                    if (f == null) onSelect(null) else {
                        val slot = (f * slots.size).toInt().coerceIn(0, slots.size - 1)
                        onSelect(ordered.firstOrNull { slotOf(it) == slot })
                    }
                },
        ) {
            val plot = Plot(size.width, size.height, 34.dp.toPx(), 18.dp.toPx())
            val top = ticks.last()
            fun y(v: Double) = plot.h - (v / top).toFloat() * plot.h
            for (tick in ticks) {
                drawLine(axis.copy(alpha = 0.18f), Offset(0f, y(tick)), Offset(plot.w, y(tick)), 1.dp.toPx())
                drawLabel(measurer.label(trim(tick), axisStyle), rightX = plot.width, y = y(tick), color = axis)
            }
            val slotW = plot.w / slots.size
            val barW = slotW * 0.7f
            for (p in ordered) {
                val i = slotOf(p)
                if (i < 0) continue
                val dim = selection != null && p.id != shown.id
                val a = if (dim) 0.35f else 1f
                val left = i * slotW + (slotW - barW) / 2
                val solarTop = y(p.solar)
                val gridTop = y(p.solar + p.grid)
                val r = CornerRadius(3.dp.toPx())
                if (p.solar > 0) drawRoundRect(tones.solar.copy(alpha = a), Offset(left, solarTop), Size(barW, plot.h - solarTop), r)
                if (p.grid > 0) drawRoundRect(tones.grid.copy(alpha = a), Offset(left, gridTop), Size(barW, solarTop - gridTop), r)
            }
            slots.forEachIndexed { i, d ->
                val show = if (byDay) i % 7 == 0 else true
                if (!show) return@forEachIndexed
                val text = if (byDay) d.dayOfMonth.toString() else d.month.getDisplayName(java.time.format.TextStyle.NARROW, Locale.getDefault())
                drawLabel(measurer.label(text, axisStyle), centerX = i * slotW + slotW / 2, y = plot.h + 10.dp.toPx(), color = axis)
            }
        }
    }
}

@Composable
private fun KwhValue(source: EnergySource, kWh: Double, modifier: Modifier) {
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    Column(modifier) {
        androidx.compose.foundation.layout.Row(
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
            horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(5.dp),
        ) {
            SourceIcon(source, 14.dp)
            androidx.compose.material3.Text(source.title, style = MaterialTheme.typography.labelMedium, color = secondary)
        }
        androidx.compose.foundation.layout.Row(verticalAlignment = androidx.compose.ui.Alignment.Bottom) {
            androidx.compose.material3.Text(com.loopbreak.inverterly.core.PowerFormat.kWhNumber(kWh), style = MaterialTheme.typography.titleMedium)
            androidx.compose.foundation.layout.Spacer(Modifier.width(3.dp))
            androidx.compose.material3.Text("kWh", style = MaterialTheme.typography.labelSmall, color = secondary)
        }
    }
}

// endregion
