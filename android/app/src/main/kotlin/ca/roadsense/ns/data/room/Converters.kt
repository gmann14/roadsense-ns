package ca.roadsense.ns.data.room

import androidx.room.TypeConverter
import java.time.Instant
import java.util.UUID

/**
 * Type converters used across every entity. We store:
 * - `UUID` as TEXT (lowercase), matching the wire format. Always lowercased
 *   on write so equality joins against server-returned ids work without case
 *   surprises.
 * - `Instant` as INTEGER epoch-millis. Preserves ordering, indexes well, and
 *   doesn't lose precision on round-trip.
 */
class Converters {
    @TypeConverter
    fun uuidToString(value: UUID?): String? = value?.toString()?.lowercase()

    @TypeConverter
    fun stringToUuid(value: String?): UUID? = value?.let(UUID::fromString)

    @TypeConverter
    fun instantToEpochMillis(value: Instant?): Long? = value?.toEpochMilli()

    @TypeConverter
    fun epochMillisToInstant(value: Long?): Instant? = value?.let(Instant::ofEpochMilli)

    @TypeConverter
    fun uploadBatchStateToString(value: UploadBatchState?): String? = value?.name

    @TypeConverter
    fun stringToUploadBatchState(value: String?): UploadBatchState? =
        value?.let(UploadBatchState::valueOf)
}
