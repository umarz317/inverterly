package com.loopbreak.inverterly.core

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant

/** Answers by action, and counts every URL it was asked for. */
private class DayCloud(private val noRecordFor: String? = null) : HttpTransport {
    val urls = ArrayList<String>()
    override suspend fun get(url: String): Pair<Int, String> {
        urls += url
        val action = Regex("action=([A-Za-z]+)").find(url)?.groupValues?.get(1)
        return 200 to when {
            action == "authSource" -> """{"err":0,"desc":"ERR_NONE","dat":{"secret":"s3cret","token":"t0ken","expire":3600}}"""
            action == "webQueryDeviceEs" -> """{"err":0,"dat":{"device":${Fixtures.devicesEs}}}"""
            action == "queryDeviceDataOneDay" && noRecordFor != null && "date=$noRecordFor" in url -> """{"err":12,"desc":"ERR_NO_RECORD"}"""
            action == "queryDeviceDataOneDay" -> """{"err":0,"dat":{"title":[{"title":"Timestamp"},{"title":"PV1 Input Power"},{"title":"AC output active power"}],
                "row":[{"field":["2026-10-12 12:00:00","3000","1000"]},{"field":["2026-10-12 12:05:00","3000","1000"]}]}}"""
            else -> """{"err":12,"desc":"ERR_NO_RECORD"}"""
        }
    }
    fun count(action: String) = urls.count { "action=$action" in it }
}

class HistoryTest {
    private val clock = { Instant.parse("2026-10-13T12:00:00Z") }
    private val config = InverterConfig(CloudProfile.Dessmonitor, "me@example.com", "correct horse")
    private val file = File(Files.createTempDirectory("history").toFile(), "history.json")

    private fun service(cloud: DayCloud) = InverterService({ config }, SessionStore.MemoryOnly, HistoryStore(file), cloud, clock)

    @Test fun aSavedDayNeedsNoNetworkOnTheNextLaunch() = runBlocking {
        val cloud = DayCloud()
        val read = service(cloud).fetchDayTotals("2026-10-12")
        assertEquals(true, read?.complete)
        delay(1300)   // the save waits for reads to settle

        val before = cloud.urls.size
        val next = service(cloud)
        next.selectDevice("00000000000000")
        assertEquals(read, next.fetchDayTotals("2026-10-12"))
        assertEquals("no login, no device list, no day request", before, cloud.urls.size)
    }

    @Test fun aDayWithNoReportsIsNotAskedForAgain() = runBlocking {
        val cloud = DayCloud(noRecordFor = "2026-09-01")
        assertNull(service(cloud).fetchDayTotals("2026-09-01"))
        delay(1300)

        val next = service(cloud)
        next.selectDevice("00000000000000")
        assertNull(next.fetchDayTotals("2026-09-01"))
        assertEquals("the empty day was remembered across launches", 1, cloud.count("queryDeviceDataOneDay"))
    }

    @Test fun theDayStillGoingIsReadAgain() = runBlocking {
        val cloud = DayCloud()
        val service = service(cloud)
        service.fetchDayTotals("2026-10-13")
        service.fetchDayTotals("2026-10-13")
        assertEquals(2, cloud.count("queryDeviceDataOneDay"))
    }
}
