package ca.roadsense.ns.collection

import ca.roadsense.ns.sensor.MotionVector3
import org.junit.Test
import kotlin.test.assertEquals

class SensorBridgeTest {
    @Test
    fun `pairs latest gravity with linear acceleration`() {
        val bridge = SensorBridge()
        bridge.ingestGravity(MotionVector3(0.0, 0.0, 1.0))
        val sample = bridge.ingestLinearAcceleration(
            userAcceleration = MotionVector3(0.1, 0.2, 0.3),
            timestampEpochSeconds = 100.5,
        )
        assertEquals(100.5, sample.timestamp)
        assertEquals(MotionVector3(0.1, 0.2, 0.3), sample.userAcceleration)
        assertEquals(MotionVector3(0.0, 0.0, 1.0), sample.gravity)
    }

    @Test
    fun `subsequent gravity ingest replaces stored vector`() {
        val bridge = SensorBridge()
        bridge.ingestGravity(MotionVector3(0.0, 0.0, 1.0))
        bridge.ingestGravity(MotionVector3(0.0, 0.5, 0.866))
        val sample = bridge.ingestLinearAcceleration(
            userAcceleration = MotionVector3(0.0, 0.0, 0.0),
            timestampEpochSeconds = 0.0,
        )
        assertEquals(MotionVector3(0.0, 0.5, 0.866), sample.gravity)
    }

    @Test
    fun `defaults to upright gravity when nothing has been ingested`() {
        val bridge = SensorBridge()
        val sample = bridge.ingestLinearAcceleration(
            userAcceleration = MotionVector3(0.0, 0.0, 0.0),
            timestampEpochSeconds = 0.0,
        )
        assertEquals(MotionVector3(0.0, 0.0, 1.0), sample.gravity)
    }
}
