'use client';

/**
 * Report Progress Component
 * Spec: 013-reports-export
 *
 * Displays progress for async report generation with polling updates
 */

import { useEffect, useState } from 'react';
import { Loader2, CheckCircle, XCircle, Clock, FileText } from 'lucide-react';
import { Progress } from '@/components/ui/progress';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import type { ReportGenerationState } from '@/types/reports';

interface ReportProgressProps {
  state: ReportGenerationState;
  progress: number;
  error?: string | null;
  recordCount?: number | null;
  isAsync?: boolean;
  onCancel?: () => void;
  onRetry?: () => void;
}

const STATE_CONFIG: Record<
  ReportGenerationState,
  {
    icon: React.ComponentType<{ className?: string }>;
    title: string;
    description: string;
    color: string;
  }
> = {
  idle: {
    icon: FileText,
    title: 'Prêt',
    description: 'Configurez vos options de rapport et cliquez sur générer',
    color: 'text-slate-400',
  },
  counting: {
    icon: Clock,
    title: 'Comptage des enregistrements',
    description: 'Vérification du nombre d\'enregistrements à inclure...',
    color: 'text-blue-500',
  },
  generating: {
    icon: Loader2,
    title: 'Génération du rapport',
    description: 'Traitement des données et création de votre rapport...',
    color: 'text-blue-500',
  },
  polling: {
    icon: Loader2,
    title: 'Traitement en cours...',
    description: 'Rapport volumineux en cours de traitement. Cela peut prendre quelques minutes.',
    color: 'text-amber-500',
  },
  completed: {
    icon: CheckCircle,
    title: 'Rapport prêt',
    description: 'Votre rapport a été généré avec succès',
    color: 'text-green-500',
  },
  failed: {
    icon: XCircle,
    title: 'Échec de la génération',
    description: 'Une erreur est survenue lors de la génération de votre rapport',
    color: 'text-red-500',
  },
};

export function ReportProgress({
  state,
  progress,
  error,
  recordCount,
  isAsync,
  onCancel,
  onRetry,
}: ReportProgressProps) {
  const [animatedProgress, setAnimatedProgress] = useState(0);

  // Animate progress bar
  useEffect(() => {
    const timer = setTimeout(() => {
      setAnimatedProgress(progress);
    }, 100);
    return () => clearTimeout(timer);
  }, [progress]);

  const config = STATE_CONFIG[state];
  const Icon = config.icon;
  const isProcessing = state === 'generating' || state === 'polling' || state === 'counting';

  if (state === 'idle') {
    return null;
  }

  return (
    <Card className="border-2 border-dashed">
      <CardHeader className="pb-3">
        <div className="flex items-center gap-3">
          <div className={`${config.color} ${isProcessing ? 'animate-spin' : ''}`}>
            <Icon className="h-6 w-6" />
          </div>
          <div>
            <CardTitle className="text-lg">{config.title}</CardTitle>
            <CardDescription>
              {error || config.description}
            </CardDescription>
          </div>
        </div>
      </CardHeader>

      <CardContent className="space-y-4">
        {/* Progress bar for processing states */}
        {isProcessing && (
          <div className="space-y-2">
            <Progress value={animatedProgress} className="h-2" />
            <div className="flex justify-between text-xs text-slate-500">
              <span>{Math.round(animatedProgress)}% complété</span>
              {recordCount && <span>{recordCount.toLocaleString()} enregistrements</span>}
            </div>
          </div>
        )}

        {/* Async indicator */}
        {isAsync && state === 'polling' && (
          <div className="rounded-lg bg-amber-50 p-3 text-sm text-amber-800">
            <strong>Rapport volumineux :</strong> Ce rapport est en cours de traitement en arrière-plan.
            Vous pouvez fermer cette page et revenir plus tard - le rapport sera disponible dans votre
            historique des rapports.
          </div>
        )}

        {/* Estimated time for async */}
        {isAsync && isProcessing && recordCount && (
          <div className="text-sm text-slate-500">
            Temps estimé : ~{Math.max(1, Math.ceil(recordCount / 500))} minutes
          </div>
        )}

        {/* Error message */}
        {state === 'failed' && error && (
          <div className="rounded-lg bg-red-50 p-3 text-sm text-red-800">
            <strong>Erreur :</strong> {error}
          </div>
        )}

        {/* Action buttons */}
        <div className="flex gap-2">
          {isProcessing && onCancel && (
            <Button variant="outline" onClick={onCancel}>
              Annuler
            </Button>
          )}
          {state === 'failed' && onRetry && (
            <Button onClick={onRetry}>
              Réessayer
            </Button>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
