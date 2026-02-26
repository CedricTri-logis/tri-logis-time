'use client';

import { useState, useCallback } from 'react';
import { useCustom } from '@refinedev/core';
import { Users } from 'lucide-react';
import { TeamComparisonTable } from '@/components/dashboard/team-comparison-table';
import { DateRangeSelector } from '@/components/dashboard/date-range-selector';
import { DataFreshness } from '@/components/dashboard/data-freshness';
import type { TeamSummary, DateRange } from '@/types/dashboard';
import { getDateRangeDates } from '@/types/dashboard';

const REFRESH_INTERVAL = 30000; // 30 seconds

export default function TeamsPage() {
  const [dateRange, setDateRange] = useState<DateRange>({ preset: 'this_month' });
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [isRefreshing, setIsRefreshing] = useState(false);

  const { start, end } = getDateRangeDates(dateRange);

  const {
    query,
    result,
  } = useCustom<TeamSummary[]>({
    url: '',
    method: 'get',
    config: {
      payload: {
        p_start_date: start.toISOString(),
        p_end_date: end.toISOString(),
      },
    },
    meta: { rpc: 'get_manager_team_summaries' },
    queryOptions: {
      refetchInterval: REFRESH_INTERVAL,
      refetchIntervalInBackground: true,
      staleTime: REFRESH_INTERVAL - 5000,
    },
  });

  const handleRefresh = useCallback(async () => {
    setIsRefreshing(true);
    try {
      await query.refetch();
      setLastUpdated(new Date());
    } finally {
      setIsRefreshing(false);
    }
  }, [query]);

  // Update lastUpdated when data is successfully fetched
  if (query.isSuccess && !lastUpdated) {
    setLastUpdated(new Date());
  }

  const teamsData = result?.data as TeamSummary[] | undefined;
  const hasNoTeams = !query.isLoading && (!teamsData || teamsData.length === 0);

  return (
    <div className="space-y-6">
      {/* Page header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 className="text-2xl font-bold text-slate-900">Comparaison des &eacute;quipes</h2>
          <p className="text-sm text-slate-500">
            Comparez les performances entre les &eacute;quipes et les gestionnaires
          </p>
        </div>
        <DataFreshness
          lastUpdated={lastUpdated}
          isRefreshing={isRefreshing}
          onRefresh={handleRefresh}
          error={query.error instanceof Error ? query.error : null}
        />
      </div>

      {/* Filters */}
      <div className="flex items-center gap-4">
        <DateRangeSelector value={dateRange} onChange={setDateRange} />
      </div>

      {/* Content */}
      {hasNoTeams ? (
        <EmptyTeamsState />
      ) : (
        <TeamComparisonTable data={teamsData} isLoading={query.isLoading} />
      )}
    </div>
  );
}

function EmptyTeamsState() {
  return (
    <div className="flex flex-col items-center justify-center rounded-lg border border-dashed border-slate-300 bg-white py-16">
      <div className="flex h-16 w-16 items-center justify-center rounded-full bg-slate-100">
        <Users className="h-8 w-8 text-slate-400" />
      </div>
      <h3 className="mt-4 text-lg font-semibold text-slate-900">Aucune &eacute;quipe trouv&eacute;e</h3>
      <p className="mt-2 text-center text-sm text-slate-500 max-w-md">
        Aucun gestionnaire avec des membres d&apos;&eacute;quipe trouv&eacute; dans votre organisation. Les &eacute;quipes sont cr&eacute;&eacute;es
        lorsque des employ&eacute;s sont assign&eacute;s &agrave; des gestionnaires dans les param&egrave;tres de supervision.
      </p>
    </div>
  );
}
