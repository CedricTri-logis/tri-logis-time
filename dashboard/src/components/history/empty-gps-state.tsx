'use client';

import { MapPinOff } from 'lucide-react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';

interface EmptyGpsStateProps {
  title?: string;
  description?: string;
}

/**
 * Empty state component for shifts with no GPS data.
 * Displayed when a shift exists but has zero GPS points.
 */
export function EmptyGpsState({
  title = 'No GPS Data',
  description = 'This shift does not have any GPS tracking data recorded.',
}: EmptyGpsStateProps) {
  return (
    <Card>
      <CardHeader className="pb-3">
        <CardTitle className="text-base font-medium">GPS Trail</CardTitle>
      </CardHeader>
      <CardContent>
        <div className="py-12 text-center">
          <MapPinOff className="h-12 w-12 mx-auto mb-4 text-slate-300" />
          <h3 className="text-lg font-medium text-slate-700">{title}</h3>
          <p className="text-sm text-slate-500 mt-1 max-w-sm mx-auto">{description}</p>
          <div className="mt-6 p-4 bg-slate-50 rounded-lg max-w-md mx-auto">
            <p className="text-xs text-slate-500">
              <strong>Possible reasons:</strong>
            </p>
            <ul className="text-xs text-slate-500 mt-2 text-left list-disc list-inside space-y-1">
              <li>GPS was not enabled during the shift</li>
              <li>The employee denied location permissions</li>
              <li>The shift was very short (under 5 minutes)</li>
              <li>Network connectivity issues prevented sync</li>
            </ul>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}
