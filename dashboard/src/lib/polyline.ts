/**
 * Decodes a Google encoded polyline string with precision 6 (polyline6).
 * Returns an array of [latitude, longitude] pairs.
 */
export function decodePolyline6(encoded: string): [number, number][] {
  const points: [number, number][] = [];
  let index = 0;
  let lat = 0;
  let lng = 0;

  while (index < encoded.length) {
    // Decode latitude
    let shift = 0;
    let result = 0;
    let byte: number;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lat += result & 1 ? ~(result >> 1) : result >> 1;

    // Decode longitude
    shift = 0;
    result = 0;
    do {
      byte = encoded.charCodeAt(index++) - 63;
      result |= (byte & 0x1f) << shift;
      shift += 5;
    } while (byte >= 0x20);
    lng += result & 1 ? ~(result >> 1) : result >> 1;

    // Precision 6: divide by 1e6
    points.push([lat / 1e6, lng / 1e6]);
  }

  return points;
}

/**
 * Decodes and combines multiple encoded polyline6 strings into a single
 * array of [latitude, longitude] pairs. Used when OSRM gaps=split
 * produces multiple matchings.
 */
export function combinePolylines(encodedList: string[]): [number, number][] {
  const combined: [number, number][] = [];
  for (const encoded of encodedList) {
    combined.push(...decodePolyline6(encoded));
  }
  return combined;
}
