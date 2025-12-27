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
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.ParcelUuid
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
        startScanLoop()
        startStalenessChecks()
    }

    fun stop() {
        scanJob?.cancel()
        stalenessJob?.cancel()
        stopScan()
        disconnectGatt()
    }

    fun sendCommand(command: String) {
        val characteristic = txCharacteristic ?: return
        val gatt = gatt ?: return
        val payload = command.toByteArray(Charset.forName("US-ASCII"))
        characteristic.value = payload
        gatt.writeCharacteristic(characteristic)
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
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanner.startScan(listOf(filter), settings, scanCallback)
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        bluetoothAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val device = result.device ?: return
            val name = device.name ?: ""
            if (name.contains("MySondy", ignoreCase = true)) {
                stopScan()
                connect(device)
            }
        }
    }

    @SuppressLint("MissingPermission")
    private fun connect(device: BluetoothDevice) {
        disconnectGatt()
        gatt = device.connectGatt(context, false, gattCallback)
    }

    private fun disconnectGatt() {
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
                gatt.discoverServices()
            } else {
                disconnectGatt()
            }
        }

        @SuppressLint("MissingPermission")
        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val service: BluetoothGattService = gatt.getService(SERVICE_UUID) ?: return
            rxCharacteristic = service.getCharacteristic(RX_UUID)
            txCharacteristic = service.getCharacteristic(TX_UUID)
            enableNotifications(gatt, rxCharacteristic)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic
        ) {
            if (characteristic.uuid != RX_UUID) return
            val raw = characteristic.value?.toString(Charset.forName("US-ASCII")) ?: return
            handleMessage(raw)
        }
    }

    @SuppressLint("MissingPermission")
    private fun enableNotifications(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic?) {
        characteristic ?: return
        gatt.setCharacteristicNotification(characteristic, true)
        val descriptor = characteristic.getDescriptor(CLIENT_CONFIG_UUID)
        descriptor?.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        if (descriptor != null) {
            gatt.writeDescriptor(descriptor)
        }
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
