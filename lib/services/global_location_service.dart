import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/bus_model.dart';
import 'notification_service.dart';
import 'route_service.dart';

/// Global service สำหรับ location tracking และแจ้งเตือนรถใกล้ถึง
/// ทำงานตลอดเวลาไม่ว่าจะอยู่หน้าไหนก็ตาม
class GlobalLocationService extends ChangeNotifier {
  static final GlobalLocationService _instance =
      GlobalLocationService._internal();
  factory GlobalLocationService() => _instance;
  GlobalLocationService._internal();

  // State
  LatLng? _userPosition;
  List<Bus> _buses = [];
  Bus? _closestBus;
  List<Map<String, dynamic>> _allBusStops = [];
  bool _notifyEnabled = false;
  String? _selectedNotifyRouteId;
  bool _hasAlerted = false;
  bool _isInitialized = false;

  // Subscriptions
  StreamSubscription? _busSubscription;
  StreamSubscription<Position>? _positionSubscription;

  // Constants
  static const double _alertDistanceMeters =
      500.0; // แจ้งเตือนเมื่อรถอยู่ห่าง 500m
  static const double _stopProximityMeters = 50.0;

  // Getters
  LatLng? get userPosition => _userPosition;
  List<Bus> get buses => _buses;
  Bus? get closestBus => _closestBus;
  List<Map<String, dynamic>> get allBusStops => _allBusStops;
  bool get notifyEnabled => _notifyEnabled;
  String? get selectedNotifyRouteId => _selectedNotifyRouteId;
  bool get isInitialized => _isInitialized;

  /// เริ่มต้น service (เรียกครั้งเดียวตอน app start)
  Future<void> initialize() async {
    if (_isInitialized) return;

    debugPrint("🚀 [GlobalLocationService] Initializing...");

    await NotificationService.initialize();
    await _fetchBusStops();
    _listenToBusLocation();
    await _startLocationTracking();

    _isInitialized = true;
    debugPrint("✅ [GlobalLocationService] Initialized successfully");
  }

  /// เปิด/ปิดการแจ้งเตือน
  void setNotifyEnabled(bool enabled, {String? routeId}) {
    _notifyEnabled = enabled;
    _selectedNotifyRouteId = routeId;
    _hasAlerted = false; // reset เพื่อให้แจ้งเตือนใหม่ได้
    notifyListeners();
    debugPrint(
      "🔔 [GlobalLocationService] Notify enabled: $enabled, routeId: $routeId",
    );
  }

  /// ดึงข้อมูลป้ายรถจาก Firestore
  Future<void> _fetchBusStops() async {
    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('Bus stop')
          .get();
      _allBusStops = snapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          'name': data['name'],
          'lat': double.tryParse(data['lat'].toString()) ?? 0.0,
          'long': double.tryParse(data['long'].toString()) ?? 0.0,
          'route_id': data['route_id'],
        };
      }).toList();

      debugPrint(
        "🚏 [GlobalLocationService] Fetched ${_allBusStops.length} bus stops",
      );
      notifyListeners();
    } catch (e) {
      debugPrint("❌ [GlobalLocationService] Error fetching bus stops: $e");
    }
  }

  /// ฟังตำแหน่งรถจาก Firebase Realtime Database
  void _listenToBusLocation() {
    final gpsRef = FirebaseDatabase.instance.ref("GPS");
    _busSubscription = gpsRef.onValue.listen((event) {
      final data = event.snapshot.value;
      if (data == null) return;

      List<Bus> newBuses = [];

      if (data is Map) {
        data.forEach((key, value) {
          if (value is Map &&
              value.containsKey('lat') &&
              value.containsKey('lng')) {
            try {
              newBuses.add(Bus.fromFirebase(key.toString(), value));
            } catch (e) {
              debugPrint('Error parsing bus $key: $e');
            }
          }
        });

        if (newBuses.isEmpty &&
            data.containsKey('lat') &&
            data.containsKey('lng')) {
          newBuses.add(Bus.fromFirebase('bus_1', data));
        }
      }

      _buses = newBuses;
      _updateClosestBus();
      notifyListeners();
    });
  }

  /// เริ่มติดตามตำแหน่งผู้ใช้
  Future<void> _startLocationTracking() async {
    debugPrint("📡 [GlobalLocationService] Starting location tracking...");

    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint("❌ [GlobalLocationService] Location service is DISABLED!");
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        debugPrint("❌ [GlobalLocationService] Permission DENIED!");
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      debugPrint("❌ [GlobalLocationService] Permission DENIED FOREVER!");
      return;
    }

    _positionSubscription =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          ),
        ).listen(
          (Position position) {
            _userPosition = LatLng(position.latitude, position.longitude);
            _updateClosestBus();
            notifyListeners();
          },
          onError: (e) {
            debugPrint("❌ [GlobalLocationService] Location Stream Error: $e");
            // Handle error gracefully, maybe disable tracking
          },
        );
  }

  /// คำนวณรถที่ใกล้ที่สุดและแจ้งเตือน
  Future<void> _updateClosestBus() async {
    if (_buses.isEmpty || _userPosition == null) return;

    final Distance distance = const Distance();
    List<Bus> busesWithDistance = [];

    for (final bus in _buses) {
      double? roadDist = await RouteService.getRoadDistance(
        _userPosition!,
        bus.position,
      );
      double dist =
          roadDist ??
          distance.as(LengthUnit.Meter, _userPosition!, bus.position);
      busesWithDistance.add(bus.copyWithDistance(dist));
    }

    busesWithDistance.sort(
      (a, b) => (a.distanceToUser ?? double.infinity).compareTo(
        b.distanceToUser ?? double.infinity,
      ),
    );

    _buses = busesWithDistance;
    _closestBus = busesWithDistance.isNotEmpty ? busesWithDistance.first : null;

    // แจ้งเตือนถ้าเปิดไว้
    if (_notifyEnabled) {
      Bus? targetBus;
      if (_selectedNotifyRouteId == null) {
        targetBus = _closestBus;
      } else {
        final filteredBuses = busesWithDistance
            .where((b) => b.routeId == _selectedNotifyRouteId)
            .toList();
        targetBus = filteredBuses.isNotEmpty ? filteredBuses.first : null;
      }

      if (targetBus != null) {
        final targetDist = targetBus.distanceToUser ?? double.infinity;
        if (targetDist <= _alertDistanceMeters && !_hasAlerted) {
          _hasAlerted = true;
          // คำนวณ ETA (ความเร็วเฉลี่ย 35 km/h)
          final etaSeconds = NotificationService.calculateEtaSeconds(
            targetDist,
          );
          await NotificationService.alertBusNearby(
            busName: targetBus.name,
            distanceMeters: targetDist,
            etaSeconds: etaSeconds,
          );
          debugPrint(
            "🔔 [GlobalLocationService] Alert sent! Bus: ${targetBus.name}, Distance: ${targetDist.toStringAsFixed(0)}m, ETA: ${etaSeconds}s",
          );
        } else if (targetDist > _alertDistanceMeters) {
          _hasAlerted = false;
        }
      }
    }

    notifyListeners();
  }

  /// คำนวณหาป้ายที่ใกล้ที่สุด
  String getClosestStopInfo() {
    if (_userPosition == null) return "รอ GPS...";
    if (_allBusStops.isEmpty) return "ไม่มีข้อมูลป้าย";

    final Distance distance = const Distance();
    double closestDist = double.infinity;
    String? closestName;

    for (var stop in _allBusStops) {
      final stopPos = LatLng(stop['lat'], stop['long']);
      final dist = distance.as(LengthUnit.Meter, _userPosition!, stopPos);
      if (dist < closestDist) {
        closestDist = dist;
        closestName = stop['name'];
      }
    }

    if (closestName == null) return "ไม่พบ";
    return "$closestName (${closestDist.toStringAsFixed(0)}m)";
  }

  /// คืนค่า Map ของป้ายที่ใกล้ที่สุด
  Map<String, dynamic>? findClosestStop() {
    if (_userPosition == null || _allBusStops.isEmpty) return null;

    final Distance distance = const Distance();
    double closestDist = double.infinity;
    Map<String, dynamic>? closestStop;

    for (var stop in _allBusStops) {
      final stopPos = LatLng(stop['lat'], stop['long']);
      final dist = distance.as(LengthUnit.Meter, _userPosition!, stopPos);
      if (dist < closestDist) {
        closestDist = dist;
        closestStop = stop;
      }
    }

    return closestStop;
  }

  /// ปิด service (เรียกตอน dispose app)
  void dispose() {
    _busSubscription?.cancel();
    _positionSubscription?.cancel();
    super.dispose();
  }
}
