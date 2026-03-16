'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
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
} from '@/components/ui/alert-dialog';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Pencil, Trash2, Loader2 } from 'lucide-react';
import { toast } from 'sonner';
import {
  getEmployeeRateHistory,
  updateRatePeriod,
  deleteRatePeriod,
} from '@/lib/api/remuneration';
import type { EmployeeHourlyRateWithCreator } from '@/types/remuneration';

interface RateHistoryProps {
  employeeId: string;
  onRateChanged?: () => void;
}

export function RateHistory({ employeeId, onRateChanged }: RateHistoryProps) {
  const [history, setHistory] = useState<EmployeeHourlyRateWithCreator[]>([]);
  const [loading, setLoading] = useState(true);

  // Edit dialog state
  const [editingRate, setEditingRate] = useState<EmployeeHourlyRateWithCreator | null>(null);
  const [formRate, setFormRate] = useState('');
  const [formFrom, setFormFrom] = useState('');
  const [formTo, setFormTo] = useState('');
  const [isSaving, setIsSaving] = useState(false);

  // Delete dialog state
  const [deletingRate, setDeletingRate] = useState<EmployeeHourlyRateWithCreator | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);

  const fetchHistory = useCallback(() => {
    setLoading(true);
    getEmployeeRateHistory(employeeId)
      .then(setHistory)
      .finally(() => setLoading(false));
  }, [employeeId]);

  useEffect(() => {
    fetchHistory();
  }, [fetchHistory]);

  // Open edit dialog
  const openEdit = (entry: EmployeeHourlyRateWithCreator) => {
    setEditingRate(entry);
    setFormRate(entry.rate.toString());
    setFormFrom(entry.effective_from);
    setFormTo(entry.effective_to ?? '');
  };

  // Handle edit save
  const handleEditSave = async () => {
    const parsedRate = parseFloat(formRate);
    if (isNaN(parsedRate) || parsedRate <= 0) {
      toast.error('Le taux doit être supérieur à 0.');
      return;
    }
    if (!formFrom) {
      toast.error('La date de début est requise.');
      return;
    }

    setIsSaving(true);
    try {
      const result = await updateRatePeriod(
        editingRate!.id,
        parsedRate,
        formFrom,
        formTo || null
      );

      if (!result.success) {
        toast.error(result.error?.message ?? 'Erreur inconnue.');
        return;
      }

      toast.success('Période de taux mise à jour.');
      setEditingRate(null);
      fetchHistory();
      onRateChanged?.();
    } catch (e: any) {
      toast.error(e.message || 'Erreur lors de la sauvegarde.');
    } finally {
      setIsSaving(false);
    }
  };

  // Handle delete
  const handleDelete = async () => {
    if (!deletingRate) return;

    setIsDeleting(true);
    try {
      const result = await deleteRatePeriod(deletingRate.id);

      if (!result.success) {
        toast.error(result.error?.message ?? 'Erreur inconnue.');
        return;
      }

      toast.success('Période de taux supprimée.');
      setDeletingRate(null);
      fetchHistory();
      onRateChanged?.();
    } catch (e: any) {
      toast.error(e.message || 'Erreur lors de la suppression.');
    } finally {
      setIsDeleting(false);
    }
  };

  if (loading) {
    return <div className="text-sm text-muted-foreground">Chargement...</div>;
  }

  if (history.length === 0) {
    return (
      <div className="text-sm text-muted-foreground">
        Aucun historique de taux pour cet employé.
      </div>
    );
  }

  return (
    <div>
      <h4 className="text-sm font-medium mb-2">Historique des taux</h4>
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Taux ($/h)</TableHead>
            <TableHead>Du</TableHead>
            <TableHead>Au</TableHead>
            <TableHead>Créé par</TableHead>
            <TableHead className="text-right">Actions</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {history.map((entry) => (
            <TableRow key={entry.id}>
              <TableCell className="font-mono">{entry.rate.toFixed(2)} $</TableCell>
              <TableCell>{entry.effective_from}</TableCell>
              <TableCell>
                {entry.effective_to ?? (
                  <span className="text-green-600 font-medium">En cours</span>
                )}
              </TableCell>
              <TableCell className="text-muted-foreground">
                {entry.creator_name ?? '—'}
              </TableCell>
              <TableCell className="text-right">
                <div className="flex items-center justify-end gap-1">
                  <Button
                    variant="ghost"
                    size="sm"
                    onClick={() => openEdit(entry)}
                  >
                    <Pencil className="h-3.5 w-3.5" />
                  </Button>
                  {/* Only show delete for non-active periods */}
                  {entry.effective_to !== null && (
                    <Button
                      variant="ghost"
                      size="sm"
                      onClick={() => setDeletingRate(entry)}
                      className="text-destructive hover:text-destructive"
                    >
                      <Trash2 className="h-3.5 w-3.5" />
                    </Button>
                  )}
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>

      {/* Edit Dialog */}
      <Dialog open={!!editingRate} onOpenChange={(open) => !open && setEditingRate(null)}>
        <DialogContent className="sm:max-w-[420px]">
          <DialogHeader>
            <DialogTitle>Modifier la période de taux</DialogTitle>
            <DialogDescription>
              Modifiez le taux horaire et les dates de cette période.
            </DialogDescription>
          </DialogHeader>
          <div className="space-y-4 py-2">
            <div className="space-y-2">
              <Label htmlFor="edit-rate">Taux horaire ($/h)</Label>
              <Input
                id="edit-rate"
                type="number"
                step="0.01"
                min="0.01"
                value={formRate}
                onChange={(e) => setFormRate(e.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="edit-from">Date de début</Label>
              <Input
                id="edit-from"
                type="date"
                value={formFrom}
                onChange={(e) => setFormFrom(e.target.value)}
              />
            </div>
            <div className="space-y-2">
              <Label htmlFor="edit-to">Date de fin (optionnel)</Label>
              <Input
                id="edit-to"
                type="date"
                value={formTo}
                onChange={(e) => setFormTo(e.target.value)}
              />
              <p className="text-xs text-muted-foreground">
                Laissez vide pour une période en cours.
              </p>
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setEditingRate(null)} disabled={isSaving}>
              Annuler
            </Button>
            <Button onClick={handleEditSave} disabled={isSaving}>
              {isSaving ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Enregistrement...
                </>
              ) : (
                'Mettre à jour'
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Delete Confirmation Dialog */}
      <AlertDialog open={!!deletingRate} onOpenChange={(open) => !open && setDeletingRate(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Supprimer cette période de taux ?</AlertDialogTitle>
            <AlertDialogDescription>
              Êtes-vous sûr de vouloir supprimer la période de{' '}
              <span className="font-medium">{deletingRate?.rate.toFixed(2)} $/h</span>
              {' '}({deletingRate?.effective_from} → {deletingRate?.effective_to}) ?
              Cette action est irréversible.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel disabled={isDeleting}>Annuler</AlertDialogCancel>
            <AlertDialogAction
              onClick={handleDelete}
              disabled={isDeleting}
              className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
            >
              {isDeleting ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Suppression...
                </>
              ) : (
                'Supprimer'
              )}
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  );
}
