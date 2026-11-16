# Alethia Mobile architecture baseline

## Current boundary

- `app` owns Android UI, navigation, lifecycle state, and device-specific preferences.
- `core` owns simulation state transitions, scoring, and access rules. Keep it independent of Android, Compose, networking, and persistence frameworks.
- `../backend` owns privileged HTTP handlers and the Supabase migration/test chain. It contains no learner-facing web UI.
- Native Compose login and sign-up screens use `AuthViewModel` and `AuthRepository`. Email registration/sign-in call Supabase Auth through the Kotlin SDK; username sign-in uses the backend endpoint and imports its verified tokens into the SDK. The SDK session is encrypted with an Android Keystore key. An authenticated session routes welcome/login/register to the dashboard. The hosted Supabase project and Vercel API are configured. Signed-in dashboard and learning data use the caller JWT through `LearnerRepository`; `PracticeViewModel` coordinates account data and practice submission. Guest dashboard preview data is kept separate.

The integration covers all three native practices and account features. `LearningViewModel` owns lesson interactions, durable recovery and verified submission through `LearnerRepository`; see [MODULES.md](MODULES.md). `PracticeViewModel` owns navigation and practice state; keep adding feature-specific ViewModels and repositories as each connected feature is implemented instead of creating empty layers now.

## Feature change boundary

For each connected feature, keep the flow explicit:

```text
Compose screen -> feature ViewModel -> repository -> Supabase or Alethia Backend
                                      -> map network DTOs to app/domain models
```

- Put rendering and user interaction in Compose screens.
- Keep orchestration and screen state in feature ViewModels.
- Put network and persistence details in `app` data implementations behind feature repository interfaces.
- Put reusable, platform-independent rules and models in `core`.
- Keep authorization and authoritative progress checks on Supabase/server; hiding a button in Android is not authorization.
- Only public Supabase keys and the API base URL may be configured in Android. Server keys belong in backend deployment secrets.

A feature should be changed as a vertical slice: screen/state, repository contract and implementation, backend/API or migration when required, and focused tests at the layer that owns the behavior.

## CI checks

The Android workflow always posts a required summary check, then runs its build jobs only when Android source or Gradle configuration changes. It checks `:core:test`, Android lint, Android 17 instrumentation flows, and a debug APK. The monorepo has separate backend API and database workflows; see [`../../backend/README.md`](../../backend/README.md).

See [INTEGRATION.md](INTEGRATION.md) for the RPC mapping, environment selection and current feature limits.
