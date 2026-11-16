package dev.alethia.mobile

import android.app.Application
import android.content.Context
import io.github.jan.supabase.auth.Auth
import io.github.jan.supabase.createSupabaseClient

class AlethiaApplication : Application() {
    val container: AppContainer by lazy { AppContainer(this) }
}

class AppContainer(context: Context) {
    internal val client by lazy {
        val url = BuildConfig.SUPABASE_URL.trim().trimEnd('/')
        val key = BuildConfig.SUPABASE_PUBLISHABLE_KEY.trim()
        if (url.isBlank() || key.isBlank()) {
            null
        } else {
            val client = createSupabaseClient(supabaseUrl = url, supabaseKey = key) {
                install(Auth) {
                    sessionManager = AndroidKeystoreSessionManager(context.applicationContext)
                }
            }
            client
        }
    }
    val authRepository: AuthRepository by lazy {
        client?.let { SupabaseAuthRepository(it, BuildConfig.API_BASE_URL) } ?: UnavailableAuthRepository
    }
    val learnerRepository: LearnerRepository? by lazy {
        client?.let { LearnerRepository(it, BuildConfig.SUPABASE_URL, BuildConfig.SUPABASE_PUBLISHABLE_KEY) }
    }
    val reportsRepository: ReportsRepository? by lazy {
        learnerRepository?.let { ReportsRepository(it) }
    }

}
