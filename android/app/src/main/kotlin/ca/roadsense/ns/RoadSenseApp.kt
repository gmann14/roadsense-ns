package ca.roadsense.ns

import android.app.Application

/**
 * Application entry point. A12-2b is intentionally empty — wire up the
 * collection service container, work scheduling, and Sentry init in A12-3.
 */
class RoadSenseApp : Application()
