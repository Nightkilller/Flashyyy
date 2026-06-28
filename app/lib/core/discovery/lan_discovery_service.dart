import 'dart:async';
import 'dart:convert';
import 'dart:io';

class LanDevice {
  final String deviceId;
  final String deviceName;
  final String ipAddress;
  final int port;
  final DateTime lastSeen;

  LanDevice({
    required this.deviceId,
    required this.deviceName,
    required this.ipAddress,
    required this.port,
    required this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'port': port,
      };

  factory LanDevice.fromJson(Map<String, dynamic> json, String ipAddress) {
    return LanDevice(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String,
      ipAddress: ipAddress,
      port: json['port'] as int,
      lastSeen: DateTime.now(),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LanDevice &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId;

  @override
  int get hashCode => deviceId.hashCode;
}

/// Discovers peer devices on the same local network using a UDP Multicast Beacon.
///
/// This pure Dart approach is extremely reliable across all platforms (Android,
/// iOS, macOS, Windows, Linux) and does not suffer from platform-specific mDNS bugs.
class LanDiscoveryService {
  static const String _multicastAddress = '224.0.2.51'; // standard private multicast range
  static const int _multicastPort = 8888;

  RawDatagramSocket? _socket;
  Timer? _beaconTimer;
  bool _isAdvertising = false;
  bool _isListening = false;

  final StreamController<List<LanDevice>> _devicesController =
      StreamController<List<LanDevice>>.broadcast();
  final Map<String, LanDevice> _discoveredDevices = {};
  Timer? _pruneTimer;

  /// Exposes a stream of currently active devices on the local network.
  Stream<List<LanDevice>> get discoveredDevices => _devicesController.stream;

  /// List of current discovered devices.
  List<LanDevice> get currentDevices => _discoveredDevices.values.toList();

  /// Starts broadcasting this device's presence and listening to other peers on the LAN.
  Future<void> start({
    required String deviceId,
    required String deviceName,
    required int port,
  }) async {
    if (_socket != null) await stop();

    try {
      // Bind to multicast port
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _multicastPort,
        reuseAddress: true,
        reusePort: true,
      );

      _socket!.multicastLoopback = true;
      try {
        _socket!.joinMulticast(InternetAddress(_multicastAddress));
      } catch (_) {
        // Fallback if network interface doesn't support multicast directly
      }

      _isListening = true;
      _isAdvertising = true;

      // Start listening for UDP beacons
      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _socket!.receive();
          if (datagram != null) {
            _handleIncomingBeacon(datagram, deviceId);
          }
        }
      });

      // Start sending periodic beacons every 2 seconds
      final beaconPayload = utf8.encode(jsonEncode({
        'deviceId': deviceId,
        'deviceName': deviceName,
        'port': port,
      }));

      _beaconTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
        if (_socket != null && _isAdvertising) {
          _socket!.send(
            beaconPayload,
            InternetAddress(_multicastAddress),
            _multicastPort,
          );
        }
      });

      // Prune inactive devices (last seen > 8 seconds ago)
      _pruneTimer = Timer.periodic(const Duration(seconds: 4), (timer) {
        final now = DateTime.now();
        final beforeCount = _discoveredDevices.length;
        
        _discoveredDevices.removeWhere((id, device) =>
            now.difference(device.lastSeen) > const Duration(seconds: 8));

        if (_discoveredDevices.length != beforeCount && !_devicesController.isClosed) {
          _devicesController.add(currentDevices);
        }
      });
    } catch (e) {
      // Bind or socket error
      await stop();
      rethrow;
    }
  }

  void _handleIncomingBeacon(Datagram datagram, String ownDeviceId) {
    try {
      final message = utf8.decode(datagram.data);
      final json = jsonDecode(message) as Map<String, dynamic>;
      
      final deviceId = json['deviceId'] as String;
      // Skip self
      if (deviceId == ownDeviceId) return;

      final ipAddress = datagram.address.address;
      final device = LanDevice.fromJson(json, ipAddress);

      _discoveredDevices[deviceId] = device;
      
      if (!_devicesController.isClosed) {
        _devicesController.add(currentDevices);
      }
    } catch (_) {
      // Fail silently for malformed datagrams
    }
  }

  /// Stops advertising and listening.
  Future<void> stop() async {
    _isAdvertising = false;
    _isListening = false;
    _beaconTimer?.cancel();
    _beaconTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;

    _socket?.close();
    _socket = null;
    _discoveredDevices.clear();
  }

  void dispose() {
    stop();
    _devicesController.close();
  }
}
