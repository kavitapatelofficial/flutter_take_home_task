/// 64-bit FNV-1a, rendered as 16 hex characters.
///
/// Used wherever an identifier has to be a pure function of content, so that
/// replaying the same input twice lands on the same row instead of creating a
/// second one. Not a security hash; collision risk at our row counts is
/// negligible.
String stableId(Iterable<Object?> parts) {
  const offset = 0xcbf29ce484222325;
  const prime = 0x100000001b3;
  var hash = offset;
  for (final part in parts) {
    for (final b in '$part|'.codeUnits) {
      hash ^= b;
      hash = (hash * prime) & 0xFFFFFFFFFFFFFFFF;
    }
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}
