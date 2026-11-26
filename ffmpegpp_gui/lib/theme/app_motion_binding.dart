import 'package:flutter/widgets.dart';

/// Extends the framework's reduced-motion policy to the app preference.
/// Native controls consult the binding directly for their private controllers.
mixin AppMotionBinding on WidgetsBinding {
  bool appAnimationsDisabled = false;

  @override
  bool get disableAnimations =>
      appAnimationsDisabled || super.disableAnimations;
}

/// Each window owns a binding, so native controls follow that window's config.
class AppWidgetsFlutterBinding extends WidgetsFlutterBinding
    with AppMotionBinding {}
