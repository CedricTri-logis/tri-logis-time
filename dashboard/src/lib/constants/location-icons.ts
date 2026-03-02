import {
  Monitor,
  Building,
  ShoppingCart,
  Home,
  Coffee,
  Fuel,
  MapPin,
} from 'lucide-react';
import type { LocationType } from '@/types/location';

export const LOCATION_TYPE_ICON_MAP: Record<LocationType, { icon: React.ElementType; className: string }> = {
  office: { icon: Monitor, className: 'h-4 w-4 text-blue-500' },
  building: { icon: Building, className: 'h-4 w-4 text-amber-500' },
  vendor: { icon: ShoppingCart, className: 'h-4 w-4 text-violet-500' },
  home: { icon: Home, className: 'h-4 w-4 text-green-500' },
  cafe_restaurant: { icon: Coffee, className: 'h-4 w-4 text-pink-500' },
  gaz: { icon: Fuel, className: 'h-4 w-4 text-red-500' },
  other: { icon: MapPin, className: 'h-4 w-4 text-gray-500' },
};
