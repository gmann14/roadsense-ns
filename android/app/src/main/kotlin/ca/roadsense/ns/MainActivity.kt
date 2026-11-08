package ca.roadsense.ns

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import ca.roadsense.ns.permissions.PermissionState
import ca.roadsense.ns.ui.AppShell
import ca.roadsense.ns.ui.AppViewModel
import ca.roadsense.ns.ui.BottomTab
import ca.roadsense.ns.ui.theme.RoadSenseTheme

/**
 * Compose-hosted launcher activity. Owns the permission launcher (which
 * MUST be registered in `onCreate`, before the activity is in STARTED) and
 * forwards everything else to [AppViewModel].
 *
 * Android 15 (targetSdk 35) draws every activity edge-to-edge; we opt in
 * explicitly on all versions with [enableEdgeToEdge] and the Compose
 * surfaces pad themselves with window insets (see `AppShell`).
 */
class MainActivity : ComponentActivity() {
    private val viewModel: AppViewModel by viewModels()

    private val foregroundLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            viewModel.onPermissionsChanged()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            RoadSenseTheme {
                val state by viewModel.state.collectAsState()
                var selectedTab by remember { mutableStateOf(BottomTab.Map) }
                AppShell(
                    state = state,
                    selectedTab = selectedTab,
                    onSelectTab = { selectedTab = it },
                    onRequestForegroundPermissions = ::requestForegroundPermissions,
                    onStart = viewModel::startRecording,
                    onStop = viewModel::stopRecording,
                    onUploadNow = viewModel::enqueueDrain,
                    onReportPothole = { viewModel.reportPothole() },
                    onUndoPothole = viewModel::undoLastPothole,
                    onSubmitFeedback = viewModel::submitFeedback,
                    onDeleteLocalData = viewModel::deleteAllLocalData,
                    onClearError = viewModel::clearError,
                    onAddPrivacyZoneAtCurrentLocation = { viewModel.addPrivacyZoneAtCurrentLocation() },
                )
            }
        }
    }

    override fun onStart() {
        super.onStart()
        viewModel.startLocationUpdates()
    }

    override fun onResume() {
        super.onResume()
        viewModel.refresh()
    }

    override fun onStop() {
        viewModel.stopLocationUpdates()
        super.onStop()
    }

    private fun requestForegroundPermissions() {
        foregroundLauncher.launch(PermissionState.foregroundLadder())
    }
}
