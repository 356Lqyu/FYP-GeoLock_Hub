import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'location_result.dart';
import 'location_service.dart';
import 'road_routing.dart';

class LocationPickerPage extends StatefulWidget {
  final String title;
  final LocationResult? initialLocation;

  /// When required, Confirm stays disabled until the server reports the point
  /// is within reach of a drivable road.
  final RoadAccessRequirement roadAccess;

  /// Overrides the preview_location_routing RPC (used by tests).
  final RoadAccessCheck? roadAccessCheck;

  /// Optional guidance shown above the selected location.
  final String? hint;

  const LocationPickerPage({
    super.key,
    required this.title,
    this.initialLocation,
    this.roadAccess = RoadAccessRequirement.none,
    this.roadAccessCheck,
    this.hint,
  });

  @override
  State<LocationPickerPage> createState() => _LocationPickerPageState();
}

class _LocationPickerPageState extends State<LocationPickerPage> {
  static const _malaysiaOverview = LatLng(4.2105, 101.9758);
  late final _service = LocationService();
  final _address = TextEditingController();
  GoogleMapController? _map;
  LocationResult? _selection;
  LatLng? _point;
  String? _message;
  bool _busy = false;
  late final RoadAccessCheck _roadCheck =
      widget.roadAccessCheck ?? previewLocationRouting;
  RoadAccessResult? _road;
  String? _roadError;
  bool _checkingRoad = false;
  int _roadRequest = 0;

  @override
  void initState() {
    super.initState();
    _selection = widget.initialLocation;
    if (_selection != null) {
      _address.text = _selection!.address;
      _point = LatLng(_selection!.latitude, _selection!.longitude);
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkRoad());
    }
  }

  bool get _roadRequired => widget.roadAccess == RoadAccessRequirement.required;

  /// Drops any road result for the previous point; call inside setState.
  void _clearRoad() {
    _roadRequest++;
    _road = null;
    _roadError = null;
    _checkingRoad = false;
  }

  Future<void> _checkRoad() async {
    final selection = _selection;
    if (!_roadRequired || selection == null || !mounted) return;
    final request = ++_roadRequest;
    setState(() {
      _road = null;
      _roadError = null;
      _checkingRoad = true;
    });
    try {
      final result = await _roadCheck(selection.latitude, selection.longitude);
      if (!mounted || request != _roadRequest) return;
      setState(() => _road = result);
    } catch (error) {
      if (!mounted || request != _roadRequest) return;
      setState(
        () => _roadError =
            'Road access could not be checked: '
            '${error is PostgrestException ? error.message : error}',
      );
    } finally {
      if (mounted && request == _roadRequest) {
        setState(() => _checkingRoad = false);
      }
    }
  }

  @override
  void dispose() {
    _address.dispose();
    _map?.dispose();
    super.dispose();
  }

  void _showError(Object error) {
    if (mounted) setState(() => _message = error.toString());
  }

  Future<void> _selectCurrentLocation() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await _service.currentLocation();
      await _apply(result);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _searchAddress() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final result = await _service.geocodeAddress(_address.text);
      await _apply(result);
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply(LocationResult result) async {
    if (!mounted) return;
    final point = LatLng(result.latitude, result.longitude);
    setState(() {
      _selection = result;
      _point = point;
      _address.text = result.address;
      _message = null;
    });
    _checkRoad();
    await _map?.animateCamera(CameraUpdate.newLatLngZoom(point, 16));
  }

  Future<void> _chooseMapPin(LatLng point) async {
    setState(() {
      _point = point;
      _selection = null;
      _clearRoad();
      _message = 'Looking up the pinned address…';
    });
    final result = await _service.mapPinLocation(
      point.latitude,
      point.longitude,
    );
    if (!mounted || _point != point) return;
    setState(() {
      _selection = result;
      _address.text = result.address;
      _message = null;
    });
    _checkRoad();
  }

  bool get _canConfirm =>
      _selection != null &&
      !_busy &&
      (!_roadRequired || (!_checkingRoad && _road?.routable == true));

  Widget _roadBanner(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String text) = switch (_road) {
      null when _roadError == null => (
        Icons.hourglass_top,
        scheme.primary,
        'Checking road access…',
      ),
      null => (Icons.error_outline, scheme.error, _roadError!),
      final road when road.routable => (
        Icons.check_circle_outline,
        scheme.primary,
        'Road access confirmed · ${road.summary}',
      ),
      final road => (
        Icons.block,
        scheme.error,
        '${road.summary}. Move the pin next to a road a vehicle can reach.',
      ),
    };
    return Row(
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(color: color)),
        ),
        if (_roadError != null && !_checkingRoad)
          TextButton(onPressed: _checkRoad, child: const Text('Retry')),
      ],
    );
  }

  Set<Marker> get _markers {
    final point = _point;
    if (point == null) return const {};
    return {
      Marker(
        markerId: const MarkerId('selected-location'),
        position: point,
        draggable: true,
        onDragEnd: _chooseMapPin,
      ),
    };
  }

  String get _methodLabel => switch (_selection?.method) {
    LocationSelectionMethod.currentLocation => 'Current GPS location',
    LocationSelectionMethod.addressSearch => 'Address search',
    LocationSelectionMethod.mapPin => 'Map pin',
    null => 'Choose a location',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: [
                TextField(
                  controller: _address,
                  onChanged: (_) {
                    if (_selection != null) {
                      setState(() {
                        _selection = null;
                        _point = null;
                        _clearRoad();
                      });
                    }
                  },
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _searchAddress(),
                  decoration: InputDecoration(
                    labelText: 'Enter an address',
                    hintText: 'Street, town, postcode',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      tooltip: 'Search address',
                      onPressed: _busy ? null : _searchAddress,
                      icon: const Icon(Icons.arrow_forward),
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _selectCurrentLocation,
                    icon: const Icon(Icons.my_location),
                    label: const Text('Use My Current Location'),
                  ),
                ),
              ],
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                _message!,
                style: TextStyle(
                  color: _message!.startsWith('Looking up')
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                GoogleMap(
                  initialCameraPosition: CameraPosition(
                    target: _point ?? _malaysiaOverview,
                    zoom: _point == null ? 5.5 : 16,
                  ),
                  onMapCreated: (controller) => _map = controller,
                  onTap: _chooseMapPin,
                  markers: _markers,
                  myLocationButtonEnabled: false,
                  myLocationEnabled: false,
                  mapToolbarEnabled: false,
                  zoomControlsEnabled: true,
                ),
                if (_busy)
                  const Align(
                    alignment: Alignment.topCenter,
                    child: LinearProgressIndicator(),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.hint != null) ...[
                  Text(
                    widget.hint!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 4),
                ],
                Text(
                  _methodLabel,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                if (_selection != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _selection!.address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${_selection!.latitude.toStringAsFixed(6)}, ${_selection!.longitude.toStringAsFixed(6)}'
                    '${_selection!.accuracyMeters == null ? '' : ' · GPS ±${_selection!.accuracyMeters!.round()} m'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (_roadRequired) ...[
                    const SizedBox(height: 8),
                    _roadBanner(context),
                  ],
                ] else
                  const Text(
                    'Tap the map or drag the marker, then confirm this location.',
                  ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _canConfirm
                      ? () => Navigator.pop(
                          context,
                          _selection!.withRoadAccess(_road),
                        )
                      : null,
                  child: const Text('Confirm Location'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
