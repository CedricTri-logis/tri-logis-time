import { Badge } from '@/components/ui/badge';
import type { GpsEventType, DiagnosticSeverity } from '@/types/gps-diagnostics';

const EVENT_TYPE_CONFIG: Record<GpsEventType, { label: string; className: string }> = {
  gap: { label: 'GPS gap', className: 'bg-amber-100 text-amber-800 hover:bg-amber-100' },
  service_died: { label: 'Service died', className: 'bg-red-100 text-red-800 hover:bg-red-100' },
  slc: { label: 'SLC', className: 'bg-purple-100 text-purple-800 hover:bg-purple-100' },
  recovery: { label: 'Recovery', className: 'bg-green-100 text-green-800 hover:bg-green-100' },
  lifecycle: { label: 'Lifecycle', className: 'bg-slate-100 text-slate-600 hover:bg-slate-100' },
};

const SEVERITY_CONFIG: Record<DiagnosticSeverity, { label: string; className: string }> = {
  info: { label: 'info', className: 'bg-blue-100 text-blue-800 hover:bg-blue-100' },
  warn: { label: 'warn', className: 'bg-amber-100 text-amber-800 hover:bg-amber-100' },
  error: { label: 'error', className: 'bg-red-100 text-red-800 hover:bg-red-100' },
  critical: { label: 'critical', className: 'bg-red-200 text-red-900 font-bold hover:bg-red-200' },
};

export function EventTypeBadge({ type }: { type: GpsEventType }) {
  const config = EVENT_TYPE_CONFIG[type];
  return <Badge variant="outline" className={config.className}>{config.label}</Badge>;
}

export function SeverityBadge({ severity }: { severity: DiagnosticSeverity }) {
  const config = SEVERITY_CONFIG[severity];
  return <Badge variant="outline" className={config.className}>{config.label}</Badge>;
}
