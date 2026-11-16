package dev.alethia.mobile

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.tooling.preview.Preview
import kotlin.math.min
import kotlin.math.roundToInt

@Composable
fun DashboardTopBar(
    hasUnreadNotifications: Boolean = false,
    onNotifications: () -> Unit,
    onProfile: () -> Unit,
    language: String,
    onLanguageChange: (String) -> Unit,
) {
    Surface(color = Navy950) {
        val notificationIcon = if (hasUnreadNotifications) {
            R.drawable.nav_notification_unread_pixel
        } else {
            R.drawable.nav_notification_read_pixel
        }
        val notificationBitmap = ImageBitmap.imageResource(notificationIcon)
        Row(
            modifier = Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 10.dp, vertical = 2.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                AlethiaLogo(modifier = Modifier.size(34.dp))
                Text(
                    stringResource(R.string.brand_name),
                    color = Ice,
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.2.sp,
                    fontSize = 19.sp,
                )
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                IconButton(onClick = onNotifications, modifier = Modifier.size(40.dp)) {
                    Image(
                        bitmap = notificationBitmap,
                        contentDescription = stringResource(R.string.notifications_title),
                        modifier = Modifier.size(27.dp),
                        contentScale = ContentScale.Fit,
                        filterQuality = FilterQuality.None,
                    )
                }
                IconButton(onClick = onProfile, modifier = Modifier.size(40.dp).testTag("open_profile")) {
                    Icon(painterResource(R.drawable.ic_profile), contentDescription = stringResource(R.string.profile_title), tint = Ice)
                }
                LanguageMenu(language, onLanguageChange)
            }
        }
    }
}

@Composable
fun MainBottomBar(selected: Screen, onNavigate: (Screen) -> Unit) {
    NavigationBar(containerColor = Navy950, tonalElevation = 0.dp) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 10.dp, vertical = 5.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            MainNavSideItem(
                modifier = Modifier.weight(0.8f),
                destination = Screen.Dashboard,
                selected = selected == Screen.Dashboard,
                icon = R.drawable.nav_home_pixel,
                contentDescription = R.string.tab_home,
                testTag = "main_nav_home",
                onNavigate = onNavigate,
            )
            MainFeatureSelector(
                modifier = Modifier.weight(2.5f),
                selected = selected,
                onNavigate = onNavigate,
            )
            MainNavSideItem(
                modifier = Modifier.weight(0.8f),
                destination = Screen.Achievements,
                selected = selected == Screen.Achievements,
                icon = R.drawable.nav_achievement_pixel,
                contentDescription = R.string.tab_achievements,
                testTag = "main_nav_achievements",
                onNavigate = onNavigate,
            )
        }
    }
}

private val ModuleNavSurface = Color(0xFF183B2A)
private val ModuleNavAccent = Color(0xFFA8FF62)
private val ReportNavSurface = Color(0xFF172F4B)
private val ReportNavAccent = Color(0xFF89C2FF)

@Composable
private fun MainNavSideItem(
    modifier: Modifier,
    destination: Screen,
    selected: Boolean,
    icon: Int,
    contentDescription: Int,
    testTag: String,
    onNavigate: (Screen) -> Unit,
) {
    Column(
        modifier = modifier
            .height(58.dp)
            .clip(RoundedCornerShape(14.dp))
            .selectable(selected = selected, role = Role.Tab) { onNavigate(destination) }
            .testTag(testTag)
            .padding(vertical = 5.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        val iconBitmap = ImageBitmap.imageResource(icon)
        val sourceBounds = pixelNavigationIconBounds(icon)
        val spokenLabel = stringResource(contentDescription)
        Canvas(
            Modifier.size(30.dp)
                .graphicsLayer { alpha = if (selected) 1f else 0.45f }
                .semantics { this.contentDescription = spokenLabel },
        ) {
            val scale = min(size.width / sourceBounds.width, size.height / sourceBounds.height)
            val destinationWidth = (sourceBounds.width * scale).roundToInt()
            val destinationHeight = (sourceBounds.height * scale).roundToInt()
            drawImage(
                image = iconBitmap,
                srcOffset = IntOffset(sourceBounds.x, sourceBounds.y),
                srcSize = IntSize(sourceBounds.width, sourceBounds.height),
                dstOffset = IntOffset(
                    ((size.width - destinationWidth) / 2f).roundToInt(),
                    ((size.height - destinationHeight) / 2f).roundToInt(),
                ),
                dstSize = IntSize(destinationWidth, destinationHeight),
                filterQuality = FilterQuality.None,
            )
        }
    }
}

private data class PixelNavigationIconBounds(val x: Int, val y: Int, val width: Int, val height: Int)

private fun pixelNavigationIconBounds(icon: Int): PixelNavigationIconBounds = when (icon) {
    R.drawable.nav_home_pixel -> PixelNavigationIconBounds(x = 80, y = 56, width = 352, height = 368)
    R.drawable.nav_achievement_pixel -> PixelNavigationIconBounds(x = 80, y = 40, width = 400, height = 424)
    else -> PixelNavigationIconBounds(x = 0, y = 0, width = 512, height = 512)
}

@Composable
private fun MainFeatureSelector(
    modifier: Modifier,
    selected: Screen,
    onNavigate: (Screen) -> Unit,
) {
    val moduleSelected = selected in setOf(
        Screen.Modules,
        Screen.Catalog,
        Screen.ModuleRoadmapPhishing,
        Screen.ModuleRoadmapSocialEngineering,
        Screen.ModuleRoadmapMaliciousDocument,
    )
    val reportSelected = selected == Screen.Reports
    val active = moduleSelected || reportSelected
    val tone by animateColorAsState(
        targetValue = when {
            moduleSelected -> ModuleNavSurface
            reportSelected -> ReportNavSurface
            else -> Navy900
        },
        animationSpec = tween(480, easing = FastOutSlowInEasing), label = "feature atmosphere",
    )
    val accent by animateColorAsState(
        targetValue = if (reportSelected) ReportNavAccent else ModuleNavAccent,
        animationSpec = tween(480, easing = FastOutSlowInEasing), label = "feature dial color",
    )
    val needleAngle by animateFloatAsState(
        targetValue = if (reportSelected) 30f else -30f,
        animationSpec = tween(480, easing = FastOutSlowInEasing), label = "feature needle angle",
    )
    val dialAlpha by animateFloatAsState(
        targetValue = if (active) 1f else 0.18f,
        animationSpec = tween(350), label = "feature dial visibility",
    )
    Surface(
        modifier = modifier.height(64.dp),
        color = Navy900,
        shape = RoundedCornerShape(25.dp),
        border = BorderStroke(1.dp, accent.copy(alpha = if (active) 0.28f else 0.1f)),
    ) {
        Box(Modifier.fillMaxSize().background(
            Brush.linearGradient(listOf(tone, tone.copy(alpha = 0.65f), Navy900)),
        )) {
            Canvas(Modifier.fillMaxSize()) {
                val pivot = androidx.compose.ui.geometry.Offset(size.width / 2f, size.height * 1.95f)
                val radius = size.height * 1.27f
                drawCircle(accent.copy(alpha = 0.15f * dialAlpha), radius, pivot,
                    style = Stroke(width = 6.dp.toPx()))
                val angle = Math.toRadians(needleAngle.toDouble())
                val tipX = pivot.x + (kotlin.math.sin(angle) * radius * 1.18f).toFloat()
                val tipY = pivot.y - (kotlin.math.cos(angle) * radius * 1.18f).toFloat()
                val needle = Path().apply {
                    moveTo(tipX, tipY)
                    lineTo(pivot.x - 18.dp.toPx(), pivot.y)
                    lineTo(pivot.x + 18.dp.toPx(), pivot.y)
                    close()
                }
                drawPath(needle, Ice.copy(alpha = dialAlpha))
                val shade = Path().apply {
                    moveTo(tipX, tipY)
                    lineTo(pivot.x, pivot.y)
                    lineTo(pivot.x + 18.dp.toPx(), pivot.y)
                    close()
                }
                drawPath(shade, Muted.copy(alpha = dialAlpha * 0.7f))
            }
            Row(
                Modifier.fillMaxSize().padding(horizontal = 7.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                FeaturePortrait(Screen.Modules, moduleSelected, R.drawable.nav_modules_hacker,
                    R.string.tab_modules, ModuleNavAccent, "main_nav_modules", onNavigate)
                Column(Modifier.weight(1f).padding(bottom = 8.dp),
                    horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        text = when {
                            moduleSelected -> stringResource(R.string.tab_modules)
                            reportSelected -> stringResource(R.string.tab_reports)
                            else -> stringResource(R.string.tab_modules) + " / " + stringResource(R.string.tab_reports)
                        },
                        color = Ice, fontWeight = FontWeight.Bold,
                        fontSize = if (active) 12.sp else 8.sp, maxLines = 1,
                    )
                }
                FeaturePortrait(Screen.Reports, reportSelected, R.drawable.nav_reports_detective,
                    R.string.tab_reports, ReportNavAccent, "main_nav_reports", onNavigate)
            }
        }
    }
}

@Composable
private fun FeaturePortrait(
    destination: Screen, selected: Boolean, image: Int, label: Int,
    accent: Color, tag: String, onNavigate: (Screen) -> Unit,
) {
    val emphasis by animateFloatAsState(if (selected) 1f else 0.38f,
        tween(400, easing = FastOutSlowInEasing), label = "feature portrait emphasis")
    val interactions = remember { MutableInteractionSource() }
    Box(
        Modifier.size(46.dp).clip(RoundedCornerShape(15.dp))
            .background(accent.copy(alpha = if (selected) 0.12f else 0.035f))
            .selectable(selected, interactionSource = interactions, indication = null, role = Role.Tab) {
                onNavigate(destination)
            }.testTag(tag),
        contentAlignment = Alignment.Center,
    ) {
        Image(painterResource(image), contentDescription = stringResource(label),
            modifier = Modifier.size(40.dp).graphicsLayer { alpha = emphasis },
            contentScale = ContentScale.Fit)
    }
}

@Preview(name = "Bottom navigation · Module", showBackground = true, backgroundColor = 0xFF050B14, widthDp = 390, heightDp = 96)
@Composable
fun ModuleBottomBarPreview() {
    AlethiaTheme {
        MainBottomBar(selected = Screen.Modules, onNavigate = {})
    }
}

@Preview(name = "Bottom navigation · Report", showBackground = true, backgroundColor = 0xFF050B14, widthDp = 390, heightDp = 96)
@Composable
fun ReportBottomBarPreview() {
    AlethiaTheme {
        MainBottomBar(selected = Screen.Reports, onNavigate = {})
    }
}

@Preview(name = "Bottom navigation · interactive", showBackground = true, backgroundColor = 0xFF050B14, widthDp = 390, heightDp = 96)
@Composable
fun InteractiveBottomBarPreview() {
    var selected by remember { mutableStateOf(Screen.Modules) }
    AlethiaTheme {
        MainBottomBar(selected = selected, onNavigate = { selected = it })
    }
}
