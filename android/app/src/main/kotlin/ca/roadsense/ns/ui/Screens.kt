package ca.roadsense.ns.ui

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import ca.roadsense.ns.AppLog
import ca.roadsense.ns.api.PublicLinks
import ca.roadsense.ns.ui.map.MapHost

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppShell(
    state: HomeState,
    selectedTab: BottomTab,
    onSelectTab: (BottomTab) -> Unit,
    onRequestForegroundPermissions: () -> Unit,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onUploadNow: () -> Unit,
    onReportPothole: () -> Unit,
    onUndoPothole: () -> Unit,
    onSubmitFeedback: (category: String, message: String, replyEmail: String?, contactConsent: Boolean) -> Unit,
    onDeleteLocalData: () -> Unit,
    onClearError: () -> Unit,
    onAddPrivacyZoneAtCurrentLocation: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("RoadSense NS", fontWeight = FontWeight.Bold)
                        Text(
                            "${state.environment.name.lowercase().replaceFirstChar { it.uppercase() }} • ${state.appVersion}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                ),
            )
        },
        bottomBar = {
            BottomBar(selectedTab = selectedTab, onSelectTab = onSelectTab)
        },
    ) { padding ->
        when (selectedTab) {
            BottomTab.Map -> MapScreen(
                state = state,
                onRequestForegroundPermissions = onRequestForegroundPermissions,
                onStart = onStart,
                onStop = onStop,
                onReportPothole = onReportPothole,
                onUndoPothole = onUndoPothole,
                onUploadNow = onUploadNow,
                onClearError = onClearError,
                contentPadding = padding,
            )
            BottomTab.Stats -> StatsScreen(state = state, contentPadding = padding)
            BottomTab.Settings -> SettingsScreen(
                state = state,
                onRequestForegroundPermissions = onRequestForegroundPermissions,
                onSubmitFeedback = onSubmitFeedback,
                onDeleteLocalData = onDeleteLocalData,
                onAddPrivacyZoneAtCurrentLocation = onAddPrivacyZoneAtCurrentLocation,
                contentPadding = padding,
            )
        }
    }
}

enum class BottomTab(val label: String) {
    Map("Map"),
    Stats("Stats"),
    Settings("Settings"),
}

@Composable
private fun BottomBar(selectedTab: BottomTab, onSelectTab: (BottomTab) -> Unit) {
    // Edge-to-edge (Android 15 default): the bar's surface runs under the
    // gesture/nav bar, and its buttons sit above it.
    Surface(tonalElevation = 4.dp) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .navigationBarsPadding()
                .padding(horizontal = 8.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceEvenly,
        ) {
            BottomTab.entries.forEach { tab ->
                val selected = tab == selectedTab
                TextButton(
                    onClick = { onSelectTab(tab) },
                    colors = androidx.compose.material3.ButtonDefaults.textButtonColors(
                        contentColor = if (selected) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                    ),
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                            imageVector = when (tab) {
                                BottomTab.Map -> Icons.Filled.Map
                                BottomTab.Stats -> Icons.Filled.Bolt
                                BottomTab.Settings -> Icons.Filled.Settings
                            },
                            contentDescription = tab.label,
                        )
                        Text(tab.label, style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
        }
    }
}

@Composable
private fun MapScreen(
    state: HomeState,
    onRequestForegroundPermissions: () -> Unit,
    onStart: () -> Unit,
    onStop: () -> Unit,
    onReportPothole: () -> Unit,
    onUndoPothole: () -> Unit,
    onUploadNow: () -> Unit,
    onClearError: () -> Unit,
    contentPadding: PaddingValues,
) {
    val context = LocalContext.current
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(contentPadding)
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        if (state.lastError != null) {
            ErrorBanner(message = state.lastError, onDismiss = onClearError)
        }
        StatusCard(state = state)

        if (!state.permissions.canStartForegroundDrive) {
            PermissionsCallout(
                title = "Permissions needed",
                missing = state.permissions.missingForForeground,
                actionLabel = if (state.permissions.hasOnlyApproximateLocation) {
                    "Allow precise location"
                } else {
                    "Grant location access"
                },
                onAction = {
                    // After "approximate" was chosen, Android only offers the
                    // upgrade from Settings on some versions.
                    if (state.permissions.hasOnlyApproximateLocation) {
                        context.openAppSettings()
                    } else {
                        onRequestForegroundPermissions()
                    }
                },
            )
        }

        DriveControlCard(
            isRecording = state.isRecording,
            canStart = state.permissions.canStartForegroundDrive,
            onStart = onStart,
            onStop = onStop,
        )

        PotholeReportCard(
            location = state.lastLocation,
            pendingActionId = state.pendingActionId,
            pendingActionExpiresAt = state.pendingActionExpiresAt,
            onReport = onReportPothole,
            onUndo = onUndoPothole,
        )

        Card {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Public road-quality map", style = MaterialTheme.typography.titleMedium)
                Spacer(modifier = Modifier.height(8.dp))
                MapHost(modifier = Modifier.fillMaxWidth())
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    "Roads recently driven by RoadSense participants are scored for roughness and " +
                        "potholes. Tap below for the full interactive web map (which renders the same " +
                        "tile data and pothole layer the in-app shell will adopt natively when the " +
                        "Mapbox Android SDK is provisioned).",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(modifier = Modifier.height(12.dp))
                FilledTonalButton(
                    onClick = { context.openLink(PublicLinks.WEB_MAP) },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Open public map") }
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedButton(
                    onClick = onUploadNow,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Upload pending drives now") }
            }
        }

        QueueCountsCard(state = state)
    }
}

@Composable
private fun StatusCard(state: HomeState) {
    val statusText = if (state.isRecording) "Recording is active" else "Recording is stopped"
    val accent =
        if (state.isRecording) MaterialTheme.colorScheme.tertiary
        else MaterialTheme.colorScheme.outlineVariant
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant,
        ),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(12.dp)
                        .background(color = accent, shape = CircleShape),
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(statusText, style = MaterialTheme.typography.titleMedium)
            }
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                if (state.lastLocation != null) {
                    val l = state.lastLocation
                    "Last fix: ${"%.4f".format(l.latitude)}, ${"%.4f".format(l.longitude)} (±${"%.0f".format(l.accuracyMeters)} m)"
                } else "No GPS fix yet",
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}

@Composable
private fun PermissionsCallout(
    title: String,
    missing: List<String>,
    actionLabel: String,
    onAction: () -> Unit,
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer,
        ),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Warning, contentDescription = null)
                Spacer(modifier = Modifier.width(8.dp))
                Text(title, style = MaterialTheme.typography.titleMedium)
            }
            Spacer(modifier = Modifier.height(8.dp))
            missing.forEach { Text("• $it", style = MaterialTheme.typography.bodySmall) }
            Spacer(modifier = Modifier.height(12.dp))
            Button(onClick = onAction, modifier = Modifier.fillMaxWidth()) {
                Text(actionLabel)
            }
        }
    }
}

@Composable
private fun DriveControlCard(
    isRecording: Boolean,
    canStart: Boolean,
    onStart: () -> Unit,
    onStop: () -> Unit,
) {
    Card {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("Drive collection", style = MaterialTheme.typography.titleMedium)
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                "Tap Start before you begin driving. A notification stays up while " +
                    "recording, which continues with the screen off. The drive ends " +
                    "automatically after 5 minutes parked, or when you tap Stop.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(modifier = Modifier.height(12.dp))
            if (isRecording) {
                Button(
                    onClick = onStop,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                    ),
                ) {
                    Icon(Icons.Filled.Stop, contentDescription = null)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("Stop & upload")
                }
            } else {
                Button(
                    onClick = onStart,
                    enabled = canStart,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(if (canStart) "Start drive" else "Grant permissions to start") }
            }
        }
    }
}

@Composable
private fun PotholeReportCard(
    location: LocationSnapshot?,
    pendingActionId: java.util.UUID?,
    pendingActionExpiresAt: java.time.Instant?,
    onReport: () -> Unit,
    onUndo: () -> Unit,
) {
    Card {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("Mark a pothole", style = MaterialTheme.typography.titleMedium)
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                "Use only when stopped. Tap to log the spot you're at right now. " +
                    "Reports upload in the background once the undo window passes.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(modifier = Modifier.height(12.dp))
            Button(
                onClick = onReport,
                enabled = location != null && pendingActionId == null,
                modifier = Modifier.fillMaxWidth(),
            ) { Text(if (location == null) "Waiting for GPS" else "Mark pothole here") }

            if (pendingActionId != null) {
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedButton(
                    onClick = onUndo,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Undo last report") }
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    "You have a few seconds to undo before the report is queued for upload.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun QueueCountsCard(state: HomeState) {
    Card {
        Column(modifier = Modifier.padding(16.dp)) {
            Text("Pending uploads", style = MaterialTheme.typography.titleMedium)
            Spacer(modifier = Modifier.height(8.dp))
            QueueRow("Readings", state.pendingReadings)
            QueueRow("Pothole reports", state.pendingPotholeActions)
            QueueRow("Feedback messages", state.pendingFeedback)
        }
    }
}

@Composable
private fun QueueRow(label: String, count: Int) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Text(
            count.toString(),
            style = MaterialTheme.typography.bodyMedium,
            color = if (count > 0) MaterialTheme.colorScheme.primary
            else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun StatsScreen(state: HomeState, contentPadding: PaddingValues) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(contentPadding)
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Card {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Your contributions", style = MaterialTheme.typography.titleMedium)
                Spacer(modifier = Modifier.height(8.dp))
                StatRow("Drives", state.totalDrives.toString())
                StatRow("Pothole reports", state.totalPotholesReported.toString())
                StatRow("Uploaded readings", state.totalUploadedReadings.toString())
            }
        }
        Card {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Local pending", style = MaterialTheme.typography.titleMedium)
                Spacer(modifier = Modifier.height(8.dp))
                StatRow("Readings", state.pendingReadings.toString())
                StatRow("Pothole reports", state.pendingPotholeActions.toString())
                StatRow("Feedback messages", state.pendingFeedback.toString())
            }
        }
    }
}

@Composable
private fun StatRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium)
        Text(value, style = MaterialTheme.typography.titleSmall)
    }
}

@Composable
private fun SettingsScreen(
    state: HomeState,
    onRequestForegroundPermissions: () -> Unit,
    onSubmitFeedback: (String, String, String?, Boolean) -> Unit,
    onDeleteLocalData: () -> Unit,
    onAddPrivacyZoneAtCurrentLocation: () -> Unit,
    contentPadding: PaddingValues,
) {
    val context = LocalContext.current
    var showDeleteDialog by remember { mutableStateOf(false) }
    var feedbackCategory by remember { mutableStateOf("bug") }
    var feedbackMessage by remember { mutableStateOf("") }
    var feedbackEmail by remember { mutableStateOf("") }
    var contactConsent by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(contentPadding)
            // Keeps the feedback fields above the keyboard edge-to-edge.
            .imePadding()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Card {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Permissions", style = MaterialTheme.typography.titleMedium)
                Spacer(modifier = Modifier.height(8.dp))
                PermissionRow("Precise location", state.permissions.fineLocation)
                PermissionRow("Notifications", state.permissions.notifications)
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    "Location is used only while a drive is recording or the app is open. " +
                        "RoadSense never asks for \"Allow all the time\".",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedButton(
                    onClick = onRequestForegroundPermissions,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Request permissions") }
            }
        }

        Card {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Privacy", style = MaterialTheme.typography.titleMedium)
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    "Privacy zones drop readings inside a radius around your home or work " +
                        "before any data leaves the device. The current device has " +
                        "${state.privacyZoneCount} zone${if (state.privacyZoneCount == 1) "" else "s"} " +
                        "configured.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedButton(
                    onClick = onAddPrivacyZoneAtCurrentLocation,
                    enabled = state.lastLocation != null,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        if (state.lastLocation == null) {
                            "Waiting for GPS"
                        } else {
                            "Add privacy zone at current location"
                        },
                    )
                }
                Spacer(modifier = Modifier.height(4.dp))
                OutlinedButton(
                    onClick = { context.openAppSettings() },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Manage Android app permissions") }
                Spacer(modifier = Modifier.height(4.dp))
                TextButton(onClick = { context.openLink(PublicLinks.PRIVACY_POLICY) }) {
                    Text("View privacy policy")
                }
                TextButton(onClick = { context.openLink(PublicLinks.TERMS) }) {
                    Text("Terms of use")
                }
                TextButton(onClick = { context.openLink(PublicLinks.SUPPORT) }) {
                    Text("Support")
                }
            }
        }

        Card {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("Send feedback", style = MaterialTheme.typography.titleMedium)
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    "Feedback is queued locally and uploaded automatically when you have a network.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedTextField(
                    value = feedbackMessage,
                    onValueChange = { feedbackMessage = it },
                    label = { Text("Your message") },
                    modifier = Modifier.fillMaxWidth(),
                    minLines = 3,
                )
                Spacer(modifier = Modifier.height(4.dp))
                OutlinedTextField(
                    value = feedbackEmail,
                    onValueChange = { feedbackEmail = it },
                    label = { Text("Reply email (optional)") },
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Checkbox(checked = contactConsent, onCheckedChange = { contactConsent = it })
                    Text(
                        "OK to contact me about this report",
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                Button(
                    onClick = {
                        if (feedbackMessage.isNotBlank()) {
                            onSubmitFeedback(
                                feedbackCategory,
                                feedbackMessage,
                                feedbackEmail.ifBlank { null },
                                contactConsent,
                            )
                            feedbackMessage = ""
                            feedbackEmail = ""
                            contactConsent = false
                        }
                    },
                    enabled = feedbackMessage.isNotBlank(),
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Queue feedback for upload") }
            }
        }

        Card(
            colors = CardDefaults.cardColors(
                containerColor = MaterialTheme.colorScheme.errorContainer,
            ),
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(
                    "Delete local data",
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onErrorContainer,
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    "Removes every reading, pothole report, drive session, privacy zone, " +
                        "feedback message, and rotates the device token. Server-side aggregate " +
                        "data is anonymous and cannot be paired back to a deleted token.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onErrorContainer,
                )
                Spacer(modifier = Modifier.height(8.dp))
                Button(
                    onClick = { showDeleteDialog = true },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Delete all local data") }
            }
        }

        HorizontalDivider()
        Text(
            "RoadSense NS ${state.appVersion} • ${state.environment.name.lowercase()}",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }

    if (showDeleteDialog) {
        AlertDialog(
            onDismissRequest = { showDeleteDialog = false },
            title = { Text("Delete all local data?") },
            text = {
                Text(
                    "This stops any active drive and erases every reading, pothole report, " +
                        "drive session, and queued feedback message stored on this device.",
                )
            },
            confirmButton = {
                Button(
                    onClick = {
                        showDeleteDialog = false
                        onDeleteLocalData()
                    },
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.error,
                    ),
                ) { Text("Delete") }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteDialog = false }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun PermissionRow(label: String, granted: Boolean) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = if (granted) Icons.Filled.CheckCircle else Icons.Filled.Warning,
            contentDescription = null,
            tint = if (granted) Color(0xFF1E8E3E) else MaterialTheme.colorScheme.error,
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Text(
            text = if (granted) "Granted" else "Missing",
            style = MaterialTheme.typography.labelSmall,
            color = if (granted) MaterialTheme.colorScheme.onSurfaceVariant
            else MaterialTheme.colorScheme.error,
        )
    }
}

@Composable
private fun ErrorBanner(message: String, onDismiss: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.errorContainer,
        shape = RoundedCornerShape(8.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Warning, contentDescription = null, tint = MaterialTheme.colorScheme.onErrorContainer)
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                message,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onErrorContainer,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = onDismiss) { Text("Dismiss") }
        }
    }
}

/** Opens [url] in the user's browser; a device with no browser logs and no-ops. */
private fun android.content.Context.openLink(url: String) {
    try {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
    } catch (e: android.content.ActivityNotFoundException) {
        AppLog.warn("no activity can open a web link", e)
    }
}

private fun android.content.Context.openAppSettings() {
    try {
        startActivity(
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null),
            ),
        )
    } catch (e: android.content.ActivityNotFoundException) {
        AppLog.warn("app settings screen unavailable", e)
    }
}
