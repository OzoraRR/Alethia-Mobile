package dev.alethia.mobile

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CutCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.snapshotFlow
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ColorMatrix
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.res.imageResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.alethia.core.CourierStage
import dev.alethia.core.CourierState
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlin.math.PI
import kotlin.math.max
import kotlin.math.sin

enum class ModuleCategory(val storageKey: String) {
    Phishing("phishing"),
    SocialEngineering("social-engineering"),
    MaliciousDocument("malicious-document");

    fun next(): ModuleCategory = entries[(ordinal + 1) % entries.size]
    fun previous(): ModuleCategory = entries[(ordinal - 1 + entries.size) % entries.size]

    companion object {
        fun fromStorageKey(value: String): ModuleCategory = entries.firstOrNull { it.storageKey == value } ?: Phishing
    }
}

fun ModuleCategory.roadmapScreen(): Screen = when (this) {
    ModuleCategory.Phishing -> Screen.ModuleRoadmapPhishing
    ModuleCategory.SocialEngineering -> Screen.ModuleRoadmapSocialEngineering
    ModuleCategory.MaliciousDocument -> Screen.ModuleRoadmapMaliciousDocument
}

fun Screen.roadmapCategoryOrNull(): ModuleCategory? = when (this) {
    Screen.ModuleRoadmapPhishing -> ModuleCategory.Phishing
    Screen.ModuleRoadmapSocialEngineering -> ModuleCategory.SocialEngineering
    Screen.ModuleRoadmapMaliciousDocument -> ModuleCategory.MaliciousDocument
    else -> null
}

private data class ModuleVisual(
    val title: Int,
    val description: Int,
    val islandStill: Int,
    val roadmapStill: Int,
    val accent: Color,
    val hasTraining: Boolean,
)

private fun ModuleCategory.visual(): ModuleVisual = when (this) {
    ModuleCategory.Phishing -> ModuleVisual(
        R.string.module_phishing_title,
        R.string.module_phishing_description,
        R.drawable.module_island_phishing,
        R.drawable.module_roadmap_phishing,
        Color(0xFF9DFF50),
        hasTraining = true,
    )
    ModuleCategory.SocialEngineering -> ModuleVisual(
        R.string.social_title,
        R.string.social_description,
        R.drawable.module_island_social_engineering,
        R.drawable.module_roadmap_social_engineering,
        Color(0xFF87939B),
        hasTraining = false,
    )
    ModuleCategory.MaliciousDocument -> ModuleVisual(
        R.string.document_title,
        R.string.document_description,
        R.drawable.module_island_malicious_document,
        R.drawable.module_roadmap_malicious_document,
        Color(0xFF87939B),
        hasTraining = false,
    )
}

@Composable
fun ModuleSelectionScreen(
    selectedCategory: ModuleCategory,
    courier: CourierState,
    serverAccess: Map<String, String>? = null,
    signedIn: Boolean = false,
    onSelectCategory: (ModuleCategory) -> Unit,
    onOpenRoadmap: () -> Unit,
) {
    val visual = selectedCategory.visual()
    val isCompleted = selectedCategory == ModuleCategory.Phishing && (if (signedIn) serverAccess?.get("courier-sms") == "completed" else courier.stage == CourierStage.Complete)
    val isInProgress = selectedCategory == ModuleCategory.Phishing &&
        courier.stage != CourierStage.Briefing && courier.stage != CourierStage.Complete
    val lessonProgress = when {
        isCompleted -> 1f
        isInProgress -> (courier.stage.ordinal / 5f).coerceIn(0f, 1f)
        else -> 0f
    }
    val categories = ModuleCategory.entries
    val pager = rememberPagerState(initialPage = 15000 + selectedCategory.ordinal, pageCount = { 30000 })
    val scope = rememberCoroutineScope()
    LaunchedEffect(pager) {
        snapshotFlow { pager.settledPage }.distinctUntilChanged().collect { page ->
            onSelectCategory(categories[page % categories.size])
        }
    }
    LaunchedEffect(selectedCategory) {
        if (!pager.isScrollInProgress && categories[pager.settledPage % categories.size] != selectedCategory) {
            val delta = (selectedCategory.ordinal - pager.settledPage % categories.size + categories.size) % categories.size
            pager.animateScrollToPage(pager.settledPage + if (delta == 2) -1 else delta, animationSpec = tween(520))
        }
    }
    fun slideIsland(direction: Int) {
        if (!pager.isScrollInProgress) scope.launch {
            pager.animateScrollToPage(pager.currentPage + direction, animationSpec = tween(520, easing = androidx.compose.animation.core.FastOutSlowInEasing))
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text(
                stringResource(R.string.modules_title),
                color = Ice,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
            Text(stringResource(R.string.modules_description), color = Muted, style = MaterialTheme.typography.bodyMedium)
        }

        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            PixelTag(text = stringResource(R.string.module_category_index, selectedCategory.ordinal + 1, ModuleCategory.entries.size), accent = visual.accent)
            Text(
                stringResource(if (visual.hasTraining) R.string.module_status_active else R.string.module_locked),
                color = visual.accent,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                fontSize = 10.sp,
                letterSpacing = 1.sp,
            )
        }

        val previousLabel = stringResource(R.string.module_previous)
        val nextLabel = stringResource(R.string.module_next)

        Box(
            modifier = Modifier.fillMaxWidth()
                .heightIn(max = 330.dp)
                .aspectRatio(1f)
                .clip(androidx.compose.ui.graphics.RectangleShape),
            ) {
            HorizontalPager(
                state = pager,
                modifier = Modifier.fillMaxSize(),
                beyondViewportPageCount = 1,
                key = { it },
            ) { page ->
                val animatedCategory = categories[page % categories.size]
                val distance = kotlin.math.abs((pager.currentPage - page) + pager.currentPageOffsetFraction).coerceIn(0f, 1f)
                val item = animatedCategory.visual()
                Box(Modifier.fillMaxSize().padding(4.dp).graphicsLayer {
                    scaleX = 1f - distance * 0.09f
                    scaleY = 1f - distance * 0.09f
                    alpha = 1f - distance * 0.32f
                }, contentAlignment = Alignment.Center) {
                    ModuleArtwork(
                        stillResource = item.islandStill,
                        description = stringResource(item.title),
                        allowAnimation = true,
                        locked = !item.hasTraining,
                        accent = item.accent,
                        modifier = Modifier.fillMaxSize(),
                    )
                    if (!item.hasTraining) PixelLockBadge(accent = item.accent, modifier = Modifier.size(54.dp))
                }
            }

            IconButton(
                onClick = { slideIsland(-1) },
                modifier = Modifier.align(Alignment.CenterStart).size(48.dp)
                    .background(Navy900.copy(alpha = 0.92f), CutCornerShape(8.dp))
                    .semantics { contentDescription = previousLabel },
            ) {
                Text("‹", color = visual.accent, fontSize = 34.sp, lineHeight = 34.sp, textAlign = TextAlign.Center)
            }
            IconButton(
                onClick = { slideIsland(1) },
                modifier = Modifier.align(Alignment.CenterEnd).size(48.dp)
                    .background(Navy900.copy(alpha = 0.92f), CutCornerShape(8.dp))
                    .semantics { contentDescription = nextLabel },
            ) {
                Text("›", color = visual.accent, fontSize = 34.sp, lineHeight = 34.sp, textAlign = TextAlign.Center)
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
            Text(
                stringResource(visual.title),
                color = Ice,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
                modifier = Modifier.semantics { heading() },
            )
            Text(stringResource(visual.description), color = Muted, style = MaterialTheme.typography.bodyMedium)
        }

        if (visual.hasTraining) {
            ModuleProgressPanel(
                accent = visual.accent,
                progress = lessonProgress,
                completedCount = if (isCompleted) 1 else 0,
                totalCount = 1,
            )
        }

        PixelPrimaryButton(
            label = stringResource(R.string.module_open_roadmap),
            accent = visual.accent,
            onClick = onOpenRoadmap,
            modifier = Modifier.testTag("open_roadmap"),
        )
    }
}

@Composable
fun ModuleRoadmapScreen(
    category: ModuleCategory,
    courier: CourierState,
    serverAccess: Map<String, String>? = null,
    signedIn: Boolean = false,
    scrollState: androidx.compose.foundation.ScrollState,
    onBack: () -> Unit,
    onSaveScroll: (Int) -> Unit,
    onStartPractice: () -> Unit,
) {
    val visual = category.visual()
    var checkpointOpen by remember(category) { mutableStateOf(false) }
    val completed = category == ModuleCategory.Phishing && (if (signedIn) serverAccess?.get("courier-sms") == "completed" else courier.stage == CourierStage.Complete)
    val inProgress = category == ModuleCategory.Phishing &&
        courier.stage != CourierStage.Briefing && courier.stage != CourierStage.Complete
    val statusLabel = when {
        completed -> R.string.checkpoint_status_complete
        inProgress -> R.string.checkpoint_status_in_progress
        visual.hasTraining -> R.string.checkpoint_status_available
        else -> R.string.module_locked
    }
    val statusDescription = stringResource(statusLabel)
    val checkpointNumber = stringResource(R.string.checkpoint_number, 1)
    val checkpointTitle = stringResource(R.string.courier_title)
    val checkpointDescription = stringResource(R.string.courier_description)
    val checkpointAction = stringResource(
        when {
            completed -> R.string.checkpoint_repeat
            inProgress -> R.string.checkpoint_continue
            else -> R.string.checkpoint_start
        },
    )
    val checkpointClose = stringResource(R.string.checkpoint_close)

    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            OutlinedButton(
                onClick = { onSaveScroll(scrollState.value); onBack() },
                modifier = Modifier.heightIn(min = 48.dp),
                border = BorderStroke(1.dp, visual.accent.copy(alpha = 0.75f)),
                shape = SteppedFrameShape,
            ) { Text(stringResource(R.string.back), color = visual.accent, fontSize = 12.sp) }
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(stringResource(R.string.roadmap_title), color = Ice, fontWeight = FontWeight.Bold,
                    style = MaterialTheme.typography.titleLarge)
                Text(stringResource(visual.title), color = visual.accent, fontSize = 12.sp)
            }
        }

        if (visual.hasTraining) {
            ModuleProgressPanel(
                accent = visual.accent,
                progress = if (completed) 1f else if (inProgress) (courier.stage.ordinal / 5f).coerceIn(0f, 1f) else 0f,
                completedCount = if (completed) 1 else 0,
                totalCount = 1,
            )
        }

        BoxWithConstraints(Modifier.fillMaxWidth().aspectRatio(1.075f)) {
            val imageWidth = maxWidth
            val imageHeight = maxHeight
            ModuleFrame(accent = visual.accent, modifier = Modifier.fillMaxSize(), innerPadding = 5.dp) {
                Box(Modifier.fillMaxSize()) {
                    ModuleArtwork(
                        stillResource = visual.roadmapStill,
                        description = stringResource(visual.title),
                        allowAnimation = !checkpointOpen,
                        locked = !visual.hasTraining,
                        cropTopFraction = 0.38f,
                        activeRoadmapFromFraction = if (category == ModuleCategory.Phishing) 0.66f else null,
                        accent = visual.accent,
                        modifier = Modifier.fillMaxSize(),
                    )
                    Canvas(
                        Modifier.align(Alignment.TopCenter).fillMaxWidth().height(52.dp),
                    ) {
                        drawRect(
                            Brush.verticalGradient(
                                colors = listOf(Color(0xFF0C151D), Color(0xFF0C151D).copy(alpha = 0f)),
                                startY = 0f,
                                endY = size.height,
                            ),
                            size = size,
                        )
                    }
                    if (!visual.hasTraining) {
                        PixelLockBadge(accent = visual.accent, modifier = Modifier.align(Alignment.Center).size(58.dp))
                    }
                    if (category == ModuleCategory.Phishing) {
                        CheckpointMarker(
                            stateLabel = statusDescription,
                            completed = completed,
                            inProgress = inProgress,
                            accent = visual.accent,
                            modifier = Modifier.offset(
                                x = imageWidth * 0.405f - 26.dp,
                                y = imageHeight * 0.47f - 56.dp,
                            ),
                            onClick = { checkpointOpen = true },
                        )
                    }
                }
            }
        }

        if (visual.hasTraining) {
            ModuleFrame(accent = visual.accent, modifier = Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    PixelTag(text = checkpointNumber, accent = visual.accent)
                    PixelTag(text = statusDescription.uppercase(), accent = visual.accent)
                }
                Spacer(Modifier.height(5.dp))
                Text(stringResource(R.string.courier_title), color = Ice, fontWeight = FontWeight.Bold,
                    style = MaterialTheme.typography.titleMedium)
                Text(stringResource(R.string.courier_description), color = Muted, style = MaterialTheme.typography.bodySmall)
                OutlinedButton(
                    onClick = { checkpointOpen = true },
                    modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp).testTag("open_checkpoint"),
                    border = BorderStroke(1.dp, visual.accent), shape = SteppedFrameShape,
                ) { Text(stringResource(R.string.checkpoint_open_details), color = visual.accent) }
            }
        }
    }

    if (checkpointOpen && category == ModuleCategory.Phishing) {
        CheckpointDialog(
            numberLabel = checkpointNumber,
            statusLabel = statusDescription,
            title = checkpointTitle,
            description = checkpointDescription,
            actionLabel = checkpointAction,
            closeLabel = checkpointClose,
            inProgress = inProgress,
            progress = if (completed) 1f else if (inProgress) (courier.stage.ordinal / 5f).coerceIn(0f, 1f) else 0f,
            accent = visual.accent,
            onDismiss = { checkpointOpen = false },
            onStart = { onSaveScroll(scrollState.value); onStartPractice() },
        )
    }
}

@Composable
private fun ModuleProgressPanel(
    accent: Color,
    progress: Float,
    completedCount: Int,
    totalCount: Int,
) {
    ModuleFrame(accent = accent, modifier = Modifier.fillMaxWidth(), innerPadding = 12.dp) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.End,
        ) {
            Text(stringResource(R.string.module_progress_count, completedCount, totalCount), color = Ice,
                fontFamily = FontFamily.Monospace, fontSize = 10.sp)
        }
        Canvas(Modifier.fillMaxWidth().height(6.dp)) {
            drawRect(Color(0xFF1C2932), size = size)
            val fillWidth = size.width * progress.coerceIn(0f, 1f)
            if (fillWidth > 0f) drawRect(accent, size = Size(fillWidth, size.height))
        }
    }
}

@Composable
private fun ModuleFrame(
    accent: Color,
    modifier: Modifier = Modifier,
    innerPadding: androidx.compose.ui.unit.Dp = 16.dp,
    content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier.gameFrame(Color(0xFF2A4141)),
        color = Color(0xFF0C151D),
        shape = SteppedFrameShape,
        border = BorderStroke(1.dp, Color(0xFF2A4141)),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(innerPadding)
                .drawWithContent {
                    drawContent()
                    val line = 1.dp.toPx()
                    val inset = 7.dp.toPx()
                    drawLine(accent.copy(alpha = 0.18f), androidx.compose.ui.geometry.Offset(inset, 1.dp.toPx()),
                        androidx.compose.ui.geometry.Offset(size.width - inset, 1.dp.toPx()), line)
                },
            verticalArrangement = Arrangement.spacedBy(9.dp),
            content = content,
        )
    }
}

@Composable
private fun PixelTag(text: String, accent: Color) {
    Text(
        text = text,
        color = accent,
        fontFamily = FontFamily.Monospace,
        fontWeight = FontWeight.Bold,
        fontSize = 9.sp,
        letterSpacing = 0.8.sp,
        maxLines = 1,
    )
}

@Composable
private fun PixelPrimaryButton(label: String, accent: Color, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Button(
        onClick = onClick,
        modifier = modifier.fillMaxWidth().heightIn(min = 52.dp),
        shape = SteppedFrameShape,
        colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF83AE39), contentColor = Navy950),
    ) {
        Text(label, fontFamily = FontFamily(Font(R.font.quest_pixel)), fontSize = 10.sp, letterSpacing = 1.sp)
    }
}

@Composable
private fun CheckpointMarker(
    stateLabel: String,
    completed: Boolean,
    inProgress: Boolean,
    accent: Color,
    modifier: Modifier,
    onClick: () -> Unit,
) {
    val markerLabel = stringResource(R.string.checkpoint_accessibility, 1, stringResource(R.string.courier_title), stateLabel)
    val transition = rememberInfiniteTransition(label = "checkpoint pin")
    val lift by transition.animateFloat(
        initialValue = -2f,
        targetValue = 2f,
        animationSpec = infiniteRepeatable(tween(850, easing = androidx.compose.animation.core.FastOutSlowInEasing), RepeatMode.Reverse),
        label = "checkpoint pin bob",
    )
    Box(
        modifier = modifier.size(width = 52.dp, height = 56.dp)
            .graphicsLayer { translationY = lift.dp.toPx() }
            .clickable(role = Role.Button, onClick = onClick).semantics {
            contentDescription = markerLabel
            stateDescription = stateLabel
        },
    ) {
        Canvas(Modifier.align(Alignment.Center).size(width = 34.dp, height = 44.dp)) {
            // More contour steps keep the pixel silhouette readable at this small size.
            val shape = listOf(
                "00011111000", "00111111100", "01111111110", "11100000111",
                "11100000111", "11100000111", "11100000111", "01110001110",
                "01111111110", "00111111100", "00011111000", "00001110000", "00000100000",
            )
            val unit = minOf(size.width / 11f, size.height / 13f)
            val ox = (size.width - unit * 11f) / 2f
            shape.forEachIndexed { row, line -> line.forEachIndexed { column, pixel ->
                if (pixel == '1') {
                    val shade = when {
                        column <= 2 || row <= 1 -> Color(0xFFC5F780)
                        column >= 8 -> Color(0xFF456D2D)
                        row >= 9 -> Color(0xFF6D9D35)
                        else -> accent
                    }
                    drawRect(Color(0xFF08130E), Offset(ox + column * unit, row * unit + unit), Size(unit, unit))
                    drawRect(shade, Offset(ox + column * unit, row * unit), Size(unit, unit))
                }
            } }

        }
    }
}

@Composable
private fun PixelLockBadge(accent: Color, modifier: Modifier = Modifier) {
    Surface(
        modifier = modifier,
        shape = SteppedFrameShape,
        color = Color(0xE6111C23),
        border = BorderStroke(1.dp, accent.copy(alpha = 0.72f)),
    ) {
        Canvas(Modifier.fillMaxSize().padding(9.dp)) {
            val cell = size.minDimension / 16f
            val rows = listOf(
                "0000011111100000", "0001111111111000", "0011222222221100", "0011220000221100",
                "0011220000221100", "0011220000221100", "0111111111111110", "1122222222222211",
                "1122333333332211", "1122330003332411", "1122330003332211", "1122333033332211",
                "1122333033332211", "1122333333332211", "0111111111111110", "0022222222222200",
            )
            rows.forEachIndexed { row, line -> line.forEachIndexed { column, pixel ->
                val shade = when (pixel) {
                    '1' -> Color(0xFF101A20)
                    '2' -> Color(0xFF66767C)
                    '3' -> Color(0xFF9DAAB0)
                    '4' -> Color(0xFFE9F4D7)
                    else -> null
                }
                if (shade != null) drawRect(shade, Offset(column * cell, row * cell), Size(cell, cell))
            } }

        }
    }
}

@Composable
private fun CheckpointDialog(
    numberLabel: String,
    statusLabel: String,
    title: String,
    description: String,
    actionLabel: String,
    closeLabel: String,
    inProgress: Boolean,
    progress: Float,
    accent: Color,
    onDismiss: () -> Unit,
    onStart: () -> Unit,
) {
    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        ModuleFrame(
            accent = accent,
            modifier = Modifier.fillMaxWidth().widthIn(max = 390.dp).padding(horizontal = 22.dp),
            innerPadding = 22.dp,
        ) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()) {
                PixelTag(text = numberLabel, accent = accent)
                PixelTag(text = statusLabel.uppercase(), accent = accent)
            }
            Text(title, color = Ice, fontWeight = FontWeight.Bold,
                style = MaterialTheme.typography.headlineSmall)
            Text(description, color = Muted, style = MaterialTheme.typography.bodyMedium)
            if (inProgress) {
                LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth(), color = accent,
                    trackColor = Color(0xFF1C2932))
            }
            Button(
                onClick = onStart,
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag("start_checkpoint"),
                shape = SteppedFrameShape,
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF83AE39), contentColor = Navy950),
            ) {
                Text(actionLabel, fontFamily = FontFamily(Font(R.font.quest_pixel)), fontSize = 10.sp)
            }
            OutlinedButton(onClick = onDismiss, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                border = BorderStroke(1.dp, accent.copy(alpha = 0.65f)), shape = SteppedFrameShape) {
                Text(closeLabel, color = Muted)
            }
        }
    }
}

@Composable
private fun ModuleArtwork(
    stillResource: Int,
    description: String,
    allowAnimation: Boolean,
    locked: Boolean = false,
    cropTopFraction: Float = 0f,
    activeRoadmapFromFraction: Float? = null,
    accent: Color = Color(0xFF9DFF50),
    modifier: Modifier = Modifier,
) {
    val image = ImageBitmap.imageResource(stillResource)
    val phase = rememberArtworkPhase(allowAnimation)
    val grayFilter = remember { ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(0f) }) }
    Canvas(modifier.semantics { contentDescription = description }) {
        val sourceTop = (image.height * cropTopFraction.coerceIn(0f, 0.9f)).toInt()
        val sourceWidth = image.width
        val sourceHeight = image.height - sourceTop
        val scale = max(size.width / sourceWidth, size.height / sourceHeight)
        val destinationWidth = (sourceWidth * scale).toInt()
        val destinationHeight = (sourceHeight * scale).toInt()
        val bobPx = if (allowAnimation) sin(phase * 2f * PI).toFloat() * 2.2.dp.toPx() else 0f
        val destinationLeft = ((size.width - destinationWidth) / 2f).toInt()
        val destinationTop = ((size.height - destinationHeight) / 2f + bobPx).toInt()
        val grayscaleBase = locked || activeRoadmapFromFraction != null
        drawImage(
            image = image,
            srcOffset = IntOffset(0, sourceTop),
            srcSize = IntSize(sourceWidth, sourceHeight),
            dstOffset = IntOffset(destinationLeft, destinationTop),
            dstSize = IntSize(destinationWidth, destinationHeight),
            alpha = if (locked || activeRoadmapFromFraction != null) 0.68f else 1f,
            colorFilter = if (grayscaleBase) grayFilter else null,
            filterQuality = FilterQuality.None,
        )
        if (locked) drawRect(Color(0xFF061018).copy(alpha = 0.18f), size = size)
        activeRoadmapFromFraction?.let { activeFraction ->
            // Blend saturation and brightness over a broad band, preserving the original alpha.
            val band = image.height * 0.10f
            val center = image.height * activeFraction
            val first = maxOf(sourceTop, (center - band).toInt())
            var y = first
            while (y < image.height) {
                val height = minOf(4, image.height - y)
                val t = ((y - (center - band)) / (band * 2f)).coerceIn(0f, 1f)
                val smooth = t * t * (3f - 2f * t)
                drawImage(
                    image = image,
                    srcOffset = IntOffset(0, y), srcSize = IntSize(sourceWidth, height),
                    dstOffset = IntOffset(destinationLeft, destinationTop + ((y - sourceTop) * scale).toInt()),
                    dstSize = IntSize(destinationWidth, maxOf(1, kotlin.math.ceil(height * scale).toInt())),
                    alpha = 0.68f + smooth * 0.32f,
                    colorFilter = ColorFilter.colorMatrix(ColorMatrix().apply { setToSaturation(smooth) }),
                    filterQuality = FilterQuality.None,
                )
                y += height
            }
        }

    }
    if (allowAnimation) {
        val debrisClock = rememberDebrisClock()
        val fragments = remember(stillResource, cropTopFraction) {
            buildIslandFragments(roadmap = cropTopFraction > 0f)
        }
        Canvas(Modifier.fillMaxSize()) {
            fragments.forEach { rock ->
                val cycle = (debrisClock * rock.cycles + rock.phase) % 1f
                // Each emitter rests between releases; particles accelerate instead of drifting in a row.
                if (cycle < rock.activeFraction) {
                    val age = cycle / rock.activeFraction
                    val sourceY = rock.y + rock.travel * (0.16f * age + 0.84f * age * age)
                    val normalizedY = (sourceY - cropTopFraction) / (1f - cropTopFraction)
                    if (normalizedY in 0.02f..0.97f) {
                        val x = size.width * (rock.x + rock.drift * age + sin(age * PI).toFloat() * rock.sway)
                        val y = size.height * normalizedY
                        val appear = (age / 0.09f).coerceIn(0f, 1f)
                        val disappear = ((1f - age) / 0.32f).coerceIn(0f, 1f)
                        val alpha = minOf(appear, disappear) * rock.opacity
                        val colored = !locked && (activeRoadmapFromFraction == null || sourceY > activeRoadmapFromFraction)
                        val tint = if (colored) Color(0xFF758674) else Color(0xFF717C82)
                        rotate(rock.angle + rock.spin * age, Offset(x, y)) {
                            drawRockFragment(Offset(x, y), rock.width.dp.toPx(), rock.height.dp.toPx(), rock.depth, tint, alpha)
                        }
                    }
                }
            }
        }
    }
}

private data class IslandFragment(
    val x: Float, val y: Float, val width: Float, val height: Float, val depth: Float,
    val phase: Float, val cycles: Int, val activeFraction: Float, val travel: Float,
    val drift: Float, val sway: Float, val angle: Float, val spin: Float, val opacity: Float,
)

private fun buildIslandFragments(roadmap: Boolean): List<IslandFragment> = List(if (roadmap) 24 else 20) { index ->
    // Stable variation: no new random positions on recomposition or animation frames.
    val seed = ((index * 73 + 29) % 101) / 100f
    val side = if (index % 2 == 0) -1f else 1f
    val x = 0.23f + ((index * 37 + 11) % 100) / 100f * 0.54f
    val layer = index % 3
    val y = if (roadmap) {
        listOf(0.49f, 0.63f, 0.79f)[layer] + seed * 0.025f
    } else {
        // Emit beneath the sloping rock silhouette, including the deeper central underside.
        0.60f + (1f - kotlin.math.abs(x - 0.5f) / 0.28f).coerceIn(0f, 1f) * 0.15f + seed * 0.025f
    }
    IslandFragment(
        x = x, y = y,
        width = 1.8f + seed * 4.3f,
        height = 2.2f + ((index * 19) % 11) / 10f * 5.1f,
        depth = 0.25f + ((index * 13) % 9) / 8f * 0.48f,
        phase = ((index * 43) % 97) / 97f,
        cycles = listOf(3, 4, 6, 9)[index % 4],
        activeFraction = 0.44f + seed * 0.31f,
        travel = if (roadmap) 0.055f + seed * 0.035f else 0.10f + seed * 0.09f,
        drift = side * (0.008f + seed * 0.024f), sway = side * 0.006f,
        angle = side * seed * 24f, spin = side * (12f + seed * 48f),
        opacity = 0.40f + seed * 0.40f,
    )
}

private fun DrawScope.drawRockFragment(origin: Offset, width: Float, height: Float, depth: Float, tint: Color, alpha: Float) {
    val x = origin.x
    val y = origin.y
    val d = width * depth
    fun facet(points: List<Offset>, color: Color) {
        drawPath(Path().apply {
            moveTo(points.first().x, points.first().y)
            points.drop(1).forEach { lineTo(it.x, it.y) }
            close()
        }, color.copy(alpha = alpha))
    }
    // Uneven front and chipped corners avoid the identical cube silhouette.
    facet(listOf(Offset(x, y), Offset(x + width * 0.77f, y), Offset(x + width, y + height * 0.24f),
        Offset(x + width * 0.82f, y + height), Offset(x + width * 0.16f, y + height * 0.88f), Offset(x, y + height * 0.61f)), tint)
    facet(listOf(Offset(x, y), Offset(x + d, y - d * 0.65f), Offset(x + width + d * 0.6f, y - d * 0.44f),
        Offset(x + width * 0.77f, y)), Color(tint.red * 1.22f, tint.green * 1.20f, tint.blue * 1.18f))
    facet(listOf(Offset(x + width * 0.77f, y), Offset(x + width + d * 0.6f, y - d * 0.44f),
        Offset(x + width + d * 0.48f, y + height * 0.72f), Offset(x + width * 0.82f, y + height),
        Offset(x + width, y + height * 0.24f)), Color(tint.red * 0.52f, tint.green * 0.57f, tint.blue * 0.58f))
}

@Composable
private fun rememberDebrisClock(): Float {
    val transition = rememberInfiniteTransition(label = "island debris")
    val clock by transition.animateFloat(
        initialValue = 0f, targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(21600, easing = LinearEasing)),
        label = "independent fragment lifetimes",
    )
    return clock
}

@Composable
private fun rememberArtworkPhase(enabled: Boolean): Float {
    if (!enabled) return 0f
    val transition = rememberInfiniteTransition(label = "module artwork")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(3600, easing = LinearEasing), RepeatMode.Restart),
        label = "module artwork phase",
    )
    return phase
}
