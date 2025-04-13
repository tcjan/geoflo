import 'dart:async';
import 'dart:convert';
import 'dart:html' as html; // For web injection and file upload.
import 'dart:math' show Point, Rectangle;
import 'dart:math' as math; // For math calculations.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:turf/turf.dart' as turf;
import 'package:r_tree/r_tree.dart';
import 'package:alga_configui/src/config_page.dart';

/// Generate a GeoJSON polygon approximating a circle (for the radius debug).
Map<String, dynamic> createCirclePolygon(
  turf.Point center,
  double radiusKm, {
  int steps = 64,
}) {
  final List<List<double>> coordinates = [];
  final cLng = (center.coordinates[0] as num?)?.toDouble() ?? 0.0;
  final cLat = (center.coordinates[1] as num?)?.toDouble() ?? 0.0;

  // Approx conversion from km to degrees
  final degLatPerKm = 1 / 110.574;
  final degLngPerKm = 1 / (111.320 * math.cos(cLat * math.pi / 180));

  for (int i = 0; i <= steps; i++) {
    final angle = 2 * math.pi * i / steps;
    final dLat = radiusKm * degLatPerKm;
    final dLng = radiusKm * degLngPerKm;

    final lat = cLat + dLat * math.sin(angle);
    final lng = cLng + dLng * math.cos(angle);
    coordinates.add([lng, lat]);
  }
  return {
    "type": "Feature",
    "geometry": {
      "type": "Polygon",
      "coordinates": [coordinates],
    },
    "properties": {},
  };
}

/// Converts property keys to lowercase and handles specific name changes.
Map<String, dynamic> standardizeGeoJsonProperties(
  Map<String, dynamic> geojson,
  String featureType,
) {
  if (geojson['features'] is List) {
    for (final feature in geojson['features']) {
      final props = feature['properties'] as Map<String, dynamic>;
      final Map<String, dynamic> newProps = {};
      props.forEach((key, value) {
        newProps[key.toLowerCase()] = value;
      });
      if (featureType == 'new_taz') {
        if (newProps.containsKey('taz_new1')) {
          newProps['taz_id'] = newProps['taz_new1'];
          newProps.remove('taz_new1');
        }
      } else if (featureType == 'blocks') {
        if (newProps.containsKey('geoid20')) {
          final orig = newProps['geoid20'].toString();
          newProps['geoid20'] = int.tryParse(orig) ?? orig;
          // short label
          newProps['block_label'] =
              (orig.length > 4) ? orig.substring(orig.length - 4) : orig;
        }
        if (newProps.containsKey('taz_id0')) {
          newProps['taz_id'] = newProps['taz_id0'];
          newProps.remove('taz_id0');
        } else if (newProps.containsKey('taz_new1')) {
          newProps['taz_id'] = newProps['taz_new1'];
          newProps.remove('taz_new1');
        }
      } else if (featureType == 'old_taz') {
        if (newProps.containsKey('objectid')) {
          newProps['object_id'] = newProps['objectid'];
          newProps.remove('objectid');
        }
      }
      feature['properties'] = newProps;
    }
  }
  return geojson;
}

/// Create SymbolLayerProperties for ID labels.
SymbolLayerProperties createIdLabelProperties({
  required String textField,
  required String textColor,
  double textSize = 14,
  String textHaloColor = "#FFFFFF",
  double textHaloWidth = 0.5,
}) {
  return SymbolLayerProperties(
    textField: textField,
    textSize: textSize,
    textColor: textColor,
    textHaloColor: textHaloColor,
    textHaloWidth: textHaloWidth,
  );
}

/// Format numeric values with at most one decimal if needed.
String formatNumber(num n) {
  if (n is int || n % 1 == 0) return n.toString();
  return n.toStringAsFixed(1);
}

/// Build a DataCell from a value, applying numeric formatting if needed.
DataCell buildDataCell(dynamic value) {
  if (value is num) {
    return DataCell(Text(formatNumber(value)));
  }
  return DataCell(Text(value.toString()));
}

/// Filter features by computing centroid distance from a given center.
List<dynamic> filterFeaturesWithinDistance(
  List<dynamic> feats,
  turf.Point center,
  double radiusKm,
) {
  final output = <dynamic>[];
  for (final feat in feats) {
    final f = turf.Feature.fromJson(feat);
    final cent = turf.centroid(f).geometry as turf.Point;
    final distKm =
        (turf.distance(center, cent, turf.Unit.kilometers) as num?)
            ?.toDouble() ??
        9999.0;
    if (distKm <= radiusKm) {
      output.add(feat);
    }
  }
  return output;
}

/// Check bounding box intersection plus distance check.
bool isWithinBBoxAndDistance(
  turf.Point point,
  Rectangle<double> bbox,
  turf.Point center,
  double radiusKm,
) {
  final lng = (point.coordinates[0] as num?)?.toDouble() ?? 0.0;
  final lat = (point.coordinates[1] as num?)?.toDouble() ?? 0.0;
  if (lng < bbox.left ||
      lng > (bbox.left + bbox.width) ||
      lat < bbox.top ||
      lat > (bbox.top + bbox.height)) {
    return false;
  }
  final distKm =
      (turf.distance(center, point, turf.Unit.kilometers) as num?)
          ?.toDouble() ??
      9999.0;
  return distKm <= radiusKm;
}

/// Load from localStorage if present.
Map<String, dynamic>? _loadGeoJsonFromLocal(String key, String type) {
  if (html.window.localStorage.containsKey(key)) {
    final decoded = jsonDecode(html.window.localStorage[key]!);
    return standardizeGeoJsonProperties(decoded, type);
  }
  return null;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    await injectMapLibreScripts();
  }
  runApp(const MyApp());
}

/// Inject the MapLibre script + CSS for web usage.
Future<void> injectMapLibreScripts() async {
  final cssLink =
      html.LinkElement()
        ..href = "https://unpkg.com/maplibre-gl@latest/dist/maplibre-gl.css"
        ..rel = "stylesheet"
        ..crossOrigin = "anonymous";
  html.document.head!.append(cssLink);

  final completer = Completer<void>();
  final script =
      html.ScriptElement()
        ..src = "https://unpkg.com/maplibre-gl@latest/dist/maplibre-gl.js"
        ..defer = true
        ..crossOrigin = "anonymous"
        ..onLoad.listen((_) => completer.complete())
        ..onError.listen(
          (_) => completer.completeError("Failed to load MapLibre GL JS."),
        );
  html.document.head!.append(script);

  return completer.future;
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VizTAZ Dashboard',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: const Color.fromARGB(255, 249, 253, 255),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color.fromARGB(255, 184, 233, 254),
            foregroundColor: Colors.black,
          ),
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: const Color(0xFF4169E1),
          inactiveTrackColor: Colors.blue.shade100,
          thumbColor: const Color(0xFF4169E1),
        ),
      ),
      home: const DashboardPage(),
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({Key? key}) : super(key: key);
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final GlobalKey<MapViewState> _oldMapKey = GlobalKey<MapViewState>();
  final GlobalKey<MapViewState> _newMapKey = GlobalKey<MapViewState>();
  final GlobalKey<MapViewState> _combinedMapKey = GlobalKey<MapViewState>();
  final GlobalKey<MapViewState> _blocksMapKey = GlobalKey<MapViewState>();

  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _radiusController = TextEditingController(
    text: "1.0",
  );
  String _searchLabel = "Currently Searching TAZ: (none)";

  List<Map<String, dynamic>> _newTazTableData = [];
  List<Map<String, dynamic>> _blocksTableData = [];
  bool _hasSearched = false;
  int? _selectedTazId;
  double _radius = 1609.34; // 1 mile in meters
  double _radiusValue = 1.0;
  bool _useKilometers = false;
  bool _showIdLabels = false;

  // GeoJSON caches
  Map<String, dynamic>? _cachedOldTaz;
  Map<String, dynamic>? _cachedNewTaz;
  Map<String, dynamic>? _cachedBlocks;
  RTree<dynamic>? _blocksIndex;

  // Selections
  final Set<int> _selectedNewTazIds = {};
  Set<int> _selectedBlockIds = {};

  // Map style
  String _selectedMapStyleName = 'Positron';
  static const satelliteStyleJson = """
{
  "version": 8,
  "name": "ArcGIS Satellite",
  "glyphs": "https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf",
  "sources": {
    "satellite-source": {
      "type": "raster",
      "tiles": [
        "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
      ],
      "tileSize": 256
    }
  },
  "layers": [
    {
      "id": "satellite-layer",
      "type": "raster",
      "source": "satellite-source"
    }
  ]
}
""";
  final Map<String, String> _mapStyles = {
    'Positron': 'https://basemaps.cartocdn.com/gl/positron-gl-style/style.json',
    'Dark Matter':
        'https://basemaps.cartocdn.com/gl/dark-matter-gl-style/style.json',
    'Satellite': 'data:application/json,$satelliteStyleJson',
  };

  CameraPosition? _syncedCameraPosition;
  bool _isSyncEnabled = false;

  // For horizontal scrolling in data tables
  final ScrollController _newTableHorizontalScrollController =
      ScrollController();
  final ScrollController _blocksTableHorizontalScrollController =
      ScrollController();

  bool _uploadedOldTaz = false;
  bool _uploadedNewTaz = false;
  bool _uploadedBlocks = false;
  bool _filesReady = false;
  bool _isProcessingUpload = false;

  @override
  void initState() {
    super.initState();
    final allUploaded =
        html.window.localStorage.containsKey('old_taz_geojson') &&
        html.window.localStorage.containsKey('new_taz_geojson') &&
        html.window.localStorage.containsKey('blocks_geojson');
    if (allUploaded) {
      _filesReady = true;
      _loadCachedData().then((_) {
        setState(() => _isLoading = false);
      });
    } else {
      _isLoading = false;
    }
  }

  Future<void> _loadCachedData() async {
    _cachedOldTaz ??= _loadGeoJsonFromLocal('old_taz_geojson', "old_taz");
    if (_cachedOldTaz != null) _uploadedOldTaz = true;

    _cachedNewTaz ??= _loadGeoJsonFromLocal('new_taz_geojson', "new_taz");
    if (_cachedNewTaz != null) _uploadedNewTaz = true;

    _cachedBlocks ??= _loadGeoJsonFromLocal('blocks_geojson', "blocks");
    if (_cachedBlocks != null) _uploadedBlocks = true;

    // Build R-Tree for blocks, if present
    if (_cachedBlocks != null && _cachedBlocks!['features'] is List) {
      final items = <RTreeDatum<dynamic>>[];
      for (final feat in _cachedBlocks!['features']) {
        final bbox = _boundingBoxFromFeature(feat);
        items.add(RTreeDatum(bbox, feat));
      }
      _blocksIndex = RTree(16);
      _blocksIndex!.add(items);
    }
    setState(() {});
  }

  math.Rectangle<double> _boundingBoxFromFeature(dynamic feature) {
    double? minLng, minLat, maxLng, maxLat;
    final geometry = feature['geometry'];
    final type = geometry['type'];
    final coords = geometry['coordinates'];

    void processPoint(dynamic arr) {
      final lng = (arr[0] as num?)?.toDouble() ?? 0.0;
      final lat = (arr[1] as num?)?.toDouble() ?? 0.0;
      minLng = (minLng == null) ? lng : math.min(minLng!, lng);
      minLat = (minLat == null) ? lat : math.min(minLat!, lat);
      maxLng = (maxLng == null) ? lng : math.max(maxLng!, lng);
      maxLat = (maxLat == null) ? lat : math.max(maxLat!, lat);
    }

    if (type == 'Polygon') {
      for (final ring in coords) {
        for (final pt in ring) {
          processPoint(pt);
        }
      }
    } else if (type == 'MultiPolygon') {
      for (final polygon in coords) {
        for (final ring in polygon) {
          for (final pt in ring) {
            processPoint(pt);
          }
        }
      }
    }
    // Provide fallback for each if still null
    minLng ??= 0.0;
    minLat ??= 0.0;
    maxLng ??= 0.0;
    maxLat ??= 0.0;

    return math.Rectangle<double>(
      minLng ?? 0.0,
      minLat ?? 0.0,
      (maxLng ?? 0.0) - (minLng ?? 0.0),
      (maxLat ?? 0.0) - (minLat ?? 0.0),
    );
  }

  @override
  void dispose() {
    _newTableHorizontalScrollController.dispose();
    _blocksTableHorizontalScrollController.dispose();
    super.dispose();
  }

  void _runSearch() {
    final tazIdStr = _searchController.text.trim();
    if (tazIdStr.isEmpty) {
      setState(() {
        _searchLabel = "Currently Searching TAZ: (none)";
        _hasSearched = false;
        _selectedTazId = null;
      });
      return;
    }
    final tazId = int.tryParse(tazIdStr);
    if (tazId == null) {
      setState(() {
        _searchLabel = "Currently Searching TAZ: (invalid ID)";
        _hasSearched = false;
        _selectedTazId = null;
      });
      return;
    }
    setState(() {
      _searchLabel = "Currently Searching TAZ: $tazId";
      _hasSearched = true;
      _selectedTazId = tazId;
      _newTazTableData.clear();
      _blocksTableData.clear();
      _selectedNewTazIds.clear();
      _selectedBlockIds.clear();
    });
  }

  void _clearNewTazTable() {
    setState(() {
      _newTazTableData.clear();
      _selectedNewTazIds.clear();
    });
  }

  void _clearBlocksTable() {
    setState(() {
      _blocksTableData.clear();
      _selectedBlockIds.clear();
    });
  }

  void _toggleNewTazRow(int tappedId) {
    final exists = _newTazTableData.any((row) => row['id'] == tappedId);
    if (exists) {
      setState(() {
        _newTazTableData.removeWhere((row) => row['id'] == tappedId);
        _selectedNewTazIds.remove(tappedId);
      });
    } else {
      var newRow = {
        'id': tappedId,
        'hh19': 0,
        'hh49': 0,
        'emp19': 0,
        'emp49': 0,
        'persns19': 0,
        'persns49': 0,
        'workrs19': 0,
        'workrs49': 0,
      };
      if (_cachedNewTaz != null) {
        final feats = _cachedNewTaz!['features'] as List<dynamic>;
        final match = feats.firstWhere(
          (f) => (f['properties']['taz_id']?.toString() == tappedId.toString()),
          orElse: () => null,
        );
        if (match != null) {
          final props = match['properties'] as Map<String, dynamic>;
          newRow = {
            'id': tappedId,
            'hh19': props['hh19'] ?? 0,
            'hh49': props['hh49'] ?? 0,
            'emp19': props['emp19'] ?? 0,
            'emp49': props['emp49'] ?? 0,
            'persns19': props['persns19'] ?? 0,
            'persns49': props['persns49'] ?? 0,
            'workrs19': props['workrs19'] ?? 0,
            'workrs49': props['workrs49'] ?? 0,
          };
        }
      }
      setState(() {
        _newTazTableData.add(newRow);
        _selectedNewTazIds.add(tappedId);
      });
    }
  }

  void _toggleBlockRow(int tappedId) {
    final exists = _blocksTableData.any((row) => row['id'] == tappedId);
    if (exists) {
      setState(() {
        _blocksTableData.removeWhere((row) => row['id'] == tappedId);
        _selectedBlockIds.remove(tappedId);
      });
    } else {
      var newRow = {
        'id': tappedId,
        'hh19': 0,
        'hh49': 0,
        'emp19': 0,
        'emp49': 0,
        'persns19': 0,
        'persns49': 0,
        'workrs19': 0,
        'workrs49': 0,
      };
      if (_cachedBlocks != null) {
        final feats = _cachedBlocks!['features'] as List<dynamic>;
        final match = feats.firstWhere(
          (f) =>
              (f['properties']['geoid20']?.toString() == tappedId.toString()),
          orElse: () => null,
        );
        if (match != null) {
          final props = match['properties'] as Map<String, dynamic>;
          newRow = {
            'id': tappedId,
            'hh19': props['hh19'] ?? 0,
            'hh49': props['hh49'] ?? 0,
            'emp19': props['emp19'] ?? 0,
            'emp49': props['emp49'] ?? 0,
            'persns19': props['persns19'] ?? 0,
            'persns49': props['persns49'] ?? 0,
            'workrs19': props['workrs19'] ?? 0,
            'workrs49': props['workrs49'] ?? 0,
          };
        }
      }
      setState(() {
        _blocksTableData.add(newRow);
        _selectedBlockIds.add(tappedId);
      });
    }
  }

  Widget _buildRadiusControl() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0),
      child: Row(
        children: [
          Text("Radius (${_useKilometers ? 'km' : 'miles'}):"),
          const SizedBox(width: 5),
          SizedBox(
            width: 200,
            child: Slider(
              min: 0.5,
              max: 5.0,
              divisions: 5,
              label: _radiusValue.toStringAsFixed(1),
              value: _radiusValue,
              onChanged: (v) {
                setState(() {
                  _radiusValue = v;
                  _radius = _radiusValue * (_useKilometers ? 1000.0 : 1609.34);
                  _radiusController.text = _radiusValue.toStringAsFixed(1);
                });
              },
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 80,
            child: TextField(
              controller: _radiusController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(),
              ),
              onEditingComplete: () {
                double? val = double.tryParse(_radiusController.text);
                val ??= 0.5;
                if (val < 0.5) val = 0.5;
                if (val > 5.0) val = 5.0;
                setState(() {
                  _radiusValue = val!;
                  _radius = _radiusValue * (_useKilometers ? 1000.0 : 1609.34);
                  _radiusController.text = _radiusValue.toStringAsFixed(1);
                });
              },
            ),
          ),
        ],
      ),
    );
  }

  void _openInGoogleMaps() {
    double lat = 42.3601, lng = -71.0589;
    if (_selectedTazId != null && _cachedOldTaz != null) {
      final feats = _cachedOldTaz!['features'] as List<dynamic>;
      final targetF = feats.firstWhere(
        (f) =>
            (f['properties']['taz_id']?.toString() ==
                _selectedTazId.toString()),
        orElse: () => null,
      );
      if (targetF != null) {
        final tf = turf.Feature.fromJson(targetF);
        final c = turf.centroid(tf).geometry as turf.Point;
        lat = (c.coordinates[1] as num?)?.toDouble() ?? 42.3601;
        lng = (c.coordinates[0] as num?)?.toDouble() ?? -71.0589;
      }
    }
    final url = "https://www.google.com/maps/search/?api=1&query=$lat,$lng";
    html.window.open(url, '_blank');
  }

  void _goToConfigPage(BuildContext ctx) {
    Navigator.push(ctx, MaterialPageRoute(builder: (_) => const ConfigPage()));
  }

  String? _oldTazFileName;
  String? _newTazFileName;
  String? _blocksFileName;

  void _uploadGeoJson(String type) {
    final input = html.FileUploadInputElement()..accept = '.geojson';
    input.click();
    input.onChange.listen((event) async {
      if (input.files!.isNotEmpty) {
        setState(() => _isProcessingUpload = true);
        final file = input.files!.first;
        // Instead of printing "File might be large..." we just do a quiet check:
        final canStoreInLocal = file.size <= 5 * 1024 * 1024;

        final reader = html.FileReader();
        reader.readAsText(file);
        await reader.onLoad.first;

        Map<String, dynamic> data = jsonDecode(reader.result as String);
        data = standardizeGeoJsonProperties(data, type);

        if (canStoreInLocal) {
          // If small enough, store in localStorage
          if (type == "old_taz") {
            html.window.localStorage['old_taz_geojson'] = jsonEncode(data);
          } else if (type == "new_taz") {
            html.window.localStorage['new_taz_geojson'] = jsonEncode(data);
          } else if (type == "blocks") {
            html.window.localStorage['blocks_geojson'] = jsonEncode(data);
          }
        }
        // In any case, use it in memory
        if (type == "old_taz") {
          _uploadedOldTaz = true;
          _cachedOldTaz = data;
          _oldTazFileName = file.name;
        } else if (type == "new_taz") {
          _uploadedNewTaz = true;
          _cachedNewTaz = data;
          _newTazFileName = file.name;
        } else if (type == "blocks") {
          _uploadedBlocks = true;
          _cachedBlocks = data;
          _blocksFileName = file.name;
        }
        setState(() => _isProcessingUpload = false);

        if (_uploadedOldTaz && _uploadedNewTaz && _uploadedBlocks) {
          setState(() {
            _filesReady = true;
            _isLoading = true;
          });
          await _loadCachedData();
          setState(() => _isLoading = false);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text("VizTAZ Dashboard"),
          backgroundColor: const Color(0xFF013220),
          leadingWidth: 150,
          leading: _buildUploadButtons(),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (!_filesReady) {
      return Scaffold(
        appBar: AppBar(
          title: const Text(
            "Upload Required",
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          backgroundColor: const Color(0xFF013220),
          leadingWidth: 150,
          leading: _buildUploadButtons(),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text("Please upload all three GeoJSON files to continue."),
              if (_isProcessingUpload)
                const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: CircularProgressIndicator(),
                ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF013220),
        elevation: 2,
        leadingWidth: 150,
        leading: _buildUploadButtons(),
        title: Text(
          _searchLabel,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                Container(
                  height: 40,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(
                      color: const Color(0xFF3E2723),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Miles",
                        style: TextStyle(color: const Color(0xFF3E2723)),
                      ),
                      Switch(
                        value: _useKilometers,
                        onChanged: (val) {
                          setState(() {
                            _useKilometers = val;
                            _radius =
                                _radiusValue *
                                (_useKilometers ? 1000.0 : 1609.34);
                          });
                        },
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        activeColor: const Color(0xFF3E2723),
                        inactiveThumbColor: const Color(0xFF3E2723),
                        inactiveTrackColor: const Color(
                          0xFF3E2723,
                        ).withOpacity(0.3),
                      ),
                      Text(
                        "KM",
                        style: TextStyle(color: const Color(0xFF3E2723)),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 40,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(
                      color: const Color(0xFF3E2723),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "ID Labels",
                        style: TextStyle(color: const Color(0xFF3E2723)),
                      ),
                      Switch(
                        value: _showIdLabels,
                        onChanged: (val) {
                          setState(() {
                            _showIdLabels = val;
                          });
                        },
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        activeColor: const Color(0xFF3E2723),
                        inactiveThumbColor: const Color(0xFF3E2723),
                        inactiveTrackColor: const Color(
                          0xFF3E2723,
                        ).withOpacity(0.3),
                      ),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(
                      color: const Color(0xFF3E2723),
                      width: 2,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 80),
                    child: DropdownButton<String>(
                      isDense: true,
                      value: _selectedMapStyleName,
                      icon: const Icon(
                        Icons.keyboard_arrow_down,
                        color: Color(0xFF3E2723),
                      ),
                      dropdownColor: Colors.white,
                      style: const TextStyle(
                        color: Color(0xFF3E2723),
                        fontWeight: FontWeight.bold,
                      ),
                      underline: const SizedBox(),
                      onChanged: (val) {
                        setState(() {
                          _selectedMapStyleName = val!;
                        });
                      },
                      items:
                          _mapStyles.keys.map((styleName) {
                            return DropdownMenuItem<String>(
                              value: styleName,
                              child: Text(styleName),
                            );
                          }).toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // top controls
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: MediaQuery.of(context).size.width,
              ),
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 120,
                      child: TextField(
                        controller: _searchController,
                        decoration: const InputDecoration(
                          labelText: "Old TAZ ID",
                          filled: true,
                          fillColor: Colors.white,
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _runSearch(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _runSearch,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue[900],
                        foregroundColor: Colors.white,
                      ),
                      child: const Text("Search TAZ"),
                    ),
                    const SizedBox(width: 8),
                    Container(height: 40, width: 1, color: Colors.grey),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _isSyncEnabled = !_isSyncEnabled;
                          if (!_isSyncEnabled) {
                            _syncedCameraPosition = null;
                          }
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor:
                            _isSyncEnabled
                                ? const Color(0xFF8B0000)
                                : const Color(0xFF006400),
                      ),
                      child: Text(
                        _isSyncEnabled ? "View Sync ON" : "View Sync OFF",
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _openInGoogleMaps,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.deepOrange,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text("Open in Google Maps"),
                    ),
                    const SizedBox(width: 8),
                    Container(height: 40, width: 1, color: Colors.grey),
                    const SizedBox(width: 12),
                    _buildRadiusControl(),
                  ],
                ),
              ),
            ),
          ),
          // main
          Expanded(
            child: Column(
              children: [
                // first row
                Expanded(
                  child: Row(
                    children: [
                      // Old TAZ
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade400),
                          ),
                          child: MapView(
                            key: _oldMapKey,
                            title: "Old TAZ",
                            mode: MapViewMode.oldTaz,
                            drawShapes: _hasSearched,
                            selectedTazId: _selectedTazId,
                            radius: _radius,
                            cachedOldTaz: _cachedOldTaz,
                            cachedNewTaz: _cachedNewTaz,
                            cachedBlocks: _cachedBlocks,
                            blocksIndex: _blocksIndex,
                            selectedIds: const {},
                            showIdLabels: _showIdLabels,
                            onTazSelected:
                                (tazId) => debugPrint("Old TAZ tapped: $tazId"),
                            mapStyle: _mapStyles[_selectedMapStyleName],
                            syncedCameraPosition:
                                _isSyncEnabled ? _syncedCameraPosition : null,
                            onCameraIdleSync:
                                _isSyncEnabled
                                    ? (pos) => setState(
                                      () => _syncedCameraPosition = pos,
                                    )
                                    : null,
                          ),
                        ),
                      ),
                      // New TAZ
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade400),
                          ),
                          child: MapView(
                            key: _newMapKey,
                            title: "New TAZ",
                            mode: MapViewMode.newTaz,
                            drawShapes: _hasSearched,
                            selectedTazId: _selectedTazId,
                            radius: _radius,
                            cachedOldTaz: _cachedOldTaz,
                            cachedNewTaz: _cachedNewTaz,
                            cachedBlocks: _cachedBlocks,
                            blocksIndex: _blocksIndex,
                            selectedIds: _selectedNewTazIds,
                            showIdLabels: _showIdLabels,
                            onTazSelected: (id) => _toggleNewTazRow(id),
                            mapStyle: _mapStyles[_selectedMapStyleName],
                            syncedCameraPosition:
                                _isSyncEnabled ? _syncedCameraPosition : null,
                            onCameraIdleSync:
                                _isSyncEnabled
                                    ? (pos) => setState(
                                      () => _syncedCameraPosition = pos,
                                    )
                                    : null,
                          ),
                        ),
                      ),
                      // New TAZ Table
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.blueAccent),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    "New TAZ Table",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _clearNewTazTable,
                                    child: const Text(
                                      "Clear",
                                      style: TextStyle(
                                        color: Color.fromARGB(255, 255, 0, 0),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: Colors.blueAccent,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.vertical,
                                    child: Scrollbar(
                                      controller:
                                          _newTableHorizontalScrollController,
                                      thumbVisibility: true,
                                      interactive: true,
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        controller:
                                            _newTableHorizontalScrollController,
                                        child: DataTable(
                                          headingRowColor:
                                              MaterialStateProperty.all(
                                                Colors.blue[50],
                                              ),
                                          columns: const [
                                            DataColumn(label: Text("ID")),
                                            DataColumn(label: Text("HH19")),
                                            DataColumn(label: Text("HH49")),
                                            DataColumn(label: Text("EMP19")),
                                            DataColumn(label: Text("EMP49")),
                                            DataColumn(label: Text("PERSNS19")),
                                            DataColumn(label: Text("PERSNS49")),
                                            DataColumn(label: Text("WORKRS19")),
                                            DataColumn(label: Text("WORKRS49")),
                                          ],
                                          rows: () {
                                            if (_newTazTableData.isEmpty) {
                                              return [
                                                const DataRow(
                                                  cells: [
                                                    DataCell(Text("No data")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                  ],
                                                ),
                                              ];
                                            }
                                            final rows =
                                                _newTazTableData.map((row) {
                                                  return DataRow(
                                                    cells: [
                                                      buildDataCell(row['id']),
                                                      buildDataCell(
                                                        row['hh19'],
                                                      ),
                                                      buildDataCell(
                                                        row['hh49'],
                                                      ),
                                                      buildDataCell(
                                                        row['emp19'],
                                                      ),
                                                      buildDataCell(
                                                        row['emp49'],
                                                      ),
                                                      buildDataCell(
                                                        row['persns19'],
                                                      ),
                                                      buildDataCell(
                                                        row['persns49'],
                                                      ),
                                                      buildDataCell(
                                                        row['workrs19'],
                                                      ),
                                                      buildDataCell(
                                                        row['workrs49'],
                                                      ),
                                                    ],
                                                  );
                                                }).toList();

                                            final sumHH19 = _newTazTableData
                                                .fold<num>(
                                                  0,
                                                  (p, r) =>
                                                      p + (r['hh19'] as num),
                                                );
                                            final sumHH49 = _newTazTableData
                                                .fold<num>(
                                                  0,
                                                  (p, r) =>
                                                      p + (r['hh49'] as num),
                                                );
                                            final sumEMP19 = _newTazTableData
                                                .fold<num>(
                                                  0,
                                                  (p, r) =>
                                                      p + (r['emp19'] as num),
                                                );
                                            final sumEMP49 = _newTazTableData
                                                .fold<num>(
                                                  0,
                                                  (p, r) =>
                                                      p + (r['emp49'] as num),
                                                );
                                            final sumPERSNS19 = _newTazTableData
                                                .fold<num>(
                                                  0,
                                                  (p, r) =>
                                                      p +
                                                      (r['persns19'] as num),
                                                );
                                            final sumPERSNS49 = _newTazTableData
                                                .fold<num>(
                                                  0,
                                                  (p, r) =>
                                                      p +
                                                      (r['persns49'] as num),
                                                );
                                            final sumWORKRS19 = _newTazTableData
                                                .fold<num>(
                                                  0,
                                                  (p, r) =>
                                                      p +
                                                      (r['workrs19'] as num),
                                                );
                                            final sumWORKRS49 = _newTazTableData
                                                .fold<num>(
                                                  0,
                                                  (p, r) =>
                                                      p +
                                                      (r['workrs49'] as num),
                                                );

                                            rows.add(
                                              DataRow(
                                                color:
                                                    MaterialStateProperty.all(
                                                      Colors.grey[300],
                                                    ),
                                                cells: [
                                                  const DataCell(
                                                    Text(
                                                      "Total",
                                                      style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                  buildDataCell(sumHH19),
                                                  buildDataCell(sumHH49),
                                                  buildDataCell(sumEMP19),
                                                  buildDataCell(sumEMP49),
                                                  buildDataCell(sumPERSNS19),
                                                  buildDataCell(sumPERSNS49),
                                                  buildDataCell(sumWORKRS19),
                                                  buildDataCell(sumWORKRS49),
                                                ],
                                              ),
                                            );
                                            return rows;
                                          }(),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // second row
                Expanded(
                  child: Row(
                    children: [
                      // Combined
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade400),
                          ),
                          child: MapView(
                            key: _combinedMapKey,
                            title: "Combined View",
                            mode: MapViewMode.combined,
                            drawShapes: _hasSearched,
                            selectedTazId: _selectedTazId,
                            radius: _radius,
                            cachedOldTaz: _cachedOldTaz,
                            cachedNewTaz: _cachedNewTaz,
                            cachedBlocks: _cachedBlocks,
                            blocksIndex: _blocksIndex,
                            selectedIds: const {},
                            showIdLabels: _showIdLabels,
                            onTazSelected:
                                (tId) => debugPrint("Combined tapped: $tId"),
                            mapStyle: _mapStyles[_selectedMapStyleName],
                            syncedCameraPosition:
                                _isSyncEnabled ? _syncedCameraPosition : null,
                            onCameraIdleSync:
                                _isSyncEnabled
                                    ? (pos) => setState(
                                      () => _syncedCameraPosition = pos,
                                    )
                                    : null,
                          ),
                        ),
                      ),
                      // Blocks
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey.shade400),
                          ),
                          child: MapView(
                            key: _blocksMapKey,
                            title: "Blocks",
                            mode: MapViewMode.blocks,
                            drawShapes: _hasSearched,
                            selectedTazId: _selectedTazId,
                            radius: _radius,
                            cachedOldTaz: _cachedOldTaz,
                            cachedNewTaz: _cachedNewTaz,
                            cachedBlocks: _cachedBlocks,
                            blocksIndex: _blocksIndex,
                            selectedIds: _selectedBlockIds,
                            showIdLabels: _showIdLabels,
                            onTazSelected: (id) => _toggleBlockRow(id),
                            mapStyle: _mapStyles[_selectedMapStyleName],
                            syncedCameraPosition:
                                _isSyncEnabled ? _syncedCameraPosition : null,
                            onCameraIdleSync:
                                _isSyncEnabled
                                    ? (pos) => setState(
                                      () => _syncedCameraPosition = pos,
                                    )
                                    : null,
                          ),
                        ),
                      ),
                      // Blocks table
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.orangeAccent),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    "Blocks Table",
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _clearBlocksTable,
                                    child: const Text(
                                      "Clear",
                                      style: TextStyle(
                                        color: Color.fromARGB(255, 255, 0, 0),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              Expanded(
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                      color: Colors.orangeAccent,
                                    ),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.vertical,
                                    child: Scrollbar(
                                      controller:
                                          _blocksTableHorizontalScrollController,
                                      thumbVisibility: true,
                                      interactive: true,
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        controller:
                                            _blocksTableHorizontalScrollController,
                                        child: DataTable(
                                          headingRowColor:
                                              MaterialStateProperty.all(
                                                Colors.orange[50],
                                              ),
                                          columns: const [
                                            DataColumn(label: Text("ID")),
                                            DataColumn(label: Text("HH19")),
                                            DataColumn(label: Text("HH49")),
                                            DataColumn(label: Text("EMP19")),
                                            DataColumn(label: Text("EMP49")),
                                            DataColumn(label: Text("PERSNS19")),
                                            DataColumn(label: Text("PERSNS49")),
                                            DataColumn(label: Text("WORKRS19")),
                                            DataColumn(label: Text("WORKRS49")),
                                          ],
                                          rows: () {
                                            if (_blocksTableData.isEmpty) {
                                              return [
                                                const DataRow(
                                                  cells: [
                                                    DataCell(Text("No data")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                    DataCell(Text("")),
                                                  ],
                                                ),
                                              ];
                                            }
                                            final rows =
                                                _blocksTableData.map((row) {
                                                  return DataRow(
                                                    cells: [
                                                      buildDataCell(row['id']),
                                                      buildDataCell(
                                                        row['hh19'],
                                                      ),
                                                      buildDataCell(
                                                        row['hh49'],
                                                      ),
                                                      buildDataCell(
                                                        row['emp19'],
                                                      ),
                                                      buildDataCell(
                                                        row['emp49'],
                                                      ),
                                                      buildDataCell(
                                                        row['persns19'],
                                                      ),
                                                      buildDataCell(
                                                        row['persns49'],
                                                      ),
                                                      buildDataCell(
                                                        row['workrs19'],
                                                      ),
                                                      buildDataCell(
                                                        row['workrs49'],
                                                      ),
                                                    ],
                                                  );
                                                }).toList();

                                            // Summations
                                            final sumHH19 = _blocksTableData
                                                .fold<double>(
                                                  0.0,
                                                  (prev, r) =>
                                                      prev +
                                                      (r['hh19'] as num)
                                                          .toDouble(),
                                                );
                                            final sumHH49 = _blocksTableData
                                                .fold<double>(
                                                  0.0,
                                                  (prev, r) =>
                                                      prev +
                                                      (r['hh49'] as num)
                                                          .toDouble(),
                                                );
                                            final sumEMP19 = _blocksTableData
                                                .fold<double>(
                                                  0.0,
                                                  (prev, r) =>
                                                      prev +
                                                      (r['emp19'] as num)
                                                          .toDouble(),
                                                );
                                            final sumEMP49 = _blocksTableData
                                                .fold<double>(
                                                  0.0,
                                                  (prev, r) =>
                                                      prev +
                                                      (r['emp49'] as num)
                                                          .toDouble(),
                                                );
                                            final sumPERSNS19 = _blocksTableData
                                                .fold<double>(
                                                  0.0,
                                                  (prev, r) =>
                                                      prev +
                                                      (r['persns19'] as num)
                                                          .toDouble(),
                                                );
                                            final sumPERSNS49 = _blocksTableData
                                                .fold<double>(
                                                  0.0,
                                                  (prev, r) =>
                                                      prev +
                                                      (r['persns49'] as num)
                                                          .toDouble(),
                                                );
                                            final sumWORKRS19 = _blocksTableData
                                                .fold<double>(
                                                  0.0,
                                                  (prev, r) =>
                                                      prev +
                                                      (r['workrs19'] as num)
                                                          .toDouble(),
                                                );
                                            final sumWORKRS49 = _blocksTableData
                                                .fold<double>(
                                                  0.0,
                                                  (prev, r) =>
                                                      prev +
                                                      (r['workrs49'] as num)
                                                          .toDouble(),
                                                );

                                            rows.add(
                                              DataRow(
                                                color:
                                                    MaterialStateProperty.all(
                                                      Colors.grey[300],
                                                    ),
                                                cells: [
                                                  const DataCell(
                                                    Text(
                                                      "Total",
                                                      style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                  buildDataCell(sumHH19),
                                                  buildDataCell(sumHH49),
                                                  buildDataCell(sumEMP19),
                                                  buildDataCell(sumEMP49),
                                                  buildDataCell(sumPERSNS19),
                                                  buildDataCell(sumPERSNS49),
                                                  buildDataCell(sumWORKRS19),
                                                  buildDataCell(sumWORKRS49),
                                                ],
                                              ),
                                            );
                                            return rows;
                                          }(),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUploadButtons() {
    return Container(
      padding: const EdgeInsets.all(4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: "Upload Old TAZ GeoJSON file",
            child: IconButton(
              icon: Icon(
                Icons.cloud_upload,
                color: _uploadedOldTaz ? Colors.lightGreen : Colors.red,
              ),
              onPressed: () => _uploadGeoJson("old_taz"),
            ),
          ),
          Tooltip(
            message: "Upload New TAZ GeoJSON file",
            child: IconButton(
              icon: Icon(
                Icons.cloud_upload,
                color: _uploadedNewTaz ? Colors.lightGreen : Colors.red,
              ),
              onPressed: () => _uploadGeoJson("new_taz"),
            ),
          ),
          Tooltip(
            message: "Upload Blocks GeoJSON file",
            child: IconButton(
              icon: Icon(
                Icons.cloud_upload,
                color: _uploadedBlocks ? Colors.lightGreen : Colors.red,
              ),
              onPressed: () => _uploadGeoJson("blocks"),
            ),
          ),
        ],
      ),
    );
  }
}

enum MapViewMode { oldTaz, newTaz, blocks, combined }

/// A simplified annotation-based MapView using fill managers for polygons.
class MapView extends StatefulWidget {
  final String title;
  final MapViewMode mode;
  final bool drawShapes;
  final int? selectedTazId;
  final double? radius;
  final Map<String, dynamic>? cachedOldTaz;
  final Map<String, dynamic>? cachedNewTaz;
  final Map<String, dynamic>? cachedBlocks;
  final RTree<dynamic>? blocksIndex;
  final ValueChanged<int>? onTazSelected;
  final Set<int>? selectedIds;
  final String? mapStyle;
  final CameraPosition? syncedCameraPosition;
  final ValueChanged<CameraPosition>? onCameraIdleSync;
  final bool showIdLabels;

  const MapView({
    Key? key,
    required this.title,
    required this.mode,
    required this.drawShapes,
    this.selectedTazId,
    this.radius,
    this.cachedOldTaz,
    this.cachedNewTaz,
    this.cachedBlocks,
    this.blocksIndex,
    this.onTazSelected,
    this.selectedIds,
    this.mapStyle,
    this.syncedCameraPosition,
    this.onCameraIdleSync,
    this.showIdLabels = false,
  }) : super(key: key);

  @override
  MapViewState createState() => MapViewState();
}

class MapViewState extends State<MapView> {
  MaplibreMapController? controller;
  final Map<String, Map<String, dynamic>> _fillDataMap = {};
  bool _didAddFills = false;
  List<Fill> _allFills = [];
  Fill? _radiusCircleFill;

  @override
  void didUpdateWidget(MapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedTazId != widget.selectedTazId ||
        oldWidget.drawShapes != widget.drawShapes ||
        oldWidget.radius != widget.radius) {
      _didAddFills = false;
      _loadAnnotationFills();
    }
    if (oldWidget.selectedIds != widget.selectedIds && controller != null) {
      _syncSelectedFillColors();
    }
    if (widget.syncedCameraPosition != oldWidget.syncedCameraPosition) {
      _maybeMoveToSyncedPosition();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MaplibreMap(
          styleString:
              widget.mapStyle ??
              'https://basemaps.cartocdn.com/gl/positron-gl-style/style.json',
          onMapCreated: _onMapCreated,
          onStyleLoadedCallback: _onStyleLoaded,
          initialCameraPosition: const CameraPosition(
            target: LatLng(42.3601, -71.0589),
            zoom: 12,
          ),
          onCameraIdle: () async {
            if (controller != null && widget.onCameraIdleSync != null) {
              final pos = await controller!.cameraPosition;
              if (pos != null) {
                widget.onCameraIdleSync!(pos);
              }
            }
          },
        ),
        Positioned(
          top: 8,
          left: 8,
          child: Container(
            color: Colors.white70,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              (widget.mode == MapViewMode.oldTaz)
                  ? "${widget.title}\nTAZ: ${widget.selectedTazId ?? 'None'}"
                  : widget.title,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }

  void _onMapCreated(MaplibreMapController ctrl) {
    controller = ctrl;
    ctrl.onFillTapped.add(_onFillTapped);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _maybeMoveToSyncedPosition(),
    );
  }

  void _onStyleLoaded() {
    _didAddFills = false;
    _loadAnnotationFills();
  }

  void _maybeMoveToSyncedPosition() async {
    if (widget.syncedCameraPosition != null && controller != null) {
      await controller!.moveCamera(
        CameraUpdate.newCameraPosition(widget.syncedCameraPosition!),
      );
    }
  }

  Future<void> _loadAnnotationFills() async {
    if (controller == null) return;

    // Clear old fills, early exit if no search ID or data
    for (final fill in _allFills) {
      await controller!.removeFill(fill);
    }
    _allFills.clear();
    if (widget.selectedTazId == null || !widget.drawShapes) return;
    if (widget.cachedOldTaz == null) return;

    // Find your target TAZ feature
    final feats = widget.cachedOldTaz!['features'] as List<dynamic>;
    final targetF = feats.firstWhere(
      (f) =>
          f['properties']?['taz_id']?.toString() ==
          widget.selectedTazId.toString(),
      orElse: () => null,
    );
    if (targetF == null) {
      debugPrint(
        "❌ No old TAZ found for ID ${widget.selectedTazId}. No polygons drawn.",
      );
      return;
    }
    // Now we know there's a TAZ, let's build polygons
    final targetFeature = turf.Feature.fromJson(targetF);
    final targetCentroid = turf.centroid(targetFeature).geometry as turf.Point;
    final radiusKm = (widget.radius ?? 0.0) / 1000.0;

    // 1) Create TAZ polygons (like in your code), e.g. `_createFillsFromFeatureList(...)`
    // 2) Then call a zoom method once the polygons are done:

    // Example: define a separate method:
    final tazCollection = {
      "type": "FeatureCollection",
      "features": [targetF],
    };
    await _zoomToFeatureBounds(tazCollection);
  }

  Future<void> _zoomToFeatureBounds(
    Map<String, dynamic> featureCollection,
  ) async {
    if (controller == null) return;
    double? minLat, maxLat, minLng, maxLng;

    for (final f in (featureCollection['features'] as List)) {
      final geom = f['geometry'];
      if (geom['type'] == 'Polygon') {
        for (final ring in geom['coordinates']) {
          for (final pt in ring) {
            final lng = (pt[0] as num).toDouble();
            final lat = (pt[1] as num).toDouble();
            minLng = (minLng == null) ? lng : math.min(minLng, lng);
            maxLng = (maxLng == null) ? lng : math.max(maxLng, lng);
            minLat = (minLat == null) ? lat : math.min(minLat, lat);
            maxLat = (maxLat == null) ? lat : math.max(maxLat, lat);
          }
        }
      }
      // or handle MultiPolygon similarly...
    }
    if (minLat != null && maxLat != null && minLng != null && maxLng != null) {
      final bounds = LatLngBounds(
        southwest: LatLng(minLat, minLng),
        northeast: LatLng(maxLat, maxLng),
      );
      await controller!.moveCamera(
        CameraUpdate.newLatLngBounds(
          bounds,
          left: 50,
          right: 50,
          top: 50,
          bottom: 50,
        ),
      );
    }
  }

  Future<void> _loadOldTazAsFills(
    List<dynamic> feats,
    turf.Point center,
    double radiusKm, {
    double fillOpacity = 0.06,
    String lineColor = "#4169E1",
  }) async {
    final within = filterFeaturesWithinDistance(feats, center, radiusKm);
    final target =
        within.where((f) {
          final tid = f['properties']['taz_id']?.toString();
          return tid == widget.selectedTazId.toString();
        }).toList();
    final others =
        within.where((f) {
          final tid = f['properties']['taz_id']?.toString();
          return tid != widget.selectedTazId.toString();
        }).toList();
    await _createFillsFromFeatureList(
      target,
      color: "#ff8000",
      fillOpacity: fillOpacity,
      storeInList: _allFills,
    );
    await _createFillsFromFeatureList(
      others,
      color: lineColor,
      fillOpacity: fillOpacity,
      storeInList: _allFills,
    );
  }

  Future<void> _loadBlocksAsFills(
    turf.Point center,
    double radiusKm, {
    double fillOpacity = 0.05,
  }) async {
    if (widget.cachedBlocks == null) return;
    final blocksData = widget.cachedBlocks!;
    final feats = blocksData['features'] as List<dynamic>;

    final cLat = (center.coordinates[1] as num?)?.toDouble() ?? 0.0;
    final cLng = (center.coordinates[0] as num?)?.toDouble() ?? 0.0;
    final degLat = radiusKm / 110.574;
    final cosPart = math.cos(cLat * math.pi / 180.0);
    final degLng = (cosPart == 0) ? 0.0 : radiusKm / (111.320 * cosPart);
    final rect = Rectangle<double>(
      cLng - degLng,
      cLat - degLat,
      degLng * 2,
      degLat * 2,
    );

    List<dynamic> cands;
    if (widget.blocksIndex != null) {
      final sr = Rectangle<num>(rect.left, rect.top, rect.width, rect.height);
      cands = widget.blocksIndex!.search(sr).map((d) => d.value).toList();
    } else {
      cands = feats;
    }
    final filtered =
        cands.where((block) {
          final bFeat = turf.Feature.fromJson(block);
          final pCent = turf.centroid(bFeat).geometry as turf.Point;
          return isWithinBBoxAndDistance(pCent, rect, center, radiusKm);
        }).toList();

    await _createFillsFromFeatureList(
      filtered,
      color: "#FFA500",
      fillOpacity: fillOpacity,
      storeInList: _allFills,
    );
  }

  Future<void> _createFillsFromFeatureList(
    List<dynamic> feats, {
    required String color,
    required double fillOpacity,
    required List<Fill> storeInList,
  }) async {
    if (controller == null || feats.isEmpty) return;

    final fillOpts = <FillOptions>[];
    final metaList = <Map<String, dynamic>>[];

    for (final feat in feats) {
      final geom = feat['geometry'] as Map<String, dynamic>;
      final props = feat['properties'] as Map<String, dynamic>;
      final polyId = _extractIdForMode(props);

      final meta = <String, dynamic>{};
      if (widget.mode == MapViewMode.blocks) {
        meta['block_id'] = polyId;
      } else {
        meta['taz_id'] = polyId;
      }
      if (geom['type'] == 'Polygon') {
        final ring = geom['coordinates'][0];
        final latlngRing =
            ring.map<LatLng>((pt) {
              final lat = (pt[1] as num?)?.toDouble() ?? 0.0;
              final lng = (pt[0] as num?)?.toDouble() ?? 0.0;
              return LatLng(lat, lng);
            }).toList();
        fillOpts.add(
          FillOptions(
            geometry: [latlngRing],
            fillColor: color,
            fillOpacity: fillOpacity,
          ),
        );
        metaList.add(meta);
      } else if (geom['type'] == 'MultiPolygon') {
        final multiCoords = geom['coordinates'];
        for (final poly in multiCoords) {
          final ring = poly[0];
          final latlngRing =
              ring.map<LatLng>((pt) {
                final lat = (pt[1] as num?)?.toDouble() ?? 0.0;
                final lng = (pt[0] as num?)?.toDouble() ?? 0.0;
                return LatLng(lat, lng);
              }).toList();
          fillOpts.add(
            FillOptions(
              geometry: [latlngRing],
              fillColor: color,
              fillOpacity: fillOpacity,
            ),
          );
          metaList.add(meta);
        }
      }
    }
    final newFills = await controller!.addFills(fillOpts);
    storeInList.addAll(newFills);
    for (int i = 0; i < newFills.length; i++) {
      final fill = newFills[i];
      _fillDataMap[fill.id] = metaList[i];
    }
  }

  Future<void> _drawRadiusCircle(turf.Point center, double radiusKm) async {
    if (controller == null) return;
    final circleJson = createCirclePolygon(center, radiusKm, steps: 64);
    final ringCoords = circleJson['geometry']['coordinates'][0];
    final latlngRing =
        (ringCoords as List).map<LatLng>((pt) {
          final lat = (pt[1] as num?)?.toDouble() ?? 0.0;
          final lng = (pt[0] as num?)?.toDouble() ?? 0.0;
          return LatLng(lat, lng);
        }).toList();

    final opts = FillOptions(
      geometry: [latlngRing],
      fillColor: "#FF8C00",
      fillOpacity: 0.0,
    );
    final circleFills = await controller!.addFills([opts]);
    if (circleFills.isNotEmpty) {
      _radiusCircleFill = circleFills.first;
    }
  }

  void _syncSelectedFillColors() async {
    if (widget.mode == MapViewMode.newTaz ||
        widget.mode == MapViewMode.blocks) {
      final selIds = widget.selectedIds ?? {};
      for (final fill in _allFills) {
        final data = _fillDataMap[fill.id] ?? {};
        int? fillId;
        if (widget.mode == MapViewMode.blocks) {
          fillId = data['block_id'] as int?;
        } else {
          fillId = data['taz_id'] as int?;
        }
        if (fillId == null) continue;

        final isSelected = selIds.contains(fillId);
        final newColor = isSelected ? "#ffe100" : fill.options.fillColor;
        if (newColor != fill.options.fillColor) {
          await controller!.updateFill(fill, FillOptions(fillColor: newColor));
        }
      }
    }
  }

  void _onFillTapped(Fill fill) async {
    final meta = _fillDataMap[fill.id] ?? {};
    final tazId = meta['taz_id'];
    final blockId = meta['block_id'];
    if (tazId != null) {
      final tid = (tazId is int) ? tazId : int.tryParse(tazId.toString()) ?? 0;
      widget.onTazSelected?.call(tid);
    }
    if (blockId != null) {
      final bid =
          (blockId is int) ? blockId : int.tryParse(blockId.toString()) ?? 0;
      widget.onTazSelected?.call(bid);
    }

    // immediate color toggle
    final currColor = fill.options.fillColor ?? '#FF0000';
    final altColor = (currColor == '#ffe100') ? '#FF0000' : '#ffe100';
    await controller!.updateFill(fill, FillOptions(fillColor: altColor));
  }

  int? _extractIdForMode(Map<String, dynamic> props) {
    if (widget.mode == MapViewMode.blocks) {
      final raw = props['geoid20'];
      if (raw == null) return null;
      return (raw is int) ? raw : int.tryParse(raw.toString());
    } else {
      final raw = props['taz_id'];
      if (raw == null) return null;
      return (raw is int) ? raw : int.tryParse(raw.toString());
    }
  }
}
