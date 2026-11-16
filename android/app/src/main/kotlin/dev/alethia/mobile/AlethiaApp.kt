package dev.alethia.mobile

import android.content.res.Configuration
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import dev.alethia.core.*
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.distinctUntilChanged
import java.util.Locale

@OptIn(kotlinx.coroutines.FlowPreview::class)
@Composable
fun AlethiaApp(
    model: PracticeViewModel,
    authModel: AuthViewModel,
    reportsModel: ReportsViewModel,
    learning: LearningViewModel,
) {
    val language by model.language.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val baseConfiguration = LocalConfiguration.current
    val configuration = remember(baseConfiguration, language) {
        Configuration(baseConfiguration).apply { setLocale(Locale.forLanguageTag(language)) }
    }
    val localizedContext = remember(context, configuration) { context.createConfigurationContext(configuration) }
    CompositionLocalProvider(LocalContext provides localizedContext, LocalConfiguration provides configuration) {
        val screen by model.screen.collectAsStateWithLifecycle()
        val courierParent by model.courierParent.collectAsStateWithLifecycle()
        val reportEditorParent by reportsModel.editorParent.collectAsStateWithLifecycle()
        val courier by model.courier.collectAsStateWithLifecycle()
        val selectedModuleCategoryKey by model.selectedModuleCategoryKey.collectAsStateWithLifecycle()
        val savedRoadmapScroll by model.moduleRoadmapScroll.collectAsStateWithLifecycle()
        val generalScrollState = rememberScrollState()
        val roadmapScrollState = rememberScrollState(savedRoadmapScroll)
        LaunchedEffect(roadmapScrollState) {
            snapshotFlow { roadmapScrollState.value }
                .distinctUntilChanged()
                .debounce(140)
                .collect { model.saveModuleRoadmapScroll(it) }
        }
        val dashboardUiState by model.dashboardUiState.collectAsStateWithLifecycle()
        val backend by model.backend.collectAsStateWithLifecycle()
        val profileMessage by model.profileMessage.collectAsStateWithLifecycle()
        val learningUi by learning.ui.collectAsStateWithLifecycle()
        val continueSession = learningUi.sessions.values.firstOrNull { it.state.stage in 1..5 }
        if (screen == Screen.Courier) {
            LearningScreen(learning, onExit = { model.refreshBackend(); model.returnToTraining() }, onAccountChanged = model::refreshBackend,
                language = language, onLanguageChange = model::setLanguage)
            return@CompositionLocalProvider
        }
        val authSession by authModel.sessionState.collectAsStateWithLifecycle()
        val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
        DisposableEffect(lifecycleOwner) {
            val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
                if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) model.refreshBackend()
            }
            lifecycleOwner.lifecycle.addObserver(observer)
            onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
        }
        LaunchedEffect(authSession, screen) {
            if (authSession == AuthSessionState.SignedIn && screen in setOf(Screen.Welcome, Screen.Login, Screen.SignUp)) {
                model.navigate(Screen.Dashboard)
            }
        }
        LaunchedEffect(screen) {
            if (screen.roadmapCategoryOrNull() == null) generalScrollState.scrollTo(0)
            if (screen == Screen.Reports) reportsModel.refresh()
        }
        val mainSection = screen in setOf(
            Screen.Dashboard, Screen.Modules, Screen.Catalog,
            Screen.ModuleRoadmapPhishing, Screen.ModuleRoadmapSocialEngineering, Screen.ModuleRoadmapMaliciousDocument,
            Screen.Achievements, Screen.Reports,
        )
        BackHandler(screen != Screen.Welcome && screen != Screen.Dashboard) {
            if (screen.roadmapCategoryOrNull() != null) model.saveModuleRoadmapScroll(roadmapScrollState.value)
            model.navigate(backDestination(screen, courierParent, reportEditorParent))
        }
        Scaffold(
            containerColor = Navy950,
            topBar = {
                if (mainSection) {
                    DashboardTopBar(
                        hasUnreadNotifications = dashboardUiState.hasUnreadNotifications,
                        onNotifications = {
                            model.markNotificationsRead()
                            model.navigate(Screen.Notifications)
                        },
                        onProfile = { model.navigate(Screen.Profile) },
                        language = language,
                        onLanguageChange = model::setLanguage,
                    )
                } else if (screen == Screen.Welcome) {
                    LandingTopBar(language, model::setLanguage)
                } else if (screen == Screen.Profile || screen == Screen.EditProfile) {
                    ProfileTopBar(language, model::setLanguage) { model.navigate(backDestination(screen, courierParent, reportEditorParent)) }
                } else {
                    Surface(color = Navy950) {
                        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp),
                            horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                            TextButton(onClick = { model.navigate(backDestination(screen, courierParent, reportEditorParent)) }) {
                                Text(stringResource(R.string.back))
                            }
                            LanguageMenu(language, model::setLanguage)
                        }
                    }
                }
            },
            bottomBar = {
                if (mainSection) MainBottomBar(selected = screen, onNavigate = model::navigate)
            },
        ) { insets ->
            Box(Modifier.fillMaxSize().padding(insets).consumeWindowInsets(insets).imePadding(), contentAlignment = Alignment.TopCenter) {
                if (screen == Screen.Welcome) {
                    WelcomeScreen(
                        start = { model.navigate(Screen.Login) },
                        openTraining = { model.navigate(Screen.Catalog) },
                    )
                } else {
                    key(screen, courier.stage, backend.snapshot?.dashboard?.displayName, backend.signedIn) {
                        val activeScrollState = if (screen.roadmapCategoryOrNull() != null) roadmapScrollState else generalScrollState
                        Column(Modifier.widthIn(max = 640.dp).fillMaxSize().verticalScroll(activeScrollState)
                            .padding(horizontal = 24.dp, vertical = 20.dp),
                            verticalArrangement = Arrangement.spacedBy(20.dp)) {
                            if (backend.signedIn) {
                                if (backend.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                                if (backend.failed) {
                                    Text(stringResource(R.string.backend_error), color = Warning)
                                }
                                if (backend.failed || screen in setOf(Screen.Dashboard, Screen.Notifications, Screen.Achievements)) {
                                    TextButton(onClick = model::refreshBackend, enabled = !backend.busy) { Text(stringResource(R.string.backend_refresh)) }
                                }
                            }
                            when (screen) {
                            Screen.Login -> LoginScreen(
                                authModel = authModel,
                                onSignUp = {
                                    authModel.clearFeedback()
                                    model.navigate(Screen.SignUp)
                                },
                                onDashboardPreview = { model.navigate(Screen.Dashboard) },
                            )
                            Screen.SignUp -> SignUpScreen(authModel = authModel, onLogin = {
                                authModel.clearFeedback()
                                model.navigate(Screen.Login)
                            })
                            Screen.Dashboard -> DashboardScreen(
                                state = dashboardUiState,
                                onAcceptQuest = model::acceptDashboardQuest,
                                onClaimQuest = model::claimDashboardQuest,
                                onOpenReports = { model.navigate(Screen.Reports) },
                                continueModuleProgress = continueSession?.let { it.state.stage / 6f },
                                continueModuleTitle = continueSession?.state?.module?.let { module ->
                                    stringResource(when (module) {
                                        ModuleId.CourierSms -> R.string.learn_title_sms
                                        ModuleId.SocialEngineering -> R.string.learn_title_social
                                        ModuleId.ExecutableFile -> R.string.learn_title_file
                                    })
                                },
                                onContinueModule = {
                                    continueSession?.state?.module?.let { module ->
                                        val category = ModuleCategory.entries.first { it.moduleId() == module }
                                        model.selectModuleCategory(category)
                                        learning.open(module)
                                        model.openCourier(category.roadmapScreen())
                                    }
                                },
                            )
                            Screen.Modules, Screen.Catalog -> ModuleSelectionScreen(
                                selectedCategory = ModuleCategory.fromStorageKey(selectedModuleCategoryKey),
                                courier = courier,
                                serverAccess = backend.snapshot?.modules,
                                sessions = learningUi.sessions,
                                signedIn = backend.signedIn,
                                onSelectCategory = model::selectModuleCategory,
                                onOpenRoadmap = { model.navigate(ModuleCategory.fromStorageKey(selectedModuleCategoryKey).roadmapScreen()) },
                            )
                            Screen.ModuleRoadmapPhishing, Screen.ModuleRoadmapSocialEngineering, Screen.ModuleRoadmapMaliciousDocument -> ModuleRoadmapScreen(
                                category = screen.roadmapCategoryOrNull() ?: ModuleCategory.Phishing,
                                courier = courier,
                                serverAccess = backend.snapshot?.modules,
                                sessions = learningUi.sessions,
                                signedIn = backend.signedIn,
                                scrollState = roadmapScrollState,
                                onBack = { model.navigate(Screen.Modules) },
                                onSaveScroll = model::saveModuleRoadmapScroll,
                                onStartPractice = {
                                    val category = screen.roadmapCategoryOrNull() ?: ModuleCategory.Phishing
                                    learning.open(category.moduleId(), completed = backend.snapshot?.modules?.get(category.moduleId().wireId) == "completed",
                                        score = backend.snapshot?.moduleScores?.get(category.moduleId().wireId))
                                    model.saveModuleRoadmapScroll(roadmapScrollState.value)
                                    model.openCourier(screen)
                                },
                            )
                            Screen.Courier -> CourierScreen(model)
                            Screen.Achievements -> LearnerListScreen(R.string.achievements_title, backend.snapshot?.achievements.orEmpty(), backend.signedIn)
                            Screen.Reports -> ReportsListScreen(
                                    state = reportsModel.list.collectAsStateWithLifecycle().value,
                                    onRefresh = reportsModel::refresh,
                                    onLoadMore = reportsModel::loadMore,
                                    onScope = reportsModel::setScope,
                                    onSort = reportsModel::setSort,
                                    onOpenReport = { id ->
                                        reportsModel.openDetail(id)
                                        model.navigate(Screen.ReportDetail)
                                    },
                                    onNewReport = {
                                        reportsModel.openNewEditor()
                                        model.navigate(Screen.ReportEditor)
                                    },
                                )
                                Screen.ReportDetail -> {
                                    val detailId = reportsModel.detailId.collectAsStateWithLifecycle().value
                                    LaunchedEffect(detailId) {
                                        detailId?.let(reportsModel::loadDetail)
                                    }
                                    ReportDetailScreen(
                                        state = reportsModel.detail.collectAsStateWithLifecycle().value,
                                        onRetry = { detailId?.let(reportsModel::loadDetail) },
                                        onToggleSignal = reportsModel::toggleSignal,
                                        onAddNote = { text, clear -> reportsModel.addNote(text, clear) },
                                        onCastVerdict = { verdict, reason, clear -> reportsModel.castVerdict(verdict, reason, clear) },
                                        onClearValidation = reportsModel::clearDetailValidation,
                                        onEdit = { r ->
                                            reportsModel.openEditor(r)
                                            model.navigate(Screen.ReportEditor)
                                        },
                                        onDelete = {
                                            reportsModel.deleteReport {
                                                model.navigate(Screen.Reports)
                                                model.refreshBackend()
                                            }
                                        },
                                    )
                                }
                                Screen.ReportEditor -> {
                                    LaunchedEffect(Unit) { reportsModel.ensureEditorLoaded() }
                                    ReportEditorScreen(
                                        state = reportsModel.editor.collectAsStateWithLifecycle().value,
                                        onTitle = reportsModel::setEditorTitle,
                                        onCategory = reportsModel::setEditorCategory,
                                        onChannel = reportsModel::setEditorChannel,
                                        onPattern = reportsModel::setEditorPattern,
                                        onEvidence = reportsModel::setEditorEvidence,
                                        onRisk = reportsModel::setEditorRisk,
                                        onUrl = reportsModel::setEditorUrl,
                                        onScreenshot = reportsModel::setEditorScreenshot,
                                        onScreenshotError = reportsModel::setEditorValidation,
                                        onRemoveScreenshot = reportsModel::removeEditorScreenshot,
                                        onSave = {
                                            reportsModel.saveEditor { id ->
                                                reportsModel.openDetail(id)
                                                model.navigate(Screen.ReportDetail)
                                                model.refreshBackend()
                                            }
                                        },
                                        onCancel = { model.navigate(reportEditorParent) },
                                    )
                                }
                            Screen.Notifications -> LearnerListScreen(R.string.notifications_title, backend.snapshot?.notifications.orEmpty(), backend.signedIn,
                                onRead = { model.readNotification(it) })
                            Screen.Profile -> ProfileScreen(
                                profile = backend.snapshot?.profile,
                                onEdit = { model.clearProfileMessage(); model.navigate(Screen.EditProfile) },
                                onBadge = model::toggleBadge,
                                onSignOut = model::signOut,
                                busy = backend.busy,
                                message = profileMessage,
                            )
                            Screen.EditProfile -> EditProfileScreen(
                                profile = backend.snapshot?.profile,
                                busy = backend.busy,
                                message = profileMessage,
                                onSave = model::saveProfile,
                                onCancel = { model.clearProfileMessage(); model.navigate(Screen.Profile) },
                            )
                            Screen.Welcome -> Unit
                            }
                            Spacer(Modifier.height(20.dp))
                        }
                    }
                }
            }
        }
    }
}

private fun backDestination(screen: Screen, courierParent: Screen, reportEditorParent: Screen): Screen = when (screen) {
    Screen.Welcome -> Screen.Welcome
    Screen.Login -> Screen.Welcome
    Screen.SignUp -> Screen.Login
    Screen.Dashboard -> Screen.Dashboard
    Screen.Modules -> Screen.Dashboard
    Screen.Catalog -> Screen.Welcome
    Screen.ModuleRoadmapPhishing, Screen.ModuleRoadmapSocialEngineering, Screen.ModuleRoadmapMaliciousDocument -> Screen.Modules
    Screen.Courier -> courierParent
    Screen.ReportDetail -> Screen.Reports
    Screen.ReportEditor -> reportEditorParent
    Screen.Achievements, Screen.Reports, Screen.Notifications, Screen.Profile -> Screen.Dashboard
    Screen.EditProfile -> Screen.Profile
}

@Composable
private fun Title(text: String) {
    Text(text, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold,
        modifier = Modifier.semantics { heading() })
}

@Composable
private fun InfoCard(title: String, content: @Composable ColumnScope.() -> Unit) {
    Surface(color = Navy900, border = BorderStroke(1.dp, Navy700),
        shape = MaterialTheme.shapes.large, modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = Ice, fontWeight = FontWeight.SemiBold)
            content()
        }
    }
}

@Composable
private fun Action(label: String, tag: String, enabled: Boolean = true, onClick: () -> Unit) {
    Button(onClick, Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag(tag), enabled = enabled) {
        Text(label)
    }
}

private val LandingBackground = Color(0xFF070A10)
private val LandingHeader = Color(0xFF0A0F15)
private val LandingRule = Color(0xFF18202B)
private val LandingGreen = Color(0xFF8FD744)
private val LandingGreenShadow = Color(0xFF263F0D)
private val LandingFooter = Color(0xFF4E6074)

@Composable
private fun LandingTopBar(language: String, onLanguageChange: (String) -> Unit) {
    Surface(color = LandingHeader) {
        Column {
            Row(
                modifier = Modifier.fillMaxWidth()
                    .statusBarsPadding()
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    AlethiaLogo(modifier = Modifier.size(42.dp))
                    Text(
                        text = stringResource(R.string.brand_name),
                        color = Ice,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Bold,
                        letterSpacing = 1.2.sp,
                        fontSize = 19.sp,
                    )
                }
                LanguageMenu(language, onLanguageChange)
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(LandingRule))
        }
    }
}

@Composable
private fun WelcomeScreen(start: () -> Unit, openTraining: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        LandingBackdrop(Modifier.fillMaxSize())

        val compact = maxHeight < 650.dp
        Column(
            modifier = Modifier.align(Alignment.Center)
                .offset(y = if (compact) 0.dp else (-8).dp)
                .fillMaxWidth()
                .padding(horizontal = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                text = stringResource(R.string.welcome_eyebrow),
                color = LandingGreen,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.Bold,
                letterSpacing = 3.5.sp,
                fontSize = 12.sp,
                maxLines = 1,
                softWrap = false,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(if (compact) 22.dp else 50.dp))
            LandingPixelWordmark()
            Spacer(Modifier.height(if (compact) 18.dp else 44.dp))
            Text(
                text = stringResource(R.string.welcome_body),
                color = Color(0xFF8DA0B4),
                fontSize = 16.sp,
                lineHeight = 22.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.widthIn(max = 330.dp).fillMaxWidth(),
            )
            Spacer(Modifier.height(if (compact) 32.dp else 43.dp))
            LandingStartButton(onClick = start)
        }

        Text(
            text = stringResource(R.string.landing_safety_note),
            color = LandingFooter,
            fontFamily = FontFamily.Monospace,
            fontWeight = FontWeight.Medium,
            letterSpacing = 1.4.sp,
            fontSize = 11.sp,
            maxLines = 1,
            softWrap = false,
            textAlign = TextAlign.Center,
            modifier = Modifier.align(Alignment.BottomCenter)
                .padding(horizontal = 16.dp)
                .padding(bottom = maxHeight * 0.24f),
        )

        TextButton(
            onClick = openTraining,
            modifier = Modifier.align(Alignment.BottomCenter)
                .navigationBarsPadding()
                .padding(bottom = 4.dp)
                .testTag("open_training"),
            contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp),
        ) {
            Text(
                text = stringResource(R.string.open_training_guest),
                color = Muted.copy(alpha = 0.72f),
                fontFamily = FontFamily.Monospace,
                fontSize = 10.sp,
                letterSpacing = 0.1.sp,
            )
        }
    }
}

private val LandingPixelWordmarkGlyphs = listOf(
    listOf("01110", "11011", "11011", "11111", "11011", "11011", "11011"),
    listOf("11000", "11000", "11000", "11000", "11000", "11000", "11111"),
    listOf("11111", "11000", "11000", "11110", "11000", "11000", "11111"),
    listOf("11111", "00110", "00110", "00110", "00110", "00110", "00110"),
    listOf("11011", "11011", "11011", "11111", "11011", "11011", "11011"),
    listOf("11111", "00110", "00110", "00110", "00110", "00110", "11111"),
    listOf("01110", "11011", "11011", "11111", "11011", "11011", "11011"),
)

@Composable
private fun LandingPixelWordmark() {
    val density = androidx.compose.ui.platform.LocalDensity.current
    val cellPx = with(density) { 4.5.dp.roundToPx().toFloat() }
    val gapPx = with(density) { 18.dp.roundToPx().toFloat() }
    val widthPx = cellPx * 5 * LandingPixelWordmarkGlyphs.size + gapPx * (LandingPixelWordmarkGlyphs.size - 1)
    val width = with(density) { widthPx.toDp() }
    val height = with(density) { (cellPx * 7).toDp() }
    val label = stringResource(R.string.landing_product_name)

    Canvas(
        modifier = Modifier.width(width).height(height)
            .semantics {
                contentDescription = label
                heading()
            },
    ) {
        LandingPixelWordmarkGlyphs.forEachIndexed { glyphIndex, rows ->
            val glyphLeft = glyphIndex * (cellPx * 5 + gapPx)
            rows.forEachIndexed { rowIndex, row ->
                row.forEachIndexed { columnIndex, pixel ->
                    if (pixel == '1') {
                        drawRect(
                            color = Color(0xFFE5E7EB),
                            topLeft = Offset(glyphLeft + columnIndex * cellPx, rowIndex * cellPx),
                            size = Size(cellPx, cellPx),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun LandingStartButton(onClick: () -> Unit) {
    val shape = RoundedCornerShape(6.dp)
    Box(Modifier.width(140.dp).height(64.dp)) {
        Surface(
            modifier = Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(58.dp),
            shape = shape,
            color = LandingGreenShadow,
        ) {}
        Box(
            modifier = Modifier.align(Alignment.TopCenter).fillMaxWidth().height(58.dp),
            contentAlignment = Alignment.Center,
        ) {
            Box(
                modifier = Modifier.fillMaxSize()
                    .clip(shape)
                    .background(LandingGreen)
                    .clickable(role = Role.Button, onClick = onClick)
                    .testTag("start_auth"),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    text = stringResource(R.string.landing_start),
                    color = Color(0xFF08100A),
                    fontFamily = FontFamily.Monospace,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 1.sp,
                    fontSize = 17.sp,
                )
            }
        }
    }
}

@Composable
private fun LandingBackdrop(modifier: Modifier = Modifier) {
    Canvas(modifier) {
        drawRect(
            brush = Brush.radialGradient(
                colors = listOf(Color(0xFF14181E), Color(0xFF0B0F15), LandingBackground),
                center = Offset(size.width * 0.5f, size.height * 0.43f),
                radius = size.maxDimension * 0.82f,
            ),
        )
        val specks = listOf(
            0.12f to 0.26f, 0.61f to 0.22f, 0.82f to 0.34f, 0.27f to 0.50f,
            0.74f to 0.57f, 0.15f to 0.73f, 0.88f to 0.80f, 0.42f to 0.88f,
        )
        specks.forEachIndexed { index, (x, y) ->
            val side = if (index % 3 == 0) 2.dp.toPx() else 1.dp.toPx()
            drawRect(
                color = Color(0xFF91A0B1).copy(alpha = if (index % 3 == 0) 0.13f else 0.09f),
                topLeft = Offset(size.width * x, size.height * y),
                size = Size(side, side),
            )
        }
    }
}

@Composable
private fun EvidenceCard() {
    InfoCard(stringResource(R.string.receive_title)) {
        Text(CourierEvidence.sender, fontFamily = FontFamily.Monospace, color = Signal)
        Text(stringResource(R.string.sms_body))
        Text(CourierEvidence.defangedLink, color = Warning, fontFamily = FontFamily.Monospace)
    }
}

@Composable
private fun Choice(label: String, selected: Boolean, tag: String, onClick: () -> Unit) {
    OutlinedButton(onClick, Modifier.fillMaxWidth().heightIn(min = 52.dp).testTag(tag),
        border = BorderStroke(if (selected) 2.dp else 1.dp, if (selected) Signal else Navy700)) {
        Text(label, color = if (selected) Signal else Ice)
    }
}

@Composable
private fun CourierScreen(model: PracticeViewModel) {
    val focus = LocalFocusManager.current
    val state by model.courier.collectAsStateWithLifecycle()
    val sender by model.senderInput.collectAsStateWithLifecycle()
    val link by model.linkInput.collectAsStateWithLifecycle()
    val tracking by model.trackingInput.collectAsStateWithLifecycle()
    val checked by model.trackingChecked.collectAsStateWithLifecycle()
    val backend by model.backend.collectAsStateWithLifecycle()
    val verifiedScore by model.verifiedScore.collectAsStateWithLifecycle()
    Text(stringResource(R.string.practice_label), color = Signal, fontFamily = FontFamily.Monospace,
        style = MaterialTheme.typography.labelMedium)
    if (state.stage != CourierStage.Briefing && state.stage != CourierStage.Complete) {
        Text(stringResource(R.string.step_counter, state.stage.ordinal, 5), color = Muted)
        LinearProgressIndicator(progress = { state.stage.ordinal / 5f }, modifier = Modifier.fillMaxWidth())
    }
    when (state.stage) {
        CourierStage.Briefing -> {
            Title(stringResource(R.string.briefing_title))
            Text(stringResource(R.string.briefing_body), color = Muted)
            Text(stringResource(R.string.fictional_notice), color = Warning)
            Action(stringResource(R.string.begin), "begin_courier") { model.dispatch(CourierAction.Start) }
        }
        CourierStage.Receive -> {
            EvidenceCard()
            Action(stringResource(R.string.inspect_action), "inspect_message") { model.dispatch(CourierAction.Inspect) }
        }
        CourierStage.Inspect -> {
            Title(stringResource(R.string.inspect_title))
            EvidenceCard()
            OutlinedTextField(sender, model::setSender, Modifier.fillMaxWidth().testTag("sender_input"),
                label = { Text(stringResource(R.string.sender_field)) }, singleLine = true,
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false))
            OutlinedTextField(link, model::setLink, Modifier.fillMaxWidth().testTag("link_input"),
                label = { Text(stringResource(R.string.link_field)) }, singleLine = true,
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false))
            Action(stringResource(R.string.compare_action), "compare_evidence", sender.isNotBlank() && link.isNotBlank()) {
                focus.clearFocus()
                model.dispatch(CourierAction.Compare(CourierEvidence.matchesSender(sender), CourierEvidence.matchesLink(link)))
            }
            if (state.comparisonSubmitted) {
                Text(stringResource(if (state.senderMatches == true && state.linkMatches == true)
                    R.string.comparison_ok else R.string.comparison_error), color = Warning)
                Text(stringResource(R.string.sender_question))
                Choice(stringResource(R.string.sender_unverified), state.senderAssessment == SenderAssessment.Unverified, "sender_unverified") {
                    model.dispatch(CourierAction.AssessSender(SenderAssessment.Unverified))
                }
                Choice(stringResource(R.string.sender_trusted), state.senderAssessment == SenderAssessment.Trusted, "sender_trusted") {
                    model.dispatch(CourierAction.AssessSender(SenderAssessment.Trusted))
                }
                Text(stringResource(R.string.link_question))
                Choice(stringResource(R.string.link_suspicious), state.linkAssessment == LinkAssessment.Suspicious, "link_suspicious") {
                    model.dispatch(CourierAction.AssessLink(LinkAssessment.Suspicious))
                }
                Choice(stringResource(R.string.link_trusted), state.linkAssessment == LinkAssessment.Trusted, "link_trusted") {
                    model.dispatch(CourierAction.AssessLink(LinkAssessment.Trusted))
                }
                Action(stringResource(R.string.continue_action), "continue_inspection", state.canContinueInspection) {
                    model.dispatch(CourierAction.ContinueInspection)
                }
            }
        }
        CourierStage.Verify -> {
            Title(stringResource(R.string.verify_title))
            Text(stringResource(R.string.verify_body), color = Muted)
            if (!state.verificationOpen) {
                Action(stringResource(R.string.open_official), "open_official") { model.dispatch(CourierAction.OpenOfficialChannel) }
            } else {
                InfoCard(stringResource(R.string.official_title)) {
                    Text(CourierEvidence.trackingNumber, fontFamily = FontFamily.Monospace, color = Signal)
                    OutlinedTextField(tracking, model::setTracking, Modifier.fillMaxWidth().testTag("tracking_input"),
                        label = { Text(stringResource(R.string.tracking_field)) }, singleLine = true,
                        keyboardOptions = KeyboardOptions(autoCorrectEnabled = false))
                    Action(stringResource(R.string.check_tracking), "check_tracking", tracking.isNotBlank()) { focus.clearFocus(); model.checkTracking() }
                    if (checked) {
                        val found = tracking.trim().equals(CourierEvidence.trackingNumber, ignoreCase = true)
                        Text(stringResource(if (found) R.string.official_result else R.string.tracking_missing), color = Warning)
                        Action(stringResource(R.string.confirm_verification), "confirm_verification", found) {
                            model.dispatch(CourierAction.ConfirmVerification)
                        }
                    }
                }
            }
        }
        CourierStage.Decide -> {
            Title(stringResource(R.string.decide_title))
            listOf(
                Triple(R.string.choose_verify, "choose_verify", CourierDecision.VerifyOfficialChannel),
                Triple(R.string.choose_report, "choose_report", CourierDecision.ReportDelete),
                Triple(R.string.choose_open, "choose_open", CourierDecision.OpenLink),
            ).forEach { (label, tag, decision) ->
                Choice(stringResource(label), false, tag) { model.dispatch(CourierAction.Decide(decision)) }
            }
        }
        CourierStage.Reveal -> {
            Title(stringResource(R.string.reveal_title))
            Text(stringResource(R.string.reveal_body), color = Muted)
            Text(stringResource(if (state.decision == CourierDecision.OpenLink) R.string.unsafe_feedback else R.string.safe_feedback), color = Warning)
            Action(stringResource(R.string.complete_action), "complete_practice") { model.dispatch(CourierAction.Complete) }
        }
        CourierStage.Complete -> {
            val result = scoreCourier(state)
            Title(stringResource(R.string.result_title))
            Text(stringResource(R.string.result_score, if (backend.signedIn) verifiedScore ?: result.score else result.score), color = Signal,
                style = MaterialTheme.typography.displaySmall, modifier = Modifier.testTag("practice_score"))
            Text(stringResource(R.string.result_explanation), color = Muted)
            val labels = listOf(R.string.criterion_sender, R.string.criterion_link, R.string.criterion_verify, R.string.criterion_decision)
            labels.zip(result.checks).forEach { (label, met) ->
                Text("${if (met) "✓" else "·"} ${stringResource(label)} · ${stringResource(if (met) R.string.criterion_met else R.string.criterion_unmet)}",
                    color = if (met) Ice else Warning)
            }
            Text(stringResource(if (backend.signedIn) R.string.backend_result_saved else R.string.guest_note), color = Warning)
            Action(stringResource(R.string.retry), "retry_practice") { model.restart() }
            OutlinedButton(onClick = model::returnToTraining, Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.return_training))
            }
        }
    }
}
