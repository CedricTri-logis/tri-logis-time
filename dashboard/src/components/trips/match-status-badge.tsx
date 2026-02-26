import { Badge } from '@/components/ui/badge';
import { CheckCircle, Clock, Info, AlertTriangle } from 'lucide-react';

interface MatchStatusBadgeProps {
  match_status: 'pending' | 'processing' | 'matched' | 'failed' | 'anomalous';
}

const STATUS_CONFIG = {
  matched: {
    label: 'Vérifié',
    variant: 'default' as const,
    className: 'bg-green-100 text-green-700 hover:bg-green-100',
    Icon: CheckCircle,
  },
  pending: {
    label: 'En attente',
    variant: 'secondary' as const,
    className: 'bg-yellow-100 text-yellow-700 hover:bg-yellow-100',
    Icon: Clock,
  },
  processing: {
    label: 'En traitement',
    variant: 'secondary' as const,
    className: 'bg-yellow-100 text-yellow-700 hover:bg-yellow-100',
    Icon: Clock,
  },
  failed: {
    label: 'Estimé',
    variant: 'secondary' as const,
    className: 'bg-gray-100 text-gray-600 hover:bg-gray-100',
    Icon: Info,
  },
  anomalous: {
    label: 'Anomalie',
    variant: 'destructive' as const,
    className: 'bg-red-100 text-red-700 hover:bg-red-100',
    Icon: AlertTriangle,
  },
};

export function MatchStatusBadge({ match_status }: MatchStatusBadgeProps) {
  const config = STATUS_CONFIG[match_status] ?? STATUS_CONFIG.failed;
  const { label, className, Icon } = config;

  return (
    <Badge variant="secondary" className={className}>
      <Icon className="h-3 w-3 mr-1" />
      {label}
    </Badge>
  );
}
