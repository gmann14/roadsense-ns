package ca.roadsense.ns

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
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
 * Compose-hosted launcher activity. Owns the permission launchers (which
 * MUST be registered in `onCreate`, before the activity is in STARTED) and
 * forwards everything else to [AppViewModel].
 */
class MainActivity : ComponentActivity() {
    private val viewModel: AppViewModel by viewModels()

    private val foregroundLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            viewModel.onPermissionsChanged()
        }

    private val backgroundLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            viewModel.onPermissionsChanged()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
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
                    onRequestBackgroundPermission = ::requestBackgroundPermission,
                    onStart = viewModel::startRecording,
                    onStop = viewModel::stopRecording,
                    onUploadNow = viewModel::enqueueDrain,
                    onReportPothole = { viewModel.reportPothole() },
                    onUndoPothole = viewModel::undoLastPothole,
                    onSubmitFeedback = viewModel::submitFeedback,
                    onDeleteLocalData = viewModel::deleteAllLocalData,
                    onClearError = viewModel::clearError,
                )
            }
        }
    }

    override fun onResume() {
        super.onResume()
        viewModel.refresh()
    }

    private fun requestForegroundPermissions() {
        val ladder = PermissionState.foregroundLadder()
        if (ladder.isEmpty()) {
            viewModel.onPermissionsChanged()
            return
        }
        foregroundLauncher.launch(ladder)
    }

    private fun requestBackgroundPermission() {
        val permission = PermissionState.backgroundLocationPermission() ?: return
        if (PermissionState.mustRouteBackgroundToSettings()) {
            startActivity(
                Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null),
                ),
            )
        } else {
            backgroundLauncher.launch(permission)
        }
    }
}
