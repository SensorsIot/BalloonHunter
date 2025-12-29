package com.balloonhunter.app.data.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.Intent
import android.util.Log
import com.balloonhunter.app.domain.models.BLEConnectionState
import com.balloonhunter.app.domain.models.PositionData
import com.balloonhunter.app.domain.models.RadioChannelData
import com.balloonhunter.app.domain.models.SettingsData
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.nio.charset.Charset
import java.time.Duration
import java.time.Instant
import java.util.UUID

class BleService(
    private val context: Context,
    private val scope: CoroutineScope
) {
    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("53797269-614D-6972-6B6F-44616C6D6F6E")
        val TX_UUID: UUID = UUID.fromString("53797268-614D-6972-6B6F-44616C6D6F7E")
        val RX_UUID: UUID = UUID.fromString("53797267-614D-6972-6B6F-44616C6D6F8E")
        private val CLIENT_CONFIG_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        private const val TAG = "BleService"
    }

    private val bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter
    private var gatt: BluetoothGatt? = null
    private var rxCharacteristic: BluetoothGattCharacteristic? = null
    private var txCharacteristic: BluetoothGattCharacteristic? = null

    private val parser = BlePacketParser()
    private val afcSmoother = BleAfcSmoother()

    private var scanJob: Job? = null
    private var stalenessJob: Job? = null
    private var lastType1Timestamp: Instant? = null
    private var lastMessageTimestamp: Instant? = null

    private val _connectionState = MutableStateFlow(BLEConnectionState.NOT_CONNECTED)
    val connectionState: StateFlow<BLEConnectionState> = _connectionState.asStateFlow()

    val positionUpdates = MutableSharedFlow<PositionData>(extraBufferCapacity = 16)
    val radioUpdates = MutableSharedFlow<RadioChannelData>(extraBufferCapacity = 16)
    val settingsUpdates = MutableSharedFlow<SettingsData>(extraBufferCapacity = 4)
    val afcUpdates = MutableSharedFlow<AfcData>(extraBufferCapacity = 16)

    fun start() {
        if (bluetoothAdapter?.isEnabled == false) {
            val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
            enableBtIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(enableBtIntent)
        }
        startScanLoop()
        startStalenessChecks()
    }

    fun stop() {
        scanJob?.cancel()
        stalenessJob?.cancel()
        stopScan()
        disconnectGatt()
    }

    @SuppressLint("MissingPermission")
    fun resetConnection() {
        Log.d(TAG, "Resetting BLE connection")
        stopScan()
        disconnectGatt()
        gatt?.let { g ->
            try {
                val refresh = g.javaClass.getMethod("refresh")
                refresh.invoke(g)
            } catch (_: Exception) { }
        }
        scope.launch {
            delay(500)
            startScanLoop()
        }
    }

    @SuppressLint("MissingPermission")
    fun sendCommand(command: String) {
        val characteristic = txCharacteristic ?: return
        val g = gatt ?: return
        val payload = command.toByteArray(Charset.forName("US-ASCII"))
        characteristic.value = payload
        g.writeCharacteristic(characteristic)
    }

    fun requestSettings() {
        sendCommand("o{?}o")
    }

    fun setFrequency(frequency: Double, probeType: String) {
        val formatted = String.format("%.2f", frequency)
        // Convert probe type name to command value: RS41=1, M20=2, M10=3, PILOT=4, DFM=5
        val tipoValue = when (probeType.uppercase()) {
            "RS41" -> 1
            "M20" -> 2
            "M10" -> 3
            "PILOT" -> 4
            "DFM" -> 5
            else -> 1
        }
        sendCommand("o{f=$formatted/tipo=$tipoValue}o")
    }

    fun setMute(muted: Boolean) {
        sendCommand("o{mute=${if (muted) 1 else 0}}o")
    }

    fun sendSettings(settings: Map<String, Any>) {
        val pairs = settings.entries.joinToString("/") { "${it.key}=${it.value}" }
        sendCommand("o{$pairs}o")
    }

    fun setOLEDPins(sda: Int, scl: Int, rst: Int) {
        sendSettings(mapOf("oled_sda" to sda, "oled_scl" to scl, "oled_rst" to rst))
    }

    fun setLEDPin(pin: Int) {
        sendSettings(mapOf("led_pout" to pin))
    }

    fun setBuzzerPin(pin: Int) {
        sendSettings(mapOf("buz_pin" to pin))
    }

    fun setBatterySettings(pin: Int, minVoltage: Int, maxVoltage: Int, dischargeType: Int) {
        sendSettings(mapOf(
            "battery" to pin,
            "vBatMin" to minVoltage,
            "vBatMax" to maxVoltage,
            "vBatType" to dischargeType
        ))
    }

    fun setCallSign(callSign: String) {
        sendSettings(mapOf("myCall" to callSign))
    }

    fun setRXBandwidth(rs41: Int?, m20: Int?, m10: Int?, pilot: Int?, dfm: Int?) {
        val settings = mutableMapOf<String, Any>()
        rs41?.let { settings["rs41.rxbw"] = it }
        m20?.let { settings["m20.rxbw"] = it }
        m10?.let { settings["m10.rxbw"] = it }
        pilot?.let { settings["pilot.rxbw"] = it }
        dfm?.let { settings["dfm.rxbw"] = it }
        if (settings.isNotEmpty()) sendSettings(settings)
    }

    fun setLCDDriver(type: Int) {
        sendSettings(mapOf("lcd" to type))
    }

    fun setLCDOn(enabled: Boolean) {
        sendSettings(mapOf("lcdOn" to if (enabled) 1 else 0))
    }

    fun setBluetooth(enabled: Boolean) {
        sendSettings(mapOf("blu" to if (enabled) 1 else 0))
    }

    fun setSerialBaudRate(rate: Int) {
        sendSettings(mapOf("baud" to rate))
    }

    fun setSerialPort(port: Int) {
        sendSettings(mapOf("com" to port))
    }

    fun setNameType(type: Int) {
        sendSettings(mapOf("aprsName" to type))
    }

    @SuppressLint("MissingPermission")
    private fun startScanLoop() {
        scanJob?.cancel()
        scanJob = scope.launch(Dispatchers.Default) {
            while (true) {
                if (gatt == null) {
                    startScan()
                    delay(5000)
                    stopScan()
                    delay(10000)
                } else {
                    delay(2000)
                }
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun startScan() {
        val adapter = bluetoothAdapter ?: return
        val scanner = adapter.bluetoothLeScanner ?: return
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanner.startScan(null, settings, scanCallback)
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        bluetoothAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
    }

    @Volatile
    private var isConnecting = false

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (isConnecting || gatt != null) return

            val device = result.device ?: return
            val name = device.name ?: ""

            if (name.contains("MySondyGO", ignoreCase = true)) {
                Log.i(TAG, "Found MySondyGO: ${device.address}")
                isConnecting = true
                stopScan()
                connect(device)
            }
        }

        override fun onScanFailed(errorCode: Int) {
            Log.e(TAG, "Scan failed: $errorCode")
        }
    }

    @SuppressLint("MissingPermission")
    private fun connect(device: BluetoothDevice) {
        gatt = device.connectGatt(context, false, gattCallback)
    }

    private fun disconnectGatt() {
        isConnecting = false
        gatt?.close()
        gatt = null
        rxCharacteristic = null
        txCharacteristic = null
        _connectionState.value = BLEConnectionState.NOT_CONNECTED
        lastType1Timestamp = null
        lastMessageTimestamp = null
        afcSmoother.reset()
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothGatt.STATE_CONNECTED) {
                Log.i(TAG, "Connected to MySondyGO")
                gatt.requestMtu(512)
            } else {
                Log.i(TAG, "Disconnected from MySondyGO")
                disconnectGatt()
            }
        }

        @SuppressLint("MissingPermission")
        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            gatt.discoverServices()
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Service discovery failed")
                return
            }

            val service: BluetoothGattService? = gatt.getService(SERVICE_UUID)
            if (service == null) {
                Log.e(TAG, "MySondyGO service not found")
                return
            }

            rxCharacteristic = service.getCharacteristic(RX_UUID)
            txCharacteristic = service.getCharacteristic(TX_UUID)
            enableNotifications(gatt, rxCharacteristic)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray
        ) {
            if (characteristic.uuid != RX_UUID) return
            val raw = value.toString(Charset.forName("US-ASCII"))
            handleMessage(raw)
        }

        @Deprecated("Deprecated in Java")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            val value = characteristic.value ?: return
            if (characteristic.uuid != RX_UUID) return
            val raw = value.toString(Charset.forName("US-ASCII"))
            handleMessage(raw)
        }

        @SuppressLint("MissingPermission")
        override fun onDescriptorWrite(gatt: BluetoothGatt?, descriptor: BluetoothGattDescriptor?, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) {
                Log.e(TAG, "Failed to enable notifications")
            }
        }

        @SuppressLint("MissingPermission")
        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int
        ) {
            // Not used
        }
    }

    @SuppressLint("MissingPermission")
    private fun enableNotifications(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic?) {
        if (characteristic == null) {
            Log.e(TAG, "RX characteristic not found")
            return
        }

        gatt.setCharacteristicNotification(characteristic, true)

        val descriptor = characteristic.getDescriptor(CLIENT_CONFIG_UUID)
        if (descriptor == null) {
            Log.e(TAG, "CCCD descriptor not found")
            return
        }

        descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        gatt.writeDescriptor(descriptor)
    }

    private fun handleMessage(raw: String) {
        val now = Instant.now()
        lastMessageTimestamp = now

        when (val parsed = parser.parse(raw, now)) {
            is BleParsedResult.Position -> {
                lastType1Timestamp = now
                _connectionState.value = BLEConnectionState.DATA_READY
                positionUpdates.tryEmit(parsed.position)
                radioUpdates.tryEmit(parsed.radio)
                val afc = afcSmoother.add(parsed.radio.afcFrequency)
                afcUpdates.tryEmit(afc)
            }
            is BleParsedResult.Radio -> {
                if (_connectionState.value == BLEConnectionState.NOT_CONNECTED) {
                    _connectionState.value = BLEConnectionState.READY_FOR_COMMANDS
                }
                radioUpdates.tryEmit(parsed.radio)
                val afc = afcSmoother.add(parsed.radio.afcFrequency)
                afcUpdates.tryEmit(afc)
            }
            is BleParsedResult.Settings -> settingsUpdates.tryEmit(parsed.settings)
            BleParsedResult.Invalid -> Unit
        }

        if (_connectionState.value == BLEConnectionState.NOT_CONNECTED) {
            _connectionState.value = BLEConnectionState.READY_FOR_COMMANDS
        }
    }

    private fun startStalenessChecks() {
        stalenessJob?.cancel()
        stalenessJob = scope.launch(Dispatchers.Default) {
            while (true) {
                delay(3000)
                val lastType1 = lastType1Timestamp
                val state = _connectionState.value
                if (state == BLEConnectionState.DATA_READY && lastType1 != null) {
                    val since = Duration.between(lastType1, Instant.now()).seconds
                    if (since > 30) {
                        _connectionState.value = BLEConnectionState.READY_FOR_COMMANDS
                    }
                }
            }
        }
    }

    fun downgradeIfType1Missing(timeoutSeconds: Long = 10) {
        val lastType1 = lastType1Timestamp ?: return
        if (Duration.between(lastType1, Instant.now()).seconds > timeoutSeconds) {
            if (_connectionState.value == BLEConnectionState.DATA_READY) {
                _connectionState.value = BLEConnectionState.READY_FOR_COMMANDS
            }
        }
    }
}
