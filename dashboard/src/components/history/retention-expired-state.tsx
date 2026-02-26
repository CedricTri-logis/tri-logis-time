'use client';

import { Calendar, Clock } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

interface RetentionExpiredStateProps {
  retentionDays?: number;
}

/**
 * State component for shifts where GPS data has exceeded retention period.
 * Displayed when attempting to view GPS data older than 90 days.
 */
export function RetentionExpiredState({ retentionDays = 90 }: RetentionExpiredStateProps) {
  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base font-medium">Tracé GPS</CardTitle>
      </CardHeader>
      <CardContent>
        <div className="py-12 text-center">
          <div className="relative inline-block mb-4">
            <Calendar className="h-12 w-12 text-slate-300" />
            <Clock className="h-6 w-6 text-amber-500 absolute -bottom-1 -right-1 bg-white rounded-full" />
          </div>
          <h3 className="text-lg font-medium text-slate-700">Période de rétention expirée</h3>
          <p className="text-sm text-slate-500 mt-1 max-w-sm mx-auto">
            Les données GPS de plus de {retentionDays} jours sont automatiquement supprimées
            selon notre politique de rétention des données.
          </p>
          <div className="mt-6 p-4 bg-amber-50 rounded-lg max-w-md mx-auto">
            <p className="text-xs text-amber-800">
              <strong>Note :</strong> Les informations sommaires du quart sont toujours disponibles,
              mais les données détaillées du tracé GPS ont été supprimées pour respecter les
              exigences de rétention des données.
            </p>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
