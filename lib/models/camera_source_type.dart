import 'package:flutter/cupertino.dart';

enum CameraSourceType {
  webcam('FaceTime HD Camera', CupertinoIcons.video_camera_solid),
  passthrough('Screen Passthrough', CupertinoIcons.macwindow),
  demoVideo('Demo Video Loop', CupertinoIcons.play_rectangle_fill),
  image('Custom Image File...', CupertinoIcons.photo_fill),
  video('Custom Video File...', CupertinoIcons.film_fill),
  qrCode('Dynamic QR Code', CupertinoIcons.qrcode),
  testPattern('SMPTE Test Bars', CupertinoIcons.tv_fill);

  final String title;
  final IconData icon;
  const CameraSourceType(this.title, this.icon);
}
