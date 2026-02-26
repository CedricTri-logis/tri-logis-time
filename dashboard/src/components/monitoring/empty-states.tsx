'use client';

import { Users, MapPin, Clock, Wifi } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Card, CardContent } from '@/components/ui/card';

interface EmptyStateBaseProps {
  icon: React.ElementType;
  title: string;
  description: string;
  action?: {
    label: string;
    onClick: () => void;
  };
}

function EmptyStateBase({ icon: Icon, title, description, action }: EmptyStateBaseProps) {
  return (
    <div className="flex flex-col items-center justify-center py-12 text-center">
      <div className="rounded-full bg-slate-100 p-4">
        <Icon className="h-8 w-8 text-slate-400" />
      </div>
      <h3 className="mt-4 text-lg font-semibold text-slate-900">{title}</h3>
      <p className="mt-2 max-w-md text-sm text-slate-500">{description}</p>
      {action && (
        <Button variant="outline" onClick={action.onClick} className="mt-4">
          {action.label}
        </Button>
      )}
    </div>
  );
}

/**
 * Empty state when user has no supervised employees
 */
export function NoTeamEmptyState() {
  return (
    <EmptyStateBase
      icon={Users}
      title="Aucun membre d'équipe assigné"
      description="Vous n'avez aucun employé assigné à superviser. Contactez un administrateur pour configurer votre équipe."
    />
  );
}

/**
 * Empty state when all team members are off-shift
 */
export function NoActiveShiftsEmptyState() {
  return (
    <EmptyStateBase
      icon={Clock}
      title="Tous les membres de l'équipe sont hors quart"
      description="Aucun de vos employés supervisés n'est actuellement pointé. Les quarts actifs apparaîtront ici lorsque les employés commenceront leur travail."
    />
  );
}

/**
 * Empty state for search/filter with no results
 */
interface NoResultsEmptyStateProps {
  search: string;
  shiftStatus: string;
  onClearFilters: () => void;
}

export function NoResultsEmptyState({
  search,
  shiftStatus,
  onClearFilters,
}: NoResultsEmptyStateProps) {
  const hasFilters = search !== '' || shiftStatus !== 'all';

  if (!hasFilters) {
    return <NoTeamEmptyState />;
  }

  const filterParts: string[] = [];
  if (search) filterParts.push(`"${search}"`);
  if (shiftStatus !== 'all') {
    const statusLabels: Record<string, string> = {
      'on-shift': 'en quart seulement',
      'off-shift': 'hors quart seulement',
      'never-installed': 'jamais installé seulement',
    };
    filterParts.push(statusLabels[shiftStatus] ?? shiftStatus);
  }

  return (
    <EmptyStateBase
      icon={Users}
      title="Aucun employé trouvé"
      description={`Aucun employé ne correspond à vos filtres : ${filterParts.join(', ')}`}
      action={{
        label: 'Effacer les filtres',
        onClick: onClearFilters,
      }}
    />
  );
}

/**
 * Empty state when GPS data is not yet available for an active shift
 */
export function LocationPendingState() {
  return (
    <Card className="border-dashed">
      <CardContent className="flex items-center gap-3 py-4">
        <div className="rounded-full bg-slate-100 p-2">
          <MapPin className="h-4 w-4 text-slate-400" />
        </div>
        <div>
          <p className="text-sm font-medium text-slate-700">Position en attente</p>
          <p className="text-xs text-slate-500">En attente de la première mise à jour GPS</p>
        </div>
      </CardContent>
    </Card>
  );
}

/**
 * Empty state for GPS trail with no points
 */
export function NoGpsTrailEmptyState() {
  return (
    <EmptyStateBase
      icon={MapPin}
      title="Aucun trajet GPS disponible"
      description="Aucune donnée de suivi GPS n'a encore été enregistrée pour ce quart. Le trajet apparaîtra lorsque l'employé se déplacera avec le GPS activé."
    />
  );
}

/**
 * Empty state when offline/disconnected
 */
interface OfflineEmptyStateProps {
  lastUpdated?: Date | null;
  onRetry?: () => void;
}

export function OfflineEmptyState({ lastUpdated, onRetry }: OfflineEmptyStateProps) {
  return (
    <EmptyStateBase
      icon={Wifi}
      title="Connexion perdue"
      description={
        lastUpdated
          ? `Impossible de se connecter aux mises à jour en temps réel. Dernière mise à jour ${formatTimeAgo(lastUpdated)}.`
          : 'Impossible de se connecter aux mises à jour en temps réel. Veuillez vérifier votre connexion internet.'
      }
      action={
        onRetry
          ? {
              label: 'Réessayer la connexion',
              onClick: onRetry,
            }
          : undefined
      }
    />
  );
}

/**
 * Compact inline empty state for cards/map
 */
interface InlineEmptyStateProps {
  message: string;
}

export function InlineEmptyState({ message }: InlineEmptyStateProps) {
  return (
    <div className="flex items-center justify-center py-8 text-sm text-slate-500">
      {message}
    </div>
  );
}

// Helper function
function formatTimeAgo(date: Date): string {
  const seconds = Math.floor((Date.now() - date.getTime()) / 1000);

  if (seconds < 5) return 'à l\'instant';
  if (seconds < 60) return `il y a ${seconds}s`;

  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `il y a ${minutes}min`;

  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `il y a ${hours}h`;

  return date.toLocaleString();
}
