# Native learning modules

Implemented 16 November 2026. The existing Alethia pixel islands/roadmaps remain the entry navigation. A native bottom sheet introduces each checkpoint; the exercise uses a dedicated full-screen Compose scaffold with a fixed primary action and explicit exit/resume.

## Modules and server contract

| ID | Native exercise | Verified completion |
| --- | --- | --- |
| `courier-sms` | Observe SMS, copy/paste evidence, assess sender/link, check tracking in a simulated official channel, choose, learn impact | Four server criteria; 100 unlocks Social Engineering |
| `social-engineering` | Choose 2–5 synthetic artifacts, inspect exposure and all selected pairings, review pretexts, choose mitigation | Unscored completion; unlocks Executable File |
| `executable-file` | Receive attachment, open at least two details, verify independently, decide, learn impact | Three server criteria; 100 completes mastery |

Lesson copy for Social Engineering and File is adapted directly from the web's ID/EN dictionaries in `app/src/main/assets/learning/`. No real file or URL is opened by the simulation. Existing pixel artwork is reused.

`core/LearningSession.kt` owns stage gates and ordered decision identifiers. `LearningScreen.kt` renders native interactions. `LearningViewModel.kt` coordinates local recovery and account writes through `LearnerRepository`; screen rendering never awards points.

## Recovery and rewards

- SharedPreferences store a small per-account recovery copy of synthetic lesson state immediately on interaction; auth tokens remain in the existing encrypted Auth session store. Cloud backup is disabled by the application.
- Migration `20261116000000_learning_session_recovery.sql` introduces RPC-only account-owned recovery snapshots. `open_learning_session` resumes the same attempt atomically, `save_learning_session` checks the attempt owner and revision, and `get_learning_sessions` returns only the caller's snapshots.
- Recovery JSON is presentation data. It does not authorize module completion, score, points or unlocks. Those remain in `complete_verified_practice_attempt` and existing server triggers.
- Saves are serialized; edits that arrive during a save retain the next dirty snapshot. Identical retries are idempotent, while a stale device revision cannot overwrite a newer snapshot.
- Final submission retries use the same server attempt ID. On verified completion Android refreshes the dashboard, access, quests, points, notifications and achievements. A failed attempt retains its result and can be repeated; retakes do not grant duplicate completion rewards.
- First completions grant the existing 20/30/50 module points. Quest rewards remain separate, must be claimed, and are also idempotent.
- Guest sessions stay under a separate device key and use local sequential unlocks. They are not uploaded or merged into an account. Signed-in unlocks use the server snapshot.
- Background Auth initialization/refresh is not treated as logout. Account switches clear the displayed learning state and select the correct recovery namespace.

## Validation

Run `./gradlew :core:test :app:lintDebug :app:assembleDebug` in `android/`. With the emulator, Docker Supabase and API local available, run:

```sh
./gradlew :app:connectedDebugAndroidTest -PalethiaConfig=alethia.local.properties
```

Instrumentation covers copy/paste, wrong-answer scoring, activity recreation, durable local recovery, all three native guest exercises, all three signed-in exercises, account access/rewards, and re-login. Connected tests create/delete only temporary local accounts. `backend/supabase/tests/020_learning_session_recovery.sql` additionally covers revision conflicts, owner isolation, forged snapshot non-authority, completion rewards and server-side unlocks. The full local database suite has 335 assertions.

Hosted migration application and a temporary-account RPC check were completed on 16 November. The hosted check confirmed all three results, recovery snapshots, 100 completion points, idempotent claims and re-login; its temporary account was deleted. These hosted checks exercise the app's endpoint contracts, while native UI instrumentation uses the local target.

## Hosted UI regression verification

The signed-in `PracticeJourneyTest` can explicitly target only Alethia Mobile hosted
with `-PalethiaConfig=alethia.hosted.properties` and
`-Pandroid.testInstrumentationRunnerArguments.alethiaHostedAudit=true`.
Select the signed-in test method when running it. The default remains local-only;
CI never opts into hosted account creation.

The hosted journey now registers through UI, checks stage 3 before backgrounding,
compares the device draft and hosted snapshot, recreates the activity and reopens
the same session. It then completes all three modules, checks unlocks/rewards,
opens achievements, marks notifications read, changes language across recreation,
submits a synthetic report through UI and verifies relogin. Cleanup deletes only
that synthetic account's reports before deleting the account through Vercel.
The expanded hosted journey passed with zero failures on 16 November 2026.

The earlier stage-2 assertion was not sufficient evidence of data rollback: it did
not establish stage 3 before changing lifecycle. No rollback was reproduced with
explicit local and remote checkpoints. Its original cause remains unconfirmed.
Evidence input handlers now ignore unchanged text, preserving comparison and
verification when the same value is pasted again; changed text still invalidates
those results.
