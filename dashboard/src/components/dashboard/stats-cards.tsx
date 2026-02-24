'use client';

import { Users, Clock, CheckCircle, Briefcase } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import type { OrganizationDashboardSummary } from '@/types/dashboard';
import { formatHours } from '@/types/dashboard';

interface StatsCardsProps {
  data?: OrganizationDashboardSummary;
  isLoading?: boolean;
}

export function StatsCards({ data, isLoading }: StatsCardsProps) {
  if (isLoading) {
    return <StatsCardsSkeleton />;
  }

  const stats = [
    {
      title: 'Total Employees',
      value: data?.employee_counts?.total ?? 0,
      subtitle: `${data?.employee_counts?.by_role?.manager ?? 0} managers, ${data?.employee_counts?.by_role?.admin ?? 0} admins`,
      icon: Users,
      color: 'text-blue-600',
      bgColor: 'bg-blue-50',
    },
    {
      title: 'Active Shifts',
      value: data?.shift_stats?.active_shifts ?? 0,
      subtitle: `${data?.shift_stats?.completed_today ?? 0} completed today`,
      icon: Briefcase,
      color: 'text-green-600',
      bgColor: 'bg-green-50',
    },
    {
      title: 'Hours Today',
      value: formatHours(data?.shift_stats?.total_hours_today ?? 0),
      subtitle: `${formatHours(data?.shift_stats?.total_hours_this_week ?? 0)} this week`,
      icon: Clock,
      color: 'text-purple-600',
      bgColor: 'bg-purple-50',
    },
    {
      title: 'Hours This Month',
      value: formatHours(data?.shift_stats?.total_hours_this_month ?? 0),
      subtitle: `Active: ${data?.employee_counts?.active_status?.active ?? 0}`,
      icon: CheckCircle,
      color: 'text-orange-600',
      bgColor: 'bg-orange-50',
    },
  ];

  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
      {stats.map((stat) => (
        <Card key={stat.title}>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <CardTitle className="text-sm font-medium text-slate-600">
              {stat.title}
            </CardTitle>
            <div className={`rounded-full p-2 ${stat.bgColor}`}>
              <stat.icon className={`h-4 w-4 ${stat.color}`} />
            </div>
          </CardHeader>
          <CardContent>
            <div className="text-2xl font-bold text-slate-900">{stat.value}</div>
            <p className="text-xs text-slate-500">{stat.subtitle}</p>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}

function StatsCardsSkeleton() {
  return (
    <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
      {Array.from({ length: 4 }).map((_, i) => (
        <Card key={i}>
          <CardHeader className="flex flex-row items-center justify-between space-y-0 pb-2">
            <Skeleton className="h-4 w-24" />
            <Skeleton className="h-8 w-8 rounded-full" />
          </CardHeader>
          <CardContent>
            <Skeleton className="h-8 w-20 mb-2" />
            <Skeleton className="h-3 w-32" />
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
