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
  bool _isInitialized = false;

  // New State for Destination
  String? _destinationName;
  String? _destinationRouteId;
  final Map<String, double> _prevDistToDest =
      {}; // เก็บระยะห่างจากปลายทางครั้งก่อน
  final Map<String, int> _lastAlertStage =
      {}; // เก็บระดับการแจ้งเตือนล่าสุดของแต่ละคัน (0=ยังไม่แจ้ง, 1=5นาที, 2=3นาที, 3=1นาที, 4=ถึงแล้ว)

  // Subscriptions
  StreamSubscription? _busSubscription;
  StreamSubscription<Position>? _positionSubscription;

  // Constants
  static const double _alertDistanceMeters = 250.0; // ระยะ "มาถึงแล้ว"
  static const double _stopProximityMeters = 50.0;

  // Getters
  LatLng? get userPosition => _userPosition;
  List<Bus> get buses => _buses;
  Bus? get closestBus => _closestBus;
  List<Map<String, dynamic>> get allBusStops => _allBusStops;
  bool get notifyEnabled => _notifyEnabled;
  String? get selectedNotifyRouteId => _selectedNotifyRouteId;
  bool get isInitialized => _isInitialized;
  String? get destinationName => _destinationName;
  String? get destinationRouteId => _destinationRouteId;

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
    _lastAlertStage.clear(); // Reset history
    notifyListeners();
    debugPrint(
      "🔔 [GlobalLocationService] Notify enabled: $enabled, routeId: $routeId",
    );
  }

  /// ตั้งค่าจุดหมายปลายทาง (ถ้า name เป็น null คือยกเลิก)
  void setDestination(String? name, String? routeId) {
    _destinationName = name;
    _destinationRouteId = routeId;
    _prevDistToDest.clear(); // Reset history
    _lastAlertStage.clear(); // Reset alert history

    // ถ้ามีการเลือกปลายทาง ให้เปิดแจ้งเตือนอัตโนมัติสำหรับสายนั้น
    if (name != null && routeId != null) {
      _notifyEnabled = true;
      _selectedNotifyRouteId = routeId;
      debugPrint(
        "🎯 [GlobalLocationService] Source set to $name (Route: $routeId)",
      );
    } else {
      // ถ้ายกเลิก ก็ไม่ต้องปิด notify แต่ให้เคลียร์ filter
      _selectedNotifyRouteId = null;
      debugPrint("❌ [GlobalLocationService] Destination cleared");
    }

    _updateClosestBus(); // Recalculate immediately
    notifyListeners();
  }

  /// คืนค่าพิกัดของจุดหมายปลายทาง (ถ้ามี)
  LatLng? get destinationPosition {
    if (_destinationName == null || _allBusStops.isEmpty) return null;
    try {
      final stop = _allBusStops.firstWhere(
        (s) => s['name'] == _destinationName,
      );
      return LatLng(stop['lat'], stop['long']);
    } catch (e) {
      return null;
    }
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

      // กรณีมีการเลือกจุดหมาย (Destination Set)
      if (_destinationName != null &&
          _destinationRouteId != null &&
          destinationPosition != null) {
        final destPos = destinationPosition!;

        // 1. กรองเฉพาะสายที่ถูกต้อง
        var candidateBuses = busesWithDistance.where((b) {
          return b.routeId.toLowerCase() == _destinationRouteId!.toLowerCase();
        }).toList();

        // 2. กรองเฉพาะรถที่ "กำลังเข้าหา" (Approaching)
        Bus? approachingBus;
        double minDistance = double.infinity;

        for (var bus in candidateBuses) {
          // ระยะห่างจากรถถึง "จุดหมายปลายทาง" (ไม่ใช่ถึงตัวเรา)
          // เพื่อดูว่ามันวิ่งเข้าหาจุดหมายหรือไม่
          double distToDest = distance.as(
            LengthUnit.Meter,
            bus.position,
            destPos,
          );

          if (_prevDistToDest.containsKey(bus.id)) {
            double prevDist = _prevDistToDest[bus.id]!;
            // ถ้า distance ลดลง หรือเท่าเดิม (รถติด/จอดรับ) -> ถือว่ามาถูกทาง
            // ถ้า distance เพิ่มขึ้น -> วิ่งหนี -> ไม่เอา
            if (distToDest <= prevDist) {
              // เป็นรถที่น่าสนใจ
              // เลือกคันที่ใกล้ตัวเราที่สุดจากกลุ่มนี้
              if ((bus.distanceToUser ?? double.infinity) < minDistance) {
                minDistance = bus.distanceToUser ?? double.infinity;
                approachingBus = bus;
              }
            } else {
              debugPrint(
                "🚌 [Skip] Bus ${bus.id} is moving away (Diff: ${distToDest - prevDist}m)",
              );
            }
          } else {
            // ยังไม่มีประวัติ (เพิ่งเริ่ม) -> เก็บค่าไว้ก่อน แต่ยังไม่ฟันธง (รอรอบหน้า)
            // หรือจะยอมให้ผ่านไปก่อนก็ได้ในรอบแรก แต่เพื่อให้ชัวร์ รอ update หน้าดีกว่า
            debugPrint(
              "⏳ [Wait] Initializing direction allow for bus ${bus.id}",
            );
            // Allow first time to prevent delay feeling? Let's allow if close.
            if ((bus.distanceToUser ?? double.infinity) < minDistance) {
              minDistance = bus.distanceToUser ?? double.infinity;
              approachingBus = bus;
            }
          }

          // อัพเดตประวัติ
          _prevDistToDest[bus.id] = distToDest;
        }

        targetBus = approachingBus;
      } else if (_selectedNotifyRouteId != null) {
        // กรณีเลือกสาย แต่ไม่ได้เลือกจุดหมาย
        final filteredBuses = busesWithDistance
            .where((b) => b.routeId == _selectedNotifyRouteId)
            .toList();
        targetBus = filteredBuses.isNotEmpty ? filteredBuses.first : null;
      } else {
        // กรณีเลือก "ทุกสาย"
        targetBus = _closestBus;
      }

      if (targetBus != null) {
        final targetDist = targetBus.distanceToUser ?? double.infinity;
        final etaSeconds = NotificationService.calculateEtaSeconds(targetDist);
        final busId = targetBus.id;
        final lastStage = _lastAlertStage[busId] ?? 0;

        // Stage 4: ถึงแล้ว (<= 250m)
        if (targetDist <= _alertDistanceMeters) {
          if (lastStage < 4) {
            _triggerAlert(targetBus, targetDist, etaSeconds, "รถมาถึงแล้ว!");
            _lastAlertStage[busId] = 4;
          }
        }
        // Stage 3: < 1 นาที (60s)
        else if (etaSeconds <= 60) {
          if (lastStage < 3) {
            _triggerAlert(targetBus, targetDist, etaSeconds, "อีก 1 นาทีจะถึง");
            _lastAlertStage[busId] = 3;
          }
        }
        // Stage 2: < 3 นาที (180s)
        else if (etaSeconds <= 180) {
          if (lastStage < 2) {
            _triggerAlert(targetBus, targetDist, etaSeconds, "อีก 3 นาทีจะถึง");
            _lastAlertStage[busId] = 2;
          }
        }
        // Stage 1: < 5 นาที (300s)
        else if (etaSeconds <= 300) {
          if (lastStage < 1) {
            _triggerAlert(targetBus, targetDist, etaSeconds, "อีก 5 นาทีจะถึง");
            _lastAlertStage[busId] = 1;
          }
        }
      }
    }

    notifyListeners();
  }

  Future<void> _triggerAlert(
    Bus bus,
    double dist,
    int eta,
    String msgPrefix,
  ) async {
    await NotificationService.alertBusNearby(
      busName: "${bus.name} ($msgPrefix)",
      distanceMeters: dist,
      etaSeconds: eta,
    );
    debugPrint(
      "🔔 Alert: $msgPrefix - ${bus.name} (${dist.toStringAsFixed(0)} m)",
    );
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
