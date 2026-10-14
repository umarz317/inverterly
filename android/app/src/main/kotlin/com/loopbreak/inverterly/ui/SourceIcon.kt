package com.loopbreak.inverterly.ui

import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material.icons.filled.Power
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/** Solar, grid, load and export as an icon, wherever a number needs naming. Same icons and colours as the iOS app. */
enum class EnergySource(val title: String, val icon: ImageVector) {
    Solar("Solar", Icons.Filled.WbSunny),
    Grid("Grid", Icons.Filled.Power),
    Load("Load", Icons.Filled.Home),
    Export("Export", Icons.Filled.NorthEast),
}

/** The sun is orange, the grid's plug blue, the house (load) in the text colour and the export arrow green. The charts keep their own orange and grey. */
@Composable
fun EnergySource.tint(): Color = when (this) {
    EnergySource.Solar -> marks.solar
    EnergySource.Grid -> marks.gridIcon
    EnergySource.Load -> MaterialTheme.colorScheme.onSurface
    EnergySource.Export -> marks.battery
}

@Composable
fun SourceIcon(source: EnergySource, size: Dp = 14.dp) {
    // The name is always printed beside the icon, so the icon itself says nothing to a screen reader.
    Icon(source.icon, contentDescription = null, modifier = Modifier.size(size), tint = source.tint())
}
