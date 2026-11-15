package dev.alethia.mobile

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import java.io.IOException
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.map

private val Context.languageStore by preferencesDataStore(name = "alethia_preferences")

class LanguagePreferences(context: Context) {
    private val store = context.applicationContext.languageStore
    private val key = stringPreferencesKey("language")
    val language = store.data.map { it[key] ?: "id" }.catch { error ->
        if (error is IOException) emit("id") else throw error
    }
    suspend fun setLanguage(value: String) {
        require(value in setOf("id", "en"))
        store.edit { it[key] = value }
    }
}
