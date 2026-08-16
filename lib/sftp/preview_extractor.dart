import 'dart:math';
import 'dart:typed_data';

// outcome of inspecting the first chunk (~128 KB) of a remote JPEG
class JpegInspection {
  // full image dimensions from the SOF marker, when found in the chunk
  final int? width, height;

  // embedded EXIF (IFD1) thumbnail located entirely within the inspected chunk
  final Uint8List? previewBytes;

  // when the EXIF thumbnail lies (partly) beyond the inspected chunk:
  // absolute file offset + length of the preview, for a second ranged read
  final int? previewOffset, previewLength;

  // display orientation from the EXIF (IFD0) orientation tag
  final int? rotationDegrees;
  final bool isFlipped;

  const JpegInspection({
    this.width,
    this.height,
    this.previewBytes,
    this.previewOffset,
    this.previewLength,
    this.rotationDegrees,
    this.isFlipped = false,
  });

  bool get hasInlinePreview => previewBytes != null;

  bool get needsRangedRead => previewBytes == null && previewOffset != null;
}

// parses JPEG headers from a partial byte range:
// - walks JPEG segment markers to find SOF0/1/2 dimensions
// - parses the EXIF APP1 segment (TIFF structure, IFD0 orientation, IFD1) to
//   locate the embedded thumbnail via JPEGInterchangeFormat (0x0201) and
//   JPEGInterchangeFormatLength (0x0202) tags
// tolerant of truncated input: returns whatever was found before the chunk ends.
// `headerBytes` starts at file offset 0.
class JpegPreviewExtractor {
  static const _markerSoi = 0xd8;
  static const _markerEoi = 0xd9;
  static const _markerSos = 0xda;
  static const _markerApp1 = 0xe1;
  static const _sofMarkers = {0xc0, 0xc1, 0xc2};
  static const _standaloneMarkers = {0x01, 0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, _markerSoi};
  static const _exifIdentifier = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];

  static const _tagOrientation = 0x0112;
  static const _tagThumbnailOffset = 0x0201;
  static const _tagThumbnailLength = 0x0202;
  static const _typeShort = 3;
  static const _typeLong = 4;

  // EXIF orientation -> rotation in degrees + horizontal mirroring
  static const _orientations = {
    1: (0, false),
    2: (0, true),
    3: (180, false),
    4: (180, true),
    5: (270, true),
    6: (90, false),
    7: (90, true),
    8: (270, false),
  };

  static JpegInspection inspect(Uint8List headerBytes) {
    final length = headerBytes.length;
    if (length < 4 || headerBytes[0] != 0xff || headerBytes[1] != _markerSoi) return const JpegInspection();

    final data = ByteData.sublistView(headerBytes);
    int? width, height;
    _Exif? exif;

    var offset = 2;
    while (offset + 4 <= length) {
      if (headerBytes[offset] != 0xff) break;

      final marker = headerBytes[offset + 1];
      if (marker == 0xff) {
        offset++;
        continue;
      }
      if (_standaloneMarkers.contains(marker)) {
        offset += 2;
        continue;
      }
      if (marker == _markerSos || marker == _markerEoi) break;

      final segmentLength = data.getUint16(offset + 2);
      if (segmentLength < 2) break;

      final payload = offset + 4;
      final segmentEnd = offset + 2 + segmentLength;
      if (_sofMarkers.contains(marker)) {
        if (payload + 5 <= length) {
          height = data.getUint16(payload + 1);
          width = data.getUint16(payload + 3);
        }
      } else if (marker == _markerApp1) {
        exif ??= _parseExif(headerBytes, data, payload, min(segmentEnd, length));
      }

      offset = segmentEnd;
    }

    final orientation = exif == null ? null : _orientations[exif.orientation];
    final rotationDegrees = orientation?.$1;
    final isFlipped = orientation?.$2 ?? false;

    final preview = exif?.thumbnail;
    if (preview == null) {
      return JpegInspection(
        width: width,
        height: height,
        rotationDegrees: rotationDegrees,
        isFlipped: isFlipped,
      );
    }

    if (preview.end <= length) {
      return JpegInspection(
        width: width,
        height: height,
        previewBytes: headerBytes.sublist(preview.offset, preview.end),
        rotationDegrees: rotationDegrees,
        isFlipped: isFlipped,
      );
    }
    return JpegInspection(
      width: width,
      height: height,
      previewOffset: preview.offset,
      previewLength: preview.length,
      rotationDegrees: rotationDegrees,
      isFlipped: isFlipped,
    );
  }

  // orientation (IFD0) and absolute file range of the IFD1 thumbnail, from the EXIF
  // APP1 segment spanning `[payloadStart, payloadEnd[`, or null when this is not EXIF.
  // TIFF offsets are relative to the TIFF header, right after the `Exif\0\0` identifier.
  static _Exif? _parseExif(Uint8List bytes, ByteData data, int payloadStart, int payloadEnd) {
    if (payloadStart + _exifIdentifier.length > payloadEnd) return null;
    for (var i = 0; i < _exifIdentifier.length; i++) {
      if (bytes[payloadStart + i] != _exifIdentifier[i]) return null;
    }

    final tiffStart = payloadStart + _exifIdentifier.length;
    if (tiffStart + 8 > payloadEnd) return null;

    final Endian endian;
    switch (data.getUint16(tiffStart)) {
      case 0x4949:
        endian = Endian.little;
      case 0x4d4d:
        endian = Endian.big;
      default:
        return null;
    }
    if (data.getUint16(tiffStart + 2, endian) != 42) return null;

    final ifd0 = tiffStart + data.getUint32(tiffStart + 4, endian);
    if (ifd0 + 2 > payloadEnd) return null;

    final ifd0EntryCount = data.getUint16(ifd0, endian);
    int? orientation;
    for (var i = 0; i < ifd0EntryCount; i++) {
      final entry = ifd0 + 2 + i * 12;
      if (entry + 12 > payloadEnd) break;

      if (data.getUint16(entry, endian) == _tagOrientation) {
        orientation = _entryValue(data, entry, endian);
      }
    }

    final nextIfdPointer = ifd0 + 2 + ifd0EntryCount * 12;
    if (nextIfdPointer + 4 > payloadEnd) return _Exif(orientation, null);

    final ifd1Offset = data.getUint32(nextIfdPointer, endian);
    if (ifd1Offset == 0) return _Exif(orientation, null);

    final ifd1 = tiffStart + ifd1Offset;
    if (ifd1 + 2 > payloadEnd) return _Exif(orientation, null);

    final ifd1EntryCount = data.getUint16(ifd1, endian);
    int? thumbnailOffset, thumbnailLength;
    for (var i = 0; i < ifd1EntryCount; i++) {
      final entry = ifd1 + 2 + i * 12;
      if (entry + 12 > payloadEnd) break;

      final tag = data.getUint16(entry, endian);
      if (tag != _tagThumbnailOffset && tag != _tagThumbnailLength) continue;

      final value = _entryValue(data, entry, endian);
      if (value == null) continue;

      if (tag == _tagThumbnailOffset) {
        thumbnailOffset = value;
      } else {
        thumbnailLength = value;
      }
    }
    if (thumbnailOffset == null || thumbnailLength == null || thumbnailLength <= 0) return _Exif(orientation, null);

    return _Exif(orientation, _Range(tiffStart + thumbnailOffset, thumbnailLength));
  }

  // value of a single SHORT/LONG IFD entry, stored inline in the entry value field
  static int? _entryValue(ByteData data, int entry, Endian endian) {
    final valueOffset = entry + 8;
    switch (data.getUint16(entry + 2, endian)) {
      case _typeShort:
        return data.getUint16(valueOffset, endian);
      case _typeLong:
        return data.getUint32(valueOffset, endian);
      default:
        return null;
    }
  }
}

class _Exif {
  final int? orientation;
  final _Range? thumbnail;

  const _Exif(this.orientation, this.thumbnail);
}

class _Range {
  final int offset, length;

  int get end => offset + length;

  const _Range(this.offset, this.length);
}
