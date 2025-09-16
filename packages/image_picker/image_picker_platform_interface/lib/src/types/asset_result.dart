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

  /// The ID of the asset.
  ///  * Android: `_id` column in `MediaStore` database, as a string.
  ///  * iOS/macOS: `localIdentifier` from Photos framework.
  ///
  /// This identifier is intended for same-device lookups within the current
  /// session; availability depends on the underlying provider. Some sources
  /// (e.g., cloud-backed URIs) may return null.
  final String? localIdentifier;

  @override
  bool operator ==(Object other) {
    return identical(this, other) || (other is AssetResult && file.path == other.file.path && localIdentifier == other.localIdentifier);
  }

  @override
  int get hashCode => Object.hash(file.path, localIdentifier);

  @override
  String toString() {
    return 'AssetResult(file: ${file.path}, localIdentifier: $localIdentifier)';
  }
}
