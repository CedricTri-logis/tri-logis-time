'use client';

import { Button } from '@/components/ui/button';
import { Check, Unlock } from 'lucide-react';
import type { MileageApprovalDetailSummary, MileageApproval } from '@/types/mileage';

interface MileageApprovalSummaryProps {
  summary: MileageApprovalDetailSummary;
  approval: MileageApproval | null;
  onApprove: () => void;
  onReopen: () => void;
  isSaving: boolean;
}

export function MileageApprovalSummaryFooter({
  summary,
  approval,
  onApprove,
  onReopen,
  isSaving,
}: MileageApprovalSummaryProps) {
  const isApproved = approval?.status === 'approved';
  const canApprove = summary.needs_review_count === 0 && !isApproved;

  return (
    <div className="border-t bg-muted/30 p-4 space-y-2">
      <div className="flex justify-between text-sm">
        <div className="space-y-1">
          <div>
            Remboursable: <strong>{summary.reimbursable_km.toFixed(1)} km</strong>
            <span className="text-muted-foreground ml-1">
              (perso + conducteur)
            </span>
          </div>
          <div className="text-muted-foreground text-xs">
            Compagnie: {summary.company_km.toFixed(1)} km · Passager: {summary.passenger_km.toFixed(1)} km
          </div>
          {summary.is_forfait ? (
            <div className="text-muted-foreground text-xs">
              Forfait: {summary.forfait_amount?.toFixed(2)}$ / paye
            </div>
          ) : (
            <div className="text-muted-foreground text-xs">
              YTD: {summary.ytd_km.toFixed(0)} km · Taux: {summary.rate_per_km}$/km
              {summary.rate_after_threshold && (
                <> (après {summary.threshold_km} km: {summary.rate_after_threshold}$/km)</>
              )}
            </div>
          )}
        </div>
        <div className="text-right">
          <div className="text-2xl font-bold">
            {isApproved
              ? `${approval!.reimbursement_amount?.toFixed(2)} $`
              : `${summary.estimated_amount.toFixed(2)} $`
            }
          </div>
          {!isApproved && (
            <div className="text-xs text-muted-foreground">estimé</div>
          )}
          <div className="mt-2">
            {isApproved ? (
              <Button
                variant="outline"
                size="sm"
                onClick={onReopen}
                disabled={isSaving}
              >
                <Unlock className="h-3 w-3 mr-1" />
                Rouvrir
              </Button>
            ) : (
              <Button
                size="sm"
                onClick={onApprove}
                disabled={!canApprove || isSaving}
              >
                <Check className="h-3 w-3 mr-1" />
                Approuver kilométrage
              </Button>
            )}
          </div>
        </div>
      </div>
      {summary.needs_review_count > 0 && (
        <div className="text-xs text-yellow-700 bg-yellow-50 px-2 py-1 rounded">
          {summary.needs_review_count} trajet(s) nécessitent une attribution véhicule/rôle
        </div>
      )}
    </div>
  );
}
