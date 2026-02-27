'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from '@/components/ui/select';
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from '@/components/ui/table';
import { Input } from '@/components/ui/input';
import { Textarea } from '@/components/ui/textarea';
import { Label } from '@/components/ui/label';
import { Plus, Pencil, Trash2, Car, Building2, Loader2, RefreshCw } from 'lucide-react';
import { toast } from 'sonner';
import { supabaseClient } from '@/lib/supabase/client';
import type { EmployeeVehiclePeriod } from '@/types/mileage';

interface Employee {
  id: string;
  full_name: string | null;
  email: string | null;
}

type TypeFilter = 'all' | 'personal' | 'company';
type StatusFilter = 'all' | 'active' | 'expired';

function formatDate(dateStr: string): string {
  const d = new Date(dateStr);
  return d.toLocaleDateString('fr-CA', { month: 'short', day: 'numeric', year: 'numeric' });
}

export function VehiclePeriodsTab() {
  // Data state
  const [periods, setPeriods] = useState<EmployeeVehiclePeriod[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Filter state
  const [typeFilter, setTypeFilter] = useState<TypeFilter>('all');
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all');

  // Dialog state (add/edit)
  const [showDialog, setShowDialog] = useState(false);
  const [editingPeriod, setEditingPeriod] = useState<EmployeeVehiclePeriod | null>(null);
  const [isSaving, setIsSaving] = useState(false);

  // Form state
  const [formEmployeeId, setFormEmployeeId] = useState('');
  const [formVehicleType, setFormVehicleType] = useState<'personal' | 'company'>('personal');
  const [formStartedAt, setFormStartedAt] = useState('');
  const [formEndedAt, setFormEndedAt] = useState('');
  const [formNotes, setFormNotes] = useState('');

  // Delete confirmation state
  const [deletingPeriod, setDeletingPeriod] = useState<EmployeeVehiclePeriod | null>(null);
  const [isDeleting, setIsDeleting] = useState(false);

  // Fetch all employee profiles (for dropdown)
  useEffect(() => {
    (async () => {
      const { data } = await supabaseClient
        .from('employee_profiles')
        .select('id, full_name, email')
        .order('full_name');
      if (data) {
        setEmployees(data as Employee[]);
      }
    })();
  }, []);

  // Fetch vehicle periods — uses two separate queries to avoid PostgREST recursive RLS
  const fetchPeriods = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    try {
      // 1. Fetch vehicle periods
      const { data: periodsData, error: periodsError } = await supabaseClient
        .from('employee_vehicle_periods')
        .select('*')
        .order('started_at', { ascending: false });

      if (periodsError) {
        setError(periodsError.message);
        return;
      }

      if (!periodsData || periodsData.length === 0) {
        setPeriods([]);
        return;
      }

      // 2. Fetch employee profiles for all unique employee_ids
      const employeeIds = [...new Set(periodsData.map((p) => p.employee_id).filter(Boolean))];
      const employeeMap: Record<string, { id: string; name: string }> = {};

      if (employeeIds.length > 0) {
        const { data: emps } = await supabaseClient
          .from('employee_profiles')
          .select('id, full_name, email')
          .in('id', employeeIds);

        if (emps) {
          for (const emp of emps) {
            employeeMap[emp.id] = {
              id: emp.id,
              name: emp.full_name || emp.email || 'Inconnu',
            };
          }
        }
      }

      // 3. Merge employee data into periods
      const merged = periodsData.map((period: any) => ({
        ...period,
        employee: employeeMap[period.employee_id] ?? { id: period.employee_id, name: 'Inconnu' },
      }));

      setPeriods(merged as EmployeeVehiclePeriod[]);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Erreur lors du chargement');
    } finally {
      setIsLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchPeriods();
  }, [fetchPeriods]);

  // Summary stats
  const stats = useMemo(() => {
    const total = periods.length;
    const personal = periods.filter((p) => p.vehicle_type === 'personal').length;
    const company = periods.filter((p) => p.vehicle_type === 'company').length;
    const active = periods.filter((p) => !p.ended_at).length;
    const expired = periods.filter((p) => !!p.ended_at).length;
    return { total, personal, company, active, expired };
  }, [periods]);

  // Filter periods
  const filteredPeriods = useMemo(() => {
    let filtered = periods;
    if (typeFilter !== 'all') {
      filtered = filtered.filter((p) => p.vehicle_type === typeFilter);
    }
    if (statusFilter === 'active') {
      filtered = filtered.filter((p) => !p.ended_at);
    } else if (statusFilter === 'expired') {
      filtered = filtered.filter((p) => !!p.ended_at);
    }
    return filtered;
  }, [periods, typeFilter, statusFilter]);

  // Open add dialog
  const openAddDialog = useCallback(() => {
    setEditingPeriod(null);
    setFormEmployeeId('');
    setFormVehicleType('personal');
    setFormStartedAt(new Date().toISOString().split('T')[0]);
    setFormEndedAt('');
    setFormNotes('');
    setShowDialog(true);
  }, []);

  // Open edit dialog
  const openEditDialog = useCallback((period: EmployeeVehiclePeriod) => {
    setEditingPeriod(period);
    setFormEmployeeId(period.employee_id);
    setFormVehicleType(period.vehicle_type);
    setFormStartedAt(period.started_at.split('T')[0]);
    setFormEndedAt(period.ended_at ? period.ended_at.split('T')[0] : '');
    setFormNotes(period.notes || '');
    setShowDialog(true);
  }, []);

  // Save (insert or update)
  const handleSave = useCallback(async () => {
    if (!formEmployeeId) {
      toast.error('Veuillez sélectionner un employé.');
      return;
    }
    if (!formStartedAt) {
      toast.error('Veuillez sélectionner une date de début.');
      return;
    }

    setIsSaving(true);
    try {
      const payload: any = {
        employee_id: formEmployeeId,
        vehicle_type: formVehicleType,
        started_at: formStartedAt,
        ended_at: formEndedAt || null,
        notes: formNotes.trim() || null,
      };

      if (editingPeriod) {
        // Update
        const { error: updateError } = await supabaseClient
          .from('employee_vehicle_periods')
          .update(payload)
          .eq('id', editingPeriod.id);

        if (updateError) {
          if (updateError.message.includes('overlap')) {
            toast.error('Cette période chevauche une période existante pour cet employé.');
          } else {
            toast.error(`Erreur: ${updateError.message}`);
          }
          return;
        }
        toast.success('Période mise à jour avec succès.');
      } else {
        // Insert
        const { error: insertError } = await supabaseClient
          .from('employee_vehicle_periods')
          .insert(payload);

        if (insertError) {
          if (insertError.message.includes('overlap')) {
            toast.error('Cette période chevauche une période existante pour cet employé.');
          } else {
            toast.error(`Erreur: ${insertError.message}`);
          }
          return;
        }
        toast.success('Période ajoutée avec succès.');
      }

      setShowDialog(false);
      fetchPeriods();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Erreur inattendue');
    } finally {
      setIsSaving(false);
    }
  }, [editingPeriod, formEmployeeId, formVehicleType, formStartedAt, formEndedAt, formNotes, fetchPeriods]);

  // Delete
  const handleDelete = useCallback(async () => {
    if (!deletingPeriod) return;

    setIsDeleting(true);
    try {
      const { error: deleteError } = await supabaseClient
        .from('employee_vehicle_periods')
        .delete()
        .eq('id', deletingPeriod.id);

      if (deleteError) {
        toast.error(`Erreur: ${deleteError.message}`);
        return;
      }

      toast.success('Période supprimée avec succès.');
      setDeletingPeriod(null);
      fetchPeriods();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : 'Erreur inattendue');
    } finally {
      setIsDeleting(false);
    }
  }, [deletingPeriod, fetchPeriods]);

  const getEmployeeName = (emp: Employee) => emp.full_name || emp.email || 'Inconnu';

  return (
    <div className="space-y-6">
      {/* Type filter cards */}
      <div className="grid grid-cols-3 gap-4">
        <Card
          className={`cursor-pointer hover:ring-2 hover:ring-primary/20 ${typeFilter === 'all' ? 'ring-2 ring-primary' : ''}`}
          onClick={() => setTypeFilter('all')}
        >
          <CardContent className="pt-4 pb-3 text-center">
            <p className="text-2xl font-bold">{stats.total}</p>
            <p className="text-xs text-muted-foreground">Toutes les périodes</p>
          </CardContent>
        </Card>
        <Card
          className={`cursor-pointer hover:ring-2 hover:ring-blue-500/20 ${typeFilter === 'personal' ? 'ring-2 ring-blue-500' : ''}`}
          onClick={() => setTypeFilter('personal')}
        >
          <CardContent className="pt-4 pb-3 text-center">
            <div className="flex items-center justify-center gap-1.5 mb-0.5">
              <Car className="h-4 w-4 text-blue-600" />
              <p className="text-2xl font-bold text-blue-600">{stats.personal}</p>
            </div>
            <p className="text-xs text-muted-foreground">Personnel</p>
          </CardContent>
        </Card>
        <Card
          className={`cursor-pointer hover:ring-2 hover:ring-purple-500/20 ${typeFilter === 'company' ? 'ring-2 ring-purple-500' : ''}`}
          onClick={() => setTypeFilter('company')}
        >
          <CardContent className="pt-4 pb-3 text-center">
            <div className="flex items-center justify-center gap-1.5 mb-0.5">
              <Building2 className="h-4 w-4 text-purple-600" />
              <p className="text-2xl font-bold text-purple-600">{stats.company}</p>
            </div>
            <p className="text-xs text-muted-foreground">Entreprise</p>
          </CardContent>
        </Card>
      </div>

      {/* Main table card */}
      <Card>
        <CardHeader>
          <div className="flex items-center justify-between">
            <CardTitle className="flex items-center gap-2">
              <Car className="h-5 w-5" />
              Périodes de véhicule
              {typeFilter !== 'all' && (
                <Badge variant="secondary" className="ml-2 text-xs">
                  {typeFilter === 'personal' ? 'Personnel' : 'Entreprise'} ({filteredPeriods.length})
                  <button
                    onClick={(e) => { e.stopPropagation(); setTypeFilter('all'); }}
                    className="ml-1 hover:text-destructive"
                  >
                    &times;
                  </button>
                </Badge>
              )}
              {statusFilter !== 'all' && (
                <Badge variant="secondary" className="ml-2 text-xs">
                  {statusFilter === 'active' ? 'Active' : 'Expirée'} ({filteredPeriods.length})
                  <button
                    onClick={(e) => { e.stopPropagation(); setStatusFilter('all'); }}
                    className="ml-1 hover:text-destructive"
                  >
                    &times;
                  </button>
                </Badge>
              )}
            </CardTitle>
            <div className="flex items-center gap-2">
              {/* Active/Expired toggle */}
              <div className="flex items-center rounded-md border">
                <button
                  className={`px-3 py-1.5 text-xs font-medium rounded-l-md transition-colors ${
                    statusFilter === 'all' ? 'bg-primary text-primary-foreground' : 'hover:bg-muted'
                  }`}
                  onClick={() => setStatusFilter('all')}
                >
                  Tous ({stats.total})
                </button>
                <button
                  className={`px-3 py-1.5 text-xs font-medium border-l transition-colors ${
                    statusFilter === 'active' ? 'bg-primary text-primary-foreground' : 'hover:bg-muted'
                  }`}
                  onClick={() => setStatusFilter('active')}
                >
                  Active ({stats.active})
                </button>
                <button
                  className={`px-3 py-1.5 text-xs font-medium rounded-r-md border-l transition-colors ${
                    statusFilter === 'expired' ? 'bg-primary text-primary-foreground' : 'hover:bg-muted'
                  }`}
                  onClick={() => setStatusFilter('expired')}
                >
                  Expirée ({stats.expired})
                </button>
              </div>

              <Button
                variant="ghost"
                size="sm"
                onClick={fetchPeriods}
                disabled={isLoading}
              >
                <RefreshCw className={`h-4 w-4 ${isLoading ? 'animate-spin' : ''}`} />
              </Button>

              <Button size="sm" onClick={openAddDialog}>
                <Plus className="h-4 w-4 mr-1" />
                Ajouter une période
              </Button>
            </div>
          </div>
        </CardHeader>
        <CardContent>
          {error && (
            <div className="rounded-md bg-red-50 p-3 text-sm text-red-700 mb-4">
              {error}
            </div>
          )}

          {isLoading ? (
            <div className="animate-pulse space-y-3">
              {Array.from({ length: 5 }).map((_, i) => (
                <div key={i} className="flex gap-4 py-3">
                  <div className="h-4 w-28 rounded bg-slate-200" />
                  <div className="h-4 w-20 rounded bg-slate-200" />
                  <div className="h-4 w-24 rounded bg-slate-200" />
                  <div className="h-4 w-24 rounded bg-slate-200" />
                  <div className="h-4 w-32 rounded bg-slate-200" />
                  <div className="h-4 w-16 rounded bg-slate-200" />
                </div>
              ))}
            </div>
          ) : filteredPeriods.length === 0 ? (
            <div className="py-8 text-center text-sm text-muted-foreground">
              {periods.length === 0
                ? 'Aucune période de véhicule trouvée.'
                : 'Aucune période ne correspond aux filtres sélectionnés.'}
            </div>
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Employé</TableHead>
                  <TableHead>Type</TableHead>
                  <TableHead>Début</TableHead>
                  <TableHead>Fin</TableHead>
                  <TableHead>Notes</TableHead>
                  <TableHead className="text-right">Actions</TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {filteredPeriods.map((period) => (
                  <TableRow key={period.id}>
                    <TableCell className="font-medium">
                      {period.employee?.name || 'Inconnu'}
                    </TableCell>
                    <TableCell>
                      {period.vehicle_type === 'personal' ? (
                        <Badge className="bg-blue-100 text-blue-700 hover:bg-blue-100">
                          <Car className="h-3 w-3 mr-1" />
                          Personnel
                        </Badge>
                      ) : (
                        <Badge className="bg-purple-100 text-purple-700 hover:bg-purple-100">
                          <Building2 className="h-3 w-3 mr-1" />
                          Entreprise
                        </Badge>
                      )}
                    </TableCell>
                    <TableCell>{formatDate(period.started_at)}</TableCell>
                    <TableCell>
                      {period.ended_at ? (
                        formatDate(period.ended_at)
                      ) : (
                        <Badge variant="outline" className="text-green-600 border-green-300">
                          En cours
                        </Badge>
                      )}
                    </TableCell>
                    <TableCell className="max-w-[200px] truncate text-muted-foreground">
                      {period.notes || '—'}
                    </TableCell>
                    <TableCell className="text-right">
                      <div className="flex items-center justify-end gap-1">
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => openEditDialog(period)}
                        >
                          <Pencil className="h-3.5 w-3.5" />
                        </Button>
                        <Button
                          variant="ghost"
                          size="sm"
                          onClick={() => setDeletingPeriod(period)}
                          className="text-destructive hover:text-destructive"
                        >
                          <Trash2 className="h-3.5 w-3.5" />
                        </Button>
                      </div>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>

      {/* Add/Edit Dialog */}
      <Dialog open={showDialog} onOpenChange={setShowDialog}>
        <DialogContent className="sm:max-w-[480px]">
          <DialogHeader>
            <DialogTitle>
              {editingPeriod ? 'Modifier la période' : 'Ajouter une période'}
            </DialogTitle>
            <DialogDescription>
              {editingPeriod
                ? 'Modifiez les détails de la période de véhicule.'
                : 'Définissez une nouvelle période de véhicule pour un employé.'}
            </DialogDescription>
          </DialogHeader>

          <div className="space-y-4 py-2">
            {/* Employee select */}
            <div className="space-y-2">
              <Label htmlFor="employee">Employé</Label>
              <Select value={formEmployeeId} onValueChange={setFormEmployeeId}>
                <SelectTrigger id="employee">
                  <SelectValue placeholder="Sélectionner un employé" />
                </SelectTrigger>
                <SelectContent>
                  {employees.map((emp) => (
                    <SelectItem key={emp.id} value={emp.id}>
                      {getEmployeeName(emp)}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>

            {/* Vehicle type */}
            <div className="space-y-2">
              <Label htmlFor="vehicle-type">Type de véhicule</Label>
              <Select value={formVehicleType} onValueChange={(v) => setFormVehicleType(v as 'personal' | 'company')}>
                <SelectTrigger id="vehicle-type">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="personal">
                    <div className="flex items-center gap-2">
                      <Car className="h-3.5 w-3.5 text-blue-600" />
                      Personnel
                    </div>
                  </SelectItem>
                  <SelectItem value="company">
                    <div className="flex items-center gap-2">
                      <Building2 className="h-3.5 w-3.5 text-purple-600" />
                      Entreprise
                    </div>
                  </SelectItem>
                </SelectContent>
              </Select>
            </div>

            {/* Start date */}
            <div className="space-y-2">
              <Label htmlFor="started-at">Date de début</Label>
              <Input
                id="started-at"
                type="date"
                value={formStartedAt}
                onChange={(e) => setFormStartedAt(e.target.value)}
              />
            </div>

            {/* End date */}
            <div className="space-y-2">
              <Label htmlFor="ended-at">Date de fin (optionnel)</Label>
              <Input
                id="ended-at"
                type="date"
                value={formEndedAt}
                onChange={(e) => setFormEndedAt(e.target.value)}
              />
              <p className="text-xs text-muted-foreground">
                Laissez vide pour une période en cours.
              </p>
            </div>

            {/* Notes */}
            <div className="space-y-2">
              <Label htmlFor="notes">Notes (optionnel)</Label>
              <Textarea
                id="notes"
                value={formNotes}
                onChange={(e) => setFormNotes(e.target.value)}
                placeholder="Ex: Honda Civic 2022, plaque ABC-1234"
                rows={3}
              />
            </div>
          </div>

          <DialogFooter>
            <Button variant="outline" onClick={() => setShowDialog(false)} disabled={isSaving}>
              Annuler
            </Button>
            <Button onClick={handleSave} disabled={isSaving}>
              {isSaving ? (
                <>
                  <Loader2 className="h-4 w-4 mr-2 animate-spin" />
                  Enregistrement...
                </>
              ) : editingPeriod ? (
                'Mettre à jour'
              ) : (
                'Ajouter'
              )}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Delete confirmation dialog */}
      <AlertDialog open={!!deletingPeriod} onOpenChange={(open) => !open && setDeletingPeriod(null)}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>Supprimer la période ?</AlertDialogTitle>
            <AlertDialogDescription>
              Êtes-vous sûr de vouloir supprimer cette période de véhicule pour{' '}
              <span className="font-medium">{deletingPeriod?.employee?.name || 'cet employé'}</span> ?
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
