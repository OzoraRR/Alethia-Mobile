package dev.alethia.mobile

import android.graphics.BitmapFactory
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.ui.res.imageResource
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CutCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.ProgressBarRangeInfo
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.compose.ui.zIndex
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

private val QuestFrameBorder = Color(0xFF2A4141)
private val QuestFrameInsetBorder = Color(0xFF1D3037)
private val ContinueProgressBlue = Color(0xFF5E829F)

private val QuestPixelFont = FontFamily(Font(R.font.quest_pixel))
private val QuestLime = Color(0xFF83AE39)

internal object SteppedFrameShape : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val step = with(density) { 4.dp.toPx() }
        return Outline.Generic(Path().apply {
            moveTo(step, 0f)
            lineTo(size.width - step, 0f)
            lineTo(size.width - step, step)
            lineTo(size.width, step)
            lineTo(size.width, size.height - step)
            lineTo(size.width - step, size.height - step)
            lineTo(size.width - step, size.height)
            lineTo(step, size.height)
            lineTo(step, size.height - step)
            lineTo(0f, size.height - step)
            lineTo(0f, step)
            lineTo(step, step)
            close()
        })
    }
}

internal fun Modifier.gameFrame(accent: Color = QuestFrameBorder, strength: Float = 1f): Modifier = drawWithContent {
    drawContent()
    val inset = 4.dp.toPx()
    val rail = 2.dp.toPx()
    val start = 12.dp.toPx()
    drawLine(accent.copy(alpha = 0.65f * strength), Offset(start, inset), Offset(size.width - start, inset), rail)
    drawLine(accent.copy(alpha = 0.45f * strength), Offset(start, size.height - inset), Offset(size.width - start, size.height - inset), rail)
    drawLine(accent.copy(alpha = 0.7f * strength), Offset(inset, start), Offset(inset, size.height - start), rail)
    drawLine(accent.copy(alpha = 0.4f * strength), Offset(size.width - inset, start), Offset(size.width - inset, size.height - start), rail)
}

private fun Modifier.dashboardCornerFrame(): Modifier = drawWithContent {
    drawContent()
    val arm = 12.dp.toPx()
    val inset = 4.dp.toPx()
    val stroke = 1.dp.toPx()
    val tint = Color(0xFF38514B)
    for (right in listOf(false, true)) for (bottom in listOf(false, true)) {
        val x = if (right) size.width - inset else inset
        val y = if (bottom) size.height - inset else inset
        drawLine(tint, Offset(x, y), Offset(x + if (right) -arm else arm, y), stroke)
        drawLine(tint, Offset(x, y), Offset(x, y + if (bottom) -arm else arm), stroke)
    }
}

@Composable
fun DashboardScreen(
    state: DashboardUiState,
    onAcceptQuest: (DashboardQuestState) -> Unit,
    onClaimQuest: (DashboardQuestState) -> Unit,
    continueModuleProgress: Float? = null,
    onContinueModule: () -> Unit = {},
    onOpenReports: () -> Unit = {},
) {
    var selectedQuestIndex by remember { mutableIntStateOf(-1) }
    var preferredQuestKind by remember(state.featuredQuestKind) { mutableStateOf(state.featuredQuestKind) }
    val preferredIndex = state.quests.indexOfFirst { it.kind == preferredQuestKind && !it.claimed }
    val featuredQuestIndex = preferredIndex.takeIf { it >= 0 } ?: state.quests.indexOfFirst { !it.claimed }
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween) {
                Text(
                    stringResource(R.string.tab_home), color = Signal,
                    fontFamily = FontFamily.Monospace, fontWeight = FontWeight.Bold,
                    fontSize = 11.sp, letterSpacing = 1.2.sp,
                )
                if (state.isPreview) {
                    val previewDescription = stringResource(R.string.dashboard_preview_banner)
                    Text(
                        stringResource(R.string.dashboard_preview_short),
                        color = Muted, fontSize = 10.sp, lineHeight = 14.sp,
                        modifier = Modifier.semantics { contentDescription = previewDescription }
                            .background(Color(0xFF16232A), SteppedFrameShape)
                            .padding(horizontal = 8.dp, vertical = 5.dp),
                    )
                }
            }
            Text(
                stringResource(R.string.dashboard_greeting, state.displayName),
                color = Ice,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
            Text(stringResource(R.string.dashboard_subtitle), color = Muted, fontSize = 14.sp, lineHeight = 21.sp)
        }

        StreakExpCard(
            streakDays = state.streakDays,
            points = state.points,
            pointsForNextLevel = state.pointsForNextLevel,
        )

        Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
            state.quests.getOrNull(featuredQuestIndex)?.let { quest ->
                QuestSummaryCard(quest) {
                    preferredQuestKind = quest.kind
                    selectedQuestIndex = featuredQuestIndex
                }
            }
            ReportSummaryCard(summary = state.reportSummary, onClick = onOpenReports)
            continueModuleProgress?.let { progress ->
                ContinueLearningSection(progress = progress, onClick = onContinueModule)
            }
        }
    }

    state.quests.getOrNull(selectedQuestIndex)?.let { quest ->
        DailyQuestDialog(
            quest = quest,
            index = selectedQuestIndex,
            questCount = state.quests.size,
            onDismiss = { selectedQuestIndex = -1 },
            onPrevious = {
                selectedQuestIndex = (selectedQuestIndex - 1 + state.quests.size) % state.quests.size
                preferredQuestKind = state.quests[selectedQuestIndex].kind
            },
            onNext = {
                selectedQuestIndex = (selectedQuestIndex + 1) % state.quests.size
                preferredQuestKind = state.quests[selectedQuestIndex].kind
            },
            onAccept = { onAcceptQuest(quest) },
            onClaim = { onClaimQuest(quest) },
        )
    }
}

@Composable
private fun ReportSummaryCard(summary: DashboardReportSummary?, onClick: () -> Unit) {
    val label = stringResource(R.string.dashboard_reports_open)
    Surface(
        modifier = Modifier.fillMaxWidth().dashboardCornerFrame()
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = label },
        shape = SteppedFrameShape,
        color = Navy900,
        border = BorderStroke(1.dp, QuestFrameBorder.copy(alpha = 0.72f)),
    ) {
        Column(Modifier.padding(horizontal = 16.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween) {
                Text(stringResource(R.string.dashboard_reports_title), color = QuestLime,
                    fontFamily = QuestPixelFont, fontSize = 8.sp, letterSpacing = 0.6.sp)
                Box(Modifier.size(28.dp).background(Color(0xFF17272F), SteppedFrameShape), contentAlignment = Alignment.Center) {
                    Text("↗", color = Color(0xFF9AB6C4), fontSize = 18.sp)
                }
            }
            if (summary == null) {
                Text(stringResource(R.string.dashboard_reports_unavailable), color = Muted,
                    style = MaterialTheme.typography.bodySmall)
            } else {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Column(Modifier.weight(0.88f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(7.dp)) {
                        Text(summary.uploaded.coerceAtLeast(0).toString(), color = Ice,
                            fontSize = 28.sp, lineHeight = 32.sp, fontWeight = FontWeight.Bold)
                        Text(stringResource(R.string.dashboard_reports_total_short), color = Muted,
                            style = MaterialTheme.typography.labelSmall)
                    }
                    Box(Modifier.width(1.dp).height(36.dp).background(QuestFrameBorder))
                    ReportStatusCount(summary.verified, R.string.dashboard_reports_verified, QuestLime,
                        pending = false, modifier = Modifier.weight(1f))
                    Box(Modifier.width(1.dp).height(36.dp).background(QuestFrameBorder))
                    ReportStatusCount(summary.pending, R.string.dashboard_reports_pending, Color(0xFFD1B372),
                        pending = true, modifier = Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun ReportStatusCount(count: Int, label: Int, tint: Color, pending: Boolean, modifier: Modifier) {
    Column(
        modifier.padding(vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(7.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
            Canvas(Modifier.size(20.dp)) {
                val pixels = if (pending) ReportClockPixels else ReportShieldPixels
                val cell = kotlin.math.floor(size.minDimension / 16f).coerceAtLeast(1f)
                val left = kotlin.math.floor((size.width - cell * 16f) / 2f)
                val top = kotlin.math.floor((size.height - cell * 16f) / 2f)
                pixels.forEachIndexed { y, row ->
                    row.forEachIndexed { x, pixel ->
                        if (pixel == '#') drawRect(
                            color = tint,
                            topLeft = Offset(left + x * cell, top + y * cell),
                            size = Size(cell, cell),
                        )
                    }
                }
            }
            Text(count.coerceAtLeast(0).toString(), color = tint, fontWeight = FontWeight.Bold,
                fontSize = 24.sp, lineHeight = 32.sp)
        }
        Text(stringResource(label), color = Muted, style = MaterialTheme.typography.labelSmall,
            textAlign = TextAlign.Center)
    }
}

// Sixteen-pixel silhouettes use filled cells so edges remain crisp at small sizes.
private val ReportShieldPixels = listOf(
    ".......##.......",
    ".....######.....",
    "...####..####...",
    ".####......####.",
    ".##..........##.",
    ".##..........##.",
    ".##.......##.##.",
    ".##......##..##.",
    "..##.##.##..##..",
    "..##..###...##..",
    "...##..#...##...",
    "...##......##...",
    "....##....##....",
    ".....##..##.....",
    "......####......",
    ".......##.......",
)

private val ReportClockPixels = listOf(
    ".....######.....",
    "...##########...",
    "..###......###..",
    ".##..........##.",
    ".##....##....##.",
    "##.....##.....##",
    "##.....##.....##",
    "##.....##.....##",
    "##.....###....##",
    "##......###...##",
    "##.......##...##",
    ".##..........##.",
    ".##..........##.",
    "..###......###..",
    "...##########...",
    ".....######.....",
)

private data class DailyQuestCopy(
    val title: Int,
    val subtitle: Int,
    val description: Int,
    val objectives: List<Int>,
)

private fun DashboardQuestKind.questCopy(): DailyQuestCopy = when (this) {
    DashboardQuestKind.DailyLogin -> DailyQuestCopy(
        R.string.quest_phishing_title,
        R.string.quest_phishing_subtitle,
        R.string.quest_phishing_description,
        listOf(R.string.quest_phishing_objective_one, R.string.quest_phishing_objective_two),
    )
    DashboardQuestKind.CompleteModule -> DailyQuestCopy(
        R.string.quest_digital_title,
        R.string.quest_digital_subtitle,
        R.string.quest_digital_description,
        listOf(R.string.quest_digital_objective_one, R.string.quest_digital_objective_two),
    )
    DashboardQuestKind.SubmitReport -> DailyQuestCopy(
        R.string.quest_impersonation_title,
        R.string.quest_impersonation_subtitle,
        R.string.quest_impersonation_description,
        listOf(R.string.quest_impersonation_objective_one, R.string.quest_impersonation_objective_two),
    )
}

@Preview(name = "Dashboard · sample state", showBackground = true, backgroundColor = 0xFF050B14, widthDp = 390, heightDp = 844)
@Composable
fun DashboardScreenPreview() {
    AlethiaTheme {
        Surface(modifier = Modifier.fillMaxSize(), color = Navy950) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp, vertical = 20.dp),
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                DashboardScreen(
                    state = DashboardUiState.preview(),
                    onAcceptQuest = {},
                    onClaimQuest = {},
                    continueModuleProgress = 0.4f,
                )
            }
        }
    }
}

private data class StreakAnimationSpec(
    val assetPath: String,
    val columns: Int,
    val frameCount: Int,
)

private fun streakAnimationSpec(streakDays: Int): StreakAnimationSpec = when (streakDays.coerceAtLeast(0)) {
    in 0..6 -> StreakAnimationSpec("streak/streak-01-basic-sheet.webp", columns = 10, frameCount = 60)
    in 7..13 -> StreakAnimationSpec("streak/streak-02-evolution-1-sheet.webp", columns = 11, frameCount = 66)
    in 14..20 -> StreakAnimationSpec("streak/streak-03-evolution-2-sheet.webp", columns = 12, frameCount = 72)
    else -> StreakAnimationSpec("streak/streak-04-final-evolution-sheet.webp", columns = 12, frameCount = 96)
}

@Composable
private fun StreakExpCard(streakDays: Int, points: Int, pointsForNextLevel: Int) {
    val safePoints = points.coerceAtLeast(0)
    val safeTarget = pointsForNextLevel.coerceAtLeast(1)
    val progress = (safePoints.toFloat() / safeTarget).coerceIn(0f, 1f)

    Surface(
        color = Navy900,
        shape = SteppedFrameShape,
        border = BorderStroke(1.dp, QuestFrameBorder.copy(alpha = 0.85f)),
        modifier = Modifier.fillMaxWidth().dashboardCornerFrame(),
    ) {
        Column(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                modifier = Modifier.height(48.dp),
            ) {
                StreakCharacter(streakAnimationSpec(streakDays), Modifier.size(48.dp))
                Text(
                    text = stringResource(R.string.dashboard_streak_value, streakDays.coerceAtLeast(0)),
                    color = Ice,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    stringResource(R.string.dashboard_exp_title),
                    color = Muted,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                )
                Text(
                    stringResource(R.string.dashboard_exp_progress_value, safePoints, safeTarget),
                    color = Ice,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = FontFamily.Monospace,
                )
            }

            PixelExpProgressBar(
                progress = progress,
                progressDescription = stringResource(R.string.dashboard_exp_progress_description, safePoints, safeTarget),
            )
        }
    }
}

@Composable
private fun StreakCharacter(spec: StreakAnimationSpec, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    val spriteSheet by produceState<ImageBitmap?>(initialValue = null, key1 = spec.assetPath) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                context.assets.open(spec.assetPath).use { stream ->
                    BitmapFactory.decodeStream(stream)?.asImageBitmap()
                }
            }.getOrNull()
        }
    }
    val frameIndex = remember(spec.assetPath) { mutableIntStateOf(0) }

    LaunchedEffect(spec.assetPath, spec.frameCount) {
        frameIndex.intValue = 0
        while (isActive) {
            delay(42L)
            frameIndex.intValue = (frameIndex.intValue + 1) % spec.frameCount
        }
    }

    val image = spriteSheet
    if (image != null) {
        Canvas(modifier) {
            val frameSize = 192
            val sourceX = (frameIndex.intValue % spec.columns) * frameSize
            val sourceY = (frameIndex.intValue / spec.columns) * frameSize
            drawImage(
                image = image,
                srcOffset = IntOffset(sourceX, sourceY),
                srcSize = IntSize(frameSize, frameSize),
                dstOffset = IntOffset.Zero,
                dstSize = IntSize(size.width.toInt(), size.height.toInt()),
                filterQuality = FilterQuality.None,
            )
        }
    } else {
        Spacer(modifier)
    }
}

private const val EXP_BAR_ASSET = "exp-bar-horizontal.webp"
private const val EXP_BAR_CROP_X = 24
private const val EXP_BAR_CROP_Y = 46
private const val EXP_BAR_CROP_WIDTH = 976
private const val EXP_BAR_CROP_HEIGHT = 164
private const val EXP_BAR_WIDTH_FRACTION = 0.96f
private const val EXP_BAR_DISPLAY_ASPECT_RATIO = 11f
private const val EXP_BAR_SEGMENT_COUNT = 12
private const val EXP_BAR_SEGMENT_START_X = 80
private const val EXP_BAR_SEGMENT_STEP_X = 72
private const val EXP_BAR_SEGMENT_Y = 96
private const val EXP_BAR_SEGMENT_SIZE = 64
private const val EXP_BAR_EMPTY_SAMPLE_X = 584

@Composable
private fun PixelExpProgressBar(progress: Float, progressDescription: String) {
    val context = LocalContext.current
    val artwork by produceState<ImageBitmap?>(initialValue = null, key1 = EXP_BAR_ASSET) {
        value = withContext(Dispatchers.IO) {
            runCatching {
                context.assets.open(EXP_BAR_ASSET).use { stream ->
                    BitmapFactory.decodeStream(stream)?.asImageBitmap()
                }
            }.getOrNull()
        }
    }
    val animatedProgress by animateFloatAsState(
        targetValue = progress,
        animationSpec = tween(durationMillis = 850, easing = FastOutSlowInEasing),
        label = "exp-progress",
    )

    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
        Canvas(
            modifier = Modifier
                .fillMaxWidth(EXP_BAR_WIDTH_FRACTION)
                .aspectRatio(EXP_BAR_DISPLAY_ASPECT_RATIO)
                .semantics {
                    contentDescription = progressDescription
                    progressBarRangeInfo = ProgressBarRangeInfo(animatedProgress, 0f..1f)
                },
        ) {
        val image = artwork ?: return@Canvas
        val destinationSize = IntSize(size.width.roundToInt(), size.height.roundToInt())
        drawImage(
            image = image,
            srcOffset = IntOffset(EXP_BAR_CROP_X, EXP_BAR_CROP_Y),
            srcSize = IntSize(EXP_BAR_CROP_WIDTH, EXP_BAR_CROP_HEIGHT),
            dstOffset = IntOffset.Zero,
            dstSize = destinationSize,
            filterQuality = FilterQuality.None,
        )

        val scaleX = size.width / EXP_BAR_CROP_WIDTH
        val scaleY = size.height / EXP_BAR_CROP_HEIGHT
        val progressInSegments = animatedProgress.coerceIn(0f, 1f) * EXP_BAR_SEGMENT_COUNT
        for (index in 0 until EXP_BAR_SEGMENT_COUNT) {
            val sourceX = EXP_BAR_SEGMENT_START_X + index * EXP_BAR_SEGMENT_STEP_X
            val destinationLeft = ((sourceX - EXP_BAR_CROP_X) * scaleX).roundToInt()
            val destinationRight = ((sourceX + EXP_BAR_SEGMENT_SIZE - EXP_BAR_CROP_X) * scaleX).roundToInt()
            val destinationTop = ((EXP_BAR_SEGMENT_Y - EXP_BAR_CROP_Y) * scaleY).roundToInt()
            val destinationBottom = ((EXP_BAR_SEGMENT_Y + EXP_BAR_SEGMENT_SIZE - EXP_BAR_CROP_Y) * scaleY).roundToInt()
            val cellSize = IntSize(destinationRight - destinationLeft, destinationBottom - destinationTop)
            val cellOffset = IntOffset(destinationLeft, destinationTop)

            drawImage(
                image = image,
                srcOffset = IntOffset(EXP_BAR_EMPTY_SAMPLE_X, EXP_BAR_SEGMENT_Y),
                srcSize = IntSize(EXP_BAR_SEGMENT_SIZE, EXP_BAR_SEGMENT_SIZE),
                dstOffset = cellOffset,
                dstSize = cellSize,
                filterQuality = FilterQuality.None,
            )

            val segmentFill = (progressInSegments - index).coerceIn(0f, 1f)
            if (segmentFill > 0f) {
                val sourceFillWidth = (EXP_BAR_SEGMENT_SIZE * segmentFill).roundToInt()
                    .coerceIn(1, EXP_BAR_SEGMENT_SIZE)
                val destinationFillWidth = (cellSize.width * segmentFill).roundToInt()
                if (destinationFillWidth > 0) {
                    drawImage(
                        image = image,
                        srcOffset = IntOffset(EXP_BAR_SEGMENT_START_X, EXP_BAR_SEGMENT_Y),
                        srcSize = IntSize(sourceFillWidth, EXP_BAR_SEGMENT_SIZE),
                        dstOffset = cellOffset,
                        dstSize = IntSize(destinationFillWidth, cellSize.height),
                        filterQuality = FilterQuality.None,
                    )
                }
            }
        }
        }
    }
}

@Composable
private fun QuestSummaryCard(quest: DashboardQuestState, onClick: () -> Unit) {
    val copy = quest.kind.questCopy()
    val openDescription = stringResource(R.string.quest_open_accessibility, stringResource(copy.title))
    Surface(
        color = Color.Transparent,
        shape = SteppedFrameShape,
        border = BorderStroke(1.dp, Color(0xFF40563E)),
        modifier = Modifier
            .fillMaxWidth()
            .gameFrame(accent = Color(0xFF40563E), strength = 0.85f)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = openDescription },
    ) {
        Row(
            modifier = Modifier
                .height(IntrinsicSize.Min)
                .heightIn(min = 104.dp)
                .background(Brush.horizontalGradient(listOf(Color(0xFF17271F), Color(0xFF18212B))))
                .clip(SteppedFrameShape),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier.width(64.dp).fillMaxHeight()
                    .background(Brush.verticalGradient(listOf(Color(0xFF263E2A), Color(0xFF15281E))))
                    .drawWithContent {
                        drawContent()
                        drawRect(QuestLime, size = Size(3.dp.toPx(), size.height))
                        drawLine(Color(0xFF40563E), Offset(size.width, 10.dp.toPx()),
                            Offset(size.width, size.height - 10.dp.toPx()), 1.dp.toPx())
                    },
                contentAlignment = Alignment.Center,
            ) {
                QuestArtwork(quest.kind, Modifier.size(44.dp))
            }
            Column(
                modifier = Modifier
                    .weight(1f)
                    .padding(horizontal = 12.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    stringResource(R.string.quest_daily_label),
                    color = QuestLime,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = QuestPixelFont,
                    fontSize = 8.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.6.sp,
                )
                Text(
                    quest.title ?: stringResource(copy.title),
                    color = Ice,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    if (quest.rewardCredits > 0) stringResource(R.string.quest_compact_reward, quest.rewardPoints, quest.rewardCredits) else stringResource(R.string.backend_exp_reward, quest.rewardPoints),
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Box(
                Modifier.padding(end = 12.dp).size(36.dp)
                    .background(Color(0xFF26372C), SteppedFrameShape),
                contentAlignment = Alignment.Center,
            ) {
                ExpandCorners(Modifier.size(16.dp))
            }
        }
    }
}

@Composable
private fun DailyQuestDialog(
    quest: DashboardQuestState,
    index: Int,
    questCount: Int,
    onDismiss: () -> Unit,
    onPrevious: () -> Unit,
    onNext: () -> Unit,
    onAccept: () -> Unit,
    onClaim: () -> Unit,
) {
    val copy = quest.kind.questCopy()
    val closeDescription = stringResource(R.string.close_quest)
    val localizedContext = LocalContext.current
    val isComplete = quest.progress >= quest.target
    val canClaim = quest.accepted && isComplete && !quest.claimed
    val buttonLabel = when {
        quest.claimed -> R.string.quest_reward_claimed
        canClaim -> R.string.quest_claim_reward
        quest.accepted -> R.string.quest_accepted
        else -> R.string.quest_accept
    }
    val noteLabel = when {
        quest.claimed -> R.string.quest_claimed_note
        canClaim -> R.string.quest_ready_note
        quest.accepted -> R.string.quest_accepted_note
        else -> R.string.quest_accept_note
    }
    val buttonEnabled = !quest.claimed && (!quest.accepted || canClaim)

    Dialog(
        onDismissRequest = onDismiss,
        properties = DialogProperties(usePlatformDefaultWidth = false),
    ) {
        CompositionLocalProvider(LocalContext provides localizedContext) {
            BoxWithConstraints(
                modifier = Modifier
                    .fillMaxSize()
                    .background(Color(0xF80A1012)),
                contentAlignment = Alignment.Center,
            ) {
            val dialogMaxHeight = maxHeight * 0.90f
            Column(
                modifier = Modifier
                    .widthIn(max = 432.dp)
                    .fillMaxWidth()
                    .padding(horizontal = 22.dp)
                    .heightIn(max = dialogMaxHeight),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(Modifier.fillMaxWidth().height(40.dp), contentAlignment = Alignment.CenterEnd) {
                    Surface(
                        color = Color(0xFF192526),
                        shape = CutCornerShape(3.dp),
                        border = BorderStroke(1.dp, QuestFrameBorder),
                        modifier = Modifier
                            .size(40.dp)
                            .clickable(role = Role.Button, onClick = onDismiss)
                            .semantics { contentDescription = closeDescription },
                    ) {
                        Box(contentAlignment = Alignment.Center) {
                            Text("×", color = Muted, fontSize = 25.sp, lineHeight = 25.sp)
                        }
                    }
                }

                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = dialogMaxHeight - 62.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Surface(
                        color = Color(0xFF10191F),
                        shape = SteppedFrameShape,
                        border = BorderStroke(2.dp, QuestFrameInsetBorder),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(top = 18.dp, bottom = 15.dp),
                    ) {
                        Surface(
                            color = Color.Transparent,
                            shape = SteppedFrameShape,
                            border = BorderStroke(1.dp, QuestFrameBorder),
                            modifier = Modifier.fillMaxWidth().padding(4.dp),
                        ) {
                            Column(
                                modifier = Modifier
                                    .heightIn(max = dialogMaxHeight - 103.dp)
                                    .verticalScroll(rememberScrollState())
                                    .background(
                                        Brush.linearGradient(
                                            listOf(Color(0xFF101B1D), Color(0xFF151925), Color(0xFF101A20)),
                                        ),
                                    )
                                    .padding(horizontal = 29.dp, vertical = 28.dp),
                                verticalArrangement = Arrangement.spacedBy(13.dp),
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically,
                                ) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                                        Box(Modifier.size(6.dp).background(QuestLime, CutCornerShape(1.dp)))
                                        Text(
                                            stringResource(R.string.quest_daily_label),
                                            color = QuestLime,
                                            style = MaterialTheme.typography.labelSmall,
                                            fontFamily = QuestPixelFont,
                    fontSize = 8.sp,
                                            fontWeight = FontWeight.Bold,
                                            letterSpacing = 0.8.sp,
                                        )
                                    }
                                    Text(
                                        stringResource(R.string.quest_reset_timer),
                                        color = Muted,
                                        style = MaterialTheme.typography.labelSmall,
                                        fontFamily = QuestPixelFont,
                    fontSize = 8.sp,
                                    )
                                }

                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(11.dp)) {
                                    Surface(
                                        color = Color(0xFF172623),
                                        shape = CutCornerShape(4.dp),
                                        border = BorderStroke(1.dp, Color(0xFF2D4740)),
                                        modifier = Modifier.size(42.dp),
                                    ) {
                                        Box(contentAlignment = Alignment.Center) {
                                            QuestArtwork(quest.kind, Modifier.size(36.dp))
                                        }
                                    }
                                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                        Text(
                                            quest.title ?: stringResource(copy.title),
                                            color = Ice,
                                            style = MaterialTheme.typography.titleMedium,
                                            fontWeight = FontWeight.Bold,
                                        )
                                        Text(stringResource(copy.subtitle), color = Muted, style = MaterialTheme.typography.bodySmall)
                                    }
                                }

                                Text(
                                    quest.description ?: stringResource(copy.description),
                                    color = Color(0xFFA7B2BC),
                                    style = MaterialTheme.typography.bodyMedium,
                                    lineHeight = 21.sp,
                                )
                                Text(
                                    stringResource(R.string.quest_objectives_label),
                                    color = Muted,
                                    style = MaterialTheme.typography.labelSmall,
                                    fontFamily = QuestPixelFont,
                    fontSize = 8.sp,
                                    fontWeight = FontWeight.Bold,
                                    letterSpacing = 2.1.sp,
                                )
                                if (quest.id.isNotBlank()) Text(stringResource(R.string.backend_quest_progress, quest.progress, quest.target), color = Ice)
                                else copy.objectives.forEachIndexed { objectiveIndex, objective ->
                                    QuestObjective(
                                        text = stringResource(objective),
                                        complete = objectiveIndex < quest.progress,
                                    )
                                }

                                Box(Modifier.fillMaxWidth().height(1.dp).background(Color(0xFF263640)))
                                Text(
                                    stringResource(R.string.quest_rewards_label),
                                    color = Muted,
                                    style = MaterialTheme.typography.labelSmall,
                                    fontFamily = QuestPixelFont,
                    fontSize = 8.sp,
                                    fontWeight = FontWeight.Bold,
                                    letterSpacing = 2.1.sp,
                                )
                                Row(horizontalArrangement = Arrangement.spacedBy(9.dp)) {
                                    RewardTile(
                                        value = stringResource(R.string.quest_credit_value, quest.rewardPoints),
                                        label = stringResource(R.string.dashboard_exp_title),
                                        color = QuestLime,
                                        icon = "ϟ",
                                        modifier = Modifier.weight(1f),
                                    )
                                    if (quest.rewardCredits > 0) RewardTile(
                                        value = stringResource(R.string.quest_credit_value, quest.rewardCredits),
                                        label = stringResource(R.string.quest_credits_label),
                                        color = Color(0xFF8DB8E7),
                                        icon = "◇",
                                        modifier = Modifier.weight(1f),
                                    )
                                }
                                Box(Modifier.fillMaxWidth().height(52.dp)) {
                                    Box(
                                        Modifier
                                            .fillMaxWidth()
                                            .height(48.dp)
                                            .offset(y = 4.dp)
                                            .background(Color(0xFF38552D), CutCornerShape(2.dp)),
                                    )
                                    Button(
                                        onClick = if (canClaim) onClaim else onAccept,
                                        enabled = buttonEnabled,
                                        colors = ButtonDefaults.buttonColors(
                                            containerColor = QuestLime,
                                            contentColor = Navy950,
                                            disabledContainerColor = Color(0xFF536B42),
                                            disabledContentColor = Color(0xFF172219),
                                        ),
                                        shape = CutCornerShape(2.dp),
                                        modifier = Modifier.fillMaxWidth().height(48.dp),
                                    ) {
                                        Text(
                                            stringResource(buttonLabel),
                                            fontFamily = QuestPixelFont,
                    fontSize = 8.sp,
                                            fontWeight = FontWeight.Black,
                                            letterSpacing = 1.3.sp,
                                        )
                                    }
                                }
                                Text(
                                    stringResource(noteLabel),
                                    color = Muted,
                                    style = MaterialTheme.typography.bodySmall,
                                    textAlign = TextAlign.Center,
                                    modifier = Modifier.fillMaxWidth(),
                                )
                            }
                        }
                    }

                    QuestTitleBadge(Modifier.align(Alignment.TopCenter).zIndex(1f))
                    QuestPagerButton(
                        label = "‹",
                        description = stringResource(R.string.quest_previous),
                        onClick = onPrevious,
                        modifier = Modifier.align(Alignment.CenterStart).offset(x = (-18).dp).zIndex(2f),
                    )
                    QuestPagerButton(
                        label = "›",
                        description = stringResource(R.string.quest_next),
                        onClick = onNext,
                        modifier = Modifier.align(Alignment.CenterEnd).offset(x = 18.dp).zIndex(2f),
                    )
                }

                Row(
                    modifier = Modifier.height(22.dp).padding(top = 2.dp),
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    repeat(questCount) { page ->
                        Box(
                            Modifier
                                .size(if (page == index) 14.dp else 6.dp, 5.dp)
                                .background(if (page == index) QuestLime else Color(0xFF34423D), RoundedCornerShape(1.dp)),
                        )
                    }
                    Spacer(Modifier.size(4.dp, 1.dp))
                    Text(
                        stringResource(R.string.quest_page_count, index + 1, questCount),
                        color = Muted,
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = QuestPixelFont,
                    fontSize = 8.sp,
                    )
                }
            }
            }
        }
    }
}

@Composable
private fun ContinueLearningSection(progress: Float, onClick: () -> Unit) {
    val safeProgress = progress.coerceIn(0f, 1f)
    val title = stringResource(R.string.continue_module_title)
    val cardDescription = stringResource(R.string.continue_module_accessibility, title)
    val progressDescription = stringResource(R.string.continue_module_progress, (safeProgress * 100).roundToInt())
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            stringResource(R.string.continue_learning_title),
            color = Ice,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
        )
        Surface(
            color = Color.Transparent,
            shape = SteppedFrameShape,
            border = BorderStroke(1.dp, QuestFrameBorder),
            modifier = Modifier
                .fillMaxWidth()
                .gameFrame()
                .clickable(role = Role.Button, onClick = onClick)
                .semantics { contentDescription = cardDescription },
        ) {
            Column(
                modifier = Modifier
                    .background(Brush.horizontalGradient(listOf(Color(0xFF151D2A), Color(0xFF111B27))))
                    .padding(horizontal = 16.dp, vertical = 15.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    stringResource(R.string.continue_module_category),
                    color = Muted,
                    style = MaterialTheme.typography.labelSmall,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.3.sp,
                )
                Text(
                    title,
                    color = Ice,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Medium,
                )
                Text(
                    stringResource(R.string.continue_module_description),
                    color = Muted,
                    style = MaterialTheme.typography.bodySmall,
                    lineHeight = 18.sp,
                )
                Canvas(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(4.dp)
                        .semantics {
                            contentDescription = progressDescription
                            progressBarRangeInfo = ProgressBarRangeInfo(safeProgress, 0f..1f)
                        },
                ) {
                    drawRect(Color(0xFF27343F))
                    drawRect(ContinueProgressBlue, size = size.copy(width = size.width * safeProgress))
                }
            }
        }
    }
}

@Composable
private fun QuestArtwork(kind: DashboardQuestKind, modifier: Modifier = Modifier) {
    val artwork = when (kind) {
        DashboardQuestKind.DailyLogin -> R.drawable.quest_phishing
        DashboardQuestKind.CompleteModule -> R.drawable.quest_fortress
        DashboardQuestKind.SubmitReport -> R.drawable.quest_impersonation
    }
    Image(
        bitmap = ImageBitmap.imageResource(artwork),
        contentDescription = null,
        filterQuality = FilterQuality.None,
        modifier = modifier,
    )
}

@Composable
private fun QuestTitleBadge(modifier: Modifier = Modifier) {
    Surface(
        color = Color(0xFF17291F),
        shape = SteppedFrameShape,
        border = BorderStroke(2.dp, Color(0xFF3C5A3C)),
        modifier = modifier.gameFrame(Color(0xFF3C5A3C)),
    ) {
        Text(
            stringResource(R.string.quest_dialog_title),
            color = QuestLime.copy(alpha = 0.88f),
            fontFamily = QuestPixelFont,
                    fontWeight = FontWeight.Normal,
            fontSize = 14.sp,
            letterSpacing = 2.sp,
            modifier = Modifier.padding(horizontal = 25.dp, vertical = 7.dp),
        )
    }
}

@Composable
private fun QuestPagerButton(
    label: String,
    description: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        color = Color(0xFF1A292A),
        shape = CutCornerShape(3.dp),
        border = BorderStroke(1.dp, QuestFrameBorder),
        modifier = modifier
            .size(42.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
    ) {
        Box(contentAlignment = Alignment.Center) {
            Text(label, color = QuestLime.copy(alpha = 0.85f), fontSize = 27.sp, lineHeight = 27.sp)
        }
    }
}

@Composable
private fun QuestObjective(text: String, complete: Boolean) {
    Row(
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Box(
            modifier = Modifier
                .padding(top = 2.dp)
                .size(11.dp)
                .then(
                    if (complete) Modifier.background(QuestLime, RoundedCornerShape(1.dp))
                    else Modifier.border(1.dp, Color(0xFF52636B), RoundedCornerShape(1.dp)),
                ),
            contentAlignment = Alignment.Center,
        ) {
            if (complete) Text("✓", color = Navy950, fontSize = 8.sp, lineHeight = 9.sp, fontWeight = FontWeight.Black)
        }
        Text(
            text,
            color = if (complete) Muted else Ice.copy(alpha = 0.83f),
            style = MaterialTheme.typography.bodySmall,
            lineHeight = 18.sp,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun RewardTile(value: String, label: String, color: Color, icon: String, modifier: Modifier = Modifier) {
    Surface(
        color = Color(0xFF172128),
        shape = CutCornerShape(3.dp),
        modifier = modifier.heightIn(min = 62.dp),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 9.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(icon, color = color, fontSize = 19.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.size(8.dp, 1.dp))
            Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
                Text(value, color = color, fontFamily = QuestPixelFont, fontSize = 10.sp, fontWeight = FontWeight.Normal, letterSpacing = 1.sp)
                Text(label, color = Muted, style = MaterialTheme.typography.labelSmall, letterSpacing = 0.6.sp)
            }
        }
    }
}

@Composable
private fun ExpandCorners(modifier: Modifier = Modifier) {
    Canvas(modifier) {
        val inset = size.minDimension * 0.15f
        val run = size.minDimension * 0.32f
        val right = size.width - inset
        val bottom = size.height - inset
        val color = Color(0xFF9DBF7E)
        val stroke = 1.6.dp.toPx()
        drawLine(color, androidx.compose.ui.geometry.Offset(inset, inset + run), androidx.compose.ui.geometry.Offset(inset, inset), stroke)
        drawLine(color, androidx.compose.ui.geometry.Offset(inset, inset), androidx.compose.ui.geometry.Offset(inset + run, inset), stroke)
        drawLine(color, androidx.compose.ui.geometry.Offset(right - run, inset), androidx.compose.ui.geometry.Offset(right, inset), stroke)
        drawLine(color, androidx.compose.ui.geometry.Offset(right, inset), androidx.compose.ui.geometry.Offset(right, inset + run), stroke)
        drawLine(color, androidx.compose.ui.geometry.Offset(inset, bottom - run), androidx.compose.ui.geometry.Offset(inset, bottom), stroke)
        drawLine(color, androidx.compose.ui.geometry.Offset(inset, bottom), androidx.compose.ui.geometry.Offset(inset + run, bottom), stroke)
        drawLine(color, androidx.compose.ui.geometry.Offset(right - run, bottom), androidx.compose.ui.geometry.Offset(right, bottom), stroke)
        drawLine(color, androidx.compose.ui.geometry.Offset(right, bottom), androidx.compose.ui.geometry.Offset(right, bottom - run), stroke)
    }
}
