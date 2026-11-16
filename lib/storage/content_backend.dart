/// Chooses the platform's content [StorageBackend]: IndexedDB on the web, and
/// [UnavailableStorageBackend] everywhere else (§5.10).
library;

import 'content_backend_stub.dart'
    if (dart.library.js_interop) 'indexed_db_storage_backend_web.dart'
    as platform;
import 'storage_backend.dart';

StorageBackend createContentBackend() =>
    platform.createPlatformContentBackend();
