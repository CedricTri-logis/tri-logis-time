'use client';

/**
 * Report History Table Component
 * Spec: 013-reports-export
 *
 * Displays report history with re-download and expiration info
 */

import { useState } from 'react';
import { format, formatDistanceToNow, isPast, parseISO } from 'date-fns';
import {
  Download,
  FileText,
  Clock,
  AlertCircle,
  CheckCircle,
  XCircle,
  Loader2,
  RefreshCw,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import {
  Tooltip,
  TooltipContent,
  TooltipProvider,
  TooltipTrigger,
} from '@/components/ui/tooltip';
import { supabaseClient } from '@/lib/supabase/client';
import type { ReportHistoryItem } from '@/types/reports';

interface ReportHistoryTableProps {
  items: ReportHistoryItem[];
  isLoading?: boolean;
  onRefresh?: () => void;
}

/**
 * Format report type for display
 */
function formatReportType(type: string): string {
  switch (type) {
    case 'timesheet':
      return 'Feuille de temps';
    case 'activity_summary':
      return 'Résumé d\'activité';
    case 'attendance':
      return 'Présence';
    case 'shift_history':
      return 'Historique des quarts';
    default:
      return type;
  }
}

/**
 * Get status badge
 */
function getStatusBadge(status: string) {
  switch (status) {
    case 'completed':
      return (
        <Badge className="bg-green-100 text-green-800">
          <CheckCircle className="mr-1 h-3 w-3" />
          Complété
        </Badge>
      );
    case 'processing':
      return (
        <Badge className="bg-blue-100 text-blue-800">
          <Loader2 className="mr-1 h-3 w-3 animate-spin" />
          En cours
        </Badge>
      );
    case 'pending':
      return (
        <Badge className="bg-yellow-100 text-yellow-800">
          <Clock className="mr-1 h-3 w-3" />
          En attente
        </Badge>
      );
    case 'failed':
      return (
        <Badge className="bg-red-100 text-red-800">
          <XCircle className="mr-1 h-3 w-3" />
          Échoué
        </Badge>
      );
    default:
      return <Badge variant="secondary">{status}</Badge>;
  }
}

/**
 * Format file size
 */
function formatFileSize(bytes?: number): string {
  if (!bytes) return '-';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function ReportHistoryTable({
  items,
  isLoading = false,
  onRefresh,
}: ReportHistoryTableProps) {
  const [downloadingId, setDownloadingId] = useState<string | null>(null);

  /**
   * Handle download click
   */
  const handleDownload = async (item: ReportHistoryItem) => {
    if (!item.file_path || !item.download_available) return;

    setDownloadingId(item.job_id);

    try {
      // Get signed URL from storage
      const { data, error } = await supabaseClient.storage
        .from('reports')
        .createSignedUrl(item.file_path, 3600); // 1 hour expiry

      if (error) {
        console.error('Failed to get download URL:', error);
        return;
      }

      // Trigger download
      const link = document.createElement('a');
      link.href = data.signedUrl;
      link.download = item.file_path.split('/').pop() || 'report';
      link.target = '_blank';
      document.body.appendChild(link);
      link.click();
      document.body.removeChild(link);
    } catch (err) {
      console.error('Download failed:', err);
    } finally {
      setDownloadingId(null);
    }
  };

  /**
   * Check if report is expired
   */
  const isExpired = (expiresAt: string): boolean => {
    return isPast(parseISO(expiresAt));
  };

  /**
   * Format date range from config
   */
  const formatDateRange = (config: ReportHistoryItem['config']): string => {
    const { date_range } = config;
    if (date_range.preset) {
      return date_range.preset.replace('_', ' ');
    }
    if (date_range.start && date_range.end) {
      return `${date_range.start} - ${date_range.end}`;
    }
    return '-';
  };

  if (isLoading) {
    return (
      <div className="flex items-center justify-center py-12">
        <RefreshCw className="h-8 w-8 text-slate-400 animate-spin" />
      </div>
    );
  }

  if (items.length === 0) {
    return (
      <div className="flex flex-col items-center justify-center py-12 text-center">
        <FileText className="h-12 w-12 text-slate-300 mb-4" />
        <h3 className="text-lg font-medium text-slate-900 mb-1">Aucun historique de rapport</h3>
        <p className="text-sm text-slate-500 max-w-sm">
          Les rapports que vous générez apparaîtront ici. Les rapports générés sont disponibles pendant 30 jours.
        </p>
      </div>
    );
  }

  return (
    <TooltipProvider>
      <div className="rounded-lg border">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Rapport</TableHead>
              <TableHead>Plage de dates</TableHead>
              <TableHead>Statut</TableHead>
              <TableHead>Enregistrements</TableHead>
              <TableHead>Taille</TableHead>
              <TableHead>Créé</TableHead>
              <TableHead>Expire</TableHead>
              <TableHead className="text-right">Actions</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {items.map((item) => {
              const expired = isExpired(item.expires_at);

              return (
                <TableRow key={item.job_id} className={expired ? 'opacity-60' : ''}>
                  <TableCell>
                    <div className="flex items-center gap-2">
                      <FileText className="h-4 w-4 text-slate-400" />
                      <span className="font-medium">
                        {formatReportType(item.report_type)}
                      </span>
                    </div>
                  </TableCell>
                  <TableCell className="text-sm text-slate-600">
                    {formatDateRange(item.config)}
                  </TableCell>
                  <TableCell>{getStatusBadge(item.status)}</TableCell>
                  <TableCell className="text-sm text-slate-600">
                    {item.record_count?.toLocaleString() || '-'}
                  </TableCell>
                  <TableCell className="text-sm text-slate-600">
                    {formatFileSize(item.file_size_bytes)}
                  </TableCell>
                  <TableCell className="text-sm text-slate-600">
                    <Tooltip>
                      <TooltipTrigger>
                        {formatDistanceToNow(parseISO(item.created_at), { addSuffix: true })}
                      </TooltipTrigger>
                      <TooltipContent>
                        {format(parseISO(item.created_at), 'PPpp')}
                      </TooltipContent>
                    </Tooltip>
                  </TableCell>
                  <TableCell className="text-sm">
                    {expired ? (
                      <span className="text-red-500 flex items-center gap-1">
                        <AlertCircle className="h-3 w-3" />
                        Expiré
                      </span>
                    ) : (
                      <Tooltip>
                        <TooltipTrigger className="text-slate-600">
                          {formatDistanceToNow(parseISO(item.expires_at), { addSuffix: true })}
                        </TooltipTrigger>
                        <TooltipContent>
                          {format(parseISO(item.expires_at), 'PPpp')}
                        </TooltipContent>
                      </Tooltip>
                    )}
                  </TableCell>
                  <TableCell className="text-right">
                    {item.download_available && !expired ? (
                      <Button
                        variant="ghost"
                        size="sm"
                        onClick={() => handleDownload(item)}
                        disabled={downloadingId === item.job_id}
                      >
                        {downloadingId === item.job_id ? (
                          <Loader2 className="h-4 w-4 animate-spin" />
                        ) : (
                          <Download className="h-4 w-4" />
                        )}
                      </Button>
                    ) : (
                      <Button variant="ghost" size="sm" disabled>
                        <Download className="h-4 w-4 text-slate-300" />
                      </Button>
                    )}
                  </TableCell>
                </TableRow>
              );
            })}
          </TableBody>
        </Table>
      </div>
    </TooltipProvider>
  );
}
