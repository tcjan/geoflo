import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:geoflo/geoflo.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: const GeoJsonMapScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class GeoJsonMapScreen extends StatefulWidget {
  const GeoJsonMapScreen({super.key});

  @override
  _GeoJsonMapScreenState createState() => _GeoJsonMapScreenState();
}

class _GeoJsonMapScreenState extends State<GeoJsonMapScreen> {
  Map<String, dynamic>? geoJsonOldTaz;
  Map<String, dynamic>? geoJsonNewTaz;
  Map<String, dynamic>? geoJsonBlocks;

  @override
  void initState() {
    super.initState();
    _loadGeoJsonData();
  }

  Future<void> _loadGeoJsonData() async {
    final oldTazString = await rootBundle.loadString(
      'assets/geojson/old_taz.geojson',
    );
    final newTazString = await rootBundle.loadString(
      'assets/geojson/new_taz.geojson',
    );
    final blocksString = await rootBundle.loadString(
      'assets/geojson/blocks.geojson',
    );

    setState(() {
      geoJsonOldTaz = jsonDecode(oldTazString);
      geoJsonNewTaz = jsonDecode(newTazString);
      geoJsonBlocks = jsonDecode(blocksString);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (geoJsonOldTaz == null ||
        geoJsonNewTaz == null ||
        geoJsonBlocks == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final overlayConfigurations = {
      'new_taz_overlay': {
        'sourceId': 'new_taz_source',
        'geojsonData': geoJsonNewTaz,
        'layerProperties': {
          'fillColor': '#00FF00',
          'fillOpacity': 0.6,
          'interactive': true,
        },
      },
      'old_taz_overlay': {
        'sourceId': 'old_taz_source',
        'geojsonData': geoJsonOldTaz,
        'layerProperties': {
          'fillColor': '#FF0000',
          'fillOpacity': 0.3,
          'interactive': false,
        },
      },
      'blocks_overlay': {
        'sourceId': 'blocks_source',
        'geojsonData': geoJsonBlocks,
        'layerProperties': {
          'fillColor': '#0000FF',
          'fillOpacity': 0.2,
          'interactive': false,
        },
      },
    };

    return Scaffold(
      appBar: AppBar(title: const Text('GeoShape Overlay Map')),
      body: GeoShapeOverlayMap(
        overlayConfigurations: overlayConfigurations,
        onFeatureSelect: (overlayId, featureId) {
          debugPrint('Selected feature: $featureId from overlay: $overlayId');
        },
      ),
    );
  }
}
