import 'storage_backend.dart';

/// Non-web builds keep content in memory only and say so (§5.10).
StorageBackend createPlatformContentBackend() =>
    const UnavailableStorageBackend();
