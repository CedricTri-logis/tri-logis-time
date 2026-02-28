'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { LayoutDashboard, Users, MapPin, MapPinned, UserCog, Radio, History, FileBarChart, SprayCan, Car } from 'lucide-react';
import { cn } from '@/lib/utils';

const navigation = [
  {
    name: 'Vue d\'ensemble',
    href: '/dashboard',
    icon: LayoutDashboard,
  },
  {
    name: 'En direct',
    href: '/dashboard/monitoring',
    icon: Radio,
  },
  {
    name: 'Équipes',
    href: '/dashboard/teams',
    icon: Users,
  },
  {
    name: 'Employés',
    href: '/dashboard/employees',
    icon: UserCog,
  },
  {
    name: 'Historique',
    href: '/dashboard/history',
    icon: History,
  },
  {
    name: 'Emplacements',
    href: '/dashboard/locations',
    icon: MapPinned,
  },
  {
    name: 'Ménage',
    href: '/dashboard/cleaning',
    icon: SprayCan,
  },
  {
    name: 'Activités',
    href: '/dashboard/mileage',
    icon: Car,
  },
  {
    name: 'Rapports',
    href: '/dashboard/reports',
    icon: FileBarChart,
  },
];

export function Sidebar() {
  const pathname = usePathname();

  return (
    <aside className="hidden w-64 flex-shrink-0 border-r border-slate-200 bg-white lg:flex lg:flex-col">
      <div className="flex h-16 items-center border-b border-slate-200 px-6">
        <MapPin className="h-6 w-6 text-slate-700" />
        <span className="ml-2 text-lg font-semibold text-slate-900">Tri-Logis Time</span>
      </div>
      <nav className="flex-1 space-y-1 p-4">
        {navigation.map((item) => {
          // Support nested routes: /dashboard/employees/123 matches /dashboard/employees
          const isActive = item.href === '/dashboard'
            ? pathname === item.href
            : pathname === item.href || pathname?.startsWith(`${item.href}/`);
          return (
            <Link
              key={item.name}
              href={item.href}
              className={cn(
                'flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors',
                isActive
                  ? 'bg-slate-100 text-slate-900'
                  : 'text-slate-600 hover:bg-slate-50 hover:text-slate-900'
              )}
            >
              <item.icon className="h-5 w-5" />
              {item.name}
            </Link>
          );
        })}
      </nav>
    </aside>
  );
}
