package dev.alethia.core

enum class ModuleId(val wireId: String) {
    CourierSms("courier-sms"), SocialEngineering("social-engineering"), ExecutableFile("executable-file")
}

data class VerifiedModuleProgress(val completed: Boolean = false, val score: Int? = null)
enum class ModuleAccess { Available, Locked, Completed }

/** Only pass server-confirmed records to this function; guest history is separate. */
fun verifiedModuleAccess(progress: Map<ModuleId, VerifiedModuleProgress>): Map<ModuleId, ModuleAccess> {
    val courier = progress[ModuleId.CourierSms] ?: VerifiedModuleProgress()
    val social = progress[ModuleId.SocialEngineering] ?: VerifiedModuleProgress()
    val document = progress[ModuleId.ExecutableFile] ?: VerifiedModuleProgress()
    val courierComplete = courier.completed && courier.score == 100
    return mapOf(
        ModuleId.CourierSms to if (courierComplete) ModuleAccess.Completed else ModuleAccess.Available,
        ModuleId.SocialEngineering to when {
            !courierComplete -> ModuleAccess.Locked
            social.completed -> ModuleAccess.Completed
            else -> ModuleAccess.Available
        },
        ModuleId.ExecutableFile to when {
            !courierComplete || !social.completed -> ModuleAccess.Locked
            document.completed && document.score == 100 -> ModuleAccess.Completed
            else -> ModuleAccess.Available
        },
    )
}

fun levelForPoints(points: Int): Int = when {
    points >= 550 -> 5
    points >= 300 -> 4
    points >= 150 -> 3
    points >= 60 -> 2
    else -> 1
}
