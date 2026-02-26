'use client';

import { useState, useCallback, useMemo } from 'react';
import dynamic from 'next/dynamic';
import { RefreshCw, Wifi, WifiOff, AlertCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';
import { Skeleton } from '@/components/ui/skeleton';
import { TeamList } from '@/components/monitoring/team-list';
import { TeamFilters } from '@/components/monitoring/team-filters';
import { StalenessLegend } from '@/components/monitoring/staleness-indicator';
import { ConnectionStatusBanner, OfflineBanner } from '@/components/monitoring/connection-status';
import { useSupervisedTeam } from '@/lib/hooks/use-supervised-team';
import type { ConnectionStatus, TeamSortOption } from '@/types/monitoring';

// Dynamically import the map component to avoid SSR issues
const TeamMap = dynamic(
  () => import('@/components/monitoring/google-team-map').then((mod) => mod.GoogleTeamMap),
  {
    ssr: false,
    loading: () => <MapSkeleton />,
  }
);

export default function MonitoringPage() {
  // Filter state
  const [search, setSearch] = useState('');
  const [shiftStatus, setShiftStatus] = useState<'all' | 'on-shift' | 'off-shift' | 'never-installed'>('on-shift');
  const [sortBy, setSortBy] = useState<TeamSortOption>('last-connection');

  // Fetch team data with real-time updates
  const {
    team,
    isLoading,
    error,
    refetch,
    lastUpdated,
    connectionStatus,
    retryConnection,
  } = useSupervisedTeam({
    search: search || undefined,
    shiftStatus,
  });

  // Client-side sort
  const sortedTeam = useMemo(() => {
    if (sortBy === 'name') {
      return [...team].sort((a, b) => a.displayName.localeCompare(b.displayName));
    }
    // 'last-connection': most recent first, nulls last
    return [...team].sort((a, b) => {
      if (!a.lastSignInAt && !b.lastSignInAt) return 0;
      if (!a.lastSignInAt) return 1;
      if (!b.lastSignInAt) return -1;
      return b.lastSignInAt.getTime() - a.lastSignInAt.getTime();
    });
  }, [team, sortBy]);

  // Refresh handler
  const [isRefreshing, setIsRefreshing] = useState(false);
  const handleRefresh = useCallback(async () => {
    setIsRefreshing(true);
    try {
      refetch();
    } finally {
      setTimeout(() => setIsRefreshing(false), 500);
    }
  }, [refetch]);

  // Clear filters handler
  const handleClearFilters = useCallback(() => {
    setSearch('');
    setShiftStatus('all');
  }, []);

  // Stats for header
  const onShiftCount = team.filter((e) => e.shiftStatus === 'on-shift').length;
  const offShiftCount = team.filter((e) => e.shiftStatus === 'off-shift').length;
  const neverInstalledCount = team.filter((e) => e.shiftStatus === 'never-installed').length;
  const totalCount = team.length;

  return (
    <div className="space-y-6">
      {/* Connection status banners */}
      <ConnectionStatusBanner status={connectionStatus} lastUpdated={lastUpdated} onRetry={retryConnection} />
      <OfflineBanner />

      {/* Page header */}
      <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h2 className="text-2xl font-bold text-slate-900">Surveillance de l&apos;équipe</h2>
          <p className="text-sm text-slate-500">
            Vue en temps réel de vos employés supervisés et de leur statut de quart
          </p>
        </div>

        <div className="flex items-center gap-3">
          <ConnectionStatusIndicator status={connectionStatus} />
          <Button
            variant="outline"
            size="sm"
            onClick={handleRefresh}
            disabled={isRefreshing}
            className="gap-2"
          >
            <RefreshCw className={`h-4 w-4 ${isRefreshing ? 'animate-spin' : ''}`} />
            {isRefreshing ? 'Actualisation...' : 'Actualiser'}
          </Button>
        </div>
      </div>

      {/* Error banner */}
      {error && (
        <Card className="border-red-200 bg-red-50">
          <CardContent className="flex items-center gap-3 py-3">
            <AlertCircle className="h-5 w-5 text-red-600" />
            <div className="text-sm text-red-700">
              <strong>Erreur de chargement des données :</strong> {error.message}
            </div>
            <Button
              variant="outline"
              size="sm"
              onClick={handleRefresh}
              className="ml-auto"
            >
              Réessayer
            </Button>
          </CardContent>
        </Card>
      )}

      {/* Summary stats */}
      <div className="grid grid-cols-2 sm:grid-cols-5 gap-4">
        <StatCard
          label="Total équipe"
          value={totalCount}
          isLoading={isLoading}
        />
        <StatCard
          label="En quart"
          value={onShiftCount}
          isLoading={isLoading}
          highlight="green"
        />
        <StatCard
          label="Hors quart"
          value={offShiftCount}
          isLoading={isLoading}
        />
        <StatCard
          label="Jamais installé"
          value={neverInstalledCount}
          isLoading={isLoading}
          highlight="orange"
        />
        <LastUpdatedCard
          lastUpdated={lastUpdated}
          isLoading={isLoading}
        />
      </div>

      {/* Filters */}
      <TeamFilters
        search={search}
        shiftStatus={shiftStatus}
        sortBy={sortBy}
        onSearchChange={setSearch}
        onShiftStatusChange={setShiftStatus}
        onSortChange={setSortBy}
        onClearFilters={handleClearFilters}
      />

      {/* Main content: list and map */}
      <div className="grid gap-6 lg:grid-cols-2">
        {/* Team list */}
        <TeamList
          team={sortedTeam}
          isLoading={isLoading}
          search={search}
          shiftStatus={shiftStatus}
          onClearFilters={handleClearFilters}
        />

        {/* Map view */}
        <div className="space-y-2">
          <TeamMap
            team={sortedTeam}
            isLoading={isLoading}
          />
          <StalenessLegend />
        </div>
      </div>
    </div>
  );
}

interface StatCardProps {
  label: string;
  value: number;
  isLoading?: boolean;
  highlight?: 'green' | 'orange';
}

function StatCard({ label, value, isLoading, highlight }: StatCardProps) {
  if (isLoading) {
    return (
      <Card>
        <CardContent className="py-4">
          <Skeleton className="h-3 w-16 mb-2" />
          <Skeleton className="h-8 w-12" />
        </CardContent>
      </Card>
    );
  }

  const cardClass = highlight === 'green'
    ? 'border-green-200 bg-green-50'
    : highlight === 'orange'
      ? 'border-orange-200 bg-orange-50'
      : '';

  const textClass = highlight === 'green'
    ? 'text-green-700'
    : highlight === 'orange'
      ? 'text-orange-700'
      : 'text-slate-900';

  return (
    <Card className={cardClass}>
      <CardContent className="py-4">
        <p className="text-xs text-slate-500 uppercase tracking-wide">{label}</p>
        <p className={`text-2xl font-bold ${textClass}`}>
          {value}
        </p>
      </CardContent>
    </Card>
  );
}

interface LastUpdatedCardProps {
  lastUpdated: Date | null;
  isLoading?: boolean;
}

function LastUpdatedCard({ lastUpdated, isLoading }: LastUpdatedCardProps) {
  if (isLoading) {
    return (
      <Card>
        <CardContent className="py-4">
          <Skeleton className="h-3 w-16 mb-2" />
          <Skeleton className="h-8 w-20" />
        </CardContent>
      </Card>
    );
  }

  const timeAgo = lastUpdated ? formatTimeAgo(lastUpdated) : 'Jamais';

  return (
    <Card>
      <CardContent className="py-4">
        <p className="text-xs text-slate-500 uppercase tracking-wide">Dernière mise à jour</p>
        <p className="text-lg font-medium text-slate-700">{timeAgo}</p>
      </CardContent>
    </Card>
  );
}

interface ConnectionStatusIndicatorProps {
  status: ConnectionStatus;
}

function ConnectionStatusIndicator({ status }: ConnectionStatusIndicatorProps) {
  const config: Record<ConnectionStatus, { icon: typeof Wifi; color: string; text: string }> = {
    connected: { icon: Wifi, color: 'text-green-600', text: 'En direct' },
    connecting: { icon: Wifi, color: 'text-yellow-600', text: 'Connexion...' },
    disconnected: { icon: WifiOff, color: 'text-slate-400', text: 'Hors ligne' },
    error: { icon: WifiOff, color: 'text-red-600', text: 'Erreur' },
  };

  const { icon: Icon, color, text } = config[status];

  return (
    <div className={`flex items-center gap-1.5 text-sm ${color}`}>
      <Icon className="h-4 w-4" />
      <span>{text}</span>
    </div>
  );
}

function MapSkeleton() {
  return (
    <Card>
      <CardContent className="p-0">
        <Skeleton className="h-[400px] w-full rounded-lg" />
      </CardContent>
    </Card>
  );
}

function formatTimeAgo(date: Date): string {
  const seconds = Math.floor((Date.now() - date.getTime()) / 1000);

  if (seconds < 5) return 'À l\'instant';
  if (seconds < 60) return `il y a ${seconds}s`;

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `il y a ${minutes}min`;

  const hours = Math.floor(minutes / 60);
  return `il y a ${hours}h`;
}
