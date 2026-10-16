class CameraFraming {
  String fitMode;
  double zoom;
  double offsetX;
  double offsetY;
  int rotation;
  bool mirror;

  CameraFraming({
    this.fitMode = 'fill',
    this.zoom = 1.0,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
    this.rotation = 0,
    required this.mirror,
  });

  Map<String, dynamic> toMap(String target) => {
    'target': target,
    'fitMode': fitMode,
    'zoom': zoom,
    'offsetX': offsetX,
    'offsetY': offsetY,
    'rotation': rotation,
    'mirror': mirror,
  };
}
