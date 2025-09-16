// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';

/// Result of picking an asset, containing both the file and optional local identifier.
///
/// This class provides access to the picked file through [file] and the platform-specific
/// local identifier through [localIdentifier] (iOS only, null on Android).
@immutable
class AssetResult {
  /// Creates an [AssetResult] with the given [file] and optional [localIdentifier].
  const AssetResult({
    required this.file,
    this.localIdentifier,
  });

  /// The picked file.
  final XFile file;

  /// The local identifier of the asset on iOS.
  ///
  /// This is the persistent identifier that can be used to retrieve the asset
  /// from the Photos library on iOS. On Android, this is always null.
  final String? localIdentifier;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other is AssetResult &&
            file.path == other.file.path &&
            localIdentifier == other.localIdentifier);
  }

  @override
  int get hashCode => Object.hash(file.path, localIdentifier);

  @override
  String toString() {
    return 'AssetResult(file: ${file.path}, localIdentifier: $localIdentifier)';
  }
}
