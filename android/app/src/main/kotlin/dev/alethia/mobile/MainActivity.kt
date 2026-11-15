package dev.alethia.mobile

import android.graphics.Color
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.ViewModelProvider

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
            navigationBarStyle = SystemBarStyle.dark(Color.TRANSPARENT),
        )
        val application = application as AlethiaApplication
        val model = ViewModelProvider(this, PracticeViewModel.Factory(LanguagePreferences(applicationContext), application.container.learnerRepository))[PracticeViewModel::class.java]
        val authModel = ViewModelProvider(this, AuthViewModel.Factory(application.container.authRepository))[AuthViewModel::class.java]
        setContent { AlethiaTheme { AlethiaApp(model, authModel) } }
    }
}
