'use client';

/**
 * Report Schedules Management Page
 * Spec: 013-reports-export - User Story 5
 *
 * Allows administrators to create, view, edit, and manage
 * recurring report schedules.
 */

import { useState } from 'react';
import { format } from 'date-fns';
import {
  Calendar,
  Plus,
  Play,
  Pause,
  Trash2,
  Clock,
  RefreshCw,
  AlertCircle,
  CheckCircle,
  XCircle,
} from 'lucide-react';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Alert, AlertDescription, AlertTitle } from '@/components/ui/alert';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from '@/components/ui/dialog';
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from '@/components/ui/alert-dialog';
import { ScheduleForm } from '@/components/reports/schedule-form';
import { useReportSchedules, CreateScheduleParams } from '@/lib/hooks/use-report-schedules';
import type { ReportSchedule, FREQUENCY_INFO, REPORT_TYPE_INFO } from '@/types/reports';

/**
 * Get status badge variant
 */
function getStatusBadge(status: string) {
  switch (status) {
    case 'active':
      return <Badge className="bg-green-100 text-green-800">Actif</Badge>;
    case 'paused':
      return <Badge className="bg-yellow-100 text-yellow-800">En pause</Badge>;
    default:
      return <Badge variant="secondary">{status}</Badge>;
  }
}

/**
 * Get last run status icon
 */
function getLastRunIcon(status?: string) {
  switch (status) {
    case 'success':
      return <CheckCircle className="h-4 w-4 text-green-500" />;
    case 'failed':
      return <XCircle className="h-4 w-4 text-red-500" />;
    default:
      return null;
  }
}

/**
 * Format frequency display
 */
function formatFrequency(schedule: ReportSchedule): string {
  const { frequency, schedule_config } = schedule;

  if (frequency === 'monthly') {
    const day = schedule_config.day_of_month || 1;
    return `Mensuel le ${day}`;
  }

  if (frequency === 'bi_weekly') {
    const dayName = getDayName(schedule_config.day_of_week || 0);
    return `Aux deux ${dayName}s`;
  }

  const dayName = getDayName(schedule_config.day_of_week || 0);
  return `Chaque ${dayName}`;
}

function getDayName(day: number): string {
  const days = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'];
  return days[day] || 'jour';
}

/**
 * Format report type display
 */
function formatReportType(type: string): string {
  switch (type) {
    case 'timesheet':
      return 'Feuille de temps';
    case 'activity_summary':
      return 'Résumé d\'activité';
    case 'attendance':
      return 'Présence';
    default:
      return type;
  }
}

export default function ReportSchedulesPage() {
  const [isCreateOpen, setIsCreateOpen] = useState(false);
  const [isCreating, setIsCreating] = useState(false);

  const {
    schedules,
    isLoading,
    error,
    totalCount,
    fetch,
    create,
    pause,
    resume,
    remove,
  } = useReportSchedules();

  /**
   * Handle create schedule
   */
  const handleCreate = async (data: CreateScheduleParams) => {
    setIsCreating(true);
    try {
      const result = await create(data);
      if (result) {
        setIsCreateOpen(false);
      }
    } finally {
      setIsCreating(false);
    }
  };

  /**
   * Handle pause/resume
   */
  const handleToggleStatus = async (schedule: ReportSchedule) => {
    if (schedule.status === 'active') {
      await pause(schedule.id);
    } else {
      await resume(schedule.id);
    }
  };

  /**
   * Handle delete
   */
  const handleDelete = async (scheduleId: string) => {
    await remove(scheduleId);
  };

  return (
    <div className="space-y-6">
      {/* Page header */}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 flex items-center gap-2">
            <Calendar className="h-6 w-6" />
            Rapports programmés
          </h1>
          <p className="text-sm text-slate-500 mt-1">
            Automatisez la génération de rapports récurrents
          </p>
        </div>

        <Dialog open={isCreateOpen} onOpenChange={setIsCreateOpen}>
          <DialogTrigger asChild>
            <Button>
              <Plus className="mr-2 h-4 w-4" />
              Nouvelle programmation
            </Button>
          </DialogTrigger>
          <DialogContent className="max-w-md">
            <DialogHeader>
              <DialogTitle>Créer une programmation de rapport</DialogTitle>
              <DialogDescription>
                Configurez la génération automatique de rapports sur une base récurrente.
              </DialogDescription>
            </DialogHeader>
            <ScheduleForm onSubmit={handleCreate} isLoading={isCreating} mode="create" />
          </DialogContent>
        </Dialog>
      </div>

      {/* Error state */}
      {error && (
        <Alert variant="destructive">
          <AlertCircle className="h-4 w-4" />
          <AlertTitle>Erreur</AlertTitle>
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      )}

      {/* Loading state */}
      {isLoading && (
        <Card>
          <CardContent className="flex items-center justify-center py-12">
            <RefreshCw className="h-8 w-8 text-slate-400 animate-spin" />
          </CardContent>
        </Card>
      )}

      {/* Empty state */}
      {!isLoading && schedules.length === 0 && (
        <Card className="border-dashed">
          <CardContent className="flex flex-col items-center justify-center py-12 text-center">
            <Calendar className="h-12 w-12 text-slate-300 mb-4" />
            <h3 className="text-lg font-medium text-slate-900 mb-1">Aucune programmation</h3>
            <p className="text-sm text-slate-500 max-w-sm mb-4">
              Créez une programmation pour générer automatiquement des rapports de manière récurrente.
            </p>
            <Button onClick={() => setIsCreateOpen(true)}>
              <Plus className="mr-2 h-4 w-4" />
              Créer votre première programmation
            </Button>
          </CardContent>
        </Card>
      )}

      {/* Schedule list */}
      {!isLoading && schedules.length > 0 && (
        <div className="space-y-4">
          {schedules.map((schedule) => (
            <Card key={schedule.id}>
              <CardContent className="p-6">
                <div className="flex items-start justify-between">
                  <div className="space-y-2">
                    <div className="flex items-center gap-3">
                      <h3 className="text-lg font-medium text-slate-900">
                        {schedule.name}
                      </h3>
                      {getStatusBadge(schedule.status)}
                    </div>

                    <div className="flex flex-wrap gap-4 text-sm text-slate-600">
                      <div className="flex items-center gap-1">
                        <span className="font-medium">Type :</span>
                        {formatReportType(schedule.report_type)}
                      </div>
                      <div className="flex items-center gap-1">
                        <Clock className="h-4 w-4" />
                        {formatFrequency(schedule)} à {schedule.schedule_config.time}
                      </div>
                    </div>

                    <div className="flex flex-wrap gap-4 text-sm text-slate-500">
                      <div>
                        <span className="font-medium">Prochaine exécution :</span>{' '}
                        {schedule.next_run_at
                          ? format(new Date(schedule.next_run_at), 'MMM d, yyyy h:mm a')
                          : 'Non programmé'}
                      </div>
                      {schedule.last_run_at && (
                        <div className="flex items-center gap-1">
                          <span className="font-medium">Dernière exécution :</span>
                          {format(new Date(schedule.last_run_at), 'MMM d, yyyy h:mm a')}
                          {getLastRunIcon(schedule.last_run_status)}
                        </div>
                      )}
                      <div>
                        <span className="font-medium">Exécutions :</span> {schedule.run_count}
                        {schedule.failure_count > 0 && (
                          <span className="text-red-500"> ({schedule.failure_count} échouée{schedule.failure_count > 1 ? 's' : ''})</span>
                        )}
                      </div>
                    </div>
                  </div>

                  <div className="flex items-center gap-2">
                    <Button
                      variant="outline"
                      size="sm"
                      onClick={() => handleToggleStatus(schedule)}
                    >
                      {schedule.status === 'active' ? (
                        <>
                          <Pause className="mr-1 h-4 w-4" />
                          Mettre en pause
                        </>
                      ) : (
                        <>
                          <Play className="mr-1 h-4 w-4" />
                          Reprendre
                        </>
                      )}
                    </Button>

                    <AlertDialog>
                      <AlertDialogTrigger asChild>
                        <Button variant="outline" size="sm" className="text-red-600 hover:text-red-700">
                          <Trash2 className="h-4 w-4" />
                        </Button>
                      </AlertDialogTrigger>
                      <AlertDialogContent>
                        <AlertDialogHeader>
                          <AlertDialogTitle>Supprimer la programmation</AlertDialogTitle>
                          <AlertDialogDescription>
                            Êtes-vous sûr de vouloir supprimer &quot;{schedule.name}&quot; ? Cette action
                            est irréversible.
                          </AlertDialogDescription>
                        </AlertDialogHeader>
                        <AlertDialogFooter>
                          <AlertDialogCancel>Annuler</AlertDialogCancel>
                          <AlertDialogAction
                            onClick={() => handleDelete(schedule.id)}
                            className="bg-red-600 hover:bg-red-700"
                          >
                            Supprimer
                          </AlertDialogAction>
                        </AlertDialogFooter>
                      </AlertDialogContent>
                    </AlertDialog>
                  </div>
                </div>
              </CardContent>
            </Card>
          ))}
        </div>
      )}

      {/* Help text */}
      <Alert>
        <Calendar className="h-4 w-4" />
        <AlertTitle>À propos des rapports programmés</AlertTitle>
        <AlertDescription>
          <ul className="list-disc list-inside mt-2 space-y-1 text-sm">
            <li>Les rapports programmés s&apos;exécutent automatiquement à l&apos;heure spécifiée</li>
            <li>Les rapports couvrent la période précédente (semaine/mois dernier) selon la fréquence</li>
            <li>Les rapports générés apparaissent dans votre historique des rapports</li>
            <li>Vous recevrez une notification lorsque les rapports programmés seront prêts</li>
          </ul>
        </AlertDescription>
      </Alert>
    </div>
  );
}
