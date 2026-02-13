'use client';

import { useState, useCallback } from 'react';
import { useCustom } from '@refinedev/core';
import { StatsCards } from '@/components/dashboard/stats-cards';
import { ActivityFeed } from '@/components/dashboard/activity-feed';
import { DataFreshness } from '@/components/dashboard/data-freshness';
import type { OrganizationDashboardSummary, ActiveEmployee } from '@/types/dashboard';

const REFRESH_INTERVAL = 30000; // 30 seconds

export default function DashboardPage() {
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);

  // Fetch organization dashboard summary
  const {
    query: summaryQuery,
    result: summaryResult,
  } = useCustom<OrganizationDashboardSummary>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_org_dashboard_summary' },
    queryOptions: {
      refetchInterval: REFRESH_INTERVAL,
      refetchIntervalInBackground: true,
      staleTime: REFRESH_INTERVAL - 5000,
    },
  });

  // Fetch active employees for activity feed
  const {
    query: activityQuery,
    result: activityResult,
  } = useCustom<ActiveEmployee[]>({
    url: '',
    method: 'get',
    meta: { rpc: 'get_team_active_status' },
    queryOptions: {
      refetchInterval: REFRESH_INTERVAL,
      refetchIntervalInBackground: true,
      staleTime: REFRESH_INTERVAL - 5000,
    },
  });

  const [isRefreshing, setIsRefreshing] = useState(false);

  const handleRefresh = useCallback(async () => {
    setIsRefreshing(true);
    try {
      await Promise.all([summaryQuery.refetch(), activityQuery.refetch()]);
      setLastUpdated(new Date());
    } finally {
      setIsRefreshing(false);
    }
  }, [summaryQuery, activityQuery]);

  const isLoading = summaryQuery.isLoading || activityQuery.isLoading;
  const error = summaryQuery.error || activityQuery.error;

  // Update lastUpdated when data is successfully fetched
  if (summaryQuery.isSuccess && !lastUpdated) {
    setLastUpdated(new Date());
  }

  // Check for empty organization (no employees)
  const summaryData = summaryResult?.data as OrganizationDashboardSummary | undefined;
  const activityData = activityResult?.data as ActiveEmployee[] | undefined;
  const hasNoEmployees = summaryData?.employee_counts?.total === 0;

  return (
    <div className="space-y-6">
      {/* Page header with data freshness */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-2xl font-bold text-slate-900">Organization Overview</h2>
          <p className="text-sm text-slate-500">
            Monitor your organization&apos;s employee activity and shift statistics
          </p>
        </div>
        <DataFreshness
          lastUpdated={lastUpdated}
          isRefreshing={isRefreshing}
          onRefresh={handleRefresh}
          error={error instanceof Error ? error : null}
        />
      </div>

      {/* Empty state for organizations with no employees */}
      {!isLoading && hasNoEmployees ? (
        <EmptyOrganizationState />
      ) : (
        <>
          {/* Stats cards */}
          <StatsCards data={summaryData} isLoading={isLoading} />

          {/* Activity feed */}
          <div className="grid gap-6 lg:grid-cols-2">
            <ActivityFeed data={activityData} isLoading={isLoading} />
            <RoleSummaryCard data={summaryData} isLoading={isLoading} />
          </div>
        </>
      )}
    </div>
  );
}

function EmptyOrganizationState() {
  return (
    <div className="flex flex-col items-center justify-center rounded-lg border border-dashed border-slate-300 bg-white py-16">
      <div className="flex h-16 w-16 items-center justify-center rounded-full bg-slate-100">
        <svg
          className="h-8 w-8 text-slate-400"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth={2}
            d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197m13.5-9a2.5 2.5 0 11-5 0 2.5 2.5 0 015 0z"
          />
        </svg>
      </div>
      <h3 className="mt-4 text-lg font-semibold text-slate-900">No employees yet</h3>
      <p className="mt-2 text-center text-sm text-slate-500 max-w-md">
        Your organization doesn&apos;t have any employees registered. Employees can sign up
        through the GPS Tracker mobile app to start tracking their shifts.
      </p>
    </div>
  );
}

function RoleSummaryCard({
  data,
  isLoading,
}: {
  data?: OrganizationDashboardSummary;
  isLoading?: boolean;
}) {
  if (isLoading) {
    return (
      <div className="rounded-lg border border-slate-200 bg-white p-6">
        <div className="h-5 w-32 bg-slate-200 rounded mb-4 animate-pulse" />
        <div className="space-y-3">
          {Array.from({ length: 4 }).map((_, i) => (
            <div key={i} className="flex justify-between">
              <div className="h-4 w-24 bg-slate-200 rounded animate-pulse" />
              <div className="h-4 w-12 bg-slate-200 rounded animate-pulse" />
            </div>
          ))}
        </div>
      </div>
    );
  }

  const roles = [
    { name: 'Employees', count: data?.employee_counts?.by_role?.employee ?? 0, color: 'bg-blue-500' },
    { name: 'Managers', count: data?.employee_counts?.by_role?.manager ?? 0, color: 'bg-green-500' },
    { name: 'Admins', count: data?.employee_counts?.by_role?.admin ?? 0, color: 'bg-purple-500' },
    { name: 'Super Admins', count: data?.employee_counts?.by_role?.super_admin ?? 0, color: 'bg-orange-500' },
  ];

  const total = data?.employee_counts?.total ?? 0;

  return (
    <div className="rounded-lg border border-slate-200 bg-white p-6">
      <h3 className="text-base font-semibold text-slate-900 mb-4">Employees by Role</h3>
      <div className="space-y-4">
        {roles.map((role) => {
          const percentage = total > 0 ? (role.count / total) * 100 : 0;
          return (
            <div key={role.name}>
              <div className="flex justify-between text-sm mb-1">
                <span className="text-slate-600">{role.name}</span>
                <span className="font-medium text-slate-900">{role.count}</span>
              </div>
              <div className="h-2 bg-slate-100 rounded-full overflow-hidden">
                <div
                  className={`h-full ${role.color} rounded-full transition-all duration-300`}
                  style={{ width: `${percentage}%` }}
                />
              </div>
            </div>
          );
        })}
      </div>
      <div className="mt-4 pt-4 border-t border-slate-100">
        <div className="flex justify-between">
          <span className="text-sm text-slate-600">Active Status</span>
          <span className="text-sm font-medium text-green-600">
            {data?.employee_counts.active_status?.active ?? 0} active
          </span>
        </div>
      </div>
    </div>
  );
}
