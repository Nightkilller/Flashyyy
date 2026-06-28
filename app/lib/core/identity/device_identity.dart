/// Represents a physical device's public identity.
class DeviceIdentity {
  final String deviceId;
  final String deviceName;
  final String deviceType; // 'mobile' | 'desktop'

  const DeviceIdentity({
    required this.deviceId,
    required this.deviceName,
    required this.deviceType,
  });

  Map<String, dynamic> toJson() => {
        'deviceId': deviceId,
        'deviceName': deviceName,
        'deviceType': deviceType,
      };

  factory DeviceIdentity.fromJson(Map<String, dynamic> json) {
    return DeviceIdentity(
      deviceId: json['deviceId'] as String,
      deviceName: json['deviceName'] as String,
      deviceType: json['deviceType'] as String,
    );
  }
}
