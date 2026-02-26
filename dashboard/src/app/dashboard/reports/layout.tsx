'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { FileText, Clock, Calendar, Users, CalendarClock } from 'lucide-react';
import { cn } from '@/lib/utils';

const reportNavigation = [
  {
    name: 'Tous les rapports',
    href: '/dashboard/reports',
    icon: FileText,
    exact: true,
  },
  {
    name: 'Feuille de temps',
    href: '/dashboard/reports/timesheet',
    icon: Clock,
  },
  {
    name: 'Résumé d\'activité',
    href: '/dashboard/reports/activity',
    icon: Users,
  },
  {
    name: 'Présence',
    href: '/dashboard/reports/attendance',
    icon: Calendar,
  },
  {
    name: 'Programmation',
    href: '/dashboard/reports/schedules',
    icon: CalendarClock,
  },
];

export default function ReportsLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  const pathname = usePathname();

  return (
    <div className="space-y-6">
      {/* Sub-navigation for reports */}
      <nav className="flex flex-wrap gap-2 border-b border-slate-200 pb-4">
        {reportNavigation.map((item) => {
          const isActive = item.exact
            ? pathname === item.href
            : pathname === item.href || pathname?.startsWith(`${item.href}/`);

          return (
            <Link
              key={item.name}
              href={item.href}
              className={cn(
                'flex items-center gap-2 rounded-lg px-4 py-2 text-sm font-medium transition-colors',
                isActive
                  ? 'bg-slate-900 text-white'
                  : 'bg-slate-100 text-slate-600 hover:bg-slate-200 hover:text-slate-900'
              )}
            >
              <item.icon className="h-4 w-4" />
              {item.name}
            </Link>
          );
        })}
      </nav>

      {/* Page content */}
      {children}
    </div>
  );
}
