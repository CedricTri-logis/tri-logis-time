'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { LayoutDashboard, Users, MapPin, MapPinned, UserCog, Radio, History, FileBarChart, ClipboardList, Car, ClipboardCheck, UtensilsCrossed, DollarSign, Activity, Receipt } from 'lucide-react';
import { useGetIdentity } from '@refinedev/core';
import type { UserIdentity } from '@/types/dashboard';
import { cn } from '@/lib/utils';
import { useMonitoringBadges } from '@/lib/hooks/use-monitoring-badges';

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
    adminOnly: true,
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
    adminOnly: true,
  },
  {
    name: 'Sessions de travail',
    href: '/dashboard/work-sessions',
    icon: ClipboardList,
  },
  {
    name: 'Activités',
    href: '/dashboard/activity',
    icon: Car,
  },
  {
    name: 'Approbation',
    href: '/dashboard/approvals',
    icon: ClipboardCheck,
  },
  {
    name: 'Kilométrage',
    href: '/dashboard/mileage-approval',
    icon: Car,
  },
  {
    name: 'Rémunération',
    href: '/dashboard/remuneration',
    icon: DollarSign,
  },
  {
    name: 'Paie',
    href: '/dashboard/remuneration/payroll',
    icon: Receipt,
  },
  {
    name: 'Diagnostics GPS',
    href: '/dashboard/diagnostics',
    icon: Activity,
    adminOnly: true,
  },
  {
    name: 'Rapports',
    href: '/dashboard/reports',
    icon: FileBarChart,
    adminOnly: true,
  },
];

export function Sidebar() {
  const pathname = usePathname();
  const badges = useMonitoringBadges();
  const { data: user } = useGetIdentity<UserIdentity>();
  const isAdmin = user?.role === 'admin' || user?.role === 'super_admin';

  const visibleNavigation = navigation.filter(
    (item) => !item.adminOnly || isAdmin
  );

  return (
    <aside className="hidden w-64 flex-shrink-0 border-r border-slate-200 bg-white lg:flex lg:flex-col">
      <div className="flex h-16 items-center border-b border-slate-200 px-6">
        <MapPin className="h-6 w-6 text-slate-700" />
        <span className="ml-2 text-lg font-semibold text-slate-900">Tri-Logis Time</span>
      </div>
      <nav className="flex-1 space-y-1 p-4">
        {visibleNavigation.map((item) => {
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
              {item.href === '/dashboard/monitoring' && badges.total > 0 && (
                <span className="ml-auto flex items-center gap-1">
                  {badges.fresh > 0 && (
                    <span className="flex h-5 min-w-5 items-center justify-center rounded-full bg-green-100 px-1.5 text-xs font-semibold text-green-700">
                      {badges.fresh}
                    </span>
                  )}
                  {badges.stale > 0 && (
                    <span className="flex h-5 min-w-5 items-center justify-center rounded-full bg-yellow-100 px-1.5 text-xs font-semibold text-yellow-700">
                      {badges.stale}
                    </span>
                  )}
                  {badges.veryStale > 0 && (
                    <span className="flex h-5 min-w-5 items-center justify-center rounded-full bg-red-100 px-1.5 text-xs font-semibold text-red-700">
                      {badges.veryStale}
                    </span>
                  )}
                  {badges.onLunch > 0 && (
                    <span className="flex h-5 min-w-5 items-center justify-center rounded-full bg-orange-100 px-1.5 text-xs font-semibold text-orange-700 gap-0.5">
                      <UtensilsCrossed className="h-3 w-3" />
                      {badges.onLunch}
                    </span>
                  )}
                </span>
              )}
            </Link>
          );
        })}
      </nav>
    </aside>
  );
}
