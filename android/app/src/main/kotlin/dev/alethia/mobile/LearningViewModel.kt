package dev.alethia.mobile

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import dev.alethia.core.*
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** Owns lesson interactions and durable recovery independently of dashboard navigation. */
class LearningViewModel(private val repository: LearnerRepository?, private val store: LearningDraftStore) : ViewModel() {
    private val mutable = MutableStateFlow(LearningUiState())
    val ui = mutable.asStateFlow()
    private var owner: String? = null
    private var epoch = 0
    private var command: Job? = null
    private val writes = Channel<Unit>(Channel.CONFLATED)
    private val lock = Mutex()
    private val cache = mutableMapOf<ModuleId, LearningSession>()

    init {
        restoreLocal()
        repository?.let { repo -> viewModelScope.launch {
            repo.identity.collectLatest { id ->
                if (id == null && owner == null) {
                    mutable.value = mutable.value.copy(sessions = cache.toMap())
                    return@collectLatest
                }
                epoch++
                command?.cancel()
                owner = id
                cache.clear()
                restoreLocal()
                mutable.value = LearningUiState(signedIn = id != null, sessions = cache.toMap())
                if (id != null) {
                    try {
                        lock.withLock {
                            val expected = epoch
                            val remote = repo.learningSessions()
                            if (owner == id && expected == epoch) remote.forEach { session ->
                                val chosen = reconcile(cache[session.state.module], session)
                                store.save(key(), chosen)
                                cache[chosen.state.module] = chosen
                            }
                            mutable.value = mutable.value.copy(sessions = cache.toMap())
                            flush()
                        }
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (_: Exception) { mutable.value = mutable.value.copy(saveFailed = true) }
                }
            }
        } }
        viewModelScope.launch {
            for (ignored in writes) {
                val expected = epoch
                try { lock.withLock { if (expected == epoch) flush() } }
                catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { if (expected == epoch) mutable.value = mutable.value.copy(saveFailed = true) }
            }
        }
    }
    private fun key() = owner ?: "guest"
    private fun restoreLocal() { ModuleId.entries.forEach { m -> store.load(key(), m)?.let { cache[m] = it } } }
    private fun reconcile(local: LearningSession?, remote: LearningSession): LearningSession = when {
        local == null || local.attemptId != remote.attemptId || !local.dirty -> remote
        local.revision == remote.revision -> local
        local.revision < remote.revision && local.state.isForwardCheckpointFrom(remote.state) ->
            local.copy(revision = remote.revision)
        else -> remote // A different device advanced or changed this attempt; keep the hosted snapshot.
    }
    private fun publish(session: LearningSession) {
        store.save(key(), session)
        cache[session.state.module] = session
        mutable.value = mutable.value.copy(session = session, sessions = cache.toMap())
    }
    fun open(module: ModuleId, completed: Boolean = false, score: Int? = null, restart: Boolean = false) {
        if (mutable.value.busy) return
        val expected = epoch
        mutable.value = mutable.value.copy(busy = true, failed = false, saveFailed = false, requestedModule = module, session = null)
        command = viewModelScope.launch {
            try {
                lock.withLock {
                    if (owner == null) {
                        val local = if (restart) null else cache[module]
                        publish(local ?: LearningSession(null, 0, LearningState(module, stage = 1)))
                    } else {
                        val remote = if (restart) null else repository!!.learningSessions().firstOrNull { it.state.module == module }
                        val local = cache[module]
                        val chosen = if (completed && remote == null && !restart) {
                            LearningSession(null, 0, LearningState(module, stage = 6), LearningResult(score, if (score == null) null else score == 100))
                        } else {
                            val draft = remote?.takeUnless { restart } ?: repository!!.openLearning(module, restart)
                            if (restart) draft else reconcile(local, draft)
                        }
                        if (expected != epoch) return@withLock
                        publish(if (chosen.state.stage == 0) chosen.copy(state = chosen.state.copy(stage = 1), dirty = true) else chosen)
                        flush()
                    }
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { if (expected == epoch) mutable.value = mutable.value.copy(failed = true) }
            finally { if (expected == epoch) mutable.value = mutable.value.copy(busy = false) }
        }
    }
    fun change(transform: (LearningState) -> LearningState) {
        if (mutable.value.busy) return
        val current = mutable.value.session ?: return
        if (current.state.stage == 6) return
        val next = transform(current.state)
        if (next == current.state) return
        publish(current.copy(state = next, dirty = owner != null))
        writes.trySend(Unit)
    }
    private suspend fun flush() {
        val id = owner ?: return
        val expected = epoch
        // Drain latest snapshots rather than cancelling an in-flight write whose response may be lost.
        for (module in ModuleId.entries) {
            while (true) {
                val pending = cache[module]?.takeIf { it.dirty && it.attemptId != null } ?: break
                val synced = repository!!.saveLearning(pending)
                if (owner != id || epoch != expected) return
                val newest = cache[module] ?: break
                val merged = if (newest.state == pending.state && newest.result == pending.result) synced.copy(dirty = false)
                    else newest.copy(revision = synced.revision, dirty = true)
                store.save(key(), merged)
                cache[module] = merged
                val current = mutable.value.session
                mutable.value = mutable.value.copy(
                    session = if (current?.state?.module == module) merged else current,
                    sessions = cache.toMap(), saveFailed = false,
                )
            }
        }
    }
    fun retrySave() { mutable.value = mutable.value.copy(saveFailed = false, failed = false); writes.trySend(Unit) }
    fun complete(onAccountChanged: () -> Unit) {
        val current = mutable.value.session ?: return
        if (current.state.stage != 5 || mutable.value.busy) return
        val expected = epoch
        mutable.value = mutable.value.copy(busy = true, failed = false)
        command = viewModelScope.launch {
            try {
                lock.withLock {
                    val result = if (owner == null) LearningResult(current.state.score(), current.state.score()?.let { it == 100 })
                    else {
                        flush()
                        repository!!.completeLearningAttempt(current.attemptId ?: error("Missing server attempt"), current.state.decisions())
                    }
                    if (expected != epoch) return@withLock
                    publish(current.copy(state = current.state.copy(stage = 6), result = result,
                        revision = cache[current.state.module]?.revision ?: current.revision, dirty = owner != null))
                    if (owner != null) flush()
                    onAccountChanged()
                }
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { if (expected == epoch) mutable.value = mutable.value.copy(failed = true) }
            finally { if (expected == epoch) mutable.value = mutable.value.copy(busy = false) }
        }
    }
    class Factory(private val repository: LearnerRepository?, private val store: LearningDraftStore) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T = LearningViewModel(repository, store) as T
    }
}

data class LearningUiState(
    val signedIn: Boolean = false, val busy: Boolean = false, val failed: Boolean = false,
    val requestedModule: ModuleId? = null,
    val saveFailed: Boolean = false, val session: LearningSession? = null,
    val sessions: Map<ModuleId, LearningSession> = emptyMap(),
)
