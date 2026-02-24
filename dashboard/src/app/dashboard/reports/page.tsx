'use client';

import Link from 'next/link';
import {
  Clock,
  Users,
  Calendar,
  FileDown,
  ArrowRight,
} from 'lucide-react';
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import type { ReportType } from '@/types/reports';

interface ReportCard {
  type: ReportType;
  title: string;
  description: string;
  icon: React.ComponentType<{ className?: string }>;
  href: string;
  features: string[];
  priority: 'P1' | 'P2' | 'P3' | 'P4';
}

const reportCards: ReportCard[] = [
  {
    type: 'timesheet',
    title: 'Timesheet Report',
    description: 'Comprehensive timesheet data for pay period processing',
    icon: Clock,
    href: '/dashboard/reports/timesheet',
    features: [
      'Shift hours by employee',
      'Overtime calculations',
      'Incomplete shift warnings',
      'PDF & CSV export',
    ],
    priority: 'P1',
  },
  {
    type: 'shift_history',
    title: 'Shift History Export',
    description: 'Detailed shift records with GPS data for individual employees',
    icon: FileDown,
    href: '/dashboard/reports/exports',
    features: [
      'Single or bulk employee export',
      'GPS point counts',
      'Distance tracking',
      'Date range filtering',
    ],
    priority: 'P2',
  },
  {
    type: 'activity_summary',
    title: 'Team Activity Summary',
    description: 'Aggregate metrics and trends for team planning',
    icon: Users,
    href: '/dashboard/reports/activity',
    features: [
      'Total hours by team',
      'Day-of-week breakdown',
      'Active employee counts',
      'Period comparisons',
    ],
    priority: 'P2',
  },
  {
    type: 'attendance',
    title: 'Attendance Report',
    description: 'Employee attendance patterns and absence tracking',
    icon: Calendar,
    href: '/dashboard/reports/attendance',
    features: [
      'Days worked vs absent',
      'Attendance rate %',
      'Calendar view',
      'Pattern analysis',
    ],
    priority: 'P3',
  },
];

export default function ReportsPage() {
  return (
    <div className="space-y-6">
      {/* Page header */}
      <div>
        <h1 className="text-2xl font-bold text-slate-900">Reports & Export</h1>
        <p className="text-sm text-slate-500 mt-1">
          Generate and download reports for payroll, compliance, and analytics
        </p>
      </div>

      {/* Report type cards */}
      <div className="grid gap-6 md:grid-cols-2">
        {reportCards.map((card) => (
          <Card key={card.type} className="flex flex-col">
            <CardHeader>
              <div className="flex items-center justify-between">
                <div className="flex h-10 w-10 items-center justify-center rounded-lg bg-slate-100">
                  <card.icon className="h-5 w-5 text-slate-700" />
                </div>
                <span className="text-xs font-medium text-slate-400">
                  {card.priority}
                </span>
              </div>
              <CardTitle className="mt-4">{card.title}</CardTitle>
              <CardDescription>{card.description}</CardDescription>
            </CardHeader>
            <CardContent className="flex-1">
              <ul className="space-y-2">
                {card.features.map((feature) => (
                  <li
                    key={feature}
                    className="flex items-center gap-2 text-sm text-slate-600"
                  >
                    <span className="h-1.5 w-1.5 rounded-full bg-slate-400" />
                    {feature}
                  </li>
                ))}
              </ul>
            </CardContent>
            <CardFooter>
              <Button asChild className="w-full">
                <Link href={card.href}>
                  Generate Report
                  <ArrowRight className="ml-2 h-4 w-4" />
                </Link>
              </Button>
            </CardFooter>
          </Card>
        ))}
      </div>

      {/* Quick actions */}
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">Quick Actions</CardTitle>
        </CardHeader>
        <CardContent>
          <div className="flex flex-wrap gap-3">
            <Button variant="outline" asChild>
              <Link href="/dashboard/reports/schedules">
                Manage Scheduled Reports
              </Link>
            </Button>
            <Button variant="outline" asChild>
              <Link href="/dashboard/reports/history">
                View Report History
              </Link>
            </Button>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
