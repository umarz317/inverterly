package com.loopbreak.inverterly.core

import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant

/** A cloud that answers from a script and remembers every URL it was asked for. */
private class FakeCloud(private val answers: (String) -> String) : HttpTransport {
    val urls = ArrayList<String>()
    override suspend fun get(url: String): Pair<Int, String> {
        urls += url
        return 200 to answers(url)
    }
}

class ClientTest {
    private val clock = { Instant.parse("2026-10-13T12:00:00Z") }
    private val login = """{"err":0,"desc":"ERR_NONE","dat":{"secret":"s3cret","token":"t0ken","expire":3600}}"""

    private fun client(cloud: FakeCloud) =
        DessMonitorClient(CloudProfile.Dessmonitor, "me@example.com", "correct horse", SessionStore.MemoryOnly, cloud, clock)

    @Test fun everyWriteActionIsRefusedBeforeAnythingIsSent() = runBlocking {
        val cloud = FakeCloud { login }
        val client = client(cloud)
        val refused = listOf(
            "ctrlDevice&pn=W0&devcode=2452&devaddr=1&sn=0&id=bat_charging_current&val=10",
            "queryDeviceCtrlField&pn=W0", "queryDeviceCtrlValue&pn=W0", "editPlant&pid=1&name=x", "updatePassword&newpwd=x",
            "authSource&usr=x", "", "&", "QUERYPLANTS", "queryPlants2", " queryPlants", "queryPlants ",
            "queryPlants&action=ctrlDevice&id=x&val=1", "queryPlants&page=0&ACTION=ctrlDevice", "queryPlants&sign=abc",
            "queryPlants&page=0&x=a b", "queryPlants&=1", "queryPlants&page",
        )
        for (action in refused) {
            try {
                client.request(action)
                throw AssertionError("should have been refused: $action")
            } catch (e: DessMonitorError) { /* refused */ }
        }
        assertEquals("not even a login", emptyList<String>(), cloud.urls)
    }

    @Test fun loginThenSignedRequest() = runBlocking {
        val cloud = FakeCloud { url -> if ("authSource" in url) login else """{"err":0,"dat":{"plant":[]}}""" }
        val dat = client(cloud).request("queryPlants&page=0&pagesize=20&i18n=en_US")
        assertTrue(dat is kotlinx.serialization.json.JsonObject)
        assertEquals(2, cloud.urls.size)
        val salt = Regex("salt=(\\d+)").find(cloud.urls[1])!!.groupValues[1]
        assertEquals(clock().toEpochMilli().toString(), salt)
        assertTrue("token=t0ken" in cloud.urls[1])
        val expected = DessSigning.requestSign("s3cret", "t0ken", "queryPlants&page=0&pagesize=20&i18n=en_US", salt)
        assertTrue("sign=$expected" in cloud.urls[1])
    }

    @Test fun aRefusedLoginIsNotRepeatedStraightAway() = runBlocking {
        val cloud = FakeCloud { """{"err":1,"desc":"ERR_PASSWORD_VERIF_FAIL"}""" }
        val client = client(cloud)
        repeat(3) {
            try {
                client.request("queryPlants&page=0")
                throw AssertionError("login should fail")
            } catch (e: DessMonitorError.LoginRejected) { assertTrue(e.isAuthFailure.not()) }
        }
        assertEquals("one attempt, then the backoff holds the rest", 1, cloud.urls.size)
    }

    @Test fun theErrorNeverCarriesThePasswordOrTheUrl() = runBlocking {
        val cloud = FakeCloud { """{"err":1,"desc":"bad correct horse at https://web.dessmonitor.com/x?token=1"}""" }
        try {
            client(cloud).request("queryPlants&page=0")
            throw AssertionError("login should fail")
        } catch (e: DessMonitorError.LoginRejected) {
            assertTrue(e.message, "correct horse" !in e.message.orEmpty() && "https" !in e.message.orEmpty())
        }
        Unit
    }

    @Test fun noControlActionNameAppearsInTheSources() {
        val sources = File("src/main/kotlin").walkTopDown().filter { it.extension == "kt" }.toList()
        assertTrue("sources not found from ${File(".").absolutePath}", sources.isNotEmpty())
        for (file in sources) {
            val text = file.readText().lowercase()
            for (word in listOf("ctrl", "senddevicecmd", "sendcmdtodevice", "editdeviceinfo", "updatepassword")) {
                assertTrue("${file.name} mentions $word", word !in text)
            }
        }
    }

    @Test fun theAllowListIsExactlyTheEightQueries() {
        assertEquals(setOf("webQueryDeviceEs", "queryDevices", "queryDeviceLastData", "queryDeviceWarning", "queryPlants",
            "webQueryCollectorsEs", "queryDeviceDataOneDay", "webQueryDeviceEnergyFlowEs"), DessReadOnly.actions)
    }
}
