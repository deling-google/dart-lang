// Copyright (c) 2023, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:_internal';
import 'dart:_string';

@pragma("wasm:entry-point")
final class _BoxedInt extends int {
  // A boxed int contains an unboxed int.
  @pragma("wasm:entry-point")
  int value = 0;

  /// Dummy factory to silence error about missing superclass constructor.
  external factory _BoxedInt();

  external num operator +(num other);
  external num operator -(num other);
  external num operator *(num other);

  @pragma("wasm:prefer-inline")
  double operator /(num other) {
    return this.toDouble() / other.toDouble();
  }

  @pragma("wasm:prefer-inline")
  int operator ~/(num other) => other is int
      ? _truncDiv(this.value, other)
      : _BoxedDouble.truncDiv(toDouble(), unsafeCast<double>(other));

  @pragma("wasm:prefer-inline")
  num operator %(num other) => other is int
      ? _modulo(this, other)
      : _BoxedDouble.modulo(toDouble(), unsafeCast<double>(other));

  static int _modulo(int a, int b) {
    int rem = a - (a ~/ b) * b;
    if (rem < 0) {
      if (b < 0) {
        return rem - b;
      } else {
        return rem + b;
      }
    }
    return rem;
  }

  @pragma("wasm:prefer-inline")
  static int _truncDiv(int a, int b) {
    // Division special case: overflow in I64.
    // MIN_VALUE / -1 = (MAX_VALUE + 1), which wraps around to MIN_VALUE
    const int MIN_INT = -9223372036854775808;
    if (a == MIN_INT && b == -1) {
      return MIN_INT;
    }

    if (b == 0) {
      throw IntegerDivisionByZeroException();
    }

    return a._div_s(b);
  }

  @pragma("wasm:prefer-inline")
  num remainder(num other) => other is int
      ? this - (this ~/ other) * other
      : _BoxedDouble.computeRemainder(toDouble(), unsafeCast<double>(other));

  external int operator -();

  external int operator &(int other);
  external int operator |(int other);
  external int operator ^(int other);

  @pragma("wasm:prefer-inline")
  int operator >>(int shift) {
    // Unsigned comparison to check for large and negative shifts
    if (shift._lt_u(64)) {
      return value._shr_s(shift);
    }

    if (shift < 0) {
      throw ArgumentError(shift);
    }

    // shift >= 64, 0 or -1 depending on sign: `this >= 0 ? 0 : -1`
    return value._shr_s(63);
  }

  @pragma("wasm:prefer-inline")
  int operator >>>(int shift) {
    // Unsigned comparison to check for large and negative shifts
    if (shift._lt_u(64)) {
      return value._shr_u(shift);
    }

    if (shift < 0) {
      throw ArgumentError(shift);
    }

    // shift >= 64
    return 0;
  }

  @pragma("wasm:prefer-inline")
  int operator <<(int shift) {
    // Unsigned comparison to check for large and negative shifts
    if (shift._lt_u(64)) {
      return value._shl(shift);
    }

    if (shift < 0) {
      throw ArgumentError(shift);
    }

    // shift >= 64
    return 0;
  }

  external bool operator <(num other);
  external bool operator >(num other);
  external bool operator >=(num other);
  external bool operator <=(num other);

  @pragma("wasm:prefer-inline")
  bool operator ==(Object other) {
    return other is int
        ? this == other // Intrinsic ==
        : other is double
            ? this.toDouble() == other // Intrinsic ==
            : false;
  }

  @pragma("wasm:prefer-inline")
  int abs() {
    return this < 0 ? -this : this;
  }

  @pragma("wasm:prefer-inline")
  int get sign {
    return (this > 0)
        ? 1
        : (this < 0)
            ? -1
            : 0;
  }

  @pragma("wasm:prefer-inline")
  bool get isEven => (this & 1) == 0;
  @pragma("wasm:prefer-inline")
  bool get isOdd => (this & 1) != 0;
  @pragma("wasm:prefer-inline")
  bool get isNaN => false;
  @pragma("wasm:prefer-inline")
  bool get isNegative => this < 0;
  @pragma("wasm:prefer-inline")
  bool get isInfinite => false;
  @pragma("wasm:prefer-inline")
  bool get isFinite => true;

  @pragma("wasm:prefer-inline")
  int toUnsigned(int width) {
    return this & ((1 << width) - 1);
  }

  @pragma("wasm:prefer-inline")
  int toSigned(int width) {
    // The value of binary number weights each bit by a power of two.  The
    // twos-complement value weights the sign bit negatively.  We compute the
    // value of the negative weighting by isolating the sign bit with the
    // correct power of two weighting and subtracting it from the value of the
    // lower bits.
    int signMask = 1 << (width - 1);
    return (this & (signMask - 1)) - (this & signMask);
  }

  int compareTo(num other) {
    const int EQUAL = 0, LESS = -1, GREATER = 1;
    if (other is double) {
      const int MAX_EXACT_INT_TO_DOUBLE = 9007199254740992; // 2^53.
      const int MIN_EXACT_INT_TO_DOUBLE = -MAX_EXACT_INT_TO_DOUBLE;
      // With int limited to 64 bits, double.toInt() clamps
      // double value to fit into the MIN_INT64..MAX_INT64 range.
      // Check if the double value is outside of this range.
      // This check handles +/-infinity as well.
      const double minInt64AsDouble = -9223372036854775808.0;
      // MAX_INT64 is not precisely representable in doubles, so
      // check against (MAX_INT64 + 1).
      const double maxInt64Plus1AsDouble = 9223372036854775808.0;
      if (other < minInt64AsDouble) {
        return GREATER;
      } else if (other >= maxInt64Plus1AsDouble) {
        return LESS;
      }
      if (other.isNaN) {
        return LESS;
      }
      if (MIN_EXACT_INT_TO_DOUBLE <= this && this <= MAX_EXACT_INT_TO_DOUBLE) {
        // Let the double implementation deal with -0.0.
        return -(other.compareTo(this.toDouble()));
      } else {
        // If abs(other) > MAX_EXACT_INT_TO_DOUBLE, then other has an integer
        // value (no bits below the decimal point).
        other = other._toInt();
      }
    }
    if (this < other) {
      return LESS;
    } else if (this > other) {
      return GREATER;
    } else {
      return EQUAL;
    }
  }

  @pragma("wasm:prefer-inline")
  int round() {
    return this;
  }

  @pragma("wasm:prefer-inline")
  int floor() {
    return this;
  }

  @pragma("wasm:prefer-inline")
  int ceil() {
    return this;
  }

  @pragma("wasm:prefer-inline")
  int truncate() {
    return this;
  }

  @pragma("wasm:prefer-inline")
  double roundToDouble() {
    return this.toDouble();
  }

  @pragma("wasm:prefer-inline")
  double floorToDouble() {
    return this.toDouble();
  }

  @pragma("wasm:prefer-inline")
  double ceilToDouble() {
    return this.toDouble();
  }

  @pragma("wasm:prefer-inline")
  double truncateToDouble() {
    return this.toDouble();
  }

  num clamp(num lowerLimit, num upperLimit) {
    // Special case for integers.
    if (lowerLimit is int && upperLimit is int && lowerLimit <= upperLimit) {
      if (this < lowerLimit) return lowerLimit;
      if (this > upperLimit) return upperLimit;
      return this;
    }
    // Generic case involving doubles, and invalid integer ranges.
    if (lowerLimit.compareTo(upperLimit) > 0) {
      throw new ArgumentError(lowerLimit);
    }
    if (lowerLimit.isNaN) return lowerLimit;
    // Note that we don't need to care for -0.0 for the lower limit.
    if (this < lowerLimit) return lowerLimit;
    if (this.compareTo(upperLimit) > 0) return upperLimit;
    return this;
  }

  @pragma("wasm:prefer-inline")
  int toInt() {
    return this;
  }

  external double toDouble();

  String toStringAsFixed(int fractionDigits) {
    return this.toDouble().toStringAsFixed(fractionDigits);
  }

  String toStringAsExponential([int? fractionDigits]) {
    return this.toDouble().toStringAsExponential(fractionDigits);
  }

  String toStringAsPrecision(int precision) {
    return this.toDouble().toStringAsPrecision(precision);
  }

  String toRadixString(int radix) => _intToRadixString(value, radix);

  // Returns pow(this, e) % m.
  int modPow(int e, int m) {
    if (e < 0) throw new RangeError.range(e, 0, null, "exponent");
    if (m <= 0) throw new RangeError.range(m, 1, null, "modulus");
    if (e == 0) return 1;

    // This is floor(sqrt(2^63)).
    const int maxValueThatCanBeSquaredWithoutTruncation = 3037000499;
    if (m > maxValueThatCanBeSquaredWithoutTruncation) {
      // Use BigInt version to avoid truncation in multiplications below.
      return BigInt.from(this).modPow(BigInt.from(e), BigInt.from(m)).toInt();
    }

    int b = this;
    if (b < 0 || b > m) {
      b %= m;
    }
    int r = 1;
    while (e > 0) {
      if (e.isOdd) {
        r = (r * b) % m;
      }
      e >>= 1;
      b = (b * b) % m;
    }
    return r;
  }

  // If inv is false, returns gcd(x, y).
  // If inv is true and gcd(x, y) = 1, returns d, so that c*x + d*y = 1.
  // If inv is true and gcd(x, y) != 1, throws Exception("Not coprime").
  static int _binaryGcd(int x, int y, bool inv) {
    int s = 0;
    if (!inv) {
      while (x.isEven && y.isEven) {
        x >>= 1;
        y >>= 1;
        s++;
      }
      if (y.isOdd) {
        var t = x;
        x = y;
        y = t;
      }
    }
    final bool ac = x.isEven;
    int u = x;
    int v = y;
    int a = 1, b = 0, c = 0, d = 1;
    do {
      while (u.isEven) {
        u >>= 1;
        if (ac) {
          if (!a.isEven || !b.isEven) {
            a += y;
            b -= x;
          }
          a >>= 1;
        } else if (!b.isEven) {
          b -= x;
        }
        b >>= 1;
      }
      while (v.isEven) {
        v >>= 1;
        if (ac) {
          if (!c.isEven || !d.isEven) {
            c += y;
            d -= x;
          }
          c >>= 1;
        } else if (!d.isEven) {
          d -= x;
        }
        d >>= 1;
      }
      if (u >= v) {
        u -= v;
        if (ac) a -= c;
        b -= d;
      } else {
        v -= u;
        if (ac) c -= a;
        d -= b;
      }
    } while (u != 0);
    if (!inv) return v << s;
    if (v != 1) {
      throw new Exception("Not coprime");
    }
    if (d < 0) {
      d += x;
      if (d < 0) d += x;
    } else if (d > x) {
      d -= x;
      if (d > x) d -= x;
    }
    return d;
  }

  // Returns 1/this % m, with m > 0.
  int modInverse(int m) {
    if (m <= 0) throw new RangeError.range(m, 1, null, "modulus");
    if (m == 1) return 0;
    int t = this;
    if ((t < 0) || (t >= m)) t %= m;
    if (t == 1) return 1;
    if ((t == 0) || (t.isEven && m.isEven)) {
      throw new Exception("Not coprime");
    }
    return _binaryGcd(m, t, true);
  }

  // Returns gcd of abs(this) and abs(other).
  int gcd(int other) {
    int x = this.abs();
    int y = other.abs();
    if (x == 0) return y;
    if (y == 0) return x;
    if ((x == 1) || (y == 1)) return 1;
    return _binaryGcd(x, y, false);
  }

  int get hashCode => _intHashCode(this);

  external int operator ~();
  external int get bitLength;

  @override
  String toString() => _intToString(value);
}

const _digits = "0123456789abcdefghijklmnopqrstuvwxyz";

String _intToRadixString(int value, int radix) {
  if (radix < 2 || 36 < radix) {
    throw new RangeError.range(radix, 2, 36, "radix");
  }
  if (radix & (radix - 1) == 0) {
    return _toPow2String(value, radix);
  }
  if (radix == 10) return _intToString(value);
  final bool isNegative = value < 0;
  value = isNegative ? -value : value;
  if (value < 0) {
    // With int limited to 64 bits, the value
    // MIN_INT64 = -0x8000000000000000 overflows at negation:
    // -MIN_INT64 == MIN_INT64, so it requires special handling.
    return _minInt64ToRadixString(value, radix);
  }
  var temp = <int>[];
  do {
    int digit = value % radix;
    value ~/= radix;
    temp.add(_digits.codeUnitAt(digit));
  } while (value > 0);
  if (isNegative) temp.add(0x2d); // '-'.

  final string = OneByteString.withLength(temp.length);
  for (int i = 0, j = temp.length; j > 0; i++) {
    writeIntoOneByteString(string, i, temp[--j]);
  }
  return string;
}

String _toPow2String(int value, int radix) {
  if (value == 0) return "0";
  assert(radix & (radix - 1) == 0);
  var negative = value < 0;
  var bitsPerDigit = radix.bitLength - 1;
  var length = 0;
  if (negative) {
    value = -value;
    length = 1;
    if (value < 0) {
      // With int limited to 64 bits, the value
      // MIN_INT64 = -0x8000000000000000 overflows at negation:
      // -MIN_INT64 == MIN_INT64, so it requires special handling.
      return _minInt64ToRadixString(value, radix);
    }
  }
  // Integer division, rounding up, to find number of _digits.
  length += (value.bitLength + bitsPerDigit - 1) ~/ bitsPerDigit;
  final string = OneByteString.withLength(length);
  writeIntoOneByteString(
      string, 0, 0x2d); // '-'. Is overwritten if not negative.
  var mask = radix - 1;
  do {
    writeIntoOneByteString(string, --length, _digits.codeUnitAt(value & mask));
    value >>= bitsPerDigit;
  } while (value > 0);
  return string;
}

/// Converts negative value to radix string.
/// This method is only used to handle corner case of
/// MIN_INT64 = -0x8000000000000000.
String _minInt64ToRadixString(int value, int radix) {
  var temp = <int>[];
  assert(value < 0);
  do {
    int digit = -unsafeCast<int>(value.remainder(radix));
    value ~/= radix;
    temp.add(_digits.codeUnitAt(digit));
  } while (value != 0);
  temp.add(0x2d); // '-'.

  final string = OneByteString.withLength(temp.length);
  for (int i = 0, j = temp.length; j > 0; i++) {
    writeIntoOneByteString(string, i, temp[--j]);
  }
  return string;
}

/**
 * The digits of '00', '01', ... '99' as a single array.
 *
 * Get the digits of `n`, with `0 <= n < 100`, as
 * `_digitTable[n * 2]` and `_digitTable[n * 2 + 1]`.
 */
const _digitTable = const [
  0x30, 0x30, 0x30, 0x31, 0x30, 0x32, 0x30, 0x33, //
  0x30, 0x34, 0x30, 0x35, 0x30, 0x36, 0x30, 0x37, //
  0x30, 0x38, 0x30, 0x39, 0x31, 0x30, 0x31, 0x31, //
  0x31, 0x32, 0x31, 0x33, 0x31, 0x34, 0x31, 0x35, //
  0x31, 0x36, 0x31, 0x37, 0x31, 0x38, 0x31, 0x39, //
  0x32, 0x30, 0x32, 0x31, 0x32, 0x32, 0x32, 0x33, //
  0x32, 0x34, 0x32, 0x35, 0x32, 0x36, 0x32, 0x37, //
  0x32, 0x38, 0x32, 0x39, 0x33, 0x30, 0x33, 0x31, //
  0x33, 0x32, 0x33, 0x33, 0x33, 0x34, 0x33, 0x35, //
  0x33, 0x36, 0x33, 0x37, 0x33, 0x38, 0x33, 0x39, //
  0x34, 0x30, 0x34, 0x31, 0x34, 0x32, 0x34, 0x33, //
  0x34, 0x34, 0x34, 0x35, 0x34, 0x36, 0x34, 0x37, //
  0x34, 0x38, 0x34, 0x39, 0x35, 0x30, 0x35, 0x31, //
  0x35, 0x32, 0x35, 0x33, 0x35, 0x34, 0x35, 0x35, //
  0x35, 0x36, 0x35, 0x37, 0x35, 0x38, 0x35, 0x39, //
  0x36, 0x30, 0x36, 0x31, 0x36, 0x32, 0x36, 0x33, //
  0x36, 0x34, 0x36, 0x35, 0x36, 0x36, 0x36, 0x37, //
  0x36, 0x38, 0x36, 0x39, 0x37, 0x30, 0x37, 0x31, //
  0x37, 0x32, 0x37, 0x33, 0x37, 0x34, 0x37, 0x35, //
  0x37, 0x36, 0x37, 0x37, 0x37, 0x38, 0x37, 0x39, //
  0x38, 0x30, 0x38, 0x31, 0x38, 0x32, 0x38, 0x33, //
  0x38, 0x34, 0x38, 0x35, 0x38, 0x36, 0x38, 0x37, //
  0x38, 0x38, 0x38, 0x39, 0x39, 0x30, 0x39, 0x31, //
  0x39, 0x32, 0x39, 0x33, 0x39, 0x34, 0x39, 0x35, //
  0x39, 0x36, 0x39, 0x37, 0x39, 0x38, 0x39, 0x39, //
];

/**
 * Result of int.toString for -99, -98, ..., 98, 99.
 */
const _smallLookupTable = const [
  "-99", "-98", "-97", "-96", "-95", "-94", "-93", "-92", "-91", "-90", //
  "-89", "-88", "-87", "-86", "-85", "-84", "-83", "-82", "-81", "-80", //
  "-79", "-78", "-77", "-76", "-75", "-74", "-73", "-72", "-71", "-70", //
  "-69", "-68", "-67", "-66", "-65", "-64", "-63", "-62", "-61", "-60", //
  "-59", "-58", "-57", "-56", "-55", "-54", "-53", "-52", "-51", "-50", //
  "-49", "-48", "-47", "-46", "-45", "-44", "-43", "-42", "-41", "-40", //
  "-39", "-38", "-37", "-36", "-35", "-34", "-33", "-32", "-31", "-30", //
  "-29", "-28", "-27", "-26", "-25", "-24", "-23", "-22", "-21", "-20", //
  "-19", "-18", "-17", "-16", "-15", "-14", "-13", "-12", "-11", "-10", //
  "-9", "-8", "-7", "-6", "-5", "-4", "-3", "-2", "-1", "0", //
  "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", //
  "11", "12", "13", "14", "15", "16", "17", "18", "19", "20", //
  "21", "22", "23", "24", "25", "26", "27", "28", "29", "30", //
  "31", "32", "33", "34", "35", "36", "37", "38", "39", "40", //
  "41", "42", "43", "44", "45", "46", "47", "48", "49", "50", //
  "51", "52", "53", "54", "55", "56", "57", "58", "59", "60", //
  "61", "62", "63", "64", "65", "66", "67", "68", "69", "70", //
  "71", "72", "73", "74", "75", "76", "77", "78", "79", "80", //
  "81", "82", "83", "84", "85", "86", "87", "88", "89", "90", //
  "91", "92", "93", "94", "95", "96", "97", "98", "99" //
];

// Powers of 10 above 1000000 are indistinguishable by eye.
const int _POW_10_7 = 10000000;
const int _POW_10_8 = 100000000;
const int _POW_10_9 = 1000000000;

// Find the number of decimal digits in a positive smi.
// Never called with numbers < 100. These are handled before calling.
int _positiveBase10Length(int smi) {
  // A positive smi has length <= 19 if 63-bit,  <=10 if 31-bit.
  // Avoid comparing a 31-bit smi to a non-smi.
  if (smi < 1000) return 3;
  if (smi < 10000) return 4;
  if (smi < _POW_10_7) {
    if (smi < 100000) return 5;
    if (smi < 1000000) return 6;
    return 7;
  }
  if (smi < _POW_10_8) return 8;
  if (smi < _POW_10_9) return 9;
  smi = smi ~/ _POW_10_9;
  // Handle numbers < 100 before calling recursively.
  if (smi < 10) return 10;
  if (smi < 100) return 11;
  return 9 + _positiveBase10Length(smi);
}

String _intToString(int value) {
  if (value < 100 && value > -100) {
    // Issue(https://dartbug.com/39639): The analyzer incorrectly reports the
    // result type as `num`.
    return _smallLookupTable[value + 99];
  }
  if (value < 0) return _negativeToString(value);
  // Inspired by Andrei Alexandrescu: "Three Optimization Tips for C++"
  // Avoid expensive remainder operation by doing it on more than
  // one digit at a time.
  const int DIGIT_ZERO = 0x30;
  int length = _positiveBase10Length(value);
  final result = OneByteString.withLength(length);
  int index = length - 1;
  int smi = value;
  do {
    // Two digits at a time.
    final int twoDigits = smi.remainder(100);
    smi = smi ~/ 100;
    int digitIndex = twoDigits * 2;
    writeIntoOneByteString(result, index, _digitTable[digitIndex + 1]);
    writeIntoOneByteString(result, index - 1, _digitTable[digitIndex]);
    index -= 2;
  } while (smi >= 100);
  if (smi < 10) {
    // Character code for '0'.
    // Issue(https://dartbug.com/39639): The analyzer incorrectly reports the
    // result type as `num`.
    writeIntoOneByteString(result, index, DIGIT_ZERO + smi);
  } else {
    // No remainder for this case.
    // Issue(https://dartbug.com/39639): The analyzer incorrectly reports the
    // result type as `num`.
    int digitIndex = smi * 2;
    writeIntoOneByteString(result, index, _digitTable[digitIndex + 1]);
    writeIntoOneByteString(result, index - 1, _digitTable[digitIndex]);
  }
  return result;
}

// Find the number of decimal digits in a negative smi.
// Never called with numbers > -100. These are handled before calling.
int _negativeBase10Length(int negSmi) {
  // A negative smi has length <= 19 if 63-bit, <=10 if 31-bit.
  // Avoid comparing a 31-bit smi to a non-smi.
  if (negSmi > -1000) return 3;
  if (negSmi > -10000) return 4;
  if (negSmi > -_POW_10_7) {
    if (negSmi > -100000) return 5;
    if (negSmi > -1000000) return 6;
    return 7;
  }
  if (negSmi > -_POW_10_8) return 8;
  if (negSmi > -_POW_10_9) return 9;
  negSmi = negSmi ~/ _POW_10_9;
  // Handle numbers > -100 before calling recursively.
  if (negSmi > -10) return 10;
  if (negSmi > -100) return 11;
  return 9 + _negativeBase10Length(negSmi);
}

// Convert a negative smi to a string.
// Doesn't negate the smi to avoid negating the most negative smi, which
// would become a non-smi.
String _negativeToString(int negSmi) {
  // Character code for '-'
  const int MINUS_SIGN = 0x2d;
  // Character code for '0'.
  const int DIGIT_ZERO = 0x30;
  // Number of digits, not including minus.
  int digitCount = _negativeBase10Length(negSmi);
  final result = OneByteString.withLength(digitCount + 1);
  writeIntoOneByteString(result, 0, MINUS_SIGN); // '-'.
  int index = digitCount;
  do {
    int twoDigits = unsafeCast<int>(negSmi.remainder(100));
    negSmi = negSmi ~/ 100;
    int digitIndex = -twoDigits * 2;
    writeIntoOneByteString(result, index, _digitTable[digitIndex + 1]);
    writeIntoOneByteString(result, index - 1, _digitTable[digitIndex]);
    index -= 2;
  } while (negSmi <= -100);
  if (negSmi > -10) {
    writeIntoOneByteString(result, index, DIGIT_ZERO - negSmi);
  } else {
    // No remainder necessary for this case.
    int digitIndex = -negSmi * 2;
    writeIntoOneByteString(result, index, _digitTable[digitIndex + 1]);
    writeIntoOneByteString(result, index - 1, _digitTable[digitIndex]);
  }
  return result;
}

int _intHashCode(int value) {
  const int magic = 0x2D51;
  int lower = (value & 0xFFFFFFFF) * magic;
  int upper = (value >>> 32) * magic;
  int upper_accum = upper + (lower >>> 32);
  return (lower ^ upper_accum ^ (upper_accum >>> 32)) & 0x3FFFFFFF;
}
