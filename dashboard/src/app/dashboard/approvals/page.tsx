'use client';

import { ApprovalGrid } from '@/components/approvals/approval-grid';

export default function ApprovalsPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Approbation des heures</h1>
        <p className="text-muted-foreground">
          Vérifiez et approuvez les heures travaillées par employé et par jour.
        </p>
      </div>
      <ApprovalGrid />
    </div>
  );
}
