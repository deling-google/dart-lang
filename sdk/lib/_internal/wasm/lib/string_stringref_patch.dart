// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// TODO: Implementation of strings for the stringref target.
// For now, this file is identical to string_patch.dart.
// When we implement the stringref strings here, we'll likely also need to
// restructure some other patch files to make code dependent on the string
// implementation live in separate patch files for the two targets.

import "dart:_internal"
    show
        CodeUnits,
        ClassID,
        doubleToIntBits,
        EfficientLengthIterable,
        intBitsToDouble,
        IterableElementError,
        jsonEncode,
        Lists,
        mix64,
        makeListFixedLength,
        patch,
        unsafeCast,
        writeIntoOneByteString,
        writeIntoTwoByteString;

import 'dart:_js_helper' show JS;
import 'dart:_js_types' show JSStringImpl;
import 'dart:_object_helper';
import 'dart:_string_helper';
import 'dart:_wasm';

import "dart:typed_data" show Uint8List, Uint16List;

const int _maxAscii = 0x7f;
const int _maxLatin1 = 0xff;
const int _maxUtf16 = 0xffff;
const int _maxUnicode = 0x10ffff;

/// The [fromStart] and [toStart] indices together with the [length] must
/// specify ranges within the bounds of the list / string.
void _copyRangeFromUint8ListToOneByteString(
    Uint8List from, _OneByteString to, int fromStart, int toStart, int length) {
  for (int i = 0; i < length; i++) {
    to._setAt(toStart + i, from[fromStart + i]);
  }
}

String _toUpperCase(String string) => JS<String>(
    "s => stringToDartString(stringFromDartString(s).toUpperCase())", string);

String _toLowerCase(String string) => JS<String>(
    "s => stringToDartString(stringFromDartString(s).toLowerCase())", string);

@patch
class String {
  @patch
  factory String.fromCharCodes(Iterable<int> charCodes,
      [int start = 0, int? end]) {
    return _StringBase.createFromCharCodes(charCodes, start, end, null);
  }

  @patch
  factory String.fromCharCode(int charCode) {
    if (charCode >= 0) {
      if (charCode <= 0xff) {
        return _OneByteString._allocate(1).._setAt(0, charCode);
      }
      if (charCode <= 0xffff) {
        return _TwoByteString._allocate(1).._setAt(0, charCode);
      }
      if (charCode <= 0x10ffff) {
        int low = 0xDC00 | (charCode & 0x3ff);
        int bits = charCode - 0x10000;
        int high = 0xD800 | (bits >> 10);
        return _TwoByteString._allocate(2)
          .._setAt(0, high)
          .._setAt(1, low);
      }
    }
    throw new RangeError.range(charCode, 0, 0x10ffff);
  }

  @patch
  external const factory String.fromEnvironment(String name,
      {String defaultValue = ""});
}

extension _StringExtension on String {
  bool get _isOneByte => this is _OneByteString;
}

/**
 * [_StringBase] contains common methods used by concrete String
 * implementations, e.g., _OneByteString.
 */
abstract final class _StringBase implements String {
  bool _isWhitespace(int codeUnit);

  // Constants used by replaceAll encoding of string slices between matches.
  // A string slice (start+length) is encoded in a single Smi to save memory
  // overhead in the common case.
  // We use fewer bits for length (11 bits) than for the start index (19+ bits).
  // For long strings, it's possible to have many large indices,
  // but it's unlikely to have many long lengths since slices don't overlap.
  // If there are few matches in a long string, then there are few long slices,
  // and if there are many matches, there'll likely be many short slices.
  //
  // Encoding is: 0((start << _lengthBits) | length)

  // Number of bits used by length.
  // This is the shift used to encode and decode the start index.
  static const int _lengthBits = 11;
  // The maximal allowed length value in an encoded slice.
  static const int _maxLengthValue = (1 << _lengthBits) - 1;
  // Mask of length in encoded smi value.
  static const int _lengthMask = _maxLengthValue;
  static const int _startBits = _maxUnsignedSmiBits - _lengthBits;
  // Maximal allowed start index value in an encoded slice.
  static const int _maxStartValue = (1 << _startBits) - 1;
  // We pick 30 as a safe lower bound on available bits in a negative smi.
  // TODO(lrn): Consider allowing more bits for start on 64-bit systems.
  static const int _maxUnsignedSmiBits = 30;

  // For longer strings, calling into C++ to create the result of a
  // [replaceAll] is faster than [_joinReplaceAllOneByteResult].
  // TODO(lrn): See if this limit can be tweaked.
  static const int _maxJoinReplaceOneByteStringLength = 500;

  _StringBase._();

  int get hashCode {
    int hash = getHash(this);
    if (hash != 0) return hash;
    hash = _computeHashCode();
    setHash(this, hash);
    return hash;
  }

  int _computeHashCode();

  /**
   * Create the most efficient string representation for specified
   * [charCodes].
   *
   * Only uses the character codes between index [start] and index [end] of
   * `charCodes`. They must satisfy `0 <= start <= end <= charCodes.length`.
   *
   * The [limit] is an upper limit on the character codes in the iterable.
   * It's `null` if unknown.
   */
  static String createFromCharCodes(
      Iterable<int> charCodes, int start, int? end, int? limit) {
    // TODO(srdjan): Also skip copying of wide typed arrays.
    final ccid = ClassID.getID(charCodes);
    if (ccid != ClassID.cidFixedLengthList &&
        ccid != ClassID.cidListBase &&
        ccid != ClassID.cidGrowableList &&
        ccid != ClassID.cidImmutableList) {
      if (charCodes is Uint8List) {
        final actualEnd =
            RangeError.checkValidRange(start, end, charCodes.length);
        return _createOneByteString(charCodes, start, actualEnd - start);
      } else if (charCodes is! Uint16List) {
        return _createStringFromIterable(charCodes, start, end);
      }
    }
    final int codeCount = charCodes.length;
    final actualEnd = RangeError.checkValidRange(start, end, codeCount);
    final len = actualEnd - start;
    if (len == 0) return "";

    final typedCharCodes = unsafeCast<List<int>>(charCodes);

    final int actualLimit =
        limit ?? _scanCodeUnits(typedCharCodes, start, actualEnd);
    if (actualLimit < 0) {
      throw new ArgumentError(typedCharCodes);
    }
    if (actualLimit <= _maxLatin1) {
      return _createOneByteString(typedCharCodes, start, len);
    }
    if (actualLimit <= _maxUtf16) {
      return _TwoByteString._allocateFromTwoByteList(
          typedCharCodes, start, actualEnd);
    }
    // TODO(lrn): Consider passing limit to _createFromCodePoints, because
    // the function is currently fully generic and doesn't know that its
    // charCodes are not all Latin-1 or Utf-16.
    return _createFromCodePoints(typedCharCodes, start, actualEnd);
  }

  static int _scanCodeUnits(List<int> charCodes, int start, int end) {
    int bits = 0;
    for (int i = start; i < end; i++) {
      int code = charCodes[i];
      bits |= code;
    }
    return bits;
  }

  static String _createStringFromIterable(
      Iterable<int> charCodes, int start, int? end) {
    // Treat charCodes as Iterable.
    if (charCodes is EfficientLengthIterable) {
      int length = charCodes.length;
      final endVal = RangeError.checkValidRange(start, end, length);
      final charCodeList =
          List<int>.from(charCodes.take(endVal).skip(start), growable: false);
      return createFromCharCodes(charCodeList, 0, charCodeList.length, null);
    }
    // Don't know length of iterable, so iterate and see if all the values
    // are there.
    if (start < 0) throw new RangeError.range(start, 0, charCodes.length);
    var it = charCodes.iterator;
    for (int i = 0; i < start; i++) {
      if (!it.moveNext()) {
        throw new RangeError.range(start, 0, i);
      }
    }
    List<int> charCodeList;
    int bits = 0; // Bitwise-or of all char codes in list.
    final endVal = end;
    if (endVal == null) {
      var list = <int>[];
      while (it.moveNext()) {
        int code = it.current;
        bits |= code;
        list.add(code);
      }
      charCodeList = makeListFixedLength<int>(list);
    } else {
      if (endVal < start) {
        throw new RangeError.range(endVal, start, charCodes.length);
      }
      int len = endVal - start;
      charCodeList = new List<int>.generate(len, (int i) {
        if (!it.moveNext()) {
          throw new RangeError.range(endVal, start, start + i);
        }
        int code = it.current;
        bits |= code;
        return code;
      });
    }
    int length = charCodeList.length;
    if (bits < 0) {
      throw new ArgumentError(charCodes);
    }
    bool isOneByteString = (bits <= _maxLatin1);
    if (isOneByteString) {
      return _createOneByteString(charCodeList, 0, length);
    }
    return createFromCharCodes(charCodeList, 0, length, bits);
  }

  // Inlining is disabled as a workaround to http://dartbug.com/37800.

  static String _createOneByteString(List<int> charCodes, int start, int len) {
    // It's always faster to do this in Dart than to call into the runtime.
    var s = _OneByteString._allocate(len);

    // Special case for native Uint8 typed arrays.
    if (charCodes is Uint8List) {
      _copyRangeFromUint8ListToOneByteString(charCodes, s, start, 0, len);
      return s;
    }

    // Fall through to normal case.
    for (int i = 0; i < len; i++) {
      s._setAt(i, charCodes[start + i]);
    }
    return s;
  }

  static String _createFromOneByteCodes(
      List<int> charCodes, int start, int end) {
    _OneByteString result = _OneByteString._allocate(end - start);
    for (int i = start; i < end; i++) {
      result._setAt(i - start, charCodes[i]);
    }
    return result;
  }

  static String _createFromCodePoints(List<int> charCodes, int start, int end) {
    for (int i = start; i < end; i++) {
      int c = charCodes[i];
      if (c < 0) throw ArgumentError.value(i);
      if (c > 0xff) {
        return _createFromAdjustedCodePoints(charCodes, start, end);
      }
    }
    return _createFromOneByteCodes(charCodes, start, end);
  }

  static String _createFromAdjustedCodePoints(
      List<int> codePoints, int start, int end) {
    StringBuffer a = StringBuffer();
    for (int i = start; i < end; i++) {
      a.writeCharCode(codePoints[i]);
    }
    return a.toString();
  }

  String operator [](int index) => String.fromCharCode(codeUnitAt(index));

  int codeUnitAt(int index); // Implemented in the subclasses.

  int get length; // Implemented in the subclasses.

  bool get isEmpty {
    return this.length == 0;
  }

  bool get isNotEmpty => !isEmpty;

  String operator +(String other) => _interpolate([this, other]);

  String toString() {
    return this;
  }

  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is String && this.length == other.length) {
      final len = this.length;
      for (int i = 0; i < len; i++) {
        if (this.codeUnitAt(i) != other.codeUnitAt(i)) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  int compareTo(String other) {
    int thisLength = this.length;
    int otherLength = other.length;
    int len = (thisLength < otherLength) ? thisLength : otherLength;
    for (int i = 0; i < len; i++) {
      int thisCodeUnit = this.codeUnitAt(i);
      int otherCodeUnit = other.codeUnitAt(i);
      if (thisCodeUnit < otherCodeUnit) {
        return -1;
      }
      if (thisCodeUnit > otherCodeUnit) {
        return 1;
      }
    }
    if (thisLength < otherLength) return -1;
    if (thisLength > otherLength) return 1;
    return 0;
  }

  bool _substringMatches(int start, String other) {
    if (other.isEmpty) return true;
    final len = other.length;
    if ((start < 0) || (start + len > this.length)) {
      return false;
    }
    for (int i = 0; i < len; i++) {
      if (this.codeUnitAt(i + start) != other.codeUnitAt(i)) {
        return false;
      }
    }
    return true;
  }

  bool endsWith(String other) {
    return _substringMatches(this.length - other.length, other);
  }

  bool startsWith(Pattern pattern, [int index = 0]) {
    if ((index < 0) || (index > this.length)) {
      throw new RangeError.range(index, 0, this.length);
    }
    if (pattern is String) {
      return _substringMatches(index, pattern);
    }
    return pattern.matchAsPrefix(this, index) != null;
  }

  int indexOf(Pattern pattern, [int start = 0]) {
    if ((start < 0) || (start > this.length)) {
      throw new RangeError.range(start, 0, this.length, "start");
    }
    if (pattern is String) {
      String other = pattern;
      int maxIndex = this.length - other.length;
      // TODO: Use an efficient string search (e.g. BMH).
      for (int index = start; index <= maxIndex; index++) {
        if (_substringMatches(index, other)) {
          return index;
        }
      }
      return -1;
    }
    for (int i = start; i <= this.length; i++) {
      // TODO(11276); This has quadratic behavior because matchAsPrefix tries
      // to find a later match too. Optimize matchAsPrefix to avoid this.
      if (pattern.matchAsPrefix(this, i) != null) return i;
    }
    return -1;
  }

  int lastIndexOf(Pattern pattern, [int? start]) {
    if (start == null) {
      start = this.length;
    } else if (start < 0 || start > this.length) {
      throw new RangeError.range(start, 0, this.length);
    }
    if (pattern is String) {
      String other = pattern;
      int maxIndex = this.length - other.length;
      if (maxIndex < start) start = maxIndex;
      for (int index = start; index >= 0; index--) {
        if (_substringMatches(index, other)) {
          return index;
        }
      }
      return -1;
    }
    for (int i = start; i >= 0; i--) {
      // TODO(11276); This has quadratic behavior because matchAsPrefix tries
      // to find a later match too. Optimize matchAsPrefix to avoid this.
      if (pattern.matchAsPrefix(this, i) != null) return i;
    }
    return -1;
  }

  String substring(int startIndex, [int? endIndex]) {
    endIndex = RangeError.checkValidRange(startIndex, endIndex, this.length);
    return _substringUnchecked(startIndex, endIndex);
  }

  String _substringUnchecked(int startIndex, int endIndex) {
    assert((startIndex >= 0) && (startIndex <= this.length));
    assert((endIndex >= 0) && (endIndex <= this.length));
    assert(startIndex <= endIndex);

    if (startIndex == endIndex) {
      return "";
    }
    if ((startIndex == 0) && (endIndex == this.length)) {
      return this;
    }
    if ((startIndex + 1) == endIndex) {
      return this[startIndex];
    }
    return _substringUncheckedInternal(startIndex, endIndex);
  }

  String _substringUncheckedInternal(int startIndex, int endIndex);

  // Checks for one-byte whitespaces only.
  static bool _isOneByteWhitespace(int codeUnit) {
    if (codeUnit <= 32) {
      return ((codeUnit == 32) || // Space.
          ((codeUnit <= 13) && (codeUnit >= 9))); // CR, LF, TAB, etc.
    }
    return (codeUnit == 0x85) || (codeUnit == 0xA0); // NEL, NBSP.
  }

  // Characters with Whitespace property (Unicode 6.3).
  // 0009..000D    ; White_Space # Cc       <control-0009>..<control-000D>
  // 0020          ; White_Space # Zs       SPACE
  // 0085          ; White_Space # Cc       <control-0085>
  // 00A0          ; White_Space # Zs       NO-BREAK SPACE
  // 1680          ; White_Space # Zs       OGHAM SPACE MARK
  // 2000..200A    ; White_Space # Zs       EN QUAD..HAIR SPACE
  // 2028          ; White_Space # Zl       LINE SEPARATOR
  // 2029          ; White_Space # Zp       PARAGRAPH SEPARATOR
  // 202F          ; White_Space # Zs       NARROW NO-BREAK SPACE
  // 205F          ; White_Space # Zs       MEDIUM MATHEMATICAL SPACE
  // 3000          ; White_Space # Zs       IDEOGRAPHIC SPACE
  //
  // BOM: 0xFEFF
  static bool _isTwoByteWhitespace(int codeUnit) {
    if (codeUnit <= 32) {
      return (codeUnit == 32) || ((codeUnit <= 13) && (codeUnit >= 9));
    }
    if (codeUnit < 0x85) return false;
    if ((codeUnit == 0x85) || (codeUnit == 0xA0)) return true;
    return (codeUnit <= 0x200A)
        ? ((codeUnit == 0x1680) || (0x2000 <= codeUnit))
        : ((codeUnit == 0x2028) ||
            (codeUnit == 0x2029) ||
            (codeUnit == 0x202F) ||
            (codeUnit == 0x205F) ||
            (codeUnit == 0x3000) ||
            (codeUnit == 0xFEFF));
  }

  int _firstNonWhitespace() {
    final len = this.length;
    int first = 0;
    for (; first < len; first++) {
      if (!_isWhitespace(this.codeUnitAt(first))) {
        break;
      }
    }
    return first;
  }

  int _lastNonWhitespace() {
    int last = this.length - 1;
    for (; last >= 0; last--) {
      if (!_isWhitespace(this.codeUnitAt(last))) {
        break;
      }
    }
    return last;
  }

  String trim() {
    final len = this.length;
    int first = _firstNonWhitespace();
    if (len == first) {
      // String contains only whitespaces.
      return "";
    }
    int last = _lastNonWhitespace() + 1;
    if ((first == 0) && (last == len)) {
      // Returns this string since it does not have leading or trailing
      // whitespaces.
      return this;
    }
    return _substringUnchecked(first, last);
  }

  String trimLeft() {
    final len = this.length;
    int first = 0;
    for (; first < len; first++) {
      if (!_isWhitespace(this.codeUnitAt(first))) {
        break;
      }
    }
    if (len == first) {
      // String contains only whitespaces.
      return "";
    }
    if (first == 0) {
      // Returns this string since it does not have leading or trailing
      // whitespaces.
      return this;
    }
    return _substringUnchecked(first, len);
  }

  String trimRight() {
    final len = this.length;
    int last = len - 1;
    for (; last >= 0; last--) {
      if (!_isWhitespace(this.codeUnitAt(last))) {
        break;
      }
    }
    if (last == -1) {
      // String contains only whitespaces.
      return "";
    }
    if (last == (len - 1)) {
      // Returns this string since it does not have trailing whitespaces.
      return this;
    }
    return _substringUnchecked(0, last + 1);
  }

  String operator *(int times) {
    if (times <= 0) return "";
    if (times == 1) return this;
    StringBuffer buffer = new StringBuffer(this);
    for (int i = 1; i < times; i++) {
      buffer.write(this);
    }
    return buffer.toString();
  }

  String padLeft(int width, [String padding = ' ']) {
    int delta = width - this.length;
    if (delta <= 0) return this;
    StringBuffer buffer = new StringBuffer();
    for (int i = 0; i < delta; i++) {
      buffer.write(padding);
    }
    buffer.write(this);
    return buffer.toString();
  }

  String padRight(int width, [String padding = ' ']) {
    int delta = width - this.length;
    if (delta <= 0) return this;
    StringBuffer buffer = new StringBuffer(this);
    for (int i = 0; i < delta; i++) {
      buffer.write(padding);
    }
    return buffer.toString();
  }

  bool contains(Pattern pattern, [int startIndex = 0]) {
    if (pattern is String) {
      if (startIndex < 0 || startIndex > this.length) {
        throw new RangeError.range(startIndex, 0, this.length);
      }
      return indexOf(pattern, startIndex) >= 0;
    }
    return pattern.allMatches(this.substring(startIndex)).isNotEmpty;
  }

  String replaceFirst(Pattern pattern, String replacement,
      [int startIndex = 0]) {
    RangeError.checkValueInInterval(startIndex, 0, this.length, "startIndex");
    Iterator iterator = startIndex == 0
        ? pattern.allMatches(this).iterator
        : pattern.allMatches(this, startIndex).iterator;
    if (!iterator.moveNext()) return this;
    Match match = iterator.current;
    return replaceRange(match.start, match.end, replacement);
  }

  String replaceRange(int start, int? end, String replacement) {
    final length = this.length;
    final localEnd = RangeError.checkValidRange(start, end, length);
    bool replacementIsOneByte = replacement._isOneByte;
    if (start == 0 && localEnd == length) return replacement;
    int replacementLength = replacement.length;
    int totalLength = start + (length - localEnd) + replacementLength;
    if (replacementIsOneByte && this._isOneByte) {
      var result = _OneByteString._allocate(totalLength);
      int index = 0;
      index = result._setRange(index, this, 0, start);
      index = result._setRange(start, replacement, 0, replacementLength);
      result._setRange(index, this, localEnd, length);
      return result;
    }
    List slices = [];
    _addReplaceSlice(slices, 0, start);
    if (replacement.length > 0) slices.add(replacement);
    _addReplaceSlice(slices, localEnd, length);
    return _joinReplaceAllResult(
        this, slices, totalLength, replacementIsOneByte);
  }

  static int _addReplaceSlice(List matches, int start, int end) {
    int length = end - start;
    if (length > 0) {
      if (length <= _maxLengthValue && start <= _maxStartValue) {
        matches.add(-((start << _lengthBits) | length));
      } else {
        matches.add(start);
        matches.add(end);
      }
    }
    return length;
  }

  String replaceAll(Pattern pattern, String replacement) {
    int startIndex = 0;
    // String fragments that replace the prefix [this] up to [startIndex].
    List matches = [];
    int length = 0; // Length of all fragments.
    int replacementLength = replacement.length;

    if (replacementLength == 0) {
      for (Match match in pattern.allMatches(this)) {
        length += _addReplaceSlice(matches, startIndex, match.start);
        startIndex = match.end;
      }
    } else {
      for (Match match in pattern.allMatches(this)) {
        length += _addReplaceSlice(matches, startIndex, match.start);
        matches.add(replacement);
        length += replacementLength;
        startIndex = match.end;
      }
    }
    // No match, or a zero-length match at start with zero-length replacement.
    if (startIndex == 0 && length == 0) return this;
    length += _addReplaceSlice(matches, startIndex, this.length);
    bool replacementIsOneByte = replacement._isOneByte;
    if (replacementIsOneByte &&
        length < _maxJoinReplaceOneByteStringLength &&
        this._isOneByte) {
      // TODO(lrn): Is there a cut-off point, or is runtime always faster?
      return _joinReplaceAllOneByteResult(this, matches, length);
    }
    return _joinReplaceAllResult(this, matches, length, replacementIsOneByte);
  }

  /**
   * As [_joinReplaceAllResult], but knowing that the result
   * is always a [_OneByteString].
   */
  static String _joinReplaceAllOneByteResult(
      String base, List matches, int length) {
    _OneByteString result = _OneByteString._allocate(length);
    int writeIndex = 0;
    for (int i = 0; i < matches.length; i++) {
      var entry = matches[i];
      if (entry is _Smi) {
        int sliceStart = entry;
        int sliceEnd;
        if (sliceStart < 0) {
          int bits = -sliceStart;
          int sliceLength = bits & _lengthMask;
          sliceStart = bits >> _lengthBits;
          sliceEnd = sliceStart + sliceLength;
        } else {
          i++;
          // This function should only be called with valid matches lists.
          // If the list is short, or sliceEnd is not an integer, one of
          // the next few lines will throw anyway.
          assert(i < matches.length);
          sliceEnd = matches[i];
        }
        for (int j = sliceStart; j < sliceEnd; j++) {
          result._setAt(writeIndex++, base.codeUnitAt(j));
        }
      } else {
        // Replacement is a one-byte string.
        String replacement = entry;
        for (int j = 0; j < replacement.length; j++) {
          result._setAt(writeIndex++, replacement.codeUnitAt(j));
        }
      }
    }
    assert(writeIndex == length);
    return result;
  }

  /**
   * Combine the results of a [replaceAll] match into a new string.
   *
   * The [matches] lists contains Smi index pairs representing slices of
   * [base] and [String]s to be put in between the slices.
   *
   * The total [length] of the resulting string is known, as is
   * whether the replacement strings are one-byte strings.
   * If they are, then we have to check the base string slices to know
   * whether the result must be a one-byte string.
   */

  String _joinReplaceAllResult(String base, List matches, int length,
      bool replacementStringsAreOneByte) {
    if (length < 0) throw ArgumentError.value(length);
    bool isOneByte = replacementStringsAreOneByte &&
        _slicesAreOneByte(base, matches, length);
    if (isOneByte) {
      return _joinReplaceAllOneByteResult(base, matches, length);
    }
    _TwoByteString result = _TwoByteString._allocate(length);
    int writeIndex = 0;
    for (int i = 0; i < matches.length; i++) {
      var entry = matches[i];
      if (entry is _Smi) {
        int sliceStart = entry;
        int sliceEnd;
        if (sliceStart < 0) {
          int bits = -sliceStart;
          int sliceLength = bits & _lengthMask;
          sliceStart = bits >> _lengthBits;
          sliceEnd = sliceStart + sliceLength;
        } else {
          i++;
          // This function should only be called with valid matches lists.
          // If the list is short, or sliceEnd is not an integer, one of
          // the next few lines will throw anyway.
          assert(i < matches.length);
          sliceEnd = matches[i];
        }
        for (int j = sliceStart; j < sliceEnd; j++) {
          result._setAt(writeIndex++, base.codeUnitAt(j));
        }
      } else {
        // Replacement is a one-byte string.
        String replacement = entry;
        for (int j = 0; j < replacement.length; j++) {
          result._setAt(writeIndex++, replacement.codeUnitAt(j));
        }
      }
    }
    assert(writeIndex == length);
    return result;
  }

  bool _slicesAreOneByte(String base, List matches, int length) {
    for (int i = 0; i < matches.length; i++) {
      Object? o = matches[i];
      if (o is int) {
        int sliceStart = o;
        int sliceEnd;
        if (sliceStart < 0) {
          int bits = -sliceStart;
          int sliceLength = bits & _lengthMask;
          sliceStart = bits >> _lengthBits;
          sliceEnd = sliceStart + sliceLength;
        } else {
          i++;
          if (i >= length) {
            // Invalid, handled later.
            return false;
          }
          Object? p = matches[i];
          if (p is! int) {
            // Invalid, handled later.
            return false;
          }
          sliceEnd = p;
        }
        for (int j = sliceStart; j < sliceEnd; j++) {
          if (base.codeUnitAt(j) > 0xff) {
            return false;
          }
        }
      }
    }
    return true;
  }

  String replaceAllMapped(Pattern pattern, String replace(Match match)) {
    List matches = [];
    int length = 0;
    int startIndex = 0;
    bool replacementStringsAreOneByte = true;
    for (Match match in pattern.allMatches(this)) {
      length += _addReplaceSlice(matches, startIndex, match.start);
      var replacement = "${replace(match)}";
      matches.add(replacement);
      length += replacement.length;
      replacementStringsAreOneByte =
          replacementStringsAreOneByte && replacement._isOneByte;
      startIndex = match.end;
    }
    if (matches.isEmpty) return this;
    length += _addReplaceSlice(matches, startIndex, this.length);
    if (replacementStringsAreOneByte &&
        length < _maxJoinReplaceOneByteStringLength &&
        this._isOneByte) {
      return _joinReplaceAllOneByteResult(this, matches, length);
    }
    return _joinReplaceAllResult(
        this, matches, length, replacementStringsAreOneByte);
  }

  String replaceFirstMapped(Pattern pattern, String replace(Match match),
      [int startIndex = 0]) {
    RangeError.checkValueInInterval(startIndex, 0, this.length, "startIndex");

    var matches = pattern.allMatches(this, startIndex).iterator;
    if (!matches.moveNext()) return this;
    var match = matches.current;
    var replacement = "${replace(match)}";
    return replaceRange(match.start, match.end, replacement);
  }

  static String _matchString(Match match) => match[0]!;
  static String _stringIdentity(String string) => string;

  String _splitMapJoinEmptyString(
      String onMatch(Match match), String onNonMatch(String nonMatch)) {
    // Pattern is the empty string.
    StringBuffer buffer = new StringBuffer();
    int length = this.length;
    int i = 0;
    buffer.write(onNonMatch(""));
    while (i < length) {
      buffer.write(onMatch(new StringMatch(i, this, "")));
      // Special case to avoid splitting a surrogate pair.
      int code = this.codeUnitAt(i);
      if ((code & ~0x3FF) == 0xD800 && length > i + 1) {
        // Leading surrogate;
        code = this.codeUnitAt(i + 1);
        if ((code & ~0x3FF) == 0xDC00) {
          // Matching trailing surrogate.
          buffer.write(onNonMatch(this.substring(i, i + 2)));
          i += 2;
          continue;
        }
      }
      buffer.write(onNonMatch(this[i]));
      i++;
    }
    buffer.write(onMatch(new StringMatch(i, this, "")));
    buffer.write(onNonMatch(""));
    return buffer.toString();
  }

  String splitMapJoin(Pattern pattern,
      {String onMatch(Match match)?, String onNonMatch(String nonMatch)?}) {
    onMatch ??= _matchString;
    onNonMatch ??= _stringIdentity;
    if (pattern is String) {
      String stringPattern = pattern;
      if (stringPattern.isEmpty) {
        return _splitMapJoinEmptyString(onMatch, onNonMatch);
      }
    }
    StringBuffer buffer = new StringBuffer();
    int startIndex = 0;
    for (Match match in pattern.allMatches(this)) {
      buffer.write(onNonMatch(this.substring(startIndex, match.start)));
      buffer.write(onMatch(match).toString());
      startIndex = match.end;
    }
    buffer.write(onNonMatch(this.substring(startIndex)));
    return buffer.toString();
  }

  /**
   * Convert all objects in [values] to strings and concat them
   * into a result string.
   * Modifies the input list if it contains non-`String` values.
   */
  @pragma("wasm:entry-point", "call")
  static String _interpolate(final List<Object?> values) {
    final numValues = values.length;
    int totalLength = 0;
    int i = 0;
    while (i < numValues) {
      final e = values[i];
      final s = e.toString();
      values[i] = s;
      if (s is _OneByteString) {
        totalLength += s.length;
        i++;
      } else {
        // Handle remaining elements without checking for one-byte-ness.
        while (++i < numValues) {
          final e = values[i];
          values[i] = e.toString();
        }
        return _concatRangeNative(values, 0, numValues);
      }
    }
    // All strings were one-byte strings.
    return _OneByteString._concatAll(values, totalLength);
  }

  static ArgumentError _interpolationError(Object? o, Object? result) {
    // Since Dart 2.0, [result] can only be null.
    return new ArgumentError.value(
        o, "object", "toString method returned 'null'");
  }

  Iterable<Match> allMatches(String string, [int start = 0]) {
    if (start < 0 || start > string.length) {
      throw new RangeError.range(start, 0, string.length, "start");
    }
    return new StringAllMatchesIterable(string, this, start);
  }

  Match? matchAsPrefix(String string, [int start = 0]) {
    if (start < 0 || start > string.length) {
      throw new RangeError.range(start, 0, string.length);
    }
    if (start + this.length > string.length) return null;
    for (int i = 0; i < this.length; i++) {
      if (string.codeUnitAt(start + i) != this.codeUnitAt(i)) {
        return null;
      }
    }
    return new StringMatch(start, string, this);
  }

  List<String> split(Pattern pattern) {
    if ((pattern is String) && pattern.isEmpty) {
      List<String> result =
          new List<String>.generate(this.length, (int i) => this[i]);
      return result;
    }
    int length = this.length;
    Iterator iterator = pattern.allMatches(this).iterator;
    if (length == 0 && iterator.moveNext()) {
      // A matched empty string input returns the empty list.
      return <String>[];
    }
    List<String> result = <String>[];
    int startIndex = 0;
    int previousIndex = 0;
    // 'pattern' may not be implemented correctly and therefore we cannot
    // call _substringUnchecked unless it is a trustworthy type (e.g. String).
    while (true) {
      if (startIndex == length || !iterator.moveNext()) {
        result.add(this.substring(previousIndex, length));
        break;
      }
      Match match = iterator.current;
      if (match.start == length) {
        result.add(this.substring(previousIndex, length));
        break;
      }
      int endIndex = match.end;
      if (startIndex == endIndex && endIndex == previousIndex) {
        ++startIndex; // empty match, advance and restart
        continue;
      }
      result.add(this.substring(previousIndex, match.start));
      startIndex = previousIndex = endIndex;
    }
    return result;
  }

  List<int> get codeUnits => new CodeUnits(this);

  Runes get runes => new Runes(this);

  String toUpperCase() => _toUpperCase(this);

  String toLowerCase() => _toLowerCase(this);

  // Concatenate ['start', 'end'[ elements of 'strings'.
  static String _concatRange(List<String> strings, int start, int end) {
    if ((end - start) == 1) {
      return strings[start];
    }
    return _concatRangeNative(strings, start, end);
  }

  // Call this method if all elements of [strings] are known to be strings
  // but not all are known to be OneByteString(s).
  static String _concatRangeNative(List<Object?> strings, int start, int end) {
    int totalLength = 0;
    for (int i = start; i < end; i++) {
      final str = strings[i];
      if (str is JSStringImpl) {
        totalLength += str.length;
      } else {
        totalLength += unsafeCast<_StringBase>(str).length;
      }
    }
    _TwoByteString result = _TwoByteString._allocate(totalLength);
    int offset = 0;
    for (int i = start; i < end; i++) {
      final str = strings[i];
      if (str is JSStringImpl) {
        final length = str.length;
        final to = result._array;
        for (int j = 0; j < length; j++) {
          to.write(offset++, str.codeUnitAt(j));
        }
      } else {
        _StringBase s = unsafeCast<_StringBase>(strings[i]);
        offset = s._copyIntoTwoByteString(result, offset);
      }
    }
    return result;
  }

  int _copyIntoTwoByteString(_TwoByteString result, int offset);
}

@pragma("wasm:entry-point")
final class _OneByteString extends _StringBase {
  @pragma("wasm:entry-point")
  WasmIntArray<WasmI8> _array;

  _OneByteString._withLength(int length)
      : _array = WasmIntArray<WasmI8>(length),
        super._();

  // Same hash as VM
  @override
  int _computeHashCode() {
    WasmIntArray<WasmI8> array = _array;
    int length = array.length;
    int hash = 0;
    for (int i = 0; i < length; i++) {
      hash = stringCombineHashes(hash, array.readUnsigned(i));
    }
    return stringFinalizeHash(hash);
  }

  @override
  int codeUnitAt(int index) {
    RangeError.checkValueInInterval(index, 0, length - 1);
    return _array.readUnsigned(index);
  }

  @override
  int get length => _array.length;

  @override
  bool _isWhitespace(int codeUnit) {
    return _StringBase._isOneByteWhitespace(codeUnit);
  }

  bool operator ==(Object other) {
    return super == other;
  }

  @override
  String _substringUncheckedInternal(int startIndex, int endIndex) {
    int length = endIndex - startIndex;
    var result = _OneByteString._withLength(length);
    for (int i = 0; i < length; i++) {
      result._setAt(i, codeUnitAt(startIndex + i));
    }
    return result;
  }

  List<String> _splitWithCharCode(int charCode) {
    final parts = <String>[];
    int i = 0;
    int start = 0;
    for (i = 0; i < this.length; ++i) {
      if (this.codeUnitAt(i) == charCode) {
        parts.add(this._substringUnchecked(start, i));
        start = i + 1;
      }
    }
    parts.add(this._substringUnchecked(start, i));
    return parts;
  }

  List<String> split(Pattern pattern) {
    if (pattern is _OneByteString && pattern.length == 1) {
      return _splitWithCharCode(pattern.codeUnitAt(0));
    }
    return super.split(pattern);
  }

  // All element of 'strings' must be OneByteStrings.
  static _concatAll(List strings, int totalLength) {
    final result = _OneByteString._allocate(totalLength);
    final to = result._array;
    final stringsLength = strings.length;
    int j = 0;
    for (int s = 0; s < stringsLength; s++) {
      final _OneByteString e = unsafeCast<_OneByteString>(strings[s]);
      final from = e._array;
      final length = from.length;
      for (int i = 0; i < length; i++) {
        to.write(j++, from.readUnsigned(i));
      }
    }
    return result;
  }

  @override
  int _copyIntoTwoByteString(_TwoByteString result, int offset) {
    final from = _array;
    final int length = from.length;
    final to = result._array;
    int j = offset;
    for (int i = 0; i < length; i++) {
      to.write(j++, from.readUnsigned(i));
    }
    return j;
  }

  int indexOf(Pattern pattern, [int start = 0]) {
    final len = this.length;
    // Specialize for single character pattern.
    if (pattern is String && pattern.length == 1 && start >= 0 && start < len) {
      final patternCu0 = pattern.codeUnitAt(0);
      if (patternCu0 > 0xFF) {
        return -1;
      }
      for (int i = start; i < len; i++) {
        if (this.codeUnitAt(i) == patternCu0) {
          return i;
        }
      }
      return -1;
    }
    return super.indexOf(pattern, start);
  }

  bool contains(Pattern pattern, [int start = 0]) {
    final len = this.length;
    if (pattern is String && pattern.length == 1 && start >= 0 && start < len) {
      final patternCu0 = pattern.codeUnitAt(0);
      if (patternCu0 > 0xFF) {
        return false;
      }
      for (int i = start; i < len; i++) {
        if (this.codeUnitAt(i) == patternCu0) {
          return true;
        }
      }
      return false;
    }
    return super.contains(pattern, start);
  }

  String operator *(int times) {
    if (times <= 0) return "";
    if (times == 1) return this;
    int length = this.length;
    if (this.isEmpty) return this; // Don't clone empty string.
    _OneByteString result = _OneByteString._allocate(length * times);
    int index = 0;
    for (int i = 0; i < times; i++) {
      for (int j = 0; j < length; j++) {
        result._setAt(index++, this.codeUnitAt(j));
      }
    }
    return result;
  }

  String padLeft(int width, [String padding = ' ']) {
    if (!padding._isOneByte) {
      return super.padLeft(width, padding);
    }
    int length = this.length;
    int delta = width - length;
    if (delta <= 0) return this;
    int padLength = padding.length;
    int resultLength = padLength * delta + length;
    _OneByteString result = _OneByteString._allocate(resultLength);
    int index = 0;
    if (padLength == 1) {
      int padChar = padding.codeUnitAt(0);
      for (int i = 0; i < delta; i++) {
        result._setAt(index++, padChar);
      }
    } else {
      for (int i = 0; i < delta; i++) {
        for (int j = 0; j < padLength; j++) {
          result._setAt(index++, padding.codeUnitAt(j));
        }
      }
    }
    for (int i = 0; i < length; i++) {
      result._setAt(index++, this.codeUnitAt(i));
    }
    return result;
  }

  String padRight(int width, [String padding = ' ']) {
    if (!padding._isOneByte) {
      return super.padRight(width, padding);
    }
    int length = this.length;
    int delta = width - length;
    if (delta <= 0) return this;
    int padLength = padding.length;
    int resultLength = length + padLength * delta;
    _OneByteString result = _OneByteString._allocate(resultLength);
    int index = 0;
    for (int i = 0; i < length; i++) {
      result._setAt(index++, this.codeUnitAt(i));
    }
    if (padLength == 1) {
      int padChar = padding.codeUnitAt(0);
      for (int i = 0; i < delta; i++) {
        result._setAt(index++, padChar);
      }
    } else {
      for (int i = 0; i < delta; i++) {
        for (int j = 0; j < padLength; j++) {
          result._setAt(index++, padding.codeUnitAt(j));
        }
      }
    }
    return result;
  }

  // Lower-case conversion table for Latin-1 as string.
  // Upper-case ranges: 0x41-0x5a ('A' - 'Z'), 0xc0-0xd6, 0xd8-0xde.
  // Conversion to lower case performed by adding 0x20.
  static const _LC_TABLE =
      "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"
      "\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f"
      "\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f"
      "\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f"
      "\x40\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f"
      "\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x5b\x5c\x5d\x5e\x5f"
      "\x60\x61\x62\x63\x64\x65\x66\x67\x68\x69\x6a\x6b\x6c\x6d\x6e\x6f"
      "\x70\x71\x72\x73\x74\x75\x76\x77\x78\x79\x7a\x7b\x7c\x7d\x7e\x7f"
      "\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f"
      "\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f"
      "\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf"
      "\xb0\xb1\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf"
      "\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef"
      "\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xd7\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xdf"
      "\xe0\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xeb\xec\xed\xee\xef"
      "\xf0\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa\xfb\xfc\xfd\xfe\xff";

  // Upper-case conversion table for Latin-1 as string.
  // Lower-case ranges: 0x61-0x7a ('a' - 'z'), 0xe0-0xff.
  // The characters 0xb5 (µ) and 0xff (ÿ) have upper case variants
  // that are not Latin-1. These are both marked as 0x00 in the table.
  // The German "sharp s" \xdf (ß) should be converted into two characters (SS),
  // and is also marked with 0x00.
  // Conversion to lower case performed by subtracting 0x20.
  static const _UC_TABLE =
      "\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f"
      "\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f"
      "\x20\x21\x22\x23\x24\x25\x26\x27\x28\x29\x2a\x2b\x2c\x2d\x2e\x2f"
      "\x30\x31\x32\x33\x34\x35\x36\x37\x38\x39\x3a\x3b\x3c\x3d\x3e\x3f"
      "\x40\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f"
      "\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x5b\x5c\x5d\x5e\x5f"
      "\x60\x41\x42\x43\x44\x45\x46\x47\x48\x49\x4a\x4b\x4c\x4d\x4e\x4f"
      "\x50\x51\x52\x53\x54\x55\x56\x57\x58\x59\x5a\x7b\x7c\x7d\x7e\x7f"
      "\x80\x81\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x8b\x8c\x8d\x8e\x8f"
      "\x90\x91\x92\x93\x94\x95\x96\x97\x98\x99\x9a\x9b\x9c\x9d\x9e\x9f"
      "\xa0\xa1\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xab\xac\xad\xae\xaf"
      "\xb0\xb1\xb2\xb3\xb4\x00\xb6\xb7\xb8\xb9\xba\xbb\xbc\xbd\xbe\xbf"
      "\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf"
      "\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xdb\xdc\xdd\xde\x00"
      "\xc0\xc1\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xcb\xcc\xcd\xce\xcf"
      "\xd0\xd1\xd2\xd3\xd4\xd5\xd6\xf7\xd8\xd9\xda\xdb\xdc\xdd\xde\x00";

  String toLowerCase() {
    for (int i = 0; i < this.length; i++) {
      final c = this.codeUnitAt(i);
      if (c == _LC_TABLE.codeUnitAt(c)) continue;
      // Upper-case character found.
      final result = _allocate(this.length);
      for (int j = 0; j < i; j++) {
        result._setAt(j, this.codeUnitAt(j));
      }
      for (int j = i; j < this.length; j++) {
        result._setAt(j, _LC_TABLE.codeUnitAt(this.codeUnitAt(j)));
      }
      return result;
    }
    return this;
  }

  String toUpperCase() {
    for (int i = 0; i < this.length; i++) {
      final c = this.codeUnitAt(i);
      // Continue loop if character is unchanged by upper-case conversion.
      if (c == _UC_TABLE.codeUnitAt(c)) continue;

      // Check rest of string for characters that do not convert to
      // single-characters in the Latin-1 range.
      for (int j = i; j < this.length; j++) {
        final c = this.codeUnitAt(j);
        if ((_UC_TABLE.codeUnitAt(c) == 0x00) && (c != 0x00)) {
          // We use the 0x00 value for characters other than the null character,
          // that don't convert to a single Latin-1 character when upper-cased.
          // In that case, call the generic super-class method.
          return super.toUpperCase();
        }
      }
      // Some lower-case characters found, but all upper-case to single Latin-1
      // characters.
      final result = _allocate(this.length);
      for (int j = 0; j < i; j++) {
        result._setAt(j, this.codeUnitAt(j));
      }
      for (int j = i; j < this.length; j++) {
        result._setAt(j, _UC_TABLE.codeUnitAt(this.codeUnitAt(j)));
      }
      return result;
    }
    return this;
  }

  // Allocates a string of given length, expecting its content to be
  // set using _setAt.

  static _OneByteString _allocate(int length) {
    return _OneByteString._withLength(length);
  }

  external static _OneByteString _allocateFromOneByteList(
      List<int> list, int start, int end);

  /// This is internal helper method. Code point value must be a valid Latin1
  /// value (0..0xFF), index must be valid.
  @pragma('wasm:prefer-inline')
  void _setAt(int index, int codePoint) {
    _array.write(index, codePoint);
  }

  // Should be optimizable to a memory move.
  // Accepts both _OneByteString and _ExternalOneByteString as argument.
  // Returns index after last character written.
  int _setRange(int index, String oneByteString, int start, int end) {
    assert(oneByteString._isOneByte);
    assert(0 <= start);
    assert(start <= end);
    assert(end <= oneByteString.length);
    assert(0 <= index);
    assert(index + (end - start) <= length);
    for (int i = start; i < end; i++) {
      _setAt(index, oneByteString.codeUnitAt(i));
      index += 1;
    }
    return index;
  }
}

@pragma("wasm:entry-point")
final class _TwoByteString extends _StringBase {
  @pragma("wasm:entry-point")
  WasmIntArray<WasmI16> _array;

  _TwoByteString._withLength(int length)
      : _array = WasmIntArray<WasmI16>(length),
        super._();

  // Same hash as VM
  @override
  int _computeHashCode() {
    WasmIntArray<WasmI16> array = _array;
    int length = array.length;
    int hash = 0;
    for (int i = 0; i < length; i++) {
      hash = stringCombineHashes(hash, array.readUnsigned(i));
    }
    return stringFinalizeHash(hash);
  }

  // Allocates a string of given length, expecting its content to be
  // set using _setAt.

  static _TwoByteString _allocate(int length) =>
      _TwoByteString._withLength(length);

  static String _allocateFromTwoByteList(List<int> list, int start, int end) {
    final int length = end - start;
    final s = _allocate(length);
    final array = s._array;
    for (int i = 0; i < length; i++) {
      array.write(i, list[start + i]);
    }
    return s;
  }

  /// This is internal helper method. Code point value must be a valid UTF-16
  /// value (0..0xFFFF), index must be valid.
  @pragma('wasm:prefer-inline')
  void _setAt(int index, int codePoint) {
    _array.write(index, codePoint);
  }

  @override
  bool _isWhitespace(int codeUnit) {
    return _StringBase._isTwoByteWhitespace(codeUnit);
  }

  @override
  int codeUnitAt(int index) {
    RangeError.checkValueInInterval(index, 0, length - 1);
    return _array.readUnsigned(index);
  }

  @override
  int get length => _array.length;

  bool operator ==(Object other) {
    return super == other;
  }

  @override
  String _substringUncheckedInternal(int startIndex, int endIndex) {
    int length = endIndex - startIndex;
    var result = _TwoByteString._withLength(length);
    for (int i = 0; i < length; i++) {
      result._setAt(i, codeUnitAt(startIndex + i));
    }
    return result;
  }

  @override
  int _copyIntoTwoByteString(_TwoByteString result, int offset) {
    final from = _array;
    final int length = from.length;
    final to = result._array;
    int j = offset;
    for (int i = 0; i < length; i++) {
      to.write(j++, from.readUnsigned(i));
    }
    return j;
  }
}
