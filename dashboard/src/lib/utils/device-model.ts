/**
 * Maps iOS hardware identifiers (utsname.machine) to human-readable marketing names.
 * Android models are returned as-is since they already use readable names.
 */

const IPHONE_MODELS: Record<string, string> = {
  // iPhone 8
  'iPhone10,1': 'iPhone 8',
  'iPhone10,4': 'iPhone 8',
  'iPhone10,2': 'iPhone 8 Plus',
  'iPhone10,5': 'iPhone 8 Plus',
  // iPhone X
  'iPhone10,3': 'iPhone X',
  'iPhone10,6': 'iPhone X',
  // iPhone XR / XS
  'iPhone11,2': 'iPhone XS',
  'iPhone11,4': 'iPhone XS Max',
  'iPhone11,6': 'iPhone XS Max',
  'iPhone11,8': 'iPhone XR',
  // iPhone 11
  'iPhone12,1': 'iPhone 11',
  'iPhone12,3': 'iPhone 11 Pro',
  'iPhone12,5': 'iPhone 11 Pro Max',
  // iPhone SE (2nd gen)
  'iPhone12,8': 'iPhone SE (2nd)',
  // iPhone 12
  'iPhone13,1': 'iPhone 12 mini',
  'iPhone13,2': 'iPhone 12',
  'iPhone13,3': 'iPhone 12 Pro',
  'iPhone13,4': 'iPhone 12 Pro Max',
  // iPhone 13
  'iPhone14,4': 'iPhone 13 mini',
  'iPhone14,5': 'iPhone 13',
  'iPhone14,2': 'iPhone 13 Pro',
  'iPhone14,3': 'iPhone 13 Pro Max',
  // iPhone SE (3rd gen)
  'iPhone14,6': 'iPhone SE (3rd)',
  // iPhone 14
  'iPhone14,7': 'iPhone 14',
  'iPhone14,8': 'iPhone 14 Plus',
  'iPhone15,2': 'iPhone 14 Pro',
  'iPhone15,3': 'iPhone 14 Pro Max',
  // iPhone 15
  'iPhone15,4': 'iPhone 15',
  'iPhone15,5': 'iPhone 15 Plus',
  'iPhone16,1': 'iPhone 15 Pro',
  'iPhone16,2': 'iPhone 15 Pro Max',
  // iPhone 16
  'iPhone17,1': 'iPhone 16 Pro',
  'iPhone17,2': 'iPhone 16 Pro Max',
  'iPhone17,3': 'iPhone 16',
  'iPhone17,4': 'iPhone 16 Plus',
  // iPhone 16e
  'iPhone17,5': 'iPhone 16e',
};

const IPAD_MODELS: Record<string, string> = {
  'iPad13,18': 'iPad (10th)',
  'iPad13,19': 'iPad (10th)',
  'iPad14,1': 'iPad mini (6th)',
  'iPad14,2': 'iPad mini (6th)',
  'iPad14,3': 'iPad Pro 11" (4th)',
  'iPad14,4': 'iPad Pro 11" (4th)',
  'iPad14,5': 'iPad Pro 12.9" (6th)',
  'iPad14,6': 'iPad Pro 12.9" (6th)',
  'iPad14,8': 'iPad Air (M2)',
  'iPad14,9': 'iPad Air (M2)',
  'iPad14,10': 'iPad Air 13" (M2)',
  'iPad14,11': 'iPad Air 13" (M2)',
  'iPad16,1': 'iPad mini (A17 Pro)',
  'iPad16,2': 'iPad mini (A17 Pro)',
  'iPad16,3': 'iPad Pro 11" (M4)',
  'iPad16,4': 'iPad Pro 11" (M4)',
  'iPad16,5': 'iPad Pro 13" (M4)',
  'iPad16,6': 'iPad Pro 13" (M4)',
};

/**
 * Convert a device model identifier to a human-readable name.
 * - iOS: maps "iPhone16,1" → "iPhone 15 Pro"
 * - Android: already readable (e.g. "Samsung SM-S918B"), returned as-is
 * - Unknown iOS identifiers: returns cleaned version (e.g. "iPhone 16,1")
 */
export function formatDeviceModel(model: string | null | undefined): string | null {
  if (!model) return null;

  // Check iPhone mapping
  if (model.startsWith('iPhone')) {
    return IPHONE_MODELS[model] ?? formatUnknownApple(model);
  }

  // Check iPad mapping
  if (model.startsWith('iPad')) {
    return IPAD_MODELS[model] ?? formatUnknownApple(model);
  }

  // Android or other — return as-is
  return model;
}

/**
 * For unknown Apple identifiers, at least make them more readable:
 * "iPhone18,3" → "iPhone (18,3)"
 */
function formatUnknownApple(model: string): string {
  const match = model.match(/^(iPhone|iPad)(\d+,\d+)$/);
  if (match) {
    return `${match[1]} (${match[2]})`;
  }
  return model;
}
